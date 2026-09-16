// ChatBotsCore — the checkpoints this app offers
//
// A seat's model is an MLX checkpoint, and any repository id works: `--model-a` has always taken one
// and the hub client fetches whatever it names. What did not exist was a list — a place that says
// which checkpoints have actually been tried with this app, what they are, and how big they are — so
// choosing one meant knowing a repository id by heart and typing it exactly.
//
// This is that list. It is deliberately short and curated rather than a search: every entry has been
// loaded and generated text through this app's own engine, which is the only claim worth making here.
// An id that is not in the list still works; the catalogue is a set of known-good names, not an
// allow-list.
//
// A checkpoint that is not in the local `models/` directory is downloaded on first use, so the size
// hint is what a user is agreeing to when they pick one. `ModelStore` and the hub client decide where
// it lands.

import Foundation

/// One checkpoint this app knows about.
public struct ModelChoice: Sendable, Hashable, Identifiable {
    /// The Hugging Face repository id, which is what a load actually needs.
    public let id: String
    /// What to show for it. Short enough for a menu, specific enough to tell the variants apart.
    public let name: String
    /// One line for a tooltip or a list: what it is and what it costs.
    public let summary: String
    /// The short names accepted on the command line, matched without regard to case.
    ///
    /// An alias is a convenience, never the identity: whatever it resolves to is the repository id,
    /// and that is what is stored and sent over the wire.
    public let aliases: [String]
    /// The download size, from the publisher's own file listing. Nil when it is not known.
    public let approximateBytes: Int64?

    public init(
        id: String,
        name: String,
        summary: String,
        aliases: [String],
        approximateBytes: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.aliases = aliases
        self.approximateBytes = approximateBytes
    }

    /// The size as a person reads it, or nil when it is unknown.
    public var sizeLabel: String? {
        approximateBytes.map { bytes in
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useGB]
            return formatter.string(fromByteCount: bytes)
        }
    }
}

/// The checkpoints this app offers, and how a short name becomes a repository id.
public enum ModelCatalog {

    /// Everything that has been loaded through this app's own engine.
    ///
    /// Adding an entry is a claim that it has been measured, not that a repository exists: each of
    /// these has been loaded here, and driven through a real turn where the machine could hold it.
    /// Each was measured on that machine; what the 9B costs on an 8 GB Mac is in its entry below.
    public static let choices: [ModelChoice] = [
        ModelChoice(
            id: AgentSpec.defaultModelID,
            name: "Qwen3.5 4B",
            summary: "The checkpoint this app ships with. 4-bit, uniform, ~3 GB.",
            aliases: ["qwen", "qwen4b", "default"],
            approximateBytes: 3_034_300_695
        ),
        ModelChoice(
            id: "TheWirelessPhoenix/Huihui-Qwen3.5-4B-abliterated-oQ4e",
            name: "Huihui Qwen3.5 4B (abliterated)",
            summary: "Abliterated 4B, mixed-precision oQ 4/5/6-bit by TheWirelessPhoenix. ~3.2 GB.",
            aliases: ["huihui4b", "huihui-4b"],
            approximateBytes: 3_161_408_513
        ),
        ModelChoice(
            id: "TheWirelessPhoenix/Huihui-Qwen3.5-9B-abliterated-oQ4e",
            name: "Huihui Qwen3.5 9B (abliterated)",
            summary: "Abliterated 9B, mixed-precision oQ 4/5/6-bit. Slower and hungrier. ~6 GB.",
            aliases: ["huihui9b", "huihui-9b"],
            approximateBytes: 6_039_658_651
        ),
    ]

    /// The entry for an identifier, whether it is a repository id or an alias.
    public static func choice(for identifier: String) -> ModelChoice? {
        let wanted = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        return choices.first { choice in
            choice.id.lowercased() == wanted
                || choice.aliases.contains { $0.lowercased() == wanted }
        }
    }

    /// The repository id an identifier names.
    ///
    /// An alias becomes its repository id; anything else is returned unchanged, because the catalogue
    /// is a convenience and not a restriction. Whitespace is trimmed so a value pasted from a browser
    /// works.
    public static func resolve(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return choice(for: trimmed)?.id ?? trimmed
    }
}
