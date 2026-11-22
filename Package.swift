// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayIt2",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        // Local OpenTelemetry traces, metrics, and logs.
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "SayIt2",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
