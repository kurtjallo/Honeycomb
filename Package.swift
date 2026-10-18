// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Honeycomb",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Honeycomb", targets: ["Honeycomb"]),
        .executable(name: "ToneHelper", targets: ["ToneHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        // No text normalization: Honeycomb only uses speech-to-text and VAD.
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.7", traits: []),
        // 3.31.4 is the newest that builds with Swift 6.2. 3.32 needs Xcode 26.4 (Swift 6.3).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
    ],
    targets: [
        .executableTarget(
            name: "Honeycomb",
            dependencies: ["HoneycombCore"]
        ),
        .target(
            name: "HoneycombCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(name: "ToneHelper"),
        .testTarget(
            name: "HoneycombCoreTests",
            dependencies: ["HoneycombCore"]
        ),
    ]
)
