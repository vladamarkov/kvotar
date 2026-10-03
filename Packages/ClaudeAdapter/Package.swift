// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeAdapter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeAdapter", targets: ["ClaudeAdapter"])
    ],
    dependencies: [
        .package(path: "../KvotarCore")
    ],
    targets: [
        .target(name: "ClaudeAdapter", dependencies: ["KvotarCore"]),
        .testTarget(
            name: "ClaudeAdapterTests",
            dependencies: ["ClaudeAdapter", "KvotarCore"],
            resources: [.process("TestFixtures")]
        )
    ]
)
