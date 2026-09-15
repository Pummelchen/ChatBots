// swift-tools-version: 6.4
// ChatBots — two local LLMs talking to each other on a Mac (MLX / Apple Silicon).
//
// Layout:
//   ChatBotsCore — engine-agnostic chat domain, MLX engine adapter, Tavily tools, orchestrator
//   ChatBots     — SwiftUI application (two horizontal panes + control bar)
//   chatbots-cli — headless runner used to verify the engine without the GUI

import PackageDescription

// The build settings every target this package owns is compiled with.
//
// * Swift 6 language mode, stated rather than inferred from the tools version. The engine is
//   actor-isolated throughout, so this describes the code rather than aspiring to it — and it
//   is what makes the compiler check that claim.
// * Warnings are errors. The baseline is zero compiler warnings in both the products and the
//   test target, so a new warning is a regression and the build should say so. This is the
//   gate AUDIT task A03 was opened to add: without it a fresh warning is invisible.
//
// `treatAllWarnings(as: .error)` rather than `.unsafeFlags(["-warnings-as-errors"])`. Both
// reach swiftc with the same flag, but this is the documented SwiftPM setting, it applies to
// exactly the targets it is attached to — so a warning inside a dependency cannot fail this
// build — and it does not mark the package with `unsafeFlags`. `unsafeFlags` is legal for a
// root application package that is never consumed as a dependency (which is the caveat the
// SwiftPM manual attaches to it), but it is unnecessary here. Either way the flag lives in the
// manifest, so no build command can bypass it: `swift build`, `swift build --build-tests`,
// `swift test` and Xcode all get it.
let ownedTargetSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "ChatBots",
    platforms: [
        // macOS 26 because WebTransport requires it. See the wiki for what that costs:
        // anyone on Sonoma or Sequoia can no longer run the app.
        .macOS(.v26)
    ],
    products: [
        .library(name: "ChatBotsCore", targets: ["ChatBotsCore"]),
        .executable(name: "ChatBots", targets: ["ChatBots"]),
        .executable(name: "chatbots-cli", targets: ["ChatBotsCLI"]),
        .executable(name: "chatbots-probe", targets: ["ChatBotsProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
        // The released 3.x line decouples downloading and tokenization; these two
        // provide the concrete hub client and tokenizer the macros in MLXHuggingFace wrap.
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // The channel between the desktop app and the engine. Internal only: the website is
        // served by Caddy, which does not speak WebTransport.
        //
        // Pinned exactly rather than by range: this transport is the security boundary for the
        // engine connection, and two behaviours this app depends on are tied to its exact
        // version. 1.3.6 passed the ceiling to `NetworkListener.newConnectionLimit`, a budget
        // for the listener's whole life on macOS 26 rather than a concurrency cap, so a fresh
        // engine stopped accepting after sixteen connects and never recovered; 1.3.7 counts
        // in-flight sessions and returns the slot instead. And the client still subscribes by
        // sending a first frame, because an inbound stream is not delivered until its first
        // byte arrives — the trigger documented in `WebTransportClient.connect()`. A range
        // would let a future release move either behaviour under this app without the version
        // changing to notice. See the wiki tracker.
        //
        // `exact:` is the labelled form of the old `.exact("1.3.7")` requirement — the same
        // pin, and the only spelling of it that is not deprecated in tools-version 6.3, which
        // would otherwise make this manifest itself a warning.
        .package(url: "https://github.com/Pummelchen/WebTransport.git", exact: "1.3.7"),
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
                .product(name: "WebTransport", package: "WebTransport"),
            ],
            path: "Sources/ChatBotsCore",
            swiftSettings: ownedTargetSettings
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
            swiftSettings: ownedTargetSettings
        ),

        // MARK: - Headless verification

        .executableTarget(
            name: "ChatBotsCLI",
            dependencies: ["ChatBotsCore"],
            path: "Sources/ChatBotsCLI",
            swiftSettings: ownedTargetSettings
        ),

        // The app's own client, runnable from a terminal. The desktop app is a poor instrument
        // for a transport failure — the symptom is an empty thread — so this exists to make the
        // same connection observable as text, and repeatable in a loop.
        .executableTarget(
            name: "ChatBotsProbe",
            dependencies: ["ChatBotsCore"],
            path: "Sources/ChatBotsProbe",
            swiftSettings: ownedTargetSettings
        ),

        // MARK: - Tests

        .testTarget(
            name: "ChatBotsCoreTests",
            dependencies: ["ChatBotsCore"],
            path: "Tests/ChatBotsCoreTests",
            swiftSettings: ownedTargetSettings
        ),
    ]
)
