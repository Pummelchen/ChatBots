// ChatBotsCore — the standalone page a shared conversation link opens
//
// Split out of `APIServer.swift`, which held the routes, the command translation and the push feed in
// one file. This is the one route that answers with a rendered page rather than JSON, and it is
// transport-specific rather than an engine command: the engine does not render pages. The code did not
// change.

import Foundation

extension APIServer {

    /// A kept conversation as a standalone read-only page.
    ///
    /// 404 rather than a blank page for an id that names nothing: a shared link that opens an
    /// empty conversation is indistinguishable from one whose transcript was lost, and the
    /// reader has no way to tell which happened.
    /// The replay page for a shared link.
    ///
    /// The lookup reads the whole conversation index, because that is one file, and it happens
    /// off the main actor: this handler is on the main actor and so is the engine's turn loop, so an
    /// index read while a conversation was streaming stalled the stream. A malformed id never
    /// reaches the store at all, which is what it did before as well — the difference is that a
    /// well-formed id nobody has heard of no longer decodes the history to find that out.
    ///
    /// The page is rendered from the record alone. It used to be handed an origin derived from the
    /// request's `Host` (validated by `validShareHost`), which the page wrote into its JSON island and
    /// never read; the field, the reflection and the validator are gone. The link a reader
    /// copies is built by the front ends: the web interface from the origin the browser is reading at,
    /// with the engine's reported base as its fallback (`web/app.js`), and the desktop app from that
    /// reported base, which `--share-base` sets (`ChatController.shareLink(for:)`).
    /// Internal rather than private: `route` in `APIServer.swift` answers every `/s/<id>` with it.
    func sharedPage(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else { return sharedPageNotFound() }
        guard let record = await service.store.conversationOffMainActor(id: uuid) else {
            return sharedPageNotFound()
        }
        return HTTPResponse(
            contentType: "text/html; charset=utf-8",
            body: Data(SharedConversationPage.html(record).utf8),
            // The share page carries its own inline stylesheet and replay script, so it says so
            // rather than inheriting the interface's policy, which has no inline grant.
            headers: ["Content-Security-Policy": HTTPResponse.inlinePagePolicy])
    }

    /// A page that says the link does not work, rather than a bare 404 body: the reader followed a
    /// link somebody sent them, and "no conversation with that link" is the answer they need.
    private func sharedPageNotFound() -> HTTPResponse {
        let missing = [
            "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            "<title>No conversation with that link</title></head>",
            "<body style=\"font:15px/1.5 -apple-system,system-ui,sans-serif;max-width:640px;"
                + "margin:60px auto;padding:0 16px\">",
            "<h1 style=\"font-size:19px\">No conversation with that link</h1>",
            "<p>It may have been deleted, or the link may have been copied incompletely.</p>",
            "</body></html>",
        ].joined(separator: "\n")
        return HTTPResponse(
            status: 404, contentType: "text/html; charset=utf-8",
            body: Data(missing.utf8),
            // The default page policy refuses inline style, and this page carries one on its body.
            // It carries no script, so the replacement grants style only.
            headers: ["Content-Security-Policy": HTTPResponse.inlineStylePagePolicy])
    }
}
