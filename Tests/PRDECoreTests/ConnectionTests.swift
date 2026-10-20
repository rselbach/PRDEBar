import Darwin
import Foundation
import ProcessSupport
import Testing

@testable import PRDECore

@Suite(.serialized)
@MainActor
struct ConnectionTests {
  @Test func portValidation() throws {
    #expect(try LocalPort("5433").value == 5433)
    #expect(try LocalPort("65535").value == 65535)
    for text in ["", "0", "-1", "65536", "5432", "4646", " 5433", "5433 ", "5.4", "Troy Barnes"] {
      #expect(throws: ConnectionFailure.self) { try LocalPort(text) }
    }
  }

  @Test func commandsAndFinderPath() throws {
    let port = try LocalPort("5433")
    #expect(
      Command.proxy(executable: "/opt/homebrew/bin/hcloud").arguments == [
        "prde", "proxy", "--exclude", "postgres",
      ])
    #expect(
      Command.postgres(executable: "/opt/homebrew/bin/hcloud", port: port).arguments == [
        "prde", "connect", "5433:postgres.postgres:postgres",
      ])
    let configuration = ConnectionConfiguration(environment: ["PATH": "/greendale/bin"])
    #expect(configuration.launchEnvironment["PATH", default: ""].contains("/opt/homebrew/bin"))
    #expect(throws: ConnectionFailure.self) {
      try ConnectionConfiguration(executable: "/missing/hcloud").resolveExecutable()
    }
  }

  @Test func startsBothReadyChildrenAndStopsTheirDescendants() async throws {
    try await withFixture { fixture in
      #expect(fixture.controller.state == .stopped)
      try await fixture.controller.start(port: fixture.port)
      #expect(fixture.controller.state == .running)
      let pids = try fixture.recordedPIDs()
      #expect(pids.count == 6)
      #expect(getpgid(pids[0]) != getpgrp())
      try await fixture.controller.stop()
      #expect(fixture.controller.state == .stopped)
      try await fixture.assertGone(pids)
      try await fixture.controller.stop()
      try await fixture.controller.start(port: fixture.port)
      #expect(fixture.controller.state == .running)
    }
  }

  @Test func stopDuringStartupNeverLaunchesPostgres() async throws {
    try await withFixture(mode: "slow-proxy") { fixture in
      let startup = Task { try await fixture.controller.start(port: fixture.port) }
      try await eventually {
        FileManager.default.fileExists(atPath: fixture.path("proxy-descendant"))
      }
      let pids = try fixture.recordedPIDs()
      try await fixture.controller.stop()
      await #expect(throws: CancellationError.self) { try await startup.value }
      #expect(fixture.controller.state == .stopped)
      #expect(!FileManager.default.fileExists(atPath: fixture.path("postgres-parent")))
      try await fixture.assertGone(pids)
    }
  }

  @Test func stopDuringPostgresReadinessCancelsAndCleansUp() async throws {
    try await withFixture(mode: "no-postgres-response") { fixture in
      let startup = Task { try await fixture.controller.start(port: fixture.port) }
      try await eventually {
        FileManager.default.fileExists(atPath: fixture.path("postgres-descendant"))
      }
      let pids = try fixture.recordedPIDs()
      try await fixture.controller.stop()
      await #expect(throws: CancellationError.self) { try await startup.value }
      #expect(fixture.controller.state == .stopped)
      try await fixture.assertGone(pids)
    }
  }

  @Test func rejectsOverlappingStarts() async throws {
    try await withFixture(mode: "slow-proxy") { fixture in
      let startup = Task { try await fixture.controller.start(port: fixture.port) }
      try await eventually { fixture.controller.state == .starting }
      await #expect(throws: ConnectionFailure.self) {
        try await fixture.controller.start(port: fixture.port)
      }
      try await fixture.controller.stop()
      await #expect(throws: CancellationError.self) { try await startup.value }
    }
  }

  @Test func earlyExitAndLargeDiagnosticOutputDoesNotDeadlock() async throws {
    try await withFixture(mode: "early-exit") { fixture in
      do {
        try await fixture.controller.start(port: fixture.port)
        Issue.record("Startup must fail")
      } catch let error as ConnectionFailure {
        #expect(error.message.contains("status 23"))
      }
      #expect(fixture.controller.state == .stopped)
      #expect(!FileManager.default.fileExists(atPath: fixture.path("postgres-parent")))
      try await fixture.assertGone(fixture.recordedPIDs())
    }
  }

  @Test func postgresFailureRollsBackProxy() async throws {
    try await withFixture(mode: "postgres-exit") { fixture in
      do {
        try await fixture.controller.start(port: fixture.port)
        Issue.record("Startup must fail")
      } catch let error as ConnectionFailure {
        #expect(error.message.contains("status 23"))
      }
      #expect(fixture.controller.state == .stopped)
      try await fixture.assertGone(fixture.recordedPIDs())
    }
  }

  @Test func listenerAloneIsNotPostgresReadiness() async throws {
    try await withFixture(mode: "no-postgres-response", timeout: .seconds(1)) { fixture in
      do {
        try await fixture.controller.start(port: fixture.port)
        Issue.record("A listener without a PostgreSQL response must not be ready")
      } catch let error as ConnectionFailure {
        #expect(error.message.contains("PostgreSQL tunnel did not become ready"))
      }
      #expect(fixture.controller.state == .stopped)
      try await fixture.assertGone(fixture.recordedPIDs())
    }
  }

  @Test(arguments: ["proxy", "postgres"])
  func unexpectedCommandExitCleansUpOther(_ role: String) async throws {
    try await withFixture { fixture in
      try await fixture.controller.start(port: fixture.port)
      let pids = try fixture.recordedPIDs()
      try Data().write(to: URL(fileURLWithPath: fixture.path("exit-\(role)")))
      try await eventually { fixture.controller.failure != nil }
      #expect(fixture.controller.state == .stopped)
      #expect(fixture.controller.failure?.message.contains("exited with") == true)
      try await fixture.assertGone(pids)
    }
  }

  @Test func escalatesForDescendantThatIgnoresTermination() async throws {
    try await withFixture(mode: "ignore-term") { fixture in
      try await fixture.controller.start(port: fixture.port)
      let pids = try fixture.recordedPIDs()
      try await fixture.controller.stop()
      #expect(fixture.controller.state == .stopped)
      try await fixture.assertGone(pids)
    }
  }

  @Test(arguments: ["proxy-loopback", "proxy-wildcard", "postgres-loopback", "postgres-wildcard"])
  func occupiedPortIsNotAdoptedOrKilled(_ binding: String) async throws {
    try await withFixture { fixture in
      let listenerPort = binding.hasPrefix("proxy") ? fixture.proxyPort : fixture.port.value
      let fd = socket(AF_INET, SOCK_STREAM, 0)
      guard fd >= 0 else { throw POSIXError(.EMFILE) }
      defer { #expect(close(fd) == 0) }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = listenerPort.bigEndian
      address.sin_addr.s_addr = binding.hasSuffix("wildcard") ? INADDR_ANY : inet_addr("127.0.0.1")
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      #expect(result == 0)
      #expect(listen(fd, 1) == 0)
      #expect(prde_group_listens(getpgrp(), listenerPort) == 1)
      do {
        try await fixture.controller.start(port: fixture.port)
        Issue.record("An unrelated listener must prevent startup")
      } catch let error as ConnectionFailure {
        #expect(error.message.contains("unavailable"))
        let recovery =
          binding.hasPrefix("proxy")
          ? "Stop the existing PRDE proxy yourself"
          : "Choose another PostgreSQL port"
        #expect(error.message.contains(recovery))
      }
      #expect(fixture.controller.state == .stopped)
      #expect(try fixture.recordedPIDs().isEmpty)
      #expect(fcntl(fd, F_GETFD) == 0)
      #expect(prde_port_available(listenerPort) != 0)
    }
  }

  private func withFixture(
    mode: String = "normal", timeout: Duration = .seconds(5),
    body: (Fixture) async throws -> Void
  ) async throws {
    let fixture = try Fixture(mode: mode, timeout: timeout)
    do {
      try await body(fixture)
    } catch {
      try await fixture.cleanUp()
      throw error
    }
    try await fixture.cleanUp()
  }

  private func eventually(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(6))
    while ContinuousClock.now < deadline {
      if try condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw ConnectionFailure("Timed out waiting for the test child process.")
  }
}

@MainActor
private final class Fixture {
  let directory: URL
  let proxyPort: UInt16
  let port: LocalPort
  let controller: ConnectionController

  init(mode: String, timeout: Duration) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PRDEBar-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      proxyPort = try Self.freePort()
      var postgresPort = try Self.freePort()
      while postgresPort == proxyPort { postgresPort = try Self.freePort() }
      port = try LocalPort(String(postgresPort))
      let compiler = Process()
      compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
      let helper = directory.appendingPathComponent("fake-hcloud").path
      guard
        let source = Bundle.module.url(
          forResource: "helper", withExtension: "c", subdirectory: "Fixtures")
      else {
        throw ConnectionFailure("Missing fake hcloud fixture")
      }
      compiler.arguments = ["-Wall", "-Wextra", "-Werror", source.path, "-o", helper]
      try compiler.run()
      compiler.waitUntilExit()
      guard compiler.terminationStatus == 0 else {
        throw ConnectionFailure("Could not compile test helper")
      }
      var environment = ProcessInfo.processInfo.environment
      environment["PRDE_TEST_DIRECTORY"] = directory.path
      environment["PRDE_TEST_PROXY_PORT"] = String(proxyPort)
      environment["PRDE_TEST_MODE"] = mode
      controller = ConnectionController(
        configuration: .init(
          executable: helper, environment: environment, proxyPort: proxyPort,
          readinessTimeout: timeout, shutdownGrace: .milliseconds(150)))
    } catch {
      try FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

  func recordedPIDs() throws -> [pid_t] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix("-parent") || $0.hasSuffix("-child") || $0.hasSuffix("-descendant") }
      .map {
        let text = try String(contentsOfFile: path($0), encoding: .utf8)
        guard let pid = pid_t(text) else { throw ConnectionFailure("Invalid fixture PID") }
        return pid
      }
  }

  func assertGone(_ pids: [pid_t]) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      if pids.allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("Owned descendants remain alive")
  }

  func cleanUp() async throws {
    try await controller.stop()
    try await assertGone(recordedPIDs())
    try FileManager.default.removeItem(at: directory)
  }

  private static func freePort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EMFILE) }
    defer { #expect(close(fd) == 0) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else { throw POSIXError(.EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let status = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard status == 0 else { throw POSIXError(.EINVAL) }
    return UInt16(bigEndian: address.sin_port)
  }
}
