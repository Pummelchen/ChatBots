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
| **Layout** | `Split` (two panes) or `Thread` (one chat-style conversation) |
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
| both asked at once | 27–32 tok/s | 27–30 tok/s |

Both seats use the GPU, and only one seat is ever allowed to touch it at a time — see
"One MLX caller at a time" below. In practice the conversation never even contends: a turn
needs the previous speaker's text to exist before the next seat can read it, so the loop
is sequential and the speaking seat always has the GPU to itself at the full ~30 tok/s.

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

### Why the transcript is an `NSScrollView`

`ScrollViewReader.scrollTo` is unusable in this view hierarchy. Every configuration of it
was tried and each one eventually froze the window:

| What was tried | Result |
| --- | --- |
| `scrollTo` per token, animated | window stops drawing within ~60 s |
| `scrollTo` per token, unanimated | same |
| `scrollTo` throttled to 250 ms | same |
| `scrollTo` once per completed turn | same |
| follow-the-tail timer at 500 ms, AppKit scroll | same |

Sampling the frozen process every time showed the main thread pinned in
`NSRunLoop.flushObservers` → `GraphHost.flushTransactions`: scrolling changes the scroll
content's size, which republishes the view graph, which scrolls again. It is a transaction
loop, not slowness — the app is busy, not blocked, which is why it looks alive but draws
nothing.

The transcript now lives in a plain `NSScrollView` (`AppKitScrollView`), scrolled through
AppKit's one-way `contentView.scroll(to:)` from a deferred main-queue turn, and **only when
a turn completes or begins** — never on a timer. That configuration ran an 11-turn,
8-minute conversation with the window responsive throughout. The bonus is proper macOS
overlay scrollbars and rubber-banding.

The honest trade-off: while a long answer streams, the newest lines can fall below the
fold until the turn ends, at which point the view jumps to the bottom. Scrolling smoothly
while text streams is the thing SwiftUI would not let us have here.

### Standard macOS window behaviour

The window is a completely ordinary macOS window: close / minimize / zoom traffic lights
(verified present, enabled and functional — zoom toggles the frame, minimize works, close
quits), draggable and resizable from every edge down to a 720×480 minimum and up to any
size, ⇧⌘P-style menu equivalents in File, a standard Window menu (Minimize, Zoom, Enter
Full Screen), and frame autosave so size and position survive relaunch.

One thing worth knowing if you edit the layout: `.windowResizability(.contentMinSize)`
combined with a fixed `.frame(...)` silently pins the window to exactly one size. The
scene uses `.contentSize` and the content view declares minimums only.

### Sampling settings

Both seats ship with the same sampler, declared once in `AgentSpec.QwenSampling`:

| Setting | Value |
| --- | --- |
| Thinking | on (`enable_thinking: true`) |
| Temperature | 1.0 |
| Top P | 0.95 |
| Top K | 20 |
| Min P | 0.0 |
| Presence penalty | 1.5 (UI convention) |
| Repetition penalty | 1.0 (neutral) |
| Max output tokens | 32,768 |

Two details worth knowing:

* **Presence penalty is signed.** MLX *subtracts* the value it is given, so a positive
  `1.5` would reward tokens already in the context — a repetition *bonus*. The preset
  stores `-1.5`, which is what the UI's "1.5" means. The sign is flipped in exactly one
  place (`QwenSampling.presencePenalty`) with a comment, and the pane header prints the
  magnitude so it matches the number you asked for. Verified by log: `presence=-1.50`.
* **Max output tokens is the whole budget, thinking included.** `thinkingBudget` is `0`,
  so 32,768 is a single cap rather than 32,768 *plus* a thinking allowance. A reasoning
  model can in principle spend all of it inside `<think>` and emit no answer; if that
  happens the pane now says so explicitly instead of just staying empty.

**Measured caveat on this combination.** With thinking *off*, this sampler drives
Qwen 3.5-4B into a degenerate attractor on open-ended prompts: output settled into one
8-gram repeated dozens of times with a distinct-word ratio of 0.10, and ran to the token
cap. Legitimate answers from the same model measured a repeated-8-gram rate of 0.00–0.14
against 0.79–0.91 for the loop, and `RepetitionDetector` now ends a turn once the rate
passes 0.30 — so this is caught rather than allowed to burn 32k tokens, but the *output*
is still poor at that setting. The middle and high thinking levels (which are the default)
produced no such loop in testing. If you want stable output with thinking off, consider a
lower temperature and a smaller presence-penalty magnitude.

The effective sampler is printed to stderr once per seat at startup, so a run can be
audited:

```
[ChatBots] Agent A sampler: temp=1.00 topP=0.95 topK=20 minP=0.00 presence=-1.50 repetition=1.00 maxOut=32768
```

### Copying text out

The panes contain **no selectable text**, deliberately. `.textSelection(.enabled)` inside
a pane is rebuilt every time the pane republishes (~20 Hz while a model streams), and each
rebuild re-runs the selection overlay's text scan, which triggers another layout pass. The
result is the same re-entrant update that stops the window drawing; it was found by
removing the modifier from one view at a time until the freezes stopped.

Instead, **Edit ▸ Copy Conversation (⇧⌘C)** copies the whole transcript as plain text.

### Thinking controls

Each pane header has its own thinking control (`think: Medium`), so the two seats can run
different reasoning budgets side by side. Note that the control's *menu* could not be
exercised by the automated GUI checks — synthetic `CGEvent` clicks and accessibility
presses do not open SwiftUI menus — so it was verified only by rendering, by its tooltip,
and by confirming that the label and engine both follow the seat's mode. Levels: **Off**, **Minimal** (128 reasoning
tokens), **Low** (512), **Medium** (2,048, the default), **High** (8,192) and
**Unlimited** (no ceiling). A change applies from that seat's next turn.

**These levels are budgets, not requests.** Qwen 3.5's chat template exposes exactly one
thinking knob — a boolean `enable_thinking` — and the pinned MLX release has no
budget-transition API, so there is no `reasoning_effort: "low"` for the model to honour.
What is genuinely controllable is how many tokens of reasoning are permitted before the
block is closed and an answer required, which is what each level enforces: reasoning text
is counted, and once the level's ceiling is reached the block is closed with the `</think>`
delimiter the model already knows. A model that finishes thinking early is unaffected, and
when a ceiling does bite the pane says so rather than hiding the truncation. Levels also
map to the nearest native template flag (`enable_thinking: false` for Off, plus a
`reasoning_effort` hint for checkpoints that understand one), so the same control stays
meaningful if a seat is pointed at another model family.

### Two window modes

A **Layout** switch in the bar (and View ▸ Window Layout) toggles between:

* **Side by side** (`Split`, the default) — one pane per seat, each with its own scroll
  position and its own header.
* **Single thread** (`Thread`) — one conversation, newest at the bottom, attributed and
  tinted by speaker, the way a group chat reads. The per-seat headers collapse into a
  two-line settings strip above the thread, and each message is aligned to its own side
  (Agent B right, Agent A left, the moderator centred and neutral).

Both modes render the same shared log from the same controller, so switching mid
conversation is lossless and instant. The choice is stored with
`@AppStorage("windowMode")` and survives relaunch.

Unified mode obeys the same two rules as the panes, for the same measured reasons: no
`.textSelection` on anything it rebuilds while text streams, and no `Menu` rebuilt on
streaming updates. Its settings strip depends on the seats' specs rather than their
streaming text, which is what keeps the thinking controls safe to put there.

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

### One MLX caller at a time

Every Metal-touching operation — loading weights and generating — goes through a
process-wide gate (`MLXGate`). This is not a performance choice, it is a correctness one:
**MLX's Metal backend is not safe to drive from two places at once.** Running a second
evaluation while another is in flight aborts inside
`mlx::core::metal::Device::get_command_encoder` / `fast::CustomKernel::eval_gpu` with
`EXC_BAD_ACCESS`, which macOS reports as `Segmentation fault: 11`.

That is not theoretical — this app produced two such crash reports before the gate
existed, roughly 4–6 minutes into a conversation, and again in an early version of
`--benchmark` that asked both seats to generate simultaneously. An earlier revision of
this README claimed two concurrent seats "cleanly time-share at half rate each"; that
measurement was wrong, because the two seats were corrupting each other's command-encoder
state rather than sharing it.

With the gate, three back-to-back runs of simultaneous generation finish cleanly, each
seat at its full solo rate, and the app has run 7+ turn conversations with no crash
reports.

The cost is close to zero: an unrelated second seat is the only thing that ever waits, and
concurrent GPU work would be serialised by the hardware regardless.

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

## Known issue: intermittent GPU crash

There is an **unresolved, intermittent crash** in MLX's Metal layer. It appears roughly
once every few conversations in the GUI, as `Segmentation fault: 11` while the faulting
stack is entirely inside MLX:

```
mlx::core::fast::CustomKernel::eval_gpu(...)
mlx::core::gpu::eval(...)  ->  mlx::core::async_eval(...)
```

What has been ruled out, by measurement rather than assumption:

* **Not memory.** `chatbots-cli --memory-probe` shows 4.5 GB of a 23.3 GB limit in use
  with only ~126 MB of buffer cache, holding steady across turns. There is no pressure.
* **Not two seats generating at once.** All MLX entry points now go through `MLXGate`
  (see "One MLX caller at a time"), and the turn loop is sequential besides.
* **Not the CLI.** Three consecutive 8-turn `chatbots-cli` runs complete cleanly with no
  crash reports.
* **Not the transcript fix.** The freeze described below is a separate, solved problem.

The remaining correlation is that it has only been observed in the **GUI**, which renders
its window through Metal at the same time MLX is evaluating. That points at a race inside
MLX's Metal command-encoder handling — it aborts constructing a compute command encoder,
which is exactly what a second concurrent user of the Metal device would disturb. It is
not reachable from application code: everything this app controls is already serialised,
so it needs a fix in [mlx-swift](https://github.com/ml-explore/mlx-swift) /
[mlx](https://github.com/ml-explore/mlx).

If you hit it, relaunching is safe — the only cost is the conversation in flight.

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
* Only one seat may touch MLX at a time — see "One MLX caller at a time".
* The transcript auto-scrolls once per turn, not continuously while streaming — see
  "Why the transcript is an `NSScrollView`".
* Both seats are GPU-only — see the benchmark table above for why CPU offload is not an
  option for this checkpoint.
