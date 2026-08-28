// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FennecCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CoreContracts", targets: ["CoreContracts"]),
    ],
    targets: [
        .target(name: "CoreContracts"),
        .testTarget(name: "CoreContractsTests", dependencies: ["CoreContracts"]),
    ]
)
