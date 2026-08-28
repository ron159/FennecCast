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
    .library(name: "QueueFeature", targets: ["QueueFeature"]),
    .library(name: "PlaybackFeature", targets: ["PlaybackFeature"]),
    .library(name: "DownloadsFeature", targets: ["DownloadsFeature"]),
    .library(name: "StateSyncFeature", targets: ["StateSyncFeature"]),
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
    .target(
      name: "QueueFeature",
      dependencies: ["CoreContracts", "LocalData"]
    ),
    .target(
      name: "PlaybackFeature",
      dependencies: ["CoreContracts", "LocalData", "QueueFeature"]
    ),
    .target(
      name: "DownloadsFeature",
      dependencies: ["CoreContracts", "LocalData", "PlaybackFeature"]
    ),
    .target(
      name: "StateSyncFeature",
      dependencies: ["CoreContracts", "LocalData"],
      linkerSettings: [.linkedFramework("Security")]
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
    .testTarget(
      name: "QueueFeatureTests",
      dependencies: [
        "CoreContracts",
        "LocalData",
        "QueueFeature",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(
      name: "PlaybackFeatureTests",
      dependencies: [
        "CoreContracts",
        "LocalData",
        "PlaybackFeature",
      ]
    ),
    .testTarget(
      name: "DownloadsFeatureTests",
      dependencies: [
        "CoreContracts",
        "DownloadsFeature",
        "LocalData",
        "PlaybackFeature",
      ]
    ),
    .testTarget(
      name: "StateSyncFeatureTests",
      dependencies: ["CoreContracts", "LocalData", "StateSyncFeature"]
    ),
  ]
)
