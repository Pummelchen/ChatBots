// ChatBotsCore — an endpoint's configuration, and what a response carries
//
// Split out of `OpenAIResponsesClient.swift`, which held the client, its endpoint configuration, the
// compatibility and naming tables and its session wrapper in one 860-line file. Nothing changed but
// which file each one lives in.

import Foundation

/// Configuration for an OpenAI-compatible endpoint.
public struct OpenAIEndpoint: Sendable, Hashable, Codable {
    /// Base URL without a path, e.g. `http://localhost:1234`. `/v1/responses` is appended.
    public var baseURL: String
    /// Model identifier as the *server* names it. For LM Studio this is the loaded model's
    /// identifier, which is its path-like key.
    public var model: String
    /// Optional bearer token. Local servers usually need none; OpenAI requires one.
    public var apiKey: String?
    /// Which parameters this endpoint accepts.
    public var compatibility: APICompatibility

    public init(
        baseURL: String = "http://localhost:1234",
        model: String = AgentSpec.defaultModelID,
        apiKey: String? = nil,
        compatibility: APICompatibility? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.compatibility = compatibility ?? APICompatibility.inferred(fromBaseURL: baseURL)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "http://localhost:1234"
        self.baseURL = baseURL
        self.model =
            try container.decodeIfPresent(String.self, forKey: .model)
            // The default checkpoint, not a copy of its name. Older saved settings predate the
            // field, and this is what they meant.
            ?? AgentSpec.defaultModelID
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        // Older saved settings predate the field; infer from the URL.
        self.compatibility =
            try container.decodeIfPresent(APICompatibility.self, forKey: .compatibility)
            ?? APICompatibility.inferred(fromBaseURL: baseURL)
    }

    /// True when a key is needed but missing, which is worth saying before a wasted request.
    /// The key actually sent: an explicit one wins, then the environment, then the key built
    /// into this app, and only for a host that key belongs to.
    ///
    /// Resolved here rather than stored, so a saved endpoint keeps whatever the user typed
    /// and the fallback stays a fallback — nothing is written into their settings that they
    /// did not put there.
    ///
    /// The typed value goes through `BuiltInKeys.normalisedKey`, the same function the file
    /// and environment paths use. It is the third caller the normalisation fix named, and it had the
    /// same defect: a pasted key with a trailing newline was taken verbatim, so it carried a
    /// control character into the Authorization header while being non-empty, which kept
    /// `isMissingKey` false and suppressed the warning that should have said there was no
    /// usable key. A value that is only whitespace now reads as absent rather than as an
    /// empty bearer token.
    public var effectiveAPIKey: String? {
        if let typed = BuiltInKeys.normalisedKey(apiKey) { return typed }
        return BuiltInKeys.key(forBaseURL: baseURL)
    }

    public var isMissingKey: Bool {
        compatibility == .strict && (effectiveAPIKey ?? "").isEmpty
    }

    /// The full endpoint, tolerating a base URL given with or without a trailing slash or
    /// with `/v1` already present.
    ///
    /// Nil when the endpoint is one this client will not send to, which is `endpointRefusal`'s
    /// decision rather than a parsing accident.
    public var responsesURL: URL? { Self.endpointURL(base: baseURL, suffix: "/responses") }

    /// The models endpoint, under the same endpoint policy `responsesURL` applies.
    ///
    /// The reachability probe used to build this URL itself and fetch it with
    /// `URLSession.shared`, which skipped `endpointRefusal` and followed redirects while the
    /// Authorization header was attached — so a `file://` or link-local base URL was fetched
    /// and a 302 was followed to a host the check never saw. Derived here so both paths share
    /// one rule rather than one path carrying it and the other not.
    public var modelsURL: URL? { Self.endpointURL(base: baseURL, suffix: "/models") }

    /// A base URL and an API path joined into the endpoint, or nil when it is refused.
    ///
    /// Built through `URLComponents` rather than by concatenating text: a base URL carrying a
    /// query or a fragment (`https://host.example?x=1`, `https://host.example#frag`) swallowed
    /// the appended path, so the request went to `/` with the path in the query or fragment
    /// and the failure looked like a server problem. The query and fragment are dropped here
    /// because a base URL is a prefix for a path, not a complete URL.
    static func endpointURL(base: String, suffix: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        components.query = nil
        components.fragment = nil
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath.hasSuffix("/v1") ? basePath + suffix : basePath + "/v1" + suffix
        guard let url = components.url else { return nil }
        guard Self.endpointRefusal(url) == nil else { return nil }
        return url
    }

    /// Why this client will not send a request to `url`, or nil when it will.
    ///
    /// Two rules, both about an address that arrives from configuration a user — or, in an earlier build, any
    /// web page — could set. It has to be http or https: a `file://` base URL made a model request
    /// read the local disk. And it must not be link-local, where cloud metadata services live, since
    /// `http://169.254.169.254/…` is the classic way a request path like this hands out credentials,
    /// and a non-2xx body is echoed back into the snapshot the front ends display.
    ///
    /// Loopback and private addresses stay allowed on purpose — pointing a seat at LM Studio or Ollama
    /// on this Mac or on the LAN is the thing this app is for, so refusing them would break the
    /// product to close a hole it does not have. A name that resolves to a link-local address is not
    /// covered by a string check like this one; the redirect policy on the session is what keeps a
    /// validated endpoint from being re-pointed behind the check.
    static func endpointRefusal(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "only http and https endpoints are used"
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return "the endpoint has no host"
        }
        if Self.isLinkLocalLiteral(host) {
            return "it is link-local, which is where cloud metadata services answer"
        }
        return nil
    }

    /// Whether `host` is a literal address in a link-local range.
    ///
    /// A string prefix missed the IPv4-mapped IPv6 form: `url.host` for
    /// `http://[::ffff:169.254.169.254]/` is the bare `::ffff:169.254.169.254` with the
    /// brackets already stripped, so `hasPrefix("169.254.")` did not match it and the address
    /// reached the metadata service anyway. The integer and hex IPv4 spellings CFNetwork also
    /// accepts (`http://2852039166/`, `http://0xA9FEA9FE/`) were missed the same way. Parsed to
    /// bytes, so the check is about the address rather than about how it was written.
    static func isLinkLocalLiteral(_ host: String) -> Bool {
        if host.contains(":") {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard inet_pton(AF_INET6, host, &bytes) == 1 else { return false }
            // fe80::/10
            if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true }
            // ::ffff:a.b.c.d, the IPv4-mapped range, whose IPv4 part is link-local.
            let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            if mapped { return bytes[12] == 169 && bytes[13] == 254 }
            return false
        }
        guard let value = ipv4Integer(host) else { return false }
        // 169.254.0.0/16
        return (value >> 16) == 0xA9FE
    }

    /// The 32-bit value of an IPv4 literal in dotted-quad, decimal or `0x` hex form, or nil.
    static func ipv4Integer(_ host: String) -> UInt32? {
        var bytes = [UInt8](repeating: 0, count: 4)
        if inet_pton(AF_INET, host, &bytes) == 1 {
            return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
        }
        if host.hasPrefix("0x") {
            return UInt32(host.dropFirst(2), radix: 16)
        }
        if !host.isEmpty, host.allSatisfy(\.isNumber) {
            // The decimal-integer form: 2852039166 is 169.254.169.254.
            return UInt32(host)
        }
        return nil
    }

    /// Derived from the model id so the UI can show something short.
    /// The name to show for this endpoint's model.
    ///
    /// Superseded by `ModelNames.friendly`, which knows what the models are actually called;
    /// kept because it is the sensible fallback for an identifier nothing recognises.
    public var shortModelName: String {
        ModelNames.friendly(model)
    }
}

/// One streamed piece of a response.
public enum OpenAIStreamEvent: Sendable {
    case text(String)
    case reasoning(String)
    /// Usage and timing from the terminal event.
    case completed(OpenAIUsage)
    case failed(String)
}

public struct OpenAIUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var cachedTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0, cachedTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedTokens = cachedTokens
    }
}

/// A session delegate whose only job is to refuse redirects.
///
/// `completionHandler(nil)` means "do not follow": the redirect response is the answer, so a 302 from
/// an endpoint shows up as a non-2xx rather than as a request to wherever it pointed.
