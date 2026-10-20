import Combine
import Darwin
import Foundation
import ProcessSupport
import os

@MainActor
public final class ConnectionController: ObservableObject {
  @Published public private(set) var state: ConnectionState = .stopped
  @Published public private(set) var failure: ConnectionFailure?

  private let configuration: ConnectionConfiguration
  private let logger = Logger(subsystem: "dev.rselbach.PRDEBar", category: "connection")
  private var children: [OwnedProcess] = []
  private var startup: Task<Void, Error>?
  private var shutdown: Task<Void, Error>?
  private var monitor: Task<Void, Never>?
  private static let readinessSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 0.75
    configuration.timeoutIntervalForResource = 1
    configuration.connectionProxyDictionary = [:]
    return URLSession(configuration: configuration)
  }()

  public init(configuration: ConnectionConfiguration = .init()) {
    self.configuration = configuration
  }

  public func start(port: LocalPort) async throws {
    guard state == .stopped, startup == nil, shutdown == nil else {
      throw ConnectionFailure(
        "A local connection is already active or changing. Stop it before starting again.")
    }
    state = .starting
    failure = nil
    let task = Task {
      do {
        try await establish(port: port)
        try Task.checkCancellation()
        state = .running
        beginMonitoring()
      } catch {
        do {
          try await cleanUp()
          if state != .stopping { state = .stopped }
        } catch let cleanupError {
          state = .cleanupFailed
          throw ConnectionFailure(
            "\(error.localizedDescription) Cleanup also failed. \(cleanupError.localizedDescription)"
          )
        }
        throw error
      }
    }
    startup = task
    defer { startup = nil }
    try await task.value
  }

  public func stop() async throws {
    if let shutdown {
      try await shutdown.value
      return
    }
    guard state != .stopped else { return }
    state = .stopping
    monitor?.cancel()
    monitor = nil
    let pendingStartup = startup
    pendingStartup?.cancel()
    let task = Task {
      // Startup owns its rollback. Wait before touching the same children.
      if let pendingStartup { _ = await pendingStartup.result }
      try await cleanUp()
      state = .stopped
    }
    shutdown = task
    defer { shutdown = nil }
    do {
      try await task.value
    } catch {
      state = .cleanupFailed
      throw error
    }
  }

  private func establish(port: LocalPort) async throws {
    let executable = try configuration.resolveExecutable()
    try requireAvailable(configuration.proxyPort)
    try requireAvailable(port.value)
    try Task.checkCancellation()
    let proxy = try OwnedProcess(
      command: .proxy(executable: executable), environment: configuration.launchEnvironment)
    children.append(proxy)
    try await waitUntilReady(name: "Nomad proxy") {
      guard proxy.ownsListener(port: self.configuration.proxyPort) else { return false }
      guard await Self.nomadReady(port: self.configuration.proxyPort) else { return false }
      return proxy.ownsListener(port: self.configuration.proxyPort)
    }
    try Task.checkCancellation()
    try requireAvailable(port.value)
    let postgres = try OwnedProcess(
      command: .postgres(executable: executable, port: port),
      environment: configuration.launchEnvironment)
    children.append(postgres)
    try await waitUntilReady(name: "PostgreSQL tunnel") {
      guard proxy.ownsListener(port: self.configuration.proxyPort),
        postgres.ownsListener(port: port.value),
        await Self.nomadReady(port: self.configuration.proxyPort)
      else { return false }
      let ready = await Task.detached { prde_postgres_ready(port.value) == 1 }.value
      return ready && proxy.ownsListener(port: self.configuration.proxyPort)
        && postgres.ownsListener(port: port.value)
    }
  }

  private func requireAvailable(_ port: UInt16) throws {
    let error = prde_port_available(port)
    guard error == 0 else {
      let recovery =
        port == configuration.proxyPort
        ? "Stop the existing PRDE proxy yourself before starting PRDEBar."
        : "Choose another PostgreSQL port or stop the process using this port."
      throw ConnectionFailure(
        "Local port \(port) is unavailable: \(String(cString: strerror(error))). \(recovery) PRDEBar will not adopt or stop other processes."
      )
    }
  }

  private func waitUntilReady(name: String, probe: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: configuration.readinessTimeout)
    while clock.now < deadline {
      try Task.checkCancellation()
      try checkChildren()
      let ready = await probe()
      try Task.checkCancellation()
      try checkChildren()
      if ready { return }
      try await Task.sleep(for: .milliseconds(150))
    }
    throw ConnectionFailure(
      "The \(name) did not become ready within \(configuration.readinessTimeout). Check your hcloud/Doormat login, remote PRDE health, and local port conflicts in Terminal. The local processes will be stopped."
    )
  }

  private static func nomadReady(port: UInt16) async -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/v1/status/leader") else { return false }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0.75)
    request.httpMethod = "GET"
    do {
      let (data, response) = try await readinessSession.data(for: request)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
        return false
      }
      return !(try JSONDecoder().decode(String.self, from: data)).isEmpty
    } catch {
      // Connection refusal and incomplete responses are expected during startup.
      return false
    }
  }

  private func checkChildren() throws {
    for child in children {
      if let status = try child.pollExit() { throw child.exitFailure(status: status) }
    }
  }

  private func beginMonitoring() {
    monitor = Task {
      do {
        while !Task.isCancelled {
          try checkChildren()
          try await Task.sleep(for: .milliseconds(250))
        }
      } catch is CancellationError {
        return
      } catch {
        logger.error("An owned PRDE command exited unexpectedly. Cleaning up the local connection.")
        var message = error.localizedDescription
        do {
          try await stop()
        } catch {
          logger.error("Local PRDE cleanup failed.")
          message += " Cleanup also failed. \(error.localizedDescription)"
        }
        failure = ConnectionFailure(message)
      }
    }
  }

  private func cleanUp() async throws {
    guard !children.isEmpty else { return }
    var errors: [String] = []
    for child in children {
      do { try child.signal(SIGTERM) } catch { errors.append(error.localizedDescription) }
    }
    await waitForGroups(until: ContinuousClock.now.advanced(by: configuration.shutdownGrace))
    for child in children where child.groupExists {
      do { try child.signal(SIGKILL) } catch { errors.append(error.localizedDescription) }
    }
    await waitForGroups(until: ContinuousClock.now.advanced(by: .seconds(2)))
    var remaining: [OwnedProcess] = []
    for child in children {
      do { _ = try child.pollExit() } catch { errors.append(error.localizedDescription) }
      if child.groupExists { remaining.append(child) }
    }
    children = remaining
    if !remaining.isEmpty {
      errors.append("Owned local processes are still present. Try Stop PRDE again before quitting.")
    }
    if !errors.isEmpty { throw ConnectionFailure(errors.joined(separator: "\n")) }
  }

  private func waitForGroups(until deadline: ContinuousClock.Instant) async {
    while ContinuousClock.now < deadline {
      for child in children {
        do { _ = try child.pollExit() } catch {
          logger.error("Could not reap an owned PRDE command during cleanup.")
        }
      }
      if children.allSatisfy({ !$0.groupExists }) { return }
      // Cleanup must finish even if the startup task was cancelled.
      await Task.detached {
        do { try await Task.sleep(for: .milliseconds(50)) } catch {
          self.logger.error("Cleanup wait was interrupted.")
        }
      }.value
    }
  }
}
