// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "WhoopProtocol", targets: ["WhoopProtocol"]),
        .executable(name: "whoop-decode", targets: ["whoop-decode"]),
        .executable(name: "whoop-optical-experiment", targets: ["whoop-optical-experiment"]),
    ],
    targets: [
        .target(
            name: "WhoopProtocol",
            resources: [.process("Resources/whoop_protocol.json")]
        ),
        .executableTarget(
            name: "whoop-decode",
            dependencies: ["WhoopProtocol"]
        ),
        .executableTarget(
            name: "whoop-optical-experiment",
            dependencies: ["WhoopProtocol"]
        ),
        .testTarget(
            name: "WhoopProtocolTests",
            dependencies: ["WhoopProtocol"],
            resources: [.process("Resources")]
        ),
    ]
)
