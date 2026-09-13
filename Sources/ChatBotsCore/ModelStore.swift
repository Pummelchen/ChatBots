// ChatBotsCore — where model weights live
//
// The app keeps its checkpoints under `models/` in the project folder rather than in the
// shared Hugging Face cache, so a checkout is self-contained and nothing has to be hunted
// down in `~/.cache` to find out what a run used.
//
// Two shapes are understood, because local tooling produces both:
//
//   models/Qwen3.5-4B-MLX-4bit/            ← LM Studio's layout, flat, ready to load
//   models/models--org--name/snapshots/…/  ← the Hugging Face hub cache layout
//
// A directory in the flat form is loaded straight from disk. Anything else falls back to
// the hub, which is pointed at the same folder via `HF_HUB_CACHE` — so a download lands
// in the project too, in the cache layout.

import Foundation

public enum ModelStore {

    /// Environment override for unusual layouts or for tests.
    public static let environmentKey = "CHATBOTS_MODELS_DIR"

    /// Directory holding the on-disk models.
    ///
    /// Resolution order, first match wins:
    ///
    /// 1. `CHATBOTS_MODELS_DIR`.
    /// 2. The directory containing the running bundle, then each ancestor — so a built
    ///    `.app` in `dist/` still finds the checkout's `models/`, and `swift run` from the
    ///    repository root finds it directly.
    /// 3. The current working directory.
    /// 4. A `models/` beside the executable, whether or not it exists yet.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }

        var candidates: [URL] = []
        // Walk up from the bundle location: handles dist/ChatBots.app and .build/release.
        var anchor = bundleURL.standardizedFileURL
        for _ in 0..<6 {
            candidates.append(anchor.appending(path: "models", directoryHint: .isDirectory))
            let parent = anchor.deletingLastPathComponent()
            if parent.path == anchor.path { break }
            anchor = parent
        }
        candidates.append(currentDirectory.appending(path: "models", directoryHint: .isDirectory))
        if let executable = Bundle.main.executableURL {
            candidates.append(
                executable.deletingLastPathComponent()
                    .appending(path: "models", directoryHint: .isDirectory))
        }

        let fileManager = FileManager.default
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return candidate
            }
        }
        // Nothing exists yet: name the one a download should create.
        //
        // Never a path inside an app bundle. The first candidate walking up from `ChatBots.app`
        // is `<bundle>/models`, and `prepare()` creates it — so an installed app on a machine
        // with no checkpoints yet would fetch several gigabytes into its own app and invalidate
        // its signature the first time it launched. That is the same mistake the engine log made,
        // one directory over. A per-user folder is used instead.
        //
        // A checkout is unaffected: its `models/` already exists after `tools/install.sh`, and the
        // loop above returns it before reaching here.
        return RunDirectory.applicationSupport.appending(
            path: "models", directoryHint: .isDirectory)
    }

    /// Create the directory if needed, and make sure the hub downloader writes here.
    ///
    /// `HF_HUB_CACHE` is read by swift-huggingface when it resolves a snapshot rather than
    /// captured at process start, but setting it once at launch is the honest thing to do:
    /// `HF_HOME` is deliberately left alone because that is also where a Hub token lives.
    @discardableResult
    public static func prepare(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let root = directory(environment: environment)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if environment["HF_HUB_CACHE"] == nil {
            setenv("HF_HUB_CACHE", root.path, 1)
        }
        return root
    }

    /// A local directory holding a complete, flat checkpoint for `modelID`, if there is one.
    ///
    /// `modelID` may be a bare name (`Qwen3.5-4B-MLX-4bit`) or a repo id
    /// (`mlx-community/Qwen3.5-4B-MLX-4bit`); both are tried, along with an exact path.
    /// "Complete" means the files a load actually needs — a config, weights, and a
    /// tokenizer — so a partial download is not mistaken for a usable model.
    public static func localCheckpoint(
        for modelID: String,
        in root: URL? = nil
    ) -> URL? {
        let root = root ?? directory()
        let fileManager = FileManager.default
        var candidates: [URL] = []

        // An absolute path given directly.
        if modelID.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: modelID))
        }
        // The repo-id tail, and the id as-is.
        if let tail = modelID.split(separator: "/").last {
            candidates.append(root.appending(path: String(tail), directoryHint: .isDirectory))
        }
        candidates.append(root.appending(path: modelID, directoryHint: .isDirectory))

        for candidate in candidates {
            if isCompleteCheckpoint(candidate, fileManager: fileManager) { return candidate }
        }
        return nil
    }

    /// True when a directory looks like a loadable MLX checkpoint.
    ///
    /// "Complete" has to mean the files a load actually needs, which is why a sharded
    /// checkpoint is no longer accepted on the strength of its index alone. The index is a map
    /// from tensor name to shard file, and an interrupted download leaves it behind with some
    /// or none of the shards it names; `MLXEngine.load` prefers this local hit and never falls
    /// back to the hub, so an index-only directory was listed as available and then hard-failed
    /// at load. This contradicted `localCheckpoint`'s own doc — "a partial download is not
    /// mistaken for a usable model" — and `ModelStoreTests` codified the wrong rule.
    static func isCompleteCheckpoint(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            fileManager.fileExists(atPath: directory.appending(path: "config.json").path),
            fileManager.fileExists(atPath: directory.appending(path: "tokenizer.json").path)
        else { return false }

        // The index, when there is one, is the manifest: the checkpoint is complete only when
        // every shard it names is beside it. A shard fragment on its own must not count as a
        // single blob below — a directory with one of two shards and the index is exactly what
        // an interrupted download leaves, and it ends in `.safetensors` too.
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let indexes = contents.filter { $0.hasSuffix(".safetensors.index.json") }
        if !indexes.isEmpty {
            return indexes.allSatisfy { name in
                shardsArePresent(
                    namedIn: directory.appending(path: name), beside: directory,
                    fileManager: fileManager)
            }
        }

        // No index, so a single weight blob is complete on its own.
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Whether every shard an index names is a file beside it.
    ///
    /// `weight_map` is the Hugging Face index format: tensor name to shard filename. A shard
    /// has to be a plain `.safetensors` direct child, so an index cannot make a checkpoint look
    /// complete by naming a file somewhere else. An index that cannot be read, that has no
    /// `weight_map`, or whose map is empty proves nothing, and the honest answer then is no.
    private static func shardsArePresent(
        namedIn index: URL, beside directory: URL, fileManager: FileManager
    ) -> Bool {
        guard let data = try? Data(contentsOf: index),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = root["weight_map"] as? [String: String],
            !weightMap.isEmpty
        else { return false }

        return Set(weightMap.values).allSatisfy { shard in
            shard.hasSuffix(".safetensors") && !shard.contains("/")
                && fileManager.fileExists(atPath: directory.appending(path: shard).path)
        }
    }

    /// The project directory, found by walking up from the working directory or the bundle
    /// until a `Package.swift` or a `models/` folder appears.
    ///
    /// Public so anything that needs a project-relative file — the local secrets file, for
    /// instance — resolves it the same way the models folder is resolved, rather than each
    /// caller inventing its own rule.
    public static func projectRoot() -> URL? {
        var candidates: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let bundle = Bundle.main.bundleURL as URL? {
            candidates.append(bundle)
            candidates.append(bundle.deletingLastPathComponent())
        }
        let manager = FileManager.default
        for start in candidates {
            var directory = start
            for _ in 0..<6 {
                if manager.fileExists(atPath: directory.appending(path: "Package.swift").path)
                    || manager.fileExists(atPath: directory.appending(path: "models").path)
                {
                    return directory
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }

    /// The context window declared by a checkpoint's own config, if that checkpoint is on
    /// disk. `max_position_embeddings` lives under `text_config` for the Qwen 3.5 wrapper
    /// and at the top level for a plain text model.
    public static func declaredContextWindow(for modelID: String, in root: URL? = nil) -> Int? {
        guard let directory = localCheckpoint(for: modelID, in: root) else { return nil }
        let config = directory.appending(path: "config.json")
        guard let data = try? Data(contentsOf: config),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let textConfig = root["text_config"] as? [String: Any]
        for key in ["max_position_embeddings", "max_sequence_length"] {
            let nested = (textConfig?[key] as? NSNumber)?.intValue
            let flat = (root[key] as? NSNumber)?.intValue
            if let value = nested ?? flat, value > 0 { return value }
        }
        return nil
    }

    /// The loaded checkpoints on disk, for display.
    public static func availableCheckpoints(in root: URL? = nil) -> [String] {
        let root = root ?? directory()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { isCompleteCheckpoint($0) }
            .map(\.lastPathComponent)
            .sorted()
    }
}
