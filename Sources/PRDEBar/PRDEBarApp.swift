import AppKit
import Combine
import PRDECore
import Sparkle
import SwiftUI

@main
struct PRDEBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra {
      ConnectionView(controller: delegate.controller, updater: delegate.updaterController.updater)
    } label: {
      StatusLabel(controller: delegate.controller)
    }
    .menuBarExtraStyle(.window)
  }
}

private struct StatusLabel: View {
  @ObservedObject var controller: ConnectionController

  var body: some View {
    let state = controller.state
    let color: Color =
      switch state {
      case .running: .green
      case .reconnecting: .orange
      default: .red
      }
    let status = "PRDE: \(state.rawValue)"

    Image(size: CGSize(width: 38, height: 18), label: Text(status)) { context in
      context.draw(
        Text("PRDE")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(color),
        at: CGPoint(x: 19, y: 9), anchor: .center)
    }
    .renderingMode(.original)
    .help(status)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let controller = ConnectionController()
  let updaterController = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      do {
        try await controller.stop()
        sender.reply(toApplicationShouldTerminate: true)
      } catch {
        let alert = NSAlert()
        alert.messageText = "Could not stop the local PRDE connection"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Keep PRDEBar open")
        alert.runModal()
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }
}

// The macOS 27 SDK also exports a State macro missing from command-line tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

private struct ConnectionView: View {
  @ObservedObject var controller: ConnectionController
  let updater: SPUUpdater
  @ViewState private var canCheckForUpdates = false
  @AppStorage("postgresPort") private var savedPort = "5433"
  @ViewState private var error: ConnectionFailure? = nil
  @ViewState private var portText = "5433"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("PRDEBar").font(.headline)
        Spacer()
        if controller.state == .starting || controller.state == .reconnecting
          || controller.state == .stopping
        {
          ProgressView().controlSize(.small)
        }
        if controller.state == .running {
          Circle()
            .fill(.green)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
        }
        Text(controller.state.rawValue)
          .foregroundStyle(controller.state == .running ? .primary : .secondary)
      }

      Text("Local connection to your existing PRDE")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      HStack {
        Text("Postgres port")
        Spacer()
        TextField("5433", text: $portText)
          .textFieldStyle(.roundedBorder)
          .frame(width: 90)
          .disabled(controller.state != .stopped)
          .onSubmit { start() }
          .accessibilityLabel("Postgres local port")
      }
      Text("Port 5432 stays reserved for local PostgreSQL.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Button(action: toggleConnection) {
        Text(controller.state == .stopped ? "Start PRDE" : "Stop PRDE")
          .frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .disabled(controller.state == .stopping)

      Divider()
      ServicesView(postgresPort: validatedPort, error: $error)
      Divider()
      Text("Stops local tunnels, not cloud resources.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("Check for Updates…") { updater.checkForUpdates() }
          .disabled(!canCheckForUpdates)
        Spacer()
        Button("Quit") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
      }
    }
    .padding(20)
    .frame(width: 360)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { portText = savedPort }
    .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheckForUpdates = $0 }
    .onReceive(controller.$failure) { failure in
      if let failure { error = failure }
    }
    .alert(
      "PRDE local connection",
      isPresented: Binding(
        get: { error != nil }, set: { if !$0 { error = nil } }
      )
    ) {
      Button("OK", role: .cancel) { error = nil }
    } message: {
      Text(error?.localizedDescription ?? "")
    }
  }

  private var validatedPort: LocalPort? {
    do {
      return try LocalPort(portText)
    } catch {
      return nil
    }
  }

  private func toggleConnection() {
    if controller.state == .stopped {
      start()
      return
    }
    Task {
      do {
        try await controller.stop()
      } catch {
        self.error = ConnectionFailure(error.localizedDescription)
      }
    }
  }

  private func start() {
    guard controller.state == .stopped else { return }
    Task {
      do {
        let port = try LocalPort(portText)
        savedPort = String(port.value)
        try await controller.start(port: port)
      } catch is CancellationError {
        return
      } catch {
        self.error = ConnectionFailure(error.localizedDescription)
      }
    }
  }
}
