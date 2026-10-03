// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KvotarUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KvotarUI", targets: ["KvotarUI"])
    ],
    dependencies: [
        .package(path: "../KvotarCore")
    ],
    targets: [
        .target(name: "KvotarUI", dependencies: ["KvotarCore"]),
        .testTarget(
            name: "KvotarUITests",
            dependencies: ["KvotarUI", "KvotarCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
