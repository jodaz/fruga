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
    .testTarget(
      name: "FrugaRelayTests",
      dependencies: ["FrugaRelay", "FrugaRelayCore"],
      path: "Tests/FrugaRelayTests",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
