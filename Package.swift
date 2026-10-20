// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PRDEBar",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "PRDEBar", targets: ["PRDEBar"])],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
  ],
  targets: [
    .target(name: "ProcessSupport"),
    .target(name: "PRDECore", dependencies: ["ProcessSupport"]),
    .executableTarget(
      name: "PRDEBar",
      dependencies: ["PRDECore", .product(name: "Sparkle", package: "Sparkle")],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
    .testTarget(
      name: "PRDECoreTests", dependencies: ["PRDECore", "ProcessSupport"],
      resources: [.copy("Fixtures")]),
  ]
)
