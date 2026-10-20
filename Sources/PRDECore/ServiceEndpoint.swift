public struct ServiceEndpoint: Equatable, Sendable {
  public enum Destination: Equatable, Sendable {
    case webURL(String)
    case command(String)
  }

  public let name: String
  public let destination: Destination

  // Matches hcloud-prde's proxyEntries. These are references, not health results.
  public static func standard(postgresPort: LocalPort?) -> [Self] {
    var endpoints: [Self] = [
      Self(name: "portal", destination: .webURL("http://localhost:8000")),
      Self(name: "admin", destination: .webURL("http://localhost:14200")),
      Self(name: "api", destination: .webURL("http://localhost:28081")),
      Self(name: "cadence", destination: .webURL("http://localhost:7940/domain/hcp/workflows")),
      Self(name: "jaeger", destination: .webURL("http://localhost:16686")),
      Self(name: "nomad-ui", destination: .webURL("http://localhost:4646")),
      Self(name: "traefik-dashboard", destination: .webURL("http://localhost:28080")),
      Self(name: "localstack", destination: .webURL("http://localhost:4566")),
      Self(name: "dynamodb", destination: .webURL("http://localhost:9002")),
      Self(name: "minio", destination: .webURL("http://localhost:9000")),
      Self(name: "vault", destination: .webURL("http://localhost:8200")),
      Self(name: "consul", destination: .webURL("http://localhost:8500")),
      Self(
        name: "mysql",
        destination: .command("mysql --host=127.0.0.1 --user=root --password=root")),
    ]
    if let postgresPort {
      endpoints.append(
        Self(
          name: "postgres",
          destination: .command(
            "psql 'postgres://postgres:postgres@localhost:\(postgresPort.value)/postgres?sslmode=disable'"
          )))
    }
    return endpoints
  }
}
