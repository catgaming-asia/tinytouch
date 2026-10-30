// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TinyTouchManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TinyTouchManager", targets: ["TinyTouchManager"]),
        .executable(name: "tinytouch", targets: ["tinytouch"]),
    ],
    targets: [
        .target(name: "TinyTouchCore"),
        .executableTarget(name: "TinyTouchManager", dependencies: ["TinyTouchCore"]),
        .executableTarget(name: "tinytouch", dependencies: ["TinyTouchCore"]),
        .testTarget(name: "TinyTouchCoreTests", dependencies: ["TinyTouchCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
