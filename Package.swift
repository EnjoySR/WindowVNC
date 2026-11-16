// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowVNC",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .executableTarget(
            name: "WindowVNCApp",
            dependencies: ["CZlib"],
            path: "Sources/WindowVNCApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
