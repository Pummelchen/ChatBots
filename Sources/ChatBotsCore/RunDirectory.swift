// ChatBotsCore — where runtime state lives
//
// One answer, shared by the app and the engine, because they have to agree. The certificate the
// engine serves with is the one the installer prepared, and the app's engine log sits beside it.
//
// **Never inside the app bundle.** The app used to write `<ChatBots.app>/.run/app-engine.log`,
// and an installed engine would have written its certificate to `<ChatBots.app>/Contents/MacOS/
// .run`. Both are wrong twice over:
//
//   · A bundle that writes to itself has an invalid code signature from the moment it launches.
//     `codesign` refuses it outright — "unsealed contents present in the bundle root" — and a
//     notarised build would be rejected for the same reason.
//   · An app installed where it cannot write, or on a read-only volume, cannot start its engine
//     at all. The failure would be "the engine could not be started", a long way from the cause.
//
// So there are two places, and the choice is made once, here:
//
//   · **In a checkout** — `<project>/.run`, which is where `tools/install.sh` prepares the
//     certificate and `tools/start.sh` writes its pid files. Running from a checkout has to keep
//     working exactly as it did, and it does.
//   · **Otherwise** — `~/Library/Application Support/ChatBots`, which is writable, per-user, and
//     not a cache that macOS may purge while the engine is using it.

import Foundation

public enum RunDirectory {

    /// The runtime directory for a known project root, or the per-user fallback.
    ///
    /// The project root is only accepted when it really is a checkout — a `Package.swift` next to
    /// it. `ModelStore.projectRoot()` also accepts a directory merely *containing* `models`, which
    /// is right for finding checkpoints and wrong for deciding where to write: a stray `models`
    /// folder above an installed app would otherwise redirect its certificate and logs into
    /// somebody's home directory.
    public static func resolve(projectRoot: URL?) -> URL {
        if let projectRoot, isCheckout(projectRoot) {
            return projectRoot.appending(path: ".run")
        }
        return applicationSupport
    }

    /// The runtime directory for this process.
    public static var current: URL {
        resolve(projectRoot: ModelStore.projectRoot())
    }

    /// Whether this is a source checkout rather than an installed app.
    static func isCheckout(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appending(path: "Package.swift").path)
    }

    /// `~/Library/Application Support/ChatBots`.
    static var applicationSupport: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appending(path: "Library/Application Support")
        return base.appending(path: "ChatBots")
    }
}
