// ChatBotsCore — whether a seat's model can be shown an image
//
// Split out of `Attachments.swift`, which held the document shapes, the intake, the limits and the
// vision gate in one 573-line file. The gate did not change; only the file it lives in did.

import Foundation

// MARK: - Whether a seat can see

/// Whether a seat's model can accept images.
///
/// This gates the image part of the interface: images are offered only when *every*
/// participating seat supports vision, because a discussion where one participant cannot
/// see the picture is worse than being told upfront that images are unavailable. Text
/// documents have no such restriction — extraction is exactly what makes them universally
/// usable.
public enum VisionSupport: String, Sendable, Codable {
    /// The model is known to accept images.
    case supported
    /// The model is known not to, or is a local checkpoint with no vision tower.
    case unsupported
    /// Nothing is known and nothing could be found out, so the interface does not offer it.
    case unknown

    public var allowsImages: Bool { self == .supported }
}

extension AgentSpec {
    /// Model families known to accept images, matched case-insensitively against the model
    /// id. A server does not advertise this through `/v1/models`, so it has to be known — and
    /// when it is not, the answer is `unknown` rather than a hopeful `supported`.
    private static let visionModelMarkers = [
        "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-5", "o3", "o4",
        "claude-3", "claude-4", "claude-opus", "claude-sonnet", "claude-haiku",
        "gemini", "llava", "qwen-vl", "qwen2-vl", "qwen2.5-vl", "qwen3-vl", "qwen3.5-vl",
        "pixtral", "internvl", "minicpm-v", "moondream", "paligemma", "idefics",
        "smolvlm", "gemma-3", "gemma3", "mistral-small-3", "glm-4v", "glm-4.5v",
        // DeepSeek's flash tier sees images. Verified against the live API: asked to name
        // the shape and colour in a test image it answered "Green triangle.", and its own
        // reasoning read "The image shows a green triangle."
        //
        // Deliberately only the flash tier. The pro tier was asked the same question and
        // replied "Cannot see image.", so listing the family would have been wrong in the
        // other direction — it would offer images on a seat that cannot read them.
        "deepseek-flash",
    ]

    /// What this seat's model can accept.
    ///
    /// For a local checkpoint the answer comes from the checkpoint itself, which is
    /// authoritative. For an API seat it comes from a configured override first — since a
    /// server that is *not* serving the model on this disk is the only case where nothing
    /// authoritative exists — then from the checkpoint if it happens to be here, then from
    /// the model id's family.
    public var visionSupport: VisionSupport {
        if backend == .mlx {
            // The local loader only knows text models, so a checkpoint with no vision tower
            // cannot be given an image however it is asked.
            guard ModelStore.declaresVision(for: modelID) == true else { return .unsupported }
            return .supported
        }
        if let override = visionOverride { return override }

        // The endpoint's model comes first, and the order matters.
        //
        // An API seat names the model it is asking the server for, and that name is the only
        // evidence about what will answer. Asking about the local checkpoint instead was the
        // original bug in a different guise: this build's default checkpoint is the same
        // Qwen3.5 whose weights here include a vision tower, so `declaresVision` returned
        // true for a seat pointed at a text-only server model, and images were offered on the
        // strength of weights that seat would never load.
        if !openAI.model.isEmpty {
            let name = openAI.model.lowercased()
            return Self.visionModelMarkers.contains { name.contains($0) } ? .supported : .unknown
        }

        // No endpoint model named, so the checkpoint is the only thing left to go on.
        if let declared = ModelStore.declaresVision(for: modelID) {
            return declared ? .supported : .unsupported
        }
        let name = modelID.lowercased()
        return Self.visionModelMarkers.contains { name.contains($0) } ? .supported : .unknown
    }
}

extension ModelStore {
    /// Whether a checkpoint on disk declares a vision tower.
    ///
    /// Returns nil when the checkpoint is not here, which is different from "no": for an API
    /// seat pointing at a model this app has never seen, the honest answer is that nothing is
    /// known, and the interface should not offer images on a guess.
    public static func declaresVision(for modelID: String, in root: URL? = nil) -> Bool? {
        guard let directory = localCheckpoint(for: modelID, in: root) else { return nil }
        let config = directory.appending(path: "config.json")
        guard let data = try? Data(contentsOf: config),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // The multimodal wrapper puts the vision tower beside the text config; a
        // text-only checkpoint has neither, so its absence is a definite "no".
        if let vision = parsed["vision_config"] as? [String: Any], !vision.isEmpty { return true }
        if parsed["image_token_id"] != nil || parsed["vision_start_token_id"] != nil { return true }
        if let text = parsed["text_config"] as? [String: Any] {
            if let vision = text["vision_config"] as? [String: Any], !vision.isEmpty { return true }
            if text["image_token_id"] != nil { return true }
        }
        return false
    }
}
