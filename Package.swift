// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FrugaRelay",
  platforms: [.iOS("16.4")],
  products: [
    .library(name: "FrugaRelay", targets: ["FrugaRelay", "FrugaRelayCore"])
  ],
  // The two library targets build in Swift 6 language mode. The test targets
  // stay on v5: XCTest's `await fulfillment(of:)` takes a nonisolated `self`,
  // which a `@MainActor` XCTestCase cannot pass in Swift 6 mode.
  targets: [
    .target(name: "FrugaRelayCore"),
    .target(name: "FrugaRelay", dependencies: ["FrugaRelayCore"]),
    .testTarget(
      name: "FrugaRelayCoreTests",
      dependencies: ["FrugaRelayCore"],
      path: "Tests",
      exclude: ["FrugaRelayTests"],
      sources: ["FrugaRelayCoreTests"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // Same `path: "Tests"` + `sources:` shape as the core target, so this one
    // can copy the shared `Tests/Fixtures` directory too (a resource path may
    // not escape its target's directory).
    .testTarget(
      name: "FrugaRelayTests",
      dependencies: ["FrugaRelay", "FrugaRelayCore"],
      path: "Tests",
      exclude: ["FrugaRelayCoreTests"],
      sources: ["FrugaRelayTests"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
