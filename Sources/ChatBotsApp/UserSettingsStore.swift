// ChatBotsApp — reading and writing the user's settings
//
// Thin on purpose: the shape, the defaults and the reconciliation live in
// `ChatBotsCore.UserSettings`, where they can be tested without preferences. This only
// reads and writes them.
//
// Writes go through `UserDefaults.set`, which the system persists for us — there is no
// `synchronize()` to call and none is needed, because the value is durable from the moment
// it is set. The short debounce below is about write volume while typing, not about risk of
// loss, and it is short enough that a crash or force quit still keeps the change.

import ChatBotsCore
import Foundation
import SwiftUI

@MainActor
final class UserSettingsStore: ObservableObject {

    private static let key = "userSettings"

    /// Settings as loaded, which the controller is built from.
    private(set) var settings: UserSettings

    /// Set when something was stored but could not be read, so the UI can say so once
    /// rather than the user wondering why their setup reverted.
    private(set) var loadWarning: String?
    private var didReportWarning = false

    private var pendingWrite: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        fallbackTopic: String = "Why are eggs not round?"
    ) {
        let supported = AgentSpec.SeatRoster.count()
        if let data = defaults.data(forKey: Self.key) {
            do {
                self.settings = try UserSettings.decoded(from: data)
                    .reconciled(supportedSeatCount: supported)
            } catch {
                self.settings = .defaults(topic: fallbackTopic)
                self.loadWarning =
                    "Saved settings could not be read, so defaults were restored. The previous file is still at \(Self.storageDescription)."
            }
        } else {
            self.settings = .defaults(topic: fallbackTopic)
        }
    }

    /// Remember the new values, writing shortly after the last change.
    func save(_ settings: UserSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        let payload = settings.encoded()
        pendingWrite?.cancel()
        pendingWrite = Task {
            // Coalesces bursts — typing, or a slider — without making the change fragile.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            if let payload { defaults.set(payload, forKey: Self.key) }
        }
    }

    /// Write immediately, for termination.
    func saveNow(_ settings: UserSettings, defaults: UserDefaults = .standard) {
        pendingWrite?.cancel()
        pendingWrite = nil
        self.settings = settings
        if let payload = settings.encoded() { defaults.set(payload, forKey: Self.key) }
    }

    /// Consume the load warning once, so it is shown a single time.
    func takeLoadWarning() -> String? {
        guard let loadWarning, !didReportWarning else { return nil }
        didReportWarning = true
        return loadWarning
    }

    /// Where the settings live, for the About panel and for support.
    static var storageDescription: String {
        "~/Library/Preferences/local.chatbots.twollms.plist"
    }
}
