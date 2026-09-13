# ChatBots

Two or more local LLMs argue with each other about a topic you choose, while you watch.

You type a question. The models take turns answering each other — reading the whole
conversation, disagreeing, building on it — and you decide when to stop. No account, no API
key, nothing leaves your Mac.

![two panes, one conversation](docs/web-screenshot.png)

## What you get

**Two modes, because a show and an investigation want different things.**

* **Show** — give strong personalities a topic and watch them argue. No consensus required and
  no end condition. 36 characters: the Alpha, the Villain, the Skeptic, the Troll, the
  Peacemaker, the Grudge Holder…
* **Research Team** — specialists investigate a question from different methods and produce a
  report you can act on, with every claim labelled as fact, sourced, inference, assumption,
  opinion or scenario, and the disagreements and gaps named rather than hidden. The Moderator
  runs the investigation rather than only writing it up: it decides what the question still owes
  and hands the next piece of work to whichever analyst's method fits it.

**The participants have names.** Agent 1 is given a female name and Agent 2 a male one, drawn
at random from English, French, German, Spanish (Latino), Brazilian Portuguese and Italian
lists — so a conversation reads as two people talking rather than as two seat numbers. The
choice is saved with your settings and stays for that conversation.

**Two front ends, one engine.** A macOS app with the models side by side, and a web interface
at `http://localhost:7788` for any browser, including your phone. They are clients of the same
conversation engine, so anything you can do in one you can do in the other.

The website is the one part of this that is reachable from off the Mac: it listens on every
network interface, and the API behind it has no password. Anyone who can reach port 7788 on the
same network — a shared or untrusted Wi-Fi, say — can read every kept conversation, start,
pause and steer runs, change the topic and the seats, upload documents, and open any share
link. That is deliberate, because reaching it from your phone is a real feature; what matters
is that the cost is visible. `bash tools/start-web-desktop.sh --local-only` binds it to this Mac
alone. The engine itself is always loopback-only, and with Caddy not installed the website is
too.

**Nothing is lost, and it can be shared.** Every conversation is written to disk as it runs, so
closing the window — or quitting — does not lose it. **Kept** in either front end reopens one,
deletes the ones you are done with, or gives you a read-only link that replays it in a browser.
**Save** exports any conversation, or a finished report, as a text or Markdown file.

**Say who you are, and who is talking.** The human moderator has a name and, if you want one, a
way of arguing — drawn from the same library the participants use. It shapes how your
interjections are read, and it tags your messages in the log and the export. Under each
contribution, two buttons let you mark whether it moved the argument forward; the scorecard
sits in the status bar, and votes are never sent to a model.

**You do not have to invent a session.** Ten hand-written line-ups and sixteen ready-made
questions, each paired with the panel that suits it — *"Does the trial design support the
claim?"* is the wrong question for a room of comedians. **Line-up** applies either one in a
single step, or draws a random room from a seed you can read in the log and repeat.

## Quick start

```bash
git clone https://github.com/Pummelchen/ChatBots.git
cd ChatBots
bash tools/install.sh
```

The installer is written for a Mac with nothing set up on it. It installs a Swift toolchain if
you have none, downloads about 3 GB of models, builds the app, and finishes by loading a model
and generating a few tokens — so you find out *then* whether it works, not later.

Then pick one, or run all three — they share one conversation engine, so a conversation
started in the app appears in the browser:

```bash
bash tools/start-app.sh           # the macOS app, plus an API server for the website
bash tools/start-web-desktop.sh   # the website, two-pane desktop layout
bash tools/start-web-mobile.sh    # the website, forced into the phone layout
```

The desktop app is also at `~/Applications/ChatBots.command`. Each script takes `--help`.

One thing the website does that the app does not: it listens on every network interface, so a
phone on the same Wi-Fi can open it — and so can anyone else on that network, because the API
has no password. `bash tools/start-web-desktop.sh --local-only` keeps it on this Mac. See
[Using the website](https://github.com/Pummelchen/ChatBots/wiki/Using-the-website).

## Documentation

Full guides are in the **[wiki](https://github.com/Pummelchen/ChatBots/wiki)**:

| Page | What it covers |
| --- | --- |
| [Installing](https://github.com/Pummelchen/ChatBots/wiki/Installing) | requirements, what the installer does, fixing a failed setup |
| [Using the desktop app](https://github.com/Pummelchen/ChatBots/wiki/Using-the-desktop-app) | every control, and what it is for |
| [Using the website](https://github.com/Pummelchen/ChatBots/wiki/Using-the-website) | the browser and phone interface, and the three start scripts |
| [Personas](https://github.com/Pummelchen/ChatBots/wiki/Personas) | who can take part, and how to choose |
| [Running a research session](https://github.com/Pummelchen/ChatBots/wiki/Running-a-research-session) | budgets, the moderator assigning the work, and reading the report |
| [Keeping and sharing](https://github.com/Pummelchen/ChatBots/wiki/Keeping-and-sharing) | reopening a past conversation, share links and replay, where the files are, exporting one |
| [Line-ups and scenarios](https://github.com/Pummelchen/ChatBots/wiki/Lineups-and-scenarios) | choosing who is in the room, and what they are put in front of |
| [Taking part](https://github.com/Pummelchen/ChatBots/wiki/Taking-part) | your own name and persona, cutting in, and scoring the argument |
| [Using cloud models](https://github.com/Pummelchen/ChatBots/wiki/Using-cloud-models) | DeepSeek, LM Studio, or any OpenAI-compatible server |
| [Documents and images](https://github.com/Pummelchen/ChatBots/wiki/Documents-and-images) | giving the models something to read or look at |
| [Troubleshooting](https://github.com/Pummelchen/ChatBots/wiki/Troubleshooting) | when it will not start, crashes, or is slow |
| [How it works](https://github.com/Pummelchen/ChatBots/wiki/How-it-works) | the architecture, if you are curious |
| [What is left to do](https://github.com/Pummelchen/ChatBots/wiki/What-is-left-to-do) | the open work, and the limits that are accepted |
| [Security policy](SECURITY.md) | what leaves the machine, and how to report a vulnerability |

## Requirements

Apple silicon (M1 or later) — the models run on the GPU, and Intel Macs are not supported.
**macOS 26 or newer** — the desktop app reaches the engine over WebTransport, which requires it.
The app uses that transport and nothing else; the website is the HTTP side of the same engine.
Around 8 GB of free disk space; 16 GB of memory is comfortable.

## Licence

MIT — see [LICENSE](LICENSE). The app embeds third-party packages, and their notices travel with
every build: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
