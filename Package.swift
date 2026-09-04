// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sprachacus",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Lokale Sprechertrennung (Apache-2.0). Lädt seine Core-ML-Modelle
        // beim ersten Gebrauch einmalig herunter und arbeitet danach offline.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "Sprachacus",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Sprachacus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
