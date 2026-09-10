// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FrugaRelay",
  platforms: [.iOS(.v16)],
  products: [
    .library(name: "FrugaRelay", targets: ["FrugaRelay", "FrugaRelayCore"])
  ],
  targets: [
    .target(name: "FrugaRelayCore"),
    .target(name: "FrugaRelay", dependencies: ["FrugaRelayCore"]),
    .testTarget(
      name: "FrugaRelayCoreTests",
      dependencies: ["FrugaRelayCore"],
      path: "Tests",
      exclude: ["FrugaRelayTests"],
      sources: ["FrugaRelayCoreTests"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "FrugaRelayTests",
      dependencies: ["FrugaRelay"],
      path: "Tests/FrugaRelayTests"
    )
  ]
)
