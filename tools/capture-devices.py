#!/usr/bin/env python3
"""Capture the web interface at every device profile, offscreen.

Uses headless Chrome, so nothing appears on the desktop: `--headless` renders without a
window and `--screenshot` writes the result straight to a file. Each profile is captured at
its real CSS viewport and device pixel ratio, which is the whole point — a layout that looks
right at 390 points can still break at 360, and those are the widths real entry-level phones
report.

    python3 tools/capture-devices.py                  # every profile
    python3 tools/capture-devices.py --class phone    # one class
    python3 tools/capture-devices.py --id galaxy-a13  # one device
    python3 tools/capture-devices.py --common         # one per distinct shape

Output goes to `captures/`, with an index page that tiles them so the results can be
compared side by side. Exits non-zero if any capture fails or renders no messages, so it can
be wired into a check.

The server is started and stopped by this script, on its own ports, and it seeds the
conversation so there is realistic content to lay out.
"""

from __future__ import annotations

import argparse
import http.client
import json
import pathlib
import shutil
import subprocess
import sys
import time
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from cdp import (  # the tools/ directory was put on the path just above
    Chrome,
    DevToolsError,
)

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parent.parent
OUT: pathlib.Path = ROOT / "captures"
PORT: int = 7791  # the interface
ENGINE_PORT: int = 7792  # the engine behind it
CHROME: str = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# A phone profile is the strictest test, so landscape is worth checking too: it is where a
# header can eat the whole screen.
ORIENTATIONS: tuple[str, ...] = ("portrait", "landscape")

# Caddy runs in front of an engine this script has already waited for, so readiness is normally
# sub-second. The retry bound is wall-clock time rather than a count of attempts, and the pause
# applies to every retry path, so a proxy that answers before it is ready cannot make this loop
# spin and a slow-but-reachable one is not given up on for a reason that has nothing to do with
# readiness.
CADDY_READY_TIMEOUT: float = 15.0
CADDY_RETRY_INTERVAL: float = 0.5

# The engine's profile list is JSON over its own loopback API, so a value's shape is only
# known at run time. `Any` is the honest type at that boundary: every field is read by name
# and used the way the engine's documented schema defines it, and the one place this script
# needs a number it narrows the CDP reply with `isinstance` instead.
type JsonObject = dict[str, Any]


def profiles() -> list[JsonObject]:
    """Ask the running server for the profile list, so there is one source of truth."""
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    try:
        conn.request("GET", "/api/devices")
        body = conn.getresponse().read()
    finally:
        # Closed on the failure paths as well as the success path: `request` or
        # `getresponse` can raise before the old `close` was reached, leaving the socket
        # open until the garbage collector ran. The body is read in full above, so nothing
        # is used after the close; the caller is handed the parsed list, never this
        # connection.
        conn.close()
    return json.loads(body)["profiles"]


def server_is_up() -> bool:
    try:
        conn = http.client.HTTPConnection("127.0.0.1", ENGINE_PORT, timeout=2)
        try:
            conn.request("GET", "/api/health")
            ok = conn.getresponse().status == 200
        finally:
            # Closed on the failure paths as well as the success path, for the same reason
            # as `caddy_process`: a raise from `request` or `getresponse` used to skip the
            # close, and `wait_for_server` calls this in a loop of up to 90 attempts, so
            # every failed probe leaked a socket until the garbage collector ran. Only the
            # boolean is returned, never the connection.
            conn.close()
        return ok
    except (OSError, http.client.HTTPException):
        return False


def wait_for_server(timeout: float = 90) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if server_is_up():
            return True
        time.sleep(1)
    return False


def run_directory() -> pathlib.Path:
    """This tool's runtime directory, created if it is not there yet.

    `.run/` is gitignored, so it does not exist on a fresh checkout, and this tool writes its
    engine log into it before Caddy writes its config. `RunDirectory.swift` decides the same
    question for the app and the engine — one answer, shared — and this mirrors the invariant
    that matters here rather than its whole policy: one place decides where runtime state
    lives. The application-support fallback is deliberately not mirrored, because unlike the
    installed app this tool builds and serves the checkout it lives in, so its log belongs
    beside that checkout's other state. The start scripts spell this `mkdir -p "$ROOT/.run"`.
    """
    directory = ROOT / ".run"
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def output_directory() -> pathlib.Path:
    """Where captures are written, created if it is not there yet.

    `captures/` is gitignored, so it does not exist on a fresh checkout, and every writer in
    this tool needs it: `capture()` has Chrome write a screenshot into it, `downscale()` writes
    the display copy beside that, and `build_index()` writes the index page into it. `main()`
    used to be the only place that created it, which made those writes correct from the
    documented entry point and wrong from every other path through the file — the same shape
    `run_directory()` above answers for `.run/`. One place decides where captures live and
    that it exists, and all three writers go through it, so a caller that never runs `main()`
    cannot write into a directory that is not there.
    """
    OUT.mkdir(parents=True, exist_ok=True)
    return OUT


def start_servers() -> subprocess.Popen[bytes] | None:
    """Start the engine, and Caddy if it is present. Returns the engine process."""
    if server_is_up():
        print("  (a server is already listening; using it)")
        return None

    binary = ROOT / ".build" / "release" / "chatbots-cli"
    if not binary.exists():
        print("Building the engine first…")
        subprocess.run(
            ["swift", "build", "-c", "release"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    # The engine's stderr is kept: the client reports what it measured about its own layout,
    # and that report is how alignment is actually verified rather than eyeballed.
    log = (run_directory() / "capture-engine.log").open("w")
    engine = subprocess.Popen(
        [
            str(binary),
            "--serve",
            "--port",
            str(ENGINE_PORT),
            "--seed",
            "--topic",
            "Why are eggs not round?",
        ],
        cwd=ROOT,
        stdout=log,
        stderr=log,
    )

    if not wait_for_server():
        engine.terminate()
        raise SystemExit("The engine did not start.")
    return engine


def capture_caddyfile() -> str:
    """The Caddyfile a capture run uses.

    The repository's own, on the capture ports, plus one directive the repository's does not carry.

    The site address is host-less on purpose — that is what lets a phone reach the page — and a
    host-less address makes Caddy bind **every** interface, so this used to publish the whole
    unauthenticated `/api/*` surface to the network for the duration of a screenshot run. A capture run
    is not somebody choosing to share; it is a developer taking pictures on their own machine.
    `start.sh` inserts the same directive for `--local-only`, and the reason is the same one the
    Caddyfile documents: the site address names the Host a request must carry, it does not pick the
    listener, so `bind` is what chooses the interface (A183).
    """
    text = (
        (ROOT / "Caddyfile")
        .read_text()
        .replace("http://:7788", f"http://:{PORT}")
        .replace("127.0.0.1:7789", f"127.0.0.1:{ENGINE_PORT}")
    )
    return text.replace(f"http://:{PORT} {{", f"http://:{PORT} {{\n\tbind 127.0.0.1", 1)


def caddy_process() -> subprocess.Popen[bytes] | None:
    if not shutil.which("caddy"):
        return None
    config = run_directory() / "Caddyfile.capture"
    config.write_text(capture_caddyfile())
    process = subprocess.Popen(
        ["caddy", "run", "--config", str(config), "--adapter", "caddyfile"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + CADDY_READY_TIMEOUT
    while time.monotonic() < deadline:
        # A caddy that has already exited will never answer, so there is nothing to wait for:
        # stop now and let the caller serve from the engine instead. `terminate` below is a
        # no-op for a process that has already been reaped.
        if process.poll() is not None:
            break
        status: int | None = None
        try:
            conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=2)
            try:
                conn.request("GET", "/api/health")
                status = conn.getresponse().status
            finally:
                # Closed on the failure paths as well as the success path: the probe used to
                # leak its connection whenever `request` or `getresponse` raised, leaving the
                # socket open until the garbage collector ran. The caller is given the caddy
                # process, never this connection, so closing it here is the whole contract.
                conn.close()
        except (OSError, http.client.HTTPException):
            pass
        if status == 200:
            return process
        # Paced on every path. This used to sleep only inside `except`, so a proxy that
        # answered with anything other than 200 was retried with no delay at all; and the loop
        # counted 30 attempts rather than time, so what it waited for depended on how fast the
        # endpoint responded rather than on whether it had become ready.
        time.sleep(CADDY_RETRY_INTERVAL)
    process.terminate()
    return None


def capture(
    browser: Chrome,
    profile: JsonObject,
    mode: str,
    orientation: str,
    name: str,
) -> JsonObject | None:
    """Emulate one profile, screenshot it, and report what the page measured.

    Returns the page's own layout metrics, or None if the capture failed. The metrics are the
    point: a screenshot says what it looks like, the numbers say whether anything is wider
    than the screen, which is the failure that is easy to miss by eye at 3x.

    `name` is the file name to write, resolved through `output_directory()` so that the
    directory Chrome is handed a path inside exists before the write, whatever called this.
    """
    shot = output_directory() / name
    width, height = profile["width"], profile["height"]
    if orientation == "landscape":
        width, height = height, width

    browser.emulate(
        width, height, profile["pixelRatio"], mobile=profile["class"] != "desktop"
    )
    url = f"http://127.0.0.1:{PORT}/?view={mode}&capture=1"
    try:
        browser.navigate(url, settle=2.0)
        metrics = browser.metrics()
        browser.screenshot(str(shot))
    except (DevToolsError, OSError, ValueError, KeyError) as error:
        # Every failure mode of a capture is reported, not swallowed: the caller counts it and
        # the run exits non-zero. Nothing here is expected to raise, so a broad set that still
        # names the possible causes beats a bare `except Exception`.
        print(f"    failed: {error}")
        return None
    if not shot.exists() or shot.stat().st_size == 0:
        print("    failed: no screenshot written")
        return None
    return metrics


def downscale(name: str) -> None:
    """Keep the capture at its real size but make a display copy, since a 3x phone capture is
    three thousand pixels tall and unreasonable in an index page.

    `name` is resolved through `output_directory()` for the same reason `capture()` does it:
    the thumbnail is written next to the capture, into a directory this function does not
    otherwise know has been created.
    """
    shot = output_directory() / name
    if shutil.which("magick"):
        subprocess.run(
            [
                "magick",
                str(shot),
                "-resize",
                "420x",
                str(shot.with_name(shot.stem + "-thumb.png")),
            ],
            check=False,
            capture_output=True,
        )


def build_index(rows: list[JsonObject]) -> None:
    """A page that tiles every capture, for comparing profiles at a glance."""
    cards = "\n".join(
        f"""  <figure>
    <img src="{r["file"]}" alt="{r["name"]}" loading="lazy">
    <figcaption><b>{r["name"]}</b><br>{r["width"]}×{r["height"]} @{r["pixelRatio"]}x · {r["class"]} · {r["mode"]}{" · landscape" if r["orientation"] == "landscape" else ""}</figcaption>
  </figure>"""
        for r in rows
    )
    (output_directory() / "index.html").write_text(f"""<!DOCTYPE html>
<meta charset="utf-8">
<title>ChatBots device captures</title>
<style>
  body {{ background:#101014; color:#ececf1; font:14px/1.5 -apple-system, system-ui, sans-serif; margin:0; padding:24px; }}
  h1 {{ font-size:20px; margin:0 0 4px; }}
  p.sub {{ color:#9a9aa8; margin:0 0 24px; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fill, minmax(240px, 1fr)); gap:20px; }}
  figure {{ margin:0; }}
  img {{ width:100%; border:1px solid #2a2a34; border-radius:10px; background:#17171d; display:block; }}
  figcaption {{ color:#9a9aa8; font-size:12px; margin-top:6px; }}
</style>
<h1>ChatBots — device captures</h1>
<p class="sub">{len(rows)} profiles, captured offscreen at their real CSS viewport and pixel ratio.</p>
<div class="grid">
{cards}
</div>
""")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--class", dest="device_class", choices=["phone", "tablet", "desktop"]
    )
    parser.add_argument("--id", dest="device_id")
    parser.add_argument(
        "--common", action="store_true", help="one capture per distinct viewport shape"
    )
    parser.add_argument("--mode", choices=["auto", "phone", "desktop"], default="auto")
    parser.add_argument(
        "--include-landscape",
        action="store_true",
        help="also capture phones in landscape",
    )
    parser.add_argument(
        "--keep-open", action="store_true", help="leave the servers running afterwards"
    )
    args = parser.parse_args()

    # The stale sweep goes through the helper too, so `main()` no longer carries a second,
    # independent way to create `captures/`: there is one place that decides it exists, and
    # this call and the writers' calls are the same mechanism rather than two that can drift.
    for stale in output_directory().glob("*.png"):
        stale.unlink()

    engine = start_servers()
    caddy = caddy_process()
    if caddy:
        print("  serving through Caddy")
    else:
        print("  serving through the engine (no Caddy)")

    try:
        available = profiles()
        selected = available
        if args.device_id:
            selected = [p for p in available if p["id"] == args.device_id]
        elif args.device_class:
            selected = [p for p in available if p["class"] == args.device_class]
        elif args.common:
            # One per distinct shape: two devices with the same viewport prove nothing twice.
            seen: set[tuple[int, int, float]] = set()
            unique: list[JsonObject] = []
            for p in available:
                if p.get("common"):
                    key = (p["width"], p["height"], p["pixelRatio"])
                    if key not in seen:
                        seen.add(key)
                        unique.append(p)
            selected = unique

        if not selected:
            print("No profiles matched.", file=sys.stderr)
            return 1

        print(f"Capturing {len(selected)} profile(s)…")
        rows: list[JsonObject] = []
        failures = 0
        overflows: list[tuple[Any, str, Any]] = []
        viewport_mismatches: list[tuple[Any, str, Any, Any]] = []
        empty_captures: list[tuple[Any, str]] = []

        # Each browser gets its own port and its own private profile, so two captures — or two people
        # capturing at once — cannot collide or reach each other's browser (A164).
        with Chrome(CHROME) as browser:
            for profile in selected:
                orientations: list[str] = ["portrait"]
                if args.include_landscape and profile["class"] == "phone":
                    orientations.append("landscape")
                for orientation in orientations:
                    mode = args.mode
                    if mode == "auto":
                        # What the client would choose for this device on its own.
                        mode = "thread" if profile["class"] == "phone" else "split"
                    file = f"{profile['id']}-{orientation}-{mode}.png"
                    print(f"  {profile['name']} ({orientation}, {mode})")
                    metrics = capture(browser, profile, mode, orientation, file)
                    if metrics is None:
                        failures += 1
                        continue

                    downscale(file)
                    row: JsonObject = {
                        "file": file,
                        "name": profile["name"],
                        "width": profile["width"],
                        "height": profile["height"],
                        "pixelRatio": profile["pixelRatio"],
                        "class": profile["class"],
                        "mode": mode,
                        "orientation": orientation,
                        "metrics": metrics,
                    }
                    rows.append(row)

                    # The page must have laid out at the width it was asked for, and nothing
                    # may be wider than it. Both are checked rather than assumed, because a
                    # capture that silently rendered at the wrong width looks plausible.
                    requested_width = (
                        profile["height"]
                        if orientation == "landscape"
                        else profile["width"]
                    )
                    if metrics["viewport"] != requested_width:
                        # A screenshot rendered at the wrong width looks plausible and would
                        # otherwise be published under this profile's name on a green run.
                        viewport_mismatches.append(
                            (
                                profile["name"],
                                orientation,
                                metrics["viewport"],
                                requested_width,
                            )
                        )
                        print(
                            f"    ! viewport {metrics['viewport']} != requested {requested_width}"
                        )
                    if metrics["overflowing"]:
                        overflows.append(
                            (profile["name"], orientation, metrics["overflowing"])
                        )
                    if not metrics["messages"]:
                        # An empty capture proves nothing about the layout and would otherwise
                        # be published under this profile's name on a green run — the same
                        # defect the viewport mismatch above is collected for.
                        empty_captures.append((profile["name"], orientation))
                        print("    ! no messages rendered — the capture has no content")

        # The three start scripts depend on the forced views behaving, so they are checked
        # here rather than assumed: `?view=phone` has to produce a phone-shaped page on a
        # desktop browser, and `?view=desktop` the two-pane one. That is what
        # tools/start-web-mobile.sh exists for.
        print("\nForced views, on a desktop-sized browser:")
        forced_failures: list[str] = []
        with Chrome(CHROME) as browser:
            for view, expected_device, expected_layout, expected_max_width in [
                ("phone", "phone", "thread", 440),
                ("desktop", "desktop", "split", 2000),
            ]:
                browser.emulate(1440, 900, 2.0, mobile=False)
                browser.navigate(
                    f"http://127.0.0.1:{PORT}/?view={view}&capture=1", settle=2.0
                )
                metrics = browser.metrics()
                body_width = browser.evaluate(
                    "Math.round(document.body.getBoundingClientRect().width)"
                )
                if not isinstance(body_width, int):
                    raise DevToolsError(
                        f"?view={view}: body width was {body_width!r}, not a number"
                    )
                ok = (
                    metrics["device"] == expected_device
                    and metrics["layout"] == expected_layout
                    and body_width <= expected_max_width
                    and not metrics["overflowing"]
                )
                print(
                    f"  ?view={view:8s} → device={metrics['device']:8s} "
                    f"layout={metrics['layout']:7s} body={body_width}pt "
                    f"{'ok' if ok else 'UNEXPECTED'}"
                )
                if not ok:
                    forced_failures.append(view)
        if forced_failures:
            print(f"\n  The forced view is wrong for: {', '.join(forced_failures)}")

        build_index(rows)

        # Every class that forces a non-zero exit is named in the summary, and `failed` is
        # computed once and used for both the verdict and the exit status, so the line a person
        # reads cannot disagree with the status they just got. The alternative — folding every
        # class into the `failed` figure — would be less honest, not more: a viewport mismatch
        # or an overflow still produced a file in `rows`, so calling it a capture failure
        # misstates what happened. `len(rows)` therefore stays what it is (captures written),
        # each class is reported by name, and the derived verdict closes the line.
        failed = bool(
            failures
            or overflows
            or forced_failures
            or viewport_mismatches
            or empty_captures
        )
        print(
            f"\n{len(rows)} captured, {failures} failed, "
            f"{len(viewport_mismatches)} viewport mismatch(es), "
            f"{len(empty_captures)} empty capture(s), "
            f"{len(overflows)} overflow(s), "
            f"{len(forced_failures)} forced-view failure(s) — "
            f"{'FAILED' if failed else 'OK'}"
        )
        if viewport_mismatches:
            print(
                "\nViewport mismatch — the page did not lay out at the requested width:"
            )
            for name, orientation, actual, requested in viewport_mismatches:
                print(
                    f"  {name} ({orientation}): rendered at {actual}, requested {requested}"
                )
        if empty_captures:
            print("\nNo messages rendered — a capture with no content proves nothing:")
            for name, orientation in empty_captures:
                print(f"  {name} ({orientation})")
        if overflows:
            print("\nHorizontal overflow — these are layout bugs:")
            for name, orientation, items in overflows:
                print(f"  {name} ({orientation}): {', '.join(items)}")
        else:
            print("No horizontal overflow in any profile.")
        print(f"\nOpen: {OUT / 'index.html'}")
        return 1 if failed else 0
    finally:
        if not args.keep_open:
            if caddy:
                caddy.terminate()
            if engine:
                engine.terminate()


if __name__ == "__main__":
    sys.exit(main())
