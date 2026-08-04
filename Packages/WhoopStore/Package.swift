// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopStore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "WhoopStore", targets: ["WhoopStore"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../OuraProtocol"),
        // Supply-chain: pinned EXACT (not `from:`) so a clean resolve can't auto-pull a newer —
        // potentially compromised — upstream release. Must match the same exact version in the
        // other Packages/*/Package.swift and project.yml, or SPM resolution fails. Bump deliberately.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(
            name: "WhoopStore",
            dependencies: [
                "WhoopProtocol",
                "OuraProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "WhoopStoreTests",
            dependencies: ["WhoopStore", "WhoopProtocol", "OuraProtocol"],
            // schema_oracle.json — the shared Room<->GRDB schema fixture (#775). Byte-identical twin at
            // android/app/src/test/resources/schema_oracle.json; SchemaOracleTests asserts they match.
            resources: [.process("Resources")]
        ),
    ]
)
