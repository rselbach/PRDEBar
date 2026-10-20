import Foundation
import Testing

@testable import PRDECore

struct ServiceEndpointTests {
  @Test func standardCatalogMatchesProxyReferences() throws {
    let endpoints = ServiceEndpoint.standard(postgresPort: try LocalPort("5433"))
    #expect(
      endpoints.map(\.name) == [
        "portal", "admin", "api", "cadence", "jaeger", "nomad-ui", "traefik-dashboard",
        "localstack", "dynamodb", "minio", "vault", "consul", "mysql", "postgres",
      ])
    #expect(
      endpoints.map(\.destination) == [
        .webURL("http://localhost:8000"),
        .webURL("http://localhost:14200"),
        .webURL("http://localhost:28081"),
        .webURL("http://localhost:7940/domain/hcp/workflows"),
        .webURL("http://localhost:16686"),
        .webURL("http://localhost:4646"),
        .webURL("http://localhost:28080"),
        .webURL("http://localhost:4566"),
        .webURL("http://localhost:9002"),
        .webURL("http://localhost:9000"),
        .webURL("http://localhost:8200"),
        .webURL("http://localhost:8500"),
        .command("mysql --host=127.0.0.1 --user=root --password=root"),
        .command("psql 'postgres://postgres:postgres@localhost:5433/postgres?sslmode=disable'"),
      ])
  }

  @Test func webURLsAreValidLocalReferences() throws {
    let endpoints = ServiceEndpoint.standard(postgresPort: try LocalPort("5433"))
    var webCount = 0
    for endpoint in endpoints {
      switch endpoint.destination {
      case .webURL(let text):
        webCount += 1
        let url = try #require(URL(string: text))
        #expect(url.scheme == "http")
        #expect(url.host == "localhost")
        #expect(url.port != nil)
        #expect(url.user == nil)
        #expect(url.password == nil)
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        #expect(url.path == (endpoint.name == "cadence" ? "/domain/hcp/workflows" : ""))
      case .command:
        #expect(["mysql", "postgres"].contains(endpoint.name))
      }
    }
    #expect(webCount == 12)
  }

  @Test(arguments: ["5433", "15433", "65535"])
  func postgresUsesChosenPortAndShellQuotesTheURI(_ text: String) throws {
    let endpoints = ServiceEndpoint.standard(postgresPort: try LocalPort(text))
    let postgres = try #require(endpoints.last)
    #expect(postgres.name == "postgres")
    #expect(
      postgres.destination
        == .command(
          "psql 'postgres://postgres:postgres@localhost:\(text)/postgres?sslmode=disable'"))
  }

  @Test(arguments: ["", "0", "5432", "4646", "65536", "Troy Barnes"])
  func invalidPortLeavesOtherReferencesUsableWithoutFallback(_ text: String) throws {
    let port: LocalPort?
    do {
      port = try LocalPort(text)
      Issue.record("Invalid input must not produce a validated port")
    } catch {
      port = nil
    }
    let endpoints = ServiceEndpoint.standard(postgresPort: port)
    #expect(endpoints.count == 13)
    #expect(!endpoints.contains { $0.name == "postgres" })
    #expect(
      endpoints == Array(ServiceEndpoint.standard(postgresPort: try LocalPort("15433")).dropLast()))
  }

  @Test func missingPortNeverReusesAnEarlierCommand() throws {
    let chosen = ServiceEndpoint.standard(postgresPort: try LocalPort("15433"))
    let invalid = ServiceEndpoint.standard(postgresPort: nil)
    let edited = ServiceEndpoint.standard(postgresPort: try LocalPort("25433"))
    #expect(chosen.last?.name == "postgres")
    #expect(invalid.last?.name == "mysql")
    #expect(
      edited.last?.destination
        == .command(
          "psql 'postgres://postgres:postgres@localhost:25433/postgres?sslmode=disable'"))
    #expect(chosen.last != edited.last)
  }
}
