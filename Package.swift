// swift-tools-version:5.9
//
// Liric — lightweight lyrics companion for VOX Player.
//
// Two ways to build:
//   1. `open Package.swift` (or `swift run Liric`) — quickest; runs the app as a bare executable.
//   2. `xcodegen generate && open Liric.xcodeproj` — real .app bundle with Info.plist + entitlements
//      (needed for a proper Automation permission prompt and for distribution). See project.yml.
//
// Zero third-party dependencies: SQLite3, AVFoundation, NaturalLanguage and CoreFoundation's
// tokenizer all ship with macOS.

import PackageDescription

let package = Package(
    name: "Liric",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Liric", targets: ["Liric"]),
        .library(name: "LiricCore", targets: ["LiricCore"]),
    ],
    targets: [
        .target(
            name: "LiricCore",
            path: "Sources/LiricCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Liric",
            dependencies: ["LiricCore"],
            path: "Sources/Liric"
        ),
        .testTarget(
            name: "LiricCoreTests",
            dependencies: ["LiricCore"],
            path: "Tests/LiricCoreTests"
        ),
    ]
)
