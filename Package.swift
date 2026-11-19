// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayIt2",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SayIt2", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
