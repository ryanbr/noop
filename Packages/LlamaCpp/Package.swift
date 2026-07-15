// swift-tools-version:5.9
import PackageDescription

// Wraps the pinned llama.cpp prebuilt xcframework. URL + checksum are pinned EXACTLY (supply-chain:
// a clean resolve can't pull a different artifact). To bump llama.cpp, update BOTH fields together.
let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17)],
    products: [.library(name: "LlamaCpp", targets: ["LlamaCpp"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b9947/llama-b9947-xcframework.zip",
            checksum: "56047fa796b6e156d890a65e8811261572c3bb63811341ea6a84735253feba9d"
        ),
        .target(name: "LlamaCpp", dependencies: ["llama"], path: "Sources/LlamaCpp")
    ]
)
