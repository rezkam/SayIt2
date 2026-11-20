// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayIt2",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        // Crash and error reports.
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.35.0"),
    ],
    targets: [
        .executableTarget(
            name: "SayIt2",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
