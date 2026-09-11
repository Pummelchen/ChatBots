// swift-tools-version: 6.3
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
                // The vision side of the same library: a checkpoint with a vision tower is
                // loaded through this so images can actually be turned into model input.
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/ChatBotsCore",
            // Swift 6 language mode, stated rather than inferred from the tools version. The
            // engine is actor-isolated throughout, so this describes the code rather than
            // aspiring to it — and it is what makes the compiler check that claim.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - GUI

        .executableTarget(
            name: "ChatBots",
            dependencies: ["ChatBotsCore"],
            path: "Sources/ChatBotsApp",
            // The icon master travels with the app (usable at runtime, e.g. an About
            // panel). The bundle's actual icon is the .icns, installed by
            // tools/make-app.sh as CFBundleIconFile.
            resources: [.copy("Resources/AppIcon-1024.png")],
            // Swift 6 language mode, stated rather than inferred from the tools version. The
            // engine is actor-isolated throughout, so this describes the code rather than
            // aspiring to it — and it is what makes the compiler check that claim.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Headless verification

        .executableTarget(
            name: "ChatBotsCLI",
            dependencies: ["ChatBotsCore"],
            path: "Sources/ChatBotsCLI",
            // Swift 6 language mode, stated rather than inferred from the tools version. The
            // engine is actor-isolated throughout, so this describes the code rather than
            // aspiring to it — and it is what makes the compiler check that claim.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests

        .testTarget(
            name: "ChatBotsCoreTests",
            dependencies: ["ChatBotsCore"],
            path: "Tests/ChatBotsCoreTests",
            // Swift 6 language mode, stated rather than inferred from the tools version. The
            // engine is actor-isolated throughout, so this describes the code rather than
            // aspiring to it — and it is what makes the compiler check that claim.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
