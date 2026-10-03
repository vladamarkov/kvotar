// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexAdapter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexAdapter", targets: ["CodexAdapter"])
    ],
    dependencies: [
        .package(path: "../KvotarCore")
    ],
    targets: [
        .target(name: "CodexAdapter", dependencies: ["KvotarCore"]),
        .testTarget(
            name: "CodexAdapterTests",
            dependencies: ["CodexAdapter", "KvotarCore"],
            resources: [.process("TestFixtures")]
        )
    ]
)
