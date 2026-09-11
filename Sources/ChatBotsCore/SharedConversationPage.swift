// ChatBotsCore — a conversation someone can open
//
// The export is a text file, which is a good way to keep a conversation and a poor way to show
// one to somebody: it arrives as an attachment, it has no structure, and reading the argument
// means scrolling to the end. A shared link is the other half of "sharing", and the brief asks
// for both.
//
// The page carries its own replay controls, which is what makes it worth opening rather than
// mailing the text: a conversation is a thing that happened over time and the interesting part
// is usually *when* somebody said something. Playing it back a turn at a time is closer to
// having watched it than a wall of transcript is.
//
// **This renders untrusted text.** Everything on the page is output from a language model, which
// is to say it is arbitrary, and some of it will have been written by a model that has read the
// web. So nothing here is ever inserted as markup: the transcript travels as JSON with `<`
// escaped, and the script builds every node with `textContent`. There is no `innerHTML` in this
// file on purpose, and a test asserts that a message containing a script tag cannot escape.

import Foundation

public enum SharedConversationPage {

    /// A standalone page for one kept conversation.
    public static func html(_ record: StoredConversation, shareBase: String? = nil) -> String {
        let title = record.topic.isEmpty ? "An untitled conversation" : record.topic
        let exported = ISO8601DateFormatter().string(from: record.updatedAt)
        let seats = record.seats.map { "\($0.name) — \($0.mode)" }.joined(separator: ", ")

        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escape(title))</title>
            <style>
            \(css)
            </style>
            </head>
            <body>
            <header>
              <h1>\(escape(title))</h1>
              <p class="meta">\(escape(seats)) · \(record.turns.count) entries · \(escape(exported))</p>
            </header>

            <div class="controls" role="group" aria-label="Replay">
              <button id="first" title="Back to the start">&#8676;</button>
              <button id="prev" title="Previous entry">&#9664;</button>
              <button id="play" class="primary" title="Play or pause">Play</button>
              <button id="next" title="Next entry">&#9654;</button>
              <button id="last" title="Jump to the end">&#8677;</button>
              <label class="speed">Speed
                <select id="speed">
                  <option value="2400">slow</option>
                  <option value="1200" selected>normal</option>
                  <option value="500">fast</option>
                  <option value="120">very fast</option>
                </select>
              </label>
              <span id="counter" class="counter"></span>
            </div>

            <main id="log"></main>

            <section id="report-block" hidden>
              <h2>Research report</h2>
              <pre id="report"></pre>
            </section>

            <footer>
              <p>Shared from ChatBots. Read-only: nothing here can change the conversation.</p>
            </footer>

            <script id="data" type="application/json">\(dataJSON(record, shareBase: shareBase))</script>
            <script>
            \(script)
            </script>
            </body>
            </html>
            """
    }

    // MARK: Escaping

    /// Escape for HTML text and attribute values.
    ///
    /// Applied to everything interpolated into the markup, including text that "cannot" contain
    /// markup. A topic is typed by a person and a report is written by a model; neither is
    /// trusted, and the cost of escaping something that did not need it is nothing.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The transcript as JSON, safe to sit inside a `<script>` element.
    ///
    /// A `</script>` anywhere in a message would otherwise end the block early and let the rest
    /// of that message be parsed as markup — the classic way a JSON island turns into an
    /// injection. Escaping `<` as `\\u003c` is what the HTML parser will not look for, and JSON
    /// decodes it back to `<` on the other side.
    static func dataJSON(_ record: StoredConversation, shareBase: String?) -> String {
        var payload: [String: Any] = [:]
        payload["topic"] = record.topic
        payload["shareBase"] = shareBase ?? ""
        payload["entries"] = record.turns.map { turn -> [String: Any] in
            [
                "kind": turn.kind,
                "speaker": turn.speakerName,
                "text": turn.content,
                "at": ISO8601DateFormatter().string(from: turn.timestamp),
            ]
        }
        if let report = record.report {
            payload["report"] = report.markdown()
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    // MARK: The page's own parts

    private static let css = """
        :root { color-scheme: light dark; --line: color-mix(in srgb, currentColor 16%, transparent); }
        * { box-sizing: border-box; }
        body {
          margin: 0 auto; max-width: 780px; padding: 20px 16px 60px;
          font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
        }
        header h1 { font-size: 20px; margin: 0 0 4px; overflow-wrap: anywhere; }
        .meta { color: color-mix(in srgb, currentColor 60%, transparent); font-size: 12px; margin: 0 0 14px; }
        .controls {
          display: flex; align-items: center; gap: 6px; flex-wrap: wrap;
          padding: 8px 0 12px; border-bottom: 1px solid var(--line); position: sticky; top: 0;
          background: canvas; z-index: 2;
        }
        .controls button {
          font: inherit; font-size: 13px; padding: 3px 10px; border-radius: 999px;
          border: 1px solid var(--line); background: transparent; color: inherit; cursor: pointer;
        }
        .controls button.primary { border-color: currentColor; }
        .controls button:disabled { opacity: 0.35; cursor: default; }
        .speed { font-size: 12px; color: color-mix(in srgb, currentColor 65%, transparent); }
        .counter { margin-left: auto; font-size: 12px; font-variant-numeric: tabular-nums;
                   color: color-mix(in srgb, currentColor 65%, transparent); }
        .entry { padding: 10px 0 4px; animation: fade 180ms ease; }
        .entry[hidden] { display: none; }
        .who { font-size: 11px; font-weight: 700; letter-spacing: 0.03em; text-transform: uppercase; }
        .at { font-size: 11px; color: color-mix(in srgb, currentColor 50%, transparent); margin-left: 6px;
              font-family: ui-monospace, Menlo, monospace; }
        .text { white-space: pre-wrap; overflow-wrap: anywhere; margin: 3px 0 0; }
        .entry[data-kind="topic"], .entry[data-kind="steering"], .entry[data-kind="direction"] {
          border-left: 3px solid currentColor; padding-left: 10px;
        }
        .entry[data-kind="direction"] .who,
        .entry[data-kind="topic"] .who,
        .entry[data-kind="steering"] .who { opacity: 0.75; }
        .entry[data-kind="chat"] { border-left: 3px solid var(--line); padding-left: 10px; }
        .entry summary { cursor: pointer; font-size: 12px; color: color-mix(in srgb, currentColor 60%, transparent); }
        .entry pre { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 13px; }
        #report-block { margin-top: 24px; border-top: 1px solid var(--line); padding-top: 12px; }
        #report-block h2 { font-size: 15px; }
        #report { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 13px; }
        footer { margin-top: 32px; color: color-mix(in srgb, currentColor 55%, transparent); font-size: 12px; }
        @keyframes fade { from { opacity: 0; transform: translateY(3px); } to { opacity: 1; } }
        @media (prefers-reduced-motion: reduce) { .entry { animation: none; } }
        """

    /// The replay, in the page.
    ///
    /// A raw string so the JavaScript's own backslashes and braces are literal. Note what is
    /// absent: no `innerHTML`, no `insertAdjacentHTML`, no template that interpolates message
    /// text. Every node is built and filled with `textContent`, which is the only way to render
    /// text that a language model wrote without also giving it control of the page.
    private static let script = #"""
        (function () {
          var data = JSON.parse(document.getElementById("data").textContent);
          var entries = data.entries || [];
          var log = document.getElementById("log");
          var counter = document.getElementById("counter");
          var playButton = document.getElementById("play");
          var at = 0;          // how many entries have been revealed
          var timer = null;

          function label(entry) {
            switch (entry.kind) {
              case "topic": return "Moderator · topic";
              case "steering": return "Moderator";
              case "direction": return "Research moderator · assignment";
              case "summary": return "Condensed earlier discussion";
              case "report": return "Research moderator · report";
              case "tool": return "Tool · " + entry.speaker;
              default: return entry.speaker || "?";
            }
          }

          function clock(iso) {
            var when = new Date(iso);
            return isNaN(when.getTime()) ? "" : when.toLocaleTimeString();
          }

          function build(entry) {
            var wrap = document.createElement("div");
            wrap.className = "entry";
            wrap.dataset.kind = entry.kind;

            var head = document.createElement("div");
            var who = document.createElement("span");
            who.className = "who";
            who.textContent = label(entry);
            var when = document.createElement("span");
            when.className = "at";
            when.textContent = clock(entry.at);
            head.appendChild(who);
            head.appendChild(when);

            var text = document.createElement("p");
            text.className = "text";
            // The one line in this file that matters for safety.
            text.textContent = entry.text || "";

            wrap.appendChild(head);
            wrap.appendChild(text);
            return wrap;
          }

          for (var i = 0; i < entries.length; i++) {
            var node = build(entries[i]);
            node.hidden = true;
            log.appendChild(node);
          }
          var nodes = log.children;

          if (data.report) {
            document.getElementById("report").textContent = data.report;
            document.getElementById("report-block").hidden = false;
          }

          function draw() {
            for (var i = 0; i < nodes.length; i++) nodes[i].hidden = i >= at;
            counter.textContent = at + " / " + nodes.length;
            document.getElementById("prev").disabled = at === 0;
            document.getElementById("first").disabled = at === 0;
            document.getElementById("next").disabled = at >= nodes.length;
            document.getElementById("last").disabled = at >= nodes.length;
            if (at > 0 && nodes[at - 1]) nodes[at - 1].scrollIntoView({ block: "nearest" });
          }

          function stop() {
            if (timer) { clearInterval(timer); timer = null; }
            playButton.textContent = "Play";
          }

          function step(by) {
            at = Math.max(0, Math.min(nodes.length, at + by));
            if (at >= nodes.length) stop();
            draw();
          }

          function play() {
            if (timer) { stop(); return; }
            // Restart from the beginning when the end has already been reached, so Play does
            // something rather than appearing broken.
            if (at >= nodes.length) at = 0;
            playButton.textContent = "Pause";
            var delay = Number(document.getElementById("speed").value) || 1200;
            timer = setInterval(function () { step(1); }, delay);
            draw();
          }

          playButton.onclick = play;
          document.getElementById("next").onclick = function () { stop(); step(1); };
          document.getElementById("prev").onclick = function () { stop(); step(-1); };
          document.getElementById("first").onclick = function () { stop(); at = 0; draw(); };
          document.getElementById("last").onclick = function () { stop(); at = nodes.length; draw(); };
          document.getElementById("speed").onchange = function () {
            if (timer) { stop(); play(); }
          };

          document.addEventListener("keydown", function (event) {
            if (event.target.tagName === "SELECT" || event.target.tagName === "INPUT") return;
            if (event.key === " ") { event.preventDefault(); play(); }
            else if (event.key === "ArrowRight") { stop(); step(1); }
            else if (event.key === "ArrowLeft") { stop(); step(-1); }
            else if (event.key === "End") { stop(); at = nodes.length; draw(); }
            else if (event.key === "Home") { stop(); at = 0; draw(); }
          });

          // The whole conversation, not a blank page: a reader who does not want the replay
          // should not have to press Play four times to get at the transcript.
          if (location.hash === "#all" || nodes.length <= 2) {
            at = nodes.length;
          } else {
            at = Math.min(1, nodes.length);
          }
          draw();
        })();
        """#
}
