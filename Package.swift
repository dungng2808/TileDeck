// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TileDeck",
    platforms: [.macOS("14.2")],
    targets: [
        .target(
            name: "CSMC",
            path: "Sources/CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "FanHelperShared",
            path: "Sources/FanHelperShared"
        ),
        .executableTarget(
            name: "TileDeck",
            dependencies: ["CSMC", "FanHelperShared"],
            path: "Sources/TileDeck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TileDeckHelper",
            dependencies: ["CSMC", "FanHelperShared"],
            path: "Sources/TileDeckHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
