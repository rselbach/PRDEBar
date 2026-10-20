import Darwin
import Foundation
import ProcessSupport

@MainActor
final class OwnedProcess {
  let pid: pid_t
  let command: Command
  private(set) var exitStatus: Int32?

  init(command: Command, environment: [String: String]) throws {
    self.command = command
    let arguments = [command.executable] + command.arguments
    let variables = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    let argv = arguments.map { strdup($0) }
    let envp = variables.map { strdup($0) }
    defer {
      for value in argv + envp { free(value) }
    }
    guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
      throw ConnectionFailure("Not enough memory to launch hcloud.")
    }
    var child: pid_t = 0
    let error = prde_spawn(command.executable, argv + [nil], envp + [nil], &child)
    guard error == 0 else {
      throw ConnectionFailure(
        "Could not launch hcloud: \(String(cString: strerror(error))). Check that hcloud is installed and executable."
      )
    }
    pid = child
  }

  func pollExit() throws -> Int32? {
    if let exitStatus { return exitStatus }
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    if result == pid {
      exitStatus = status
      return status
    }
    if result == -1 && errno != EINTR {
      throw ConnectionFailure(
        "Could not read hcloud process status: \(String(cString: strerror(errno))).")
    }
    return nil
  }

  var groupExists: Bool {
    kill(-pid, 0) == 0 || errno == EPERM
  }

  func signal(_ signal: Int32) throws {
    guard kill(-pid, signal) == 0 || errno == ESRCH else {
      throw ConnectionFailure(
        "Could not stop the owned hcloud process group \(pid): \(String(cString: strerror(errno))). Try Stop PRDE again."
      )
    }
  }

  func ownsListener(port: UInt16) -> Bool {
    prde_group_listens(pid, port) == 1
  }

  func exitFailure(status: Int32) -> ConnectionFailure {
    let signal = status & 0x7f
    let reason = signal == 0 ? "status \((status >> 8) & 0xff)" : "signal \(signal)"
    let invocation = (["hcloud"] + command.arguments).joined(separator: " ")
    return ConnectionFailure(
      "\(invocation) exited with \(reason). Check your hcloud/Doormat login and conflicting local connections in Terminal. Run that command there for diagnostics. PRDEBar does not capture CLI output."
    )
  }
}
