// swift-tools-version: 6.2

import PackageDescription

// GRDB only supports SQLCipher through CocoaPods. To use it with SwiftPM, the
// GRDB sources are vendored as a git submodule (Vendor/GRDB.swift, pinned to a
// release tag) and compiled here against Zetetic's official SQLCipher package.
//
// GRDB's SwiftPM build imports a C module named `GRDBSQLite` (the system SQLite
// plus a few helpers). Sources/GRDBSQLite replaces it with the same helpers on
// top of SQLCipher, so the GRDB sources compile unmodified.
//
// Nothing else in the app may link the system SQLite (libsqlite3) directly.

let package = Package(
    name: "CortexCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v26),
    ],
    products: [
        .library(name: "CortexCore", targets: ["CortexCore"]),
        // The knowledge base's MCP server (docs/modules/KNOWLEDGE.md, "The MCP
        // server"), linked by the cortex-mcp tool target of the Xcode project and
        // embedded in the app.
        .library(name: "CortexMCP", targets: ["CortexMCP"]),
        .executable(name: "cortex-mcp", targets: ["cortex-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.19.0"),
    ],
    targets: [
        .target(
            name: "GRDBSQLite",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ]),
        .target(
            name: "GRDB",
            dependencies: ["GRDBSQLite"],
            path: "Vendor/GRDB.swift/GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [
                .define("SQLITE_HAS_CODEC"),
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
            ]),
        .target(
            name: "CortexCore",
            dependencies: ["GRDB"],
            resources: [.process("Emoji/emoji.json")]),
        .target(
            name: "CortexMCP",
            dependencies: ["CortexCore"]),
        .executableTarget(
            name: "cortex-mcp",
            dependencies: ["CortexCore", "CortexMCP"]),
        .testTarget(
            name: "CortexCoreTests",
            dependencies: ["CortexCore", "GRDB"],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "CortexMCPTests",
            dependencies: ["CortexMCP", "CortexCore"]),
    ],
    swiftLanguageModes: [.v6]
)
