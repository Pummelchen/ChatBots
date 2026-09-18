// ChatBotsCore — which parameters an endpoint accepts, and what a model is called
//
// Split out of `OpenAIResponsesClient.swift`, which held the client, its endpoint configuration, the
// compatibility and naming tables and its session wrapper in one 860-line file. Nothing changed but
// which file each one lives in.

import Foundation

/// keys: OpenAI itself validates strictly and rejects anything outside its schema, while
/// local engines (LM Studio) accept extensions. Sending `top_k` to OpenAI is a 400, so the
/// choice has to be explicit rather than assumed.
public enum APICompatibility: String, Sendable, Codable, CaseIterable, Identifiable {
    /// OpenAI proper: only parameters in the published schema.
    case strict
    /// Local engines: also send `top_k`, `min_p` and `repetition_penalty`.
    case extended

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .strict: "OpenAI (strict)"
        case .extended: "Extended (LM Studio et al.)"
        }
    }

    /// A sensible default from the URL: anything that is not OpenAI is probably local.
    ///
    /// Matched on the *host*, not the whole string. `contains` made
    /// `https://api.openai.com.evil.test` and `https://evil.test/?x=api.openai.com` infer
    /// `.strict`, silently dropping `top_k`/`min_p`/`repetition_penalty` for an endpoint that
    /// was not OpenAI at all — the same mistake `BuiltInKeys.key` refuses to make about a key's
    /// destination. Azure serves OpenAI from a per-resource subdomain
    /// (`<name>.openai.azure.com`), which the suffix test allows with a label boundary.
    public static func inferred(fromBaseURL baseURL: String) -> APICompatibility {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host?.lowercased() else { return .extended }
        if ["api.openai.com", "openai.azure.com", "openrouter.ai"].contains(host) { return .strict }
        if host.hasSuffix(".openai.azure.com") || host.hasSuffix(".openrouter.ai") { return .strict }
        return .extended
    }
}

/// Human names for model identifiers.
///
/// The point is that a model should be called what its maker calls it, not what its API slug
/// happens to be. A server reports `deepseek-v4-pro`; the product is DeepSeek V4.1 Flash. Left
/// to the raw id, every screen in the app shows the slug, and the same model gets a different
/// label depending on which server it was reached through.
public enum ModelNames {

    /// Known identifiers and the name to show for them, longest match first so a more
    /// specific entry wins over a general one.
    private static let table: [(match: String, name: String)] = [
        ("deepseek-v4-pro", "DeepSeek V4.1 Pro"),
        ("deepseek-v4.1-pro", "DeepSeek V4.1 Pro"),
        ("deepseek-v4-flash", "DeepSeek V4.1 Flash"),
        ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash"),
        ("deepseek-v4", "DeepSeek V4.1"),
        ("deepseek-v3", "DeepSeek V3"),
        ("deepseek-reasoner", "DeepSeek Reasoner"),
        ("deepseek-chat", "DeepSeek Chat"),
        ("gpt-4o-mini", "GPT-4o mini"),
        ("gpt-4o", "GPT-4o"),
        ("gpt-4.1-mini", "GPT-4.1 mini"),
        ("gpt-4.1", "GPT-4.1"),
        ("claude-opus-4", "Claude Opus 4"),
        ("claude-sonnet-4", "Claude Sonnet 4"),
        ("claude-haiku-4", "Claude Haiku 4"),
        ("claude-3-5-sonnet", "Claude 3.5 Sonnet"),
        ("claude-3-5-haiku", "Claude 3.5 Haiku"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
        ("gemini-2.5-flash", "Gemini 2.5 Flash"),
    ]

    /// The name to show for a model identifier.
    ///
    /// An unknown identifier is cleaned up rather than discarded: separators become spaces and
    /// words are capitalised, so `my-org/llama-3-8b-instruct` reads as "Llama 3 8b Instruct"
    /// instead of being shown raw or left blank.
    public static func friendly(_ modelID: String) -> String {
        let lowered = modelID.lowercased()
        // Drop a server prefix such as `mlx-community/` before matching.
        let slug = lowered.split(separator: "/").last.map(String.init) ?? lowered
        if let known = table.first(where: { slug.contains($0.match) }) { return known.name }
        return prettify(slug)
    }

    /// The compact label a seat shows for an MLX checkpoint.
    ///
    /// Derived from the identifier rather than stored beside it: `AgentSpec.seat(index:modelID:)` set
    /// `modelShortName` to the *default* checkpoint's name whatever it was asked for, so
    /// `chatbots-cli --model-a <another checkpoint>` told every seat's prompt — "running
    /// Qwen3.5-4B-4bit on the moderator's Mac" — and every badge that it was running the default.
    /// The `-MLX` marker comes out because it names the runtime rather than the model, and the
    /// engine here is always MLX; that leaves the default checkpoint reading exactly as it did.
    public static func shortName(_ modelID: String) -> String {
        let slug = modelID.split(separator: "/").last.map(String.init) ?? modelID
        let trimmed = slug.replacingOccurrences(of: "-MLX", with: "")
        return trimmed.isEmpty ? slug : trimmed
    }

    /// Turn a slug into something readable without pretending to know what it is.
    static func prettify(_ slug: String) -> String {
        let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
        guard !words.isEmpty else { return slug }
        return words.map { word -> String in
            // Keep a version-like token as it is: "4b" reads better than "4B" inside a name
            // that is already mixed case, and "8b" is not a word.
            if word.first?.isNumber == true { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

/// Keys the app can find for itself, so it works without a setup step.
///
/// **Not compiled into the source.** A key in a repository is a key that is public the moment
/// the repository is, and GitHub refuses the push anyway — its secret scanning blocked exactly
/// that. So the key is read, in order, from:
///
///   1. the environment (`DEEPSEEK_API_KEY`), for a shell or a launch agent
///   2. a local file, `.secrets.env` in the project root, which is gitignored
///   3. the value an endpoint already holds, if the user typed one
///
/// The file is the practical route on a desktop: present, but never committed. A fresh clone
/// without it simply has no DeepSeek key, which the interface already reports rather than
/// failing silently.
public enum BuiltInKeys {

    /// The environment variable that supplies the key.
    public static let deepSeekEnvironmentKey = "DEEPSEEK_API_KEY"

    /// The gitignored file the key can be read from.
    public static let secretsFileName = ".secrets.env"

    /// The DeepSeek key, or nil when this machine has none configured.
    public static var deepSeek: String? {
        normalisedKey(ProcessInfo.processInfo.environment[deepSeekEnvironmentKey])
            ?? normalisedKey(secretsFile()[deepSeekEnvironmentKey])
    }

    /// A key value as it should be used, or nil when there is not really one.
    ///
    /// **One function for every key path**, because they did disagree: this file trimmed
    /// `.whitespaces`, which excludes `\r`, while `TavilyClient` trimmed
    /// `.whitespacesAndNewlines`. A CRLF `.secrets.env` therefore gave the DeepSeek path a key
    /// ending in a carriage return — non-empty, so `isMissingKey` stayed false and no warning
    /// was shown, while the Authorization header carried a control character and the 401 that
    /// came back read as "the key is wrong" rather than "there is no usable key". Both resolvers
    /// now normalise through here, so the difference cannot come back one caller at a time.
    /// Blank is absent rather than an empty key: an exported-but-empty variable otherwise means
    /// sending `Bearer ` to the API.
    public static func normalisedKey(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Parse `.secrets.env`, one `NAME=value` per line.
    ///
    /// Deliberately minimal: no expansion, no quoting rules, no includes. It holds one or two
    /// keys and a parser with features is a parser with surprises.
    ///
    /// Line endings are normalised before the split, and that is not cosmetic. `split(separator:
    /// "\n")` does **not** split a CRLF file: Swift's `Character` is an extended grapheme
    /// cluster and `CR LF` is one cluster, so no character equals `"\n"` and the whole file
    /// arrives as a single "line" (measured). A CRLF file therefore used to parse as one entry
    /// whose value was the remainder of the file — so with the two keys this file documents,
    /// neither key was usable and neither was reported missing. Lines are then trimmed with
    /// `.whitespacesAndNewlines`, so a lone `\r` cannot ride inside a key either.
    public static func secretsFile(in root: URL? = nil) -> [String: String] {
        let directory =
            root ?? ModelStore.projectRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = directory.appending(path: secretsFileName)
        // The file holds API keys, so the rule for it is the rule for the TLS key: owner-only.
        // Nothing in this repository creates it, so it was whatever the user's umask made it —
        // 0644 under the common 022. Restricted on read rather than refused: an unreadable
        // secrets file is reported as "no key configured", which is a worse failure than a
        // repaired mode.
        restrictToThisUser(url)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        let normalised =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var values: [String: String] = [:]
        for line in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[trimmed.startIndex..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Tolerate quotes, because people write them.
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !name.isEmpty { values[name] = value }
        }
        return values
    }

    /// Make a credential file readable only by its owner, when it is not already.
    ///
    /// Silent when the file is absent or already owner-only. `attributesOfItem` follows a
    /// symlink, so a symlinked secrets file has its target restricted, which is the file that
    /// would actually be read.
    static func restrictToThisUser(_ url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path),
            let attributes = try? manager.attributesOfItem(atPath: url.path),
            let permissions = attributes[.posixPermissions] as? NSNumber,
            permissions.intValue & 0o077 != 0
        else { return }
        do {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            FileHandle.standardError.write(
                Data(
                    "[ChatBots] restricted \(url.lastPathComponent) to owner-only (0600); it holds API keys\n"
                        .utf8))
        } catch {
            let message =
                "[ChatBots] \(url.lastPathComponent) is readable by other users and could not be "
                + "restricted: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    /// The key for a base URL, or nil when this app has none to offer.
    ///
    /// The host is compared **exactly**, not by substring. `contains("api.deepseek.com")`
    /// would match `api.deepseek.com.evil.test`, which is a lookalike domain someone could
    /// register — and sending a real key there is the one mistake that turns a convenience
    /// into a disclosure. The host is taken from the parsed URL, so a path or a query that
    /// happens to contain the name cannot fool it either.
    public static func key(forBaseURL baseURL: String) -> String? {
        guard let host = host(of: baseURL), allowedHosts.contains(host) else { return nil }
        return deepSeek
    }

    /// The hosts this app will send its built-in key to.
    static let allowedHosts: Set<String> = ["api.deepseek.com"]

    /// The host of a base URL, lowercased, or nil when there is not one.
    ///
    /// Trimmed with `.whitespacesAndNewlines`, not `.whitespaces`: `responsesURL` already
    /// strips line endings, so a base URL ending in `\n` was requestable but this check read
    /// its host as nil and refused to attach the built-in key — two halves of the same
    /// endpoint disagreeing about the same string (the same shape already fixed for keys).
    static func host(of baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // A base URL is normally given with a scheme; tolerate one without.
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host else { return nil }
        return host.lowercased()
    }
}
