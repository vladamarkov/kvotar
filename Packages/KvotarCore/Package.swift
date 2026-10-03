// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KvotarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KvotarCore", targets: ["KvotarCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "KvotarCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "KvotarCoreTests",
            dependencies: [
                "KvotarCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
