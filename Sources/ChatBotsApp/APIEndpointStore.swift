// ChatBotsApp — persisted per-seat API endpoints
//
// Lets a seat point at any OpenAI-compatible `/v1` endpoint — LM Studio locally, or
// api.openai.com and friends — with its own URL, key and model name. Endpoints apply to
// the *next* turn, so they can be edited while a conversation is running.
//
// Keys are kept in the Keychain, not in `UserDefaults` beside the rest of the settings.
// A plain-text key in a plist is a real (if minor) leak: it ends up in backups, in
// `defaults read`, and in anything that scrapes a home directory. `OPENAI_API_KEY` is
// honoured as an override for people who would rather keep no secret on disk at all —
// and for a local server that needs no key, both stay empty.

import ChatBotsCore
import Foundation
import Security
import SwiftUI

@MainActor
final class APIEndpointStore: ObservableObject {

    /// The seats the app can configure independently.
    static let seatCount = AgentSpec.supportedSeatCount

    /// Environment override, the convention for tools that talk to OpenAI.
    static let apiKeyEnvironmentKey = "OPENAI_API_KEY"

    @Published private(set) var endpoints: [OpenAIEndpoint]
    /// Per-seat keys, mirrored from the Keychain on load.
    @Published private(set) var keys: [String]

    private let defaultsKey = "apiEndpoints"
    private static let keychainService = "local.chatbots.twollms.openai"

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let stored = Self.loadEndpoints(defaultsKey: "apiEndpoints")
        // Pad or trim to the supported seat count so the indexing below is always safe.
        var endpoints = stored
        while endpoints.count < Self.seatCount {
            endpoints.append(OpenAIEndpoint())
        }
        self.endpoints = Array(endpoints.prefix(Self.seatCount))

        let override = environment[Self.apiKeyEnvironmentKey]
        self.keys = (0..<Self.seatCount).map { index in
            if let override, !override.isEmpty { return override }
            return Self.loadKey(seat: index) ?? ""
        }
    }

    // MARK: - Access

    /// The endpoint for a seat, with the current key applied.
    func endpoint(forSeat index: Int) -> OpenAIEndpoint {
        guard endpoints.indices.contains(index) else { return OpenAIEndpoint() }
        var endpoint = endpoints[index]
        let key = keys.indices.contains(index) ? keys[index] : ""
        endpoint.apiKey = key.isEmpty ? nil : key
        return endpoint
    }

    /// Whether a seat would use the API backend, given its spec.
    func isAPI(_ spec: AgentSpec) -> Bool { spec.backend == .openAIResponses }

    // MARK: - Editing

    func setBaseURL(_ value: String, seat: Int) {
        update(seat: seat) { endpoint in
            endpoint.baseURL = value
            // A URL typed for OpenAI should not keep a local engine's parameter set.
            endpoint.compatibility = APICompatibility.inferred(fromBaseURL: value)
        }
    }

    /// Sets the model id, allowing the separate Model field to be cleared without
    /// surprising the user with an empty string on the wire.
    func setModel(_ value: String, seat: Int) {
        update(seat: seat) { $0.model = value }
    }

    func setCompatibility(_ value: APICompatibility, seat: Int) {
        update(seat: seat) { $0.compatibility = value }
    }

    func setKey(_ value: String, seat: Int) {
        guard keys.indices.contains(seat) else { return }
        keys[seat] = value
        Self.storeKey(value, seat: seat)
    }

    private func update(seat: Int, _ change: (inout OpenAIEndpoint) -> Void) {
        guard endpoints.indices.contains(seat) else { return }
        var endpoint = endpoints[seat]
        change(&endpoint)
        endpoints[seat] = endpoint
        Self.saveEndpoints(endpoints, defaultsKey: defaultsKey)
    }

    /// Copy one seat's endpoint onto the others, for the common "same server for both" case.
    func mirrorSeat(_ source: Int) {
        guard endpoints.indices.contains(source) else { return }
        let template = endpoints[source]
        let key = keys.indices.contains(source) ? keys[source] : ""
        for seat in endpoints.indices where seat != source {
            endpoints[seat] = template
            if keys.indices.contains(seat) { keys[seat] = key }
            Self.storeKey(key, seat: seat)
        }
        Self.saveEndpoints(endpoints, defaultsKey: defaultsKey)
    }

    /// True when every seat points at the same place, so the UI can say so.
    var allSeatsShareEndpoint: Bool {
        guard let first = endpoints.first else { return true }
        var template = first
        template.apiKey = nil
        return endpoints.allSatisfy { endpoint in
            var copy = endpoint
            copy.apiKey = nil
            return copy == template
        }
    }

    // MARK: - Persistence

    private static func loadEndpoints(defaultsKey: String) -> [OpenAIEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([OpenAIEndpoint].self, from: data)
        else { return [] }
        return decoded
    }

    private static func saveEndpoints(_ endpoints: [OpenAIEndpoint], defaultsKey: String) {
        // Keys live in the Keychain; keep them out of the plist.
        let redacted = endpoints.map { endpoint -> OpenAIEndpoint in
            var copy = endpoint
            copy.apiKey = nil
            return copy
        }
        guard let data = try? JSONEncoder().encode(redacted) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Keychain

    private static func account(seat: Int) -> String { "seat-\(seat)" }

    private static func query(seat: Int) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account(seat: seat),
        ]
    }

    static func loadKey(seat: Int) -> String? {
        var query = query(seat: seat)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func storeKey(_ key: String, seat: Int) -> Bool {
        let query = query(seat: seat)
        // Always replace rather than update: deleting is simpler to reason about, and the
        // item is tiny.
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey(seat: Int) {
        SecItemDelete(query(seat: seat) as CFDictionary)
    }
}
