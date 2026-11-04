// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSTPClient",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SSTPClient", targets: ["SSTPClient"]),
    ],
    targets: [
        // Pure logic, no AppKit: status parsing, settings validation,
        // AppleScript escaping, reconnect policy. Covered by tests.
        .target(name: "SSTPCore"),
        .executableTarget(name: "SSTPClient", dependencies: ["SSTPCore"]),
        .testTarget(name: "SSTPCoreTests", dependencies: ["SSTPCore"]),
    ]
)
