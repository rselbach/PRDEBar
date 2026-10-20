// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PRDEBar",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "PRDEBar", targets: ["PRDEBar"])],
  targets: [
    .target(name: "ProcessSupport"),
    .target(name: "PRDECore", dependencies: ["ProcessSupport"]),
    .executableTarget(name: "PRDEBar", dependencies: ["PRDECore"]),
    .testTarget(
      name: "PRDECoreTests", dependencies: ["PRDECore", "ProcessSupport"],
      resources: [.copy("Fixtures")]),
  ]
)
