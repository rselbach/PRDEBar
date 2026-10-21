import Foundation

public struct LocalPort: Equatable, Sendable {
  public let value: UInt16

  public init(_ text: String) throws {
    guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
      let value = UInt16(text), value > 0
    else {
      throw ConnectionFailure("Enter a PostgreSQL port from 1 to 65535.")
    }
    guard value != 5432 else {
      throw ConnectionFailure(
        "Port 5432 is reserved for your local PostgreSQL. Choose another port, such as 5433.")
    }
    guard value != 4646 else {
      throw ConnectionFailure(
        "Port 4646 is used by the PRDE Nomad proxy. Choose another PostgreSQL port.")
    }
    self.value = value
  }
}

public enum ConnectionState: String, Sendable {
  case stopped = "Stopped"
  case starting = "Starting"
  case running = "Running"
  case reconnecting = "Reconnecting"
  case stopping = "Stopping"
  case cleanupFailed = "Cleanup needed"
}

public struct ConnectionFailure: LocalizedError, Equatable, Sendable {
  public let message: String
  public var errorDescription: String? { message }

  public init(_ message: String) {
    self.message = message
  }
}

public struct Command: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]

  public static func proxy(executable: String) -> Self {
    Self(executable: executable, arguments: ["prde", "proxy", "--exclude", "postgres"])
  }

  public static func postgres(executable: String, port: LocalPort) -> Self {
    Self(
      executable: executable,
      arguments: ["prde", "connect", "\(port.value):postgres.postgres:postgres"])
  }
}

public struct ConnectionConfiguration: Sendable {
  public var executable: String?
  public var environment: [String: String]
  public var proxyPort: UInt16
  public var readinessTimeout: Duration
  public var shutdownGrace: Duration

  public init(
    executable: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    proxyPort: UInt16 = 4646,
    readinessTimeout: Duration = .seconds(45),
    shutdownGrace: Duration = .seconds(2)
  ) {
    self.executable = executable
    self.environment = environment
    self.proxyPort = proxyPort
    self.readinessTimeout = readinessTimeout
    self.shutdownGrace = shutdownGrace
  }

  var launchEnvironment: [String: String] {
    var result = environment
    let paths = [
      environment["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
      "/usr/sbin", "/sbin",
    ]
    result["PATH"] = paths.filter { !$0.isEmpty }.joined(separator: ":")
    return result
  }

  func resolveExecutable() throws -> String {
    if let executable {
      guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw ConnectionFailure(
          "hcloud is not executable at \(executable). Install hcloud before starting PRDE.")
      }
      return executable
    }
    for directory in (launchEnvironment["PATH"] ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("hcloud").path
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    throw ConnectionFailure(
      "hcloud was not found in PATH or the usual Homebrew locations. Install hcloud and log in with Doormat in Terminal."
    )
  }
}
