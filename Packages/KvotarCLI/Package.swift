// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KvotarCLI",
    platforms: [.macOS(.v14)],
    products: [
        // Canonical Pre-Alpha command is `kvotar` (Brief line 717); the binary name is the
        // product name, so the executable target keeps its module name while shipping `kvotar`.
        .executable(name: "kvotar", targets: ["KvotarCLI"])
    ],
    dependencies: [
        .package(path: "../KvotarCore"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // STEP_74: the bundle importer owns an analysis database of its own — a corpus of tester
        // bundles the app never opens — so it talks to SQLite directly rather than through
        // `SQLiteStore`, whose schema and migrator belong to the app. Already in the resolved graph
        // via KvotarCore; see the carve-out in PATTERNS.md.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "KvotarCLI",
            dependencies: [
                "KvotarCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]),
        // STEP_74: the first tests in this package. They cover `import` — the one command that
        // creates a file rather than only reading one — and build their bundle fixtures by hand,
        // because the shapes that matter (capture off, no manifest, a colliding table name) are
        // ones no machine here can produce on demand.
        .testTarget(
            name: "KvotarCLITests",
            dependencies: [
                "KvotarCLI",
                .product(name: "GRDB", package: "GRDB.swift")
            ])
    ]
)
