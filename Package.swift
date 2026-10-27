// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TileDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CSMC",
            path: "Sources/CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "TileDeck",
            dependencies: ["CSMC"],
            path: "Sources/TileDeck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
