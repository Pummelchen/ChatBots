"""Paths, device profiles and the servers a capture run needs.

The setup half of `capture-devices.py`: it decides where `captures/` and `.run/` are, asks the
running engine for its device profiles, and starts (and stops) the engine and Caddy. Split out so
the capture code is about rendering rather than process management.
"""

from __future__ import annotations

import http.client
import json
import pathlib
import shutil
import subprocess
import time
from typing import Any

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
    log = (run_directory() / "capture-engine.log").open("w", encoding="utf-8")
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
    listener, so `bind` is what chooses the interface.
    """
    text = (
        (ROOT / "Caddyfile")
        .read_text(encoding="utf-8")
        .replace("http://:7788", f"http://:{PORT}")
        .replace("127.0.0.1:7789", f"127.0.0.1:{ENGINE_PORT}")
    )
    return text.replace(f"http://:{PORT} {{", f"http://:{PORT} {{\n\tbind 127.0.0.1", 1)


def caddy_process() -> subprocess.Popen[bytes] | None:
    if not shutil.which("caddy"):
        return None
    config = run_directory() / "Caddyfile.capture"
    config.write_text(capture_caddyfile(), encoding="utf-8")
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
