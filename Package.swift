// swift-tools-version: 6.2
// ChatBots — two local LLMs talking to each other on a Mac (MLX / Apple Silicon).
//
// Layout:
//   ChatBotsCore — engine-agnostic chat domain, MLX engine adapter, Tavily tools, orchestrator
//   ChatBots     — SwiftUI application (two horizontal panes + control bar)
//   chatbots-cli — headless runner used to verify the engine without the GUI

import PackageDescription

let package = Package(
    name: "ChatBots",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ChatBotsCore", targets: ["ChatBotsCore"]),
        .executable(name: "ChatBots", targets: ["ChatBots"]),
        .executable(name: "chatbots-cli", targets: ["ChatBotsCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
        // The released 3.x line decouples downloading and tokenization; these two
        // provide the concrete hub client and tokenizer the macros in MLXHuggingFace wrap.
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // MARK: - Core

        .target(
            name: "ChatBotsCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/ChatBotsCore"
        ),

        // MARK: - GUI

        .executableTarget(
            name: "ChatBots",
            dependencies: ["ChatBotsCore"],
            path: "Sources/ChatBotsApp"
        ),

        // MARK: - Headless verification

        .executableTarget(
            name: "ChatBotsCLI",
            dependencies: ["ChatBotsCore"],
            path: "Sources/ChatBotsCLI"
        ),

        // MARK: - Tests

        .testTarget(
            name: "ChatBotsCoreTests",
            dependencies: ["ChatBotsCore"],
            path: "Tests/ChatBotsCoreTests"
        ),
    ]
)
