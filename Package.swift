// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayIt2",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates: the one third-party dependency, chosen deliberately (see AGENTS.md).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "SayIt2",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
