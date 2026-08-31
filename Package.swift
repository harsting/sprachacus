// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sprachacus",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Sprachacus",
            path: "Sources/Sprachacus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
