import AppKit
import PRDECore
import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

struct ServicesView: View {
  let postgresPort: LocalPort?
  @Binding var error: ConnectionFailure?
  @ViewState private var copiedEndpoint: ServiceEndpoint? = nil

  var body: some View {
    let endpoints = ServiceEndpoint.standard(postgresPort: postgresPort)
    let copied = copiedEndpoint.flatMap { endpoints.contains($0) ? $0 : nil }

    HStack {
      Menu("Services") {
        ForEach(endpoints, id: \.name) { endpoint in
          Button(endpoint.name) { copy(endpoint) }
            .help("Copy \(endpoint.name) to the clipboard")
        }
        if postgresPort == nil {
          Button("postgres (enter a valid port)") {}
            .disabled(true)
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Select a service to copy its URL or database command")

      Text(copied.map { "\($0.name) copied" } ?? " ")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityHidden(copied == nil)
    }
  }

  private func copy(_ endpoint: ServiceEndpoint) {
    let text: String
    switch endpoint.destination {
    case .webURL(let value), .command(let value): text = value
    }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else {
      copiedEndpoint = nil
      error = ConnectionFailure("Could not copy \(endpoint.name) to the clipboard.")
      return
    }
    copiedEndpoint = endpoint
  }
}
