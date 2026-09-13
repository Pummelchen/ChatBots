// ChatBotsCoreTests — the embedded web interface must match the files in web/
//
// `Sources/ChatBotsCore/WebAssets.swift` is generated from `web/` by `tools/embed-web.py`, and
// the generator's `--check` mode is the intended guard. It was not enough: the interface was
// hand-edited in the generated file for four commits while `web/` stood still, so Caddy served
// an older page than the engine did, and the next `tools/start.sh` would have regenerated the
// generated file from the stale source and thrown the newer work away. None of that failed a
// build.
//
// So the invariant is asserted here, where it is exercised on every `swift test` rather than
// only when someone runs the start script. The comparison is on the bytes the server actually
// serves, taken through the same public lookup a request uses, so it cannot drift from the
// lookup it is meant to protect.

import ChatBotsCore
import Foundation
import Testing

@Suite("Embedded web assets")
struct EmbeddedWebAssetTests {

    /// The repository root, derived from this file's own path.
    ///
    /// `#filePath` is the path the compiler saw, so the check follows the checkout rather than
    /// assuming a working directory — `swift test` may run from anywhere.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)  // Tests/ChatBotsCoreTests/EmbeddedWebAssetTests.swift
            .deletingLastPathComponent()  // Tests/ChatBotsCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
    }

    /// Each asset the server serves, and the file in `web/` it is generated from.
    ///
    /// `/` is listed beside `/index.html` because both are routes to the same bytes, and a
    /// generator change that favoured one would otherwise pass.
    private static let assets: [(path: String, filename: String)] = [
        ("/", "index.html"),
        ("/index.html", "index.html"),
        ("/style.css", "style.css"),
        ("/app.js", "app.js"),
    ]

    @Test("Every embedded asset is byte-for-byte the file it is generated from")
    func embeddedMatchesSources() throws {
        for asset in Self.assets {
            let served = try #require(
                WebAssets.asset(for: asset.path)?.body,
                "\(asset.path) should be served as an asset")
            let onDisk = try Data(
                contentsOf: repositoryRoot.appending(path: "web/\(asset.filename)"))

            #expect(
                served == onDisk,
                """
                \(asset.filename) has drifted from the embedded copy. `web/` is the source of \
                truth: run `python3 tools/embed-web.py` to regenerate WebAssets.swift, and move \
                any edit made in the generated file into web/ first.
                """)
        }
    }

    @Test("The live header renders the seat's name as text, never as markup")
    func liveHeaderSetsTheNameAsText() throws {
        // The seat's name is moderator-supplied and is rendered by every attached client, so
        // it is the one string in this file that must never reach `innerHTML`. It did reach it
        // — `createLiveElement` interpolated `${name.toUpperCase()}` into the header, which
        // made a stored XSS: rename a seat to `<img src=x onerror=…>` and it ran everywhere.
        //
        // This is a guard against that returning, not a substitute for the escaping itself. It
        // reads the bytes the server actually serves, like the drift check above, so it cannot
        // pass against a stale generated file.
        let served = try #require(WebAssets.asset(for: "/app.js")?.body)
        let js = try #require(String(data: served, encoding: .utf8))
        let start = try #require(js.range(of: "function createLiveElement"))
        // To the function's own closing brace rather than a character count: a fixed window
        // silently stops covering the body the moment anyone adds a comment to it, which is
        // how the first version of this guard passed a body it had truncated.
        let rest = js[start.lowerBound...]
        let end = try #require(rest.range(of: "\n  }"))
        let body = String(rest[..<end.lowerBound])

        #expect(
            body.contains("msg-who") && body.contains("textContent"),
            "the live header must set the seat's name with textContent, not inside the markup")
        #expect(
            !body.contains("${name"),
            "the seat's name is moderator-supplied and must not be interpolated into markup")
    }

    @Test("The checkout this test reads is the one it was compiled in")
    func repositoryRootIsTheCheckout() throws {
        // A guard on the guard: if the path ever resolves somewhere unexpected, the comparison
        // above would fail for the wrong reason, and this says so plainly.
        let manifest = repositoryRoot.appending(path: "Package.swift")
        #expect(
            FileManager.default.fileExists(atPath: manifest.path),
            "expected Package.swift at \(manifest.path)")
    }
}
