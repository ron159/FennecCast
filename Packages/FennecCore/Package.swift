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
    .library(name: "LocalData", targets: ["LocalData"]),
    .library(name: "FeedLibrary", targets: ["FeedLibrary"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/groue/GRDB.swift.git",
      exact: "7.11.1"
    )
  ],
  targets: [
    .target(name: "CoreContracts"),
    .target(
      name: "LocalData",
      dependencies: [
        "CoreContracts",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .target(
      name: "FeedLibrary",
      dependencies: ["CoreContracts", "LocalData"]
    ),
    .testTarget(name: "CoreContractsTests", dependencies: ["CoreContracts"]),
    .testTarget(
      name: "LocalDataTests",
      dependencies: [
        "CoreContracts",
        "LocalData",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(
      name: "FeedLibraryTests",
      dependencies: ["CoreContracts", "FeedLibrary", "LocalData"]
    ),
  ]
)
