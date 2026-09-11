# ChatBots

Two local LLMs, side by side, talking to each other about a topic you choose — with you
watching and able to cut in.

Written in Swift 6.3 for Apple Silicon. Inference is **in-process via MLX Swift**
(no Ollama, no LM Studio, no HTTP server). The default seats are two *independent*
instances of `mlx-community/Qwen3.5-4B-MLX-4bit`, and each seat is wired so that
pointing it at a different checkpoint is a one-line change.

![two panes, one conversation](docs/screenshot.png)

---

## What it does

You type a topic (default: *"Why are eggs not round?"*). The app posts your question
plus a short introduction to a **shared log**, then lets two models go. There are no
rules beyond that: no debate format, no roles, no "ask a question then wait". Each
model reads everything that has been said — including anything the other model wrote
and anything you wrote — and replies. You watch it happen.

Both seats can search the web through **Tavily**, so claims can be checked instead of
hallucinated.

### Controls

| Control | What it does |
| --- | --- |
| **Start / Restart** | Loads both models, posts the topic + introduction, begins turn 1 |
| **Pause / Resume** | Takes effect *between* turns, so a half-generated reply is never logged |
| **Stop** | Ends the conversation immediately; loaded weights stay in memory for a fast restart |
| **Clear** | Forgets the transcript. Weights stay loaded |
| **Moderator box** | Your message goes into the shared log — **both** models read it |
| **Show thinking** | Streams each model's `<think>` block into its own pane (never into the log) |
| **Models ▸ Load …** | Pre-loads weights, optionally per seat |
| **Theme** | `Original` (default) follows the Mac's appearance; `Black` is flat pure-black |

Moderator messages typed *while a model is generating* are queued, shown as `queued`,
and appended exactly once at the next turn boundary — so both models see it on their
next turn and neither sees it twice.

---

## Architecture

The point of the layout is that **a seat is swappable**. Nothing in the orchestration
knows what MLX is; nothing in the UI knows how a turn is generated.

```
Sources/ChatBotsCore            (no SwiftUI — unit-testable, no model required)
├── ChatModels.swift            Turn / Conversation / AgentSpec / TurnEvent / LLMEngine protocol
├── PromptBuilder.swift         the one introduction template + per-turn prompt assembly
├── ThinkingStripper.swift      pure state machine: <think> reasoning vs. visible answer
├── MLXEngine.swift             one MLX model instance per seat (+ ToolRegistry)
├── TavilyClient.swift          api.tavily.com search + extract
├── WebTools.swift              web_search / fetch_page as native tool specs
└── ConversationEngine.swift    the turn loop, pause gate, steering queue, transcript

Sources/ChatBotsApp             SwiftUI: two panes, control bar, moderator bar
Sources/ChatBotsCLI             headless runner — same core, no window
Tests/ChatBotsCoreTests         orchestration, prompt assembly, thinking parser
```

### Both seats run on the GPU — measured, not assumed

Two seats share the M3 GPU happily; there is no need to push one onto the CPU. Measured
with `chatbots-cli --benchmark --max-tokens 200` (M3, 24 GB, Qwen3.5-4B-MLX-4bit ×2):

| | seat A | seat B |
| --- | --- | --- |
| alone | 30.0 tok/s | 30.2 tok/s |
| both generating at once | 15.0 tok/s | 15.0 tok/s |

When both seats really do generate at the same moment the GPU serialises them and each
gets exactly half — the combined rate is unchanged, so nothing is lost, and they load
concurrently without complaint. **The conversation never hits that case anyway**: a turn
needs the previous speaker's text to exist before the next seat can read it, so the loop
is sequential and the speaking seat always has the GPU to itself at full 30 tok/s.

CPU offload is deliberately not offered. It is not merely slower — it is impossible for
this checkpoint: Qwen 3.5's linear-attention layers call MLX's `metal_kernel`, and
forcing the CPU fails hard with

```
Fatal error: [metal_kernel] Only supports the GPU.
```

If a future seat uses a dense model that lacks those kernels, `MLXEngine` can be pointed
at another device, but no such seat ships here.

`--benchmark` is kept because it is also the cheapest way to prove a new checkpoint loads
and generates at all before wiring it into a conversation.

### Themes

`Original` is the default and uses the system's dynamic colours, so it follows the Mac's
light/dark setting and the panes keep native materials. `Black` is the opt-in theme the
moderator asked for: flat `#000000` everywhere, no materials, and its own literal palette
rather than semantic colours — a material over black reads as muddy grey, and a semantic
colour like `.tertiary` would flip to dark ink on a black pane when the Mac is in light
mode. The two agent tints are also lifted in `Black`, because the system `.teal` and
`.indigo` are too dim at small sizes against pure black.

The choice is stored with `@AppStorage("themeMode")`, so it survives relaunch. The window's
AppKit appearance and background are set alongside the SwiftUI palette, because a SwiftUI
background alone leaves the titlebar and the gutter around the split view in the system
appearance.

### Three decisions worth knowing about

**1. One engine per seat, not one shared model.**
`AgentSpec` carries the model id, temperature, top-p, token budget and reasoning mode
per seat. `ConversationEngine.Seat` pairs a spec with its own `MLXEngine`, and each
`MLXEngine` holds its own `ModelContainer` — two weight copies in memory (~2.3 GB each
at 4-bit). That is deliberate: it is what makes "seat B is a different LLM" a config
change rather than a refactor.

```swift
public static func seatB(modelID: String = AgentSpec.defaultModelID) -> AgentSpec {
    AgentSpec(id: "Agent B", displayName: "Agent B", modelID: modelID,
              temperature: 0.85, topP: 0.95)
}
```

Adding a third participant is `AgentSpec` + one more `Seat`; the panes, colours and
turn rotation are already driven by the seat array.

**2. Turn order is deterministic.**
A round is A, then B, then A. Models are never asked who should speak next — that
would cost a generation per turn and occasionally deadlock. `Pause` parks the loop on
a continuation *between* turns.

**3. Every prompt is rebuilt from the shared log.**
Each turn re-renders the whole conversation with speaker tags
(`[Moderator]`, `[Agent A]`, …) rather than appending to a private per-seat
transcript. That costs a prompt prefill per turn, but it guarantees both models read
the same history including your interjections, and makes "stop, edit, resume"
trivially correct. When the log approaches the context window, the oldest chatter is
dropped and a notice is posted; the topic and introduction are pinned.

### Reasoning models

Qwen 3.5 emits a `<think>` block. `ThinkingStripper` splits it from the answer with a
pure state machine (tested in isolation, including delimiters split across tokens), so:

* reasoning is streamed to the pane for you to watch, and
* reasoning is **never** written to the shared log or fed back to the other model.

Per seat you can choose `.stream` (show it), `.discard` (think but hide), or `.off`
(ask the chat template to disable thinking via `enable_thinking: false`).

### Web search

Both endpoints of Tavily are exposed to the models as native tool calls, which Qwen 3.5
emits as `<tool_call>` blocks and MLX Swift dispatches automatically:

| Tool | Endpoint | Use |
| --- | --- | --- |
| `web_search` | `POST /search` | checkable claims, find sources |
| `fetch_page` | `POST /extract` | read a full page when a snippet is not enough |

Tool results come back to the model as `role: "tool"` messages, so it can cite them.
A failed tool is reported *to the model* as text, not thrown — a dead network kills a
turn's citation, not the conversation.

The API key defaults to the project's dev key and can be overridden with the
`TAVILY_API_KEY` environment variable or `--key` on the CLI. Set `webSearchEnabled =
false` on a seat to deny it tools entirely.

---

## Requirements

* macOS 14+ on Apple Silicon (built and tested on macOS 26.6, M3)
* Swift 6.2+ toolchain (built with Swift 6.3.3 / Xcode 26.6)
* ~5 GB free RAM for the two default seats, ~3 GB disk for the weights

### One extra step: MLX's Metal kernels

`swift build` compiles MLX's C/C++ core but **not** its Metal kernels — those ship
precompiled inside the `Cmlx.xcframework` attached to each `mlx-swift` release. Without
them MLX aborts with `Failed to load the default metallib` on the first GPU op.

`tools/fetch-metal.sh` downloads that framework once (~190 MB), extracts
`default.metallib`, and installs it as `mlx.metallib` next to the built binary, which is
the first place MLX looks. `tools/make-app.sh` calls it automatically, so for the app
bundle there is nothing to do; for `swift run` do it once after the first build:

```bash
./tools/fetch-metal.sh
```

## Build and run

```bash
# GUI as a double-clickable app bundle (fetches the Metal kernels if needed)
./tools/make-app.sh && open dist/ChatBots.app

# GUI straight from the terminal
./tools/fetch-metal.sh    # once, after the first build
swift run ChatBots

# tests (no models needed — the engine is stubbed)
swift test

# headless conversation, real models
swift run chatbots-cli --topic "Why are eggs not round?" --turns 4

# measure both seats (and prove a checkpoint works) without a full debate
swift run chatbots-cli --benchmark --max-tokens 200
```

`chatbots-cli --help` documents the other flags (`--model-a`, `--model-b`,
`--no-thinking`, `--key`). Because the CLI shares `ChatBotsCore` with the app, it is
the fastest way to check that an engine change actually works.

Weights are downloaded from the Hugging Face Hub on first use and cached in
`~/.cache/huggingface/hub`, so the first Start includes a download (~3 GB) and later
ones are local.

## Swapping in a different model

Edit the seat spec in `ChatBotsApp.swift` / the controller defaults, or on the CLI:

```bash
swift run chatbots-cli --model-a mlx-community/Qwen3.5-4B-MLX-4bit \
                       --model-b mlx-community/Qwen3.5-9B-MLX-4bit
```

Any checkpoint `mlx-swift-lm` can load will work. Vocabularies may differ between
models — that is fine here, because each seat tokenizes its own prompt.

## Known limits

* Turn order is fixed alternation; models cannot skip or address each other by name.
* Prompt history is a sliding window, not a summary: very long conversations lose the
  oldest messages rather than compressing them.
* Two 4-bit 4B models co-resident is comfortable on 24 GB; a much larger seat B will
  need seat A unloaded (`Models` menu has no unload yet) or a bigger machine.
* `MLXLMCommon`'s released 3.x line does not surface reasoning configuration, so
  `<think>` handling is ours (`ThinkingStripper`) rather than the library's, and tool
  dispatch is driven from `MLXEngine` rather than the session's own loop. Both are
  consequences of the pinned 3.31.4 API; see the comment in `MLXEngine.generate`.
* Measured on an M3: ~30 tokens/s per seat, ~20 s for a 500-token opening statement.
* Both seats are GPU-only — see the benchmark table above for why CPU offload is not an
  option for this checkpoint.
