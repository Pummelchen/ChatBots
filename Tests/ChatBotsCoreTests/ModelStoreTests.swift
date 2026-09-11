// ChatBotsCoreTests — where models are stored and how a checkpoint is found

import ChatBotsCore
import Foundation
import Testing

@Suite("ModelStore", .serialized)
struct ModelStoreTests {

    /// Build a directory that looks like a loadable checkpoint.
    private func makeCheckpoint(
        at url: URL,
        weights: String = "model.safetensors",
        includeConfig: Bool = true,
        includeTokenizer: Bool = true
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if includeConfig {
            try Data("{}".utf8).write(to: url.appending(path: "config.json"))
        }
        if includeTokenizer {
            try Data("{}".utf8).write(to: url.appending(path: "tokenizer.json"))
        }
        try Data().write(to: url.appending(path: weights))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-modelstore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("The environment override wins, and expands a tilde")
    func environmentOverride() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = ModelStore.directory(
            environment: [ModelStore.environmentKey: root.path],
            bundleURL: URL(fileURLWithPath: "/tmp/whatever"),
            currentDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(resolved.path == root.path)

        let tilde = ModelStore.directory(
            environment: [ModelStore.environmentKey: "~/models-here"],
            bundleURL: URL(fileURLWithPath: "/tmp/whatever"),
            currentDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(tilde.path.hasPrefix(NSHomeDirectory()))
        #expect(!tilde.path.contains("~"))
    }

    @Test("A models folder beside the running bundle is preferred over the working directory")
    func bundleRelativeWins() throws {
        let projectRoot = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        // A built .app in dist/, as make-app.sh produces.
        let dist = projectRoot.appending(path: "dist", directoryHint: .isDirectory)
        let app = dist.appending(path: "ChatBots.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let models = projectRoot.appending(path: "models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)

        let resolved = ModelStore.directory(
            environment: [:], bundleURL: app, currentDirectory: URL(fileURLWithPath: "/elsewhere"))
        #expect(resolved.path == models.path, "walking up from dist/ChatBots.app should find the checkout's models/")
    }

    @Test("With nothing on disk yet, it names the folder a download would create")
    func fallsBackToAName() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appending(path: "empty", directoryHint: .isDirectory)

        let resolved = ModelStore.directory(
            environment: [:], bundleURL: bundle, currentDirectory: root)
        #expect(resolved.lastPathComponent == "models")
        // It must not invent a path it cannot write to.
        #expect(resolved.path.hasPrefix(root.path))
    }

    @Test("A complete flat checkpoint is found by repo id or by bare name")
    func findsFlatCheckpoint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCheckpoint(at: root.appending(path: "Qwen3.5-4B-MLX-4bit", directoryHint: .isDirectory))

        let byRepoID = ModelStore.localCheckpoint(
            for: "mlx-community/Qwen3.5-4B-MLX-4bit", in: root)
        let byName = ModelStore.localCheckpoint(for: "Qwen3.5-4B-MLX-4bit", in: root)

        #expect(byRepoID?.lastPathComponent == "Qwen3.5-4B-MLX-4bit")
        #expect(byName == byRepoID)
    }

    @Test("A partial download is not mistaken for a usable checkpoint")
    func rejectsIncompleteCheckpoints() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Weights and config but no tokenizer.
        try makeCheckpoint(
            at: root.appending(path: "no-tokenizer", directoryHint: .isDirectory),
            includeTokenizer: false)
        // Config and tokenizer but no weights.
        try makeCheckpoint(
            at: root.appending(path: "no-weights", directoryHint: .isDirectory),
            weights: "nothing.txt")
        // Config only.
        try makeCheckpoint(
            at: root.appending(path: "config-only", directoryHint: .isDirectory),
            weights: "readme.txt", includeTokenizer: false)

        #expect(ModelStore.localCheckpoint(for: "no-tokenizer", in: root) == nil)
        #expect(ModelStore.localCheckpoint(for: "no-weights", in: root) == nil)
        #expect(ModelStore.localCheckpoint(for: "config-only", in: root) == nil)
        #expect(ModelStore.availableCheckpoints(in: root).isEmpty)
    }

    @Test("A sharded checkpoint counts as complete")
    func shardedCheckpoint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCheckpoint(
            at: root.appending(path: "sharded", directoryHint: .isDirectory),
            weights: "model.safetensors.index.json")

        #expect(ModelStore.localCheckpoint(for: "sharded", in: root) != nil)
    }

    @Test("An unknown model id resolves to nothing rather than a wrong directory")
    func unknownID() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCheckpoint(at: root.appending(path: "Present", directoryHint: .isDirectory))

        #expect(ModelStore.localCheckpoint(for: "some/Other-Model", in: root) == nil)
    }

    @Test("The available checkpoints list is complete and sorted")
    func listsCheckpoints() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCheckpoint(at: root.appending(path: "B-model", directoryHint: .isDirectory))
        try makeCheckpoint(at: root.appending(path: "A-model", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(
            at: root.appending(path: "not-a-model", directoryHint: .isDirectory),
            withIntermediateDirectories: true)

        #expect(ModelStore.availableCheckpoints(in: root) == ["A-model", "B-model"])
    }

    @Test("prepare() creates the folder and points the hub cache at it")
    func prepareCreatesAndRedirects() throws {
        let root = try temporaryRoot()
        // Tests run in parallel in one process, so the environment is saved and restored
        // rather than cleared — clearing it would corrupt a neighbouring test's state.
        let previous = getenv("HF_HUB_CACHE").map { String(cString: $0) }
        defer {
            try? FileManager.default.removeItem(at: root)
            if let previous { setenv("HF_HUB_CACHE", previous, 1) } else { unsetenv("HF_HUB_CACHE") }
        }
        unsetenv("HF_HUB_CACHE")
        // Also pass an environment without it, so the check does not depend on the
        // process-global value at all.
        let prepared = ModelStore.prepare(environment: [ModelStore.environmentKey: root.path])

        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(atPath: prepared.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        // Model downloads must land in the project, not in the shared cache.
        #expect(String(cString: getenv("HF_HUB_CACHE")) == root.path)
    }

    @Test("prepare() does not override an explicitly set hub cache")
    func prepareRespectsExistingCache() throws {
        let root = try temporaryRoot()
        let elsewhere = try temporaryRoot()
        let previous = getenv("HF_HUB_CACHE").map { String(cString: $0) }
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
            if let previous { setenv("HF_HUB_CACHE", previous, 1) } else { unsetenv("HF_HUB_CACHE") }
        }
        setenv("HF_HUB_CACHE", elsewhere.path, 1)

        // `prepare` with an environment that already names a cache must leave it alone,
        // even though the process-global value is whatever the previous test left.
        _ = ModelStore.prepare(environment: [
            ModelStore.environmentKey: root.path,
            "HF_HUB_CACHE": elsewhere.path,
        ])
        #expect(String(cString: getenv("HF_HUB_CACHE")) == elsewhere.path)
    }
}
