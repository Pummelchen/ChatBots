// ChatBotsCoreTests — a partial sharded download is not a usable checkpoint (audit A53)
//
// `isCompleteCheckpoint` accepted a `.safetensors.index.json` as proof of weights without
// checking that any shard it names exists. An interrupted multi-shard download therefore left a
// directory that `localCheckpoint` called complete and `availableCheckpoints` listed, while
// `MLXEngine.load` — which prefers the local hit and never falls back to the hub — hard-failed
// on it. That contradicted `localCheckpoint`'s own doc: "a partial download is not mistaken for
// a usable model".
//
// The index is a map from tensor name to shard filename, so "complete" now means every shard the
// index names is beside it. These tests build the shapes a download can be interrupted into.

import ChatBotsCore
import Foundation
import Testing

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "chatbots-modelstore-audit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Write the files a checkpoint needs, plus the weights shape a test asks for.
private func checkpoint(
    at url: URL, index: String? = nil, shards: [String] = [], blob: Bool = false
) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: url.appending(path: "config.json"))
    try Data("{}".utf8).write(to: url.appending(path: "tokenizer.json"))
    if blob { try Data().write(to: url.appending(path: "model.safetensors")) }
    if let index {
        try Data(index.utf8).write(to: url.appending(path: "model.safetensors.index.json"))
    }
    for shard in shards {
        let destination = url.appending(path: shard)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: destination)
    }
}

/// A two-shard index naming `first` and `second`.
private let twoShardIndex = """
    {"metadata": {"total_size": 2},
     "weight_map": {"model.embed": "first.safetensors", "model.head": "second.safetensors"}}
    """

@Suite("A sharded checkpoint is complete only with its shards", .serialized)
struct AuditModelStoreTests {

    @Test("An index with none of its shards is not a usable checkpoint")
    func indexAloneIsNotComplete() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try checkpoint(at: root.appending(path: "partial"), index: twoShardIndex)

        #expect(ModelStore.localCheckpoint(for: "partial", in: root) == nil)
        #expect(ModelStore.availableCheckpoints(in: root).isEmpty)
    }

    @Test("An index missing one of its shards is not a usable checkpoint")
    func oneMissingShardIsNotComplete() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try checkpoint(
            at: root.appending(path: "half"), index: twoShardIndex,
            shards: ["first.safetensors"])

        #expect(ModelStore.localCheckpoint(for: "half", in: root) == nil)
    }

    @Test("An index with every shard beside it is a usable checkpoint")
    func completeShardSetIsFound() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try checkpoint(
            at: root.appending(path: "whole"), index: twoShardIndex,
            shards: ["first.safetensors", "second.safetensors"])

        #expect(ModelStore.localCheckpoint(for: "whole", in: root)?.lastPathComponent == "whole")
        #expect(ModelStore.availableCheckpoints(in: root) == ["whole"])
    }

    @Test("An index that cannot be read proves nothing")
    func unreadableIndexIsNotComplete() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try checkpoint(at: root.appending(path: "junk"), index: "not json at all")

        #expect(ModelStore.localCheckpoint(for: "junk", in: root) == nil)
    }

    /// A shard has to be a plain `.safetensors` file beside the index. An index naming a file
    /// outside the directory — even one that exists — must not make the checkpoint look whole.
    @Test("An index naming a shard outside the directory is not complete")
    func shardOutsideTheDirectoryIsNotComplete() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appending(path: "sibling.safetensors"))
        try checkpoint(
            at: root.appending(path: "escape"),
            index: #"{"weight_map": {"model.embed": "../sibling.safetensors"}}"#)

        #expect(ModelStore.localCheckpoint(for: "escape", in: root) == nil)
    }

    @Test("A single-blob checkpoint is still complete without an index")
    func blobCheckpointIsStillComplete() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try checkpoint(at: root.appending(path: "flat"), blob: true)

        #expect(ModelStore.localCheckpoint(for: "flat", in: root)?.lastPathComponent == "flat")
    }
}
