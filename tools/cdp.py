#!/usr/bin/env python3
"""A minimal Chrome DevTools Protocol client, for accurate device emulation.

Why this exists rather than Chrome's command-line screenshot flags:

`--window-size` is in *physical* pixels and `--force-device-scale-factor` multiplies the CSS
viewport as well as the output, so the two cannot be set independently. Asking for a 390-point
iPhone at 3× through the command line produced a 1170-point layout — the page thought it was
on a desktop, and the screenshot clipped it. That failure is worth recording, because the
output looked plausible and only the layout report revealed it.

The DevTools protocol can set the two independently:
`Emulation.setDeviceMetricsOverride` takes a CSS width, a CSS height and a device scale
factor, which is exactly what a real phone reports.

Only what is needed is implemented: an HTTP upgrade, text frames, and four CDP calls. Chrome
requires client frames to be masked and closes the connection if they are not, so that much
is done properly.
"""

from __future__ import annotations

import base64
import http.client
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
from typing import Self

# `json.load`/`json.loads` hand back `Any`, and a DevTools reply is genuinely dynamic until a
# call site reads a field. These aliases name what that boundary actually carries — a JSON
# value, and an object whose keys are strings — so the signatures below stay precise and the
# one place a field is trusted is the place it is narrowed.
type JsonValue = (
    None | bool | int | float | str | list[JsonValue] | dict[str, JsonValue]
)
type JsonObject = dict[str, JsonValue]

# This client drives a headless Chrome on the machine it runs on, so its endpoints are
# loopback and nothing else. The websocket is deliberately unencrypted for exactly that reason:
# TLS on a loopback debugging port would mean managing a certificate without changing who can
# reach it. The safety property is the host check below, not the scheme, which is why a host
# outside this set is refused rather than trusted.
LOOPBACK_HOSTS: frozenset[str] = frozenset({"127.0.0.1", "localhost", "::1"})
DEVTOOLS_HOST: str = "127.0.0.1"

# The /json target list is a few kilobytes even with many tabs open. Reading a bounded prefix
# keeps a stuck or hostile local service from making this client allocate without limit.
MAX_TARGET_LIST_BYTES: int = 1 << 20


def require_loopback_host(host: str) -> str:
    """Return `host` when it names the loopback interface, and refuse anything else.

    Refusing here — before a socket is opened or a URL is built — is what makes the plaintext
    websocket and the dynamic HTTP URL below safe properties of the code rather than
    assumptions a reader or a scanner has to make.
    """
    if host not in LOOPBACK_HOSTS:
        allowed = ", ".join(sorted(LOOPBACK_HOSTS))
        raise DevToolsError(
            f"refusing non-loopback DevTools host {host!r} (expected {allowed})"
        )
    return host


def require_valid_port(port: int) -> int:
    """Return `port` when it is a usable TCP port, and refuse anything else."""
    if not 0 < port < 65536:
        raise DevToolsError(f"refusing out-of-range DevTools port: {port}")
    return port


def devtools_targets_url(port: int) -> str:
    """The `http://` URL of the DevTools target list, built only from loopback values.

    The scheme is a fixed literal and both host and port pass through the checks above, so no
    part of this URL can be steered from outside this process — in particular there is no way
    for it to become a `file://` read.
    """
    host = require_loopback_host(DEVTOOLS_HOST)
    return f"http://{host}:{require_valid_port(port)}/json"


class DevToolsError(RuntimeError):
    pass


def chrome_devtools_port(profile: str, timeout: float = 30.0) -> int:
    """The port Chrome bound to, read from the file it writes into its own profile.

    `--remote-debugging-port=0` asks Chrome for a free port instead of naming one, and it records
    what it chose in `<profile>/DevToolsActivePort` — first line the port, second the browser's
    websocket path. The value is parsed and validated like any other port, so a file holding
    anything else is a refusal rather than a URL (A164).
    """
    path = os.path.join(profile, "DevToolsActivePort")
    deadline = time.time() + timeout
    reason = "the file was never written"
    while time.time() < deadline:
        try:
            with open(path, encoding="utf-8") as handle:
                first = handle.readline().strip()
        except OSError as error:
            reason = str(error)
        else:
            try:
                return require_valid_port(int(first))
            except ValueError:
                reason = f"the first line was not a number: {first!r}"
            except DevToolsError as error:
                reason = str(error)
        time.sleep(0.1)
    raise DevToolsError(f"Chrome never recorded a debugging port in {path}: {reason}")


class _WebSocket:
    """A client WebSocket, text frames only, no fragmentation."""

    sock: socket.socket
    _buffer: bytes

    def __init__(self, url: str, timeout: float = 20) -> None:
        # semgrep's insecure-websocket rule flags the two `ws`-scheme URL literals just below.
        # It is right that they use the unencrypted scheme and not TLS — the peer is Chrome's
        # DevTools endpoint on the loopback interface — and what the rule cannot see is the host
        # check a few lines down, which refuses any endpoint that is not loopback before a
        # socket is opened. This comment, and AUDIT/ledger.json's A09 entry, record that finding
        # as deliberate rather than ignored.
        if not url.startswith("ws://"):
            raise DevToolsError(f"unsupported websocket url: {url}")
        rest = url[len("ws://") :]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        # The host is validated, so the plaintext transport cannot leave this machine.
        self.sock = socket.create_connection(
            (require_loopback_host(host), require_valid_port(int(port or 80))),
            timeout=timeout,
        )
        self.sock.settimeout(timeout)
        self._buffer = b""

        key = base64.b64encode(os.urandom(16)).decode()
        handshake = (
            f"GET /{path} HTTP/1.1\r\n"
            f"Host: {hostport}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(handshake.encode())

        header = b""
        while b"\r\n\r\n" not in header:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise DevToolsError("connection closed during handshake")
            header += chunk
        if b"101" not in header.split(b"\r\n")[0]:
            raise DevToolsError(f"upgrade refused: {header.splitlines()[0]!r}")
        # Anything after the handshake belongs to the frame stream.
        self._buffer = header.split(b"\r\n\r\n", 1)[1]

    # ── Framing ──────────────────────────────────────────────────────────────────────

    def send(self, text: str) -> None:
        payload = text.encode()
        header = bytearray([0x81])  # FIN + text opcode
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < (1 << 16):
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        # A client frame must be masked; Chrome closes the socket otherwise.
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def _read_exactly(self, count: int) -> bytes:
        while len(self._buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise DevToolsError("connection closed")
            self._buffer += chunk
        result, self._buffer = self._buffer[:count], self._buffer[count:]
        return result

    def receive(self) -> str:
        """One text message, skipping control frames and joining fragments."""
        pieces: list[bytes] = []
        while True:
            first, second = self._read_exactly(2)
            fin = first & 0x80
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exactly(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exactly(8))[0]
            payload = self._read_exactly(length)

            if opcode == 0x8:  # close
                raise DevToolsError("server closed the websocket")
            if opcode == 0x9:  # ping
                self.sock.sendall(b"\x8a\x80" + os.urandom(4))
                continue
            if opcode == 0xA:  # pong
                continue
            pieces.append(payload)
            if fin:
                return b"".join(pieces).decode()

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


class Chrome:
    """A headless Chrome instance driven over the DevTools protocol."""

    binary: str
    port: int
    profile: str
    private_profile: bool
    process: subprocess.Popen[bytes] | None
    socket: _WebSocket | None
    _next_id: int

    def __init__(self, binary: str, port: int = 0, profile: str | None = None) -> None:
        self.binary = binary
        # Zero asks Chrome for a free port, and `start` reads back which one it got. A fixed default
        # port is what let a second run either fail to start or — worse — reach the browser the first
        # run had already opened, because the endpoint it waits for is just a port on loopback (A164).
        self.port = port
        # `None` means "make this run a directory of its own", which `start` does with `mkdtemp`.
        # A caller that names one keeps it, and this class never removes a directory it did not make.
        self.private_profile = profile is None
        self.profile = profile or ""
        self.process = None
        self.socket = None
        self._next_id = 1

    def __enter__(self) -> Self:
        self.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.stop()

    def start(self, url: str = "about:blank") -> None:
        if self.private_profile:
            # A directory of this run's own. `mkdtemp` creates it atomically, with mode 0700 and a
            # name nothing can predict or pre-create; the fixed `/tmp/chatbots-cdp` this replaced was
            # world-visible and shared, so a second run deleted the first run's profile and any local
            # process could pre-create, seed or watch that path (A164).
            self.profile = tempfile.mkdtemp(prefix="chatbots-cdp-")
        try:
            self.process = subprocess.Popen(
                [
                    self.binary,
                    "--headless=new",
                    "--disable-gpu",
                    "--hide-scrollbars",
                    "--no-first-run",
                    "--no-default-browser-check",
                    "--disable-extensions",
                    "--disable-background-networking",
                    f"--user-data-dir={self.profile}",
                    f"--remote-debugging-port={self.port}",
                    url,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            # The binary is not there or not runnable: remove the directory this run made rather than
            # leaving it in the temporary directory for the next run to find (A164).
            self.stop()
            raise

        if self.port == 0:
            try:
                self.port = chrome_devtools_port(self.profile)
            except DevToolsError:
                # Chrome never got as far as listening: stop it (and remove the profile we made)
                # rather than leaving both behind.
                self.stop()
                raise

        # Wait for the debugging endpoint, then find the page target.
        target: JsonObject | None = None
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                # semgrep's dynamic-urllib rule flags the `urlopen` below because its URL is
                # assembled at run time. The URL comes from `devtools_targets_url`, which pins
                # the scheme to `http` and passes a fixed loopback host and the port through
                # the same validation the websocket uses, so no external input can choose the
                # scheme or host; `r.read` is bounded so the reply cannot be unbounded. The
                # rule cannot see the pinning, the host check or the read limit, so the finding
                # is recorded as a deliberate waiver in AUDIT/ledger.json's A09 entry.
                with urllib.request.urlopen(
                    devtools_targets_url(self.port), timeout=2
                ) as r:
                    body = r.read(MAX_TARGET_LIST_BYTES + 1)
                if len(body) > MAX_TARGET_LIST_BYTES:
                    raise DevToolsError(
                        f"the DevTools target list exceeded {MAX_TARGET_LIST_BYTES} bytes"
                    )
                pages: JsonValue = json.loads(body)
                if not isinstance(pages, list):
                    # A reply that is not the target list means the endpoint is not ready
                    # yet, which is exactly what this loop waits out.
                    time.sleep(0.3)
                    continue
                target = next(
                    (
                        page
                        for page in pages
                        if isinstance(page, dict) and page.get("type") == "page"
                    ),
                    None,
                )
                if target:
                    break
            except (OSError, ValueError, http.client.HTTPException):
                time.sleep(0.3)
        if not target:
            self.stop()
            raise DevToolsError("Chrome's debugging endpoint never came up")

        endpoint = target.get("webSocketDebuggerUrl")
        if not isinstance(endpoint, str):
            self.stop()
            raise DevToolsError("Chrome's page target carries no websocket url")
        self.socket = _WebSocket(endpoint)

    def stop(self) -> None:
        """Shut down only the browser this instance started.

        Terminates by PID, never by name. A name-based kill would take out the Chrome a
        person is actually using, which is exactly the sort of collateral damage a capture
        tool must never cause — and the flag check below makes that mistake impossible even
        if this code is edited later.
        """
        if self.socket:
            self.socket.close()
            self.socket = None
        if self.process:
            pid = self.process.pid
            if self._is_our_headless_instance(pid):
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
            else:
                # Refuse rather than risk closing someone's browser.
                print(
                    f"  refusing to terminate pid {pid}: not the headless instance",
                    file=sys.stderr,
                )
            self.process = None
        # Only a directory this class made is removed. A caller that named a profile keeps it — a
        # capture tool that deleted a directory it was pointed at would be the same collateral damage
        # the pid check above exists to prevent (A164).
        if self.private_profile and self.profile:
            shutil.rmtree(self.profile, ignore_errors=True)
            self.profile = ""

    def _is_our_headless_instance(self, pid: int) -> bool:
        """True only for a headless Chrome carrying this instance's private profile."""
        try:
            out = subprocess.run(
                ["ps", "-p", str(pid), "-o", "command="],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            ).stdout
        except (OSError, subprocess.TimeoutExpired):
            return False
        # The configured profile, not a hard-coded default: a caller that passes its own
        # --user-data-dir must still be able to stop the Chrome it started, or the next
        # start() rmtree's the profile directory and races for the debugging port.
        return "--headless" in out and self.profile in out

    def call(self, method: str, params: JsonObject | None = None) -> JsonObject:
        """Send a command and wait for its reply, ignoring events."""
        if not self.socket:
            raise DevToolsError("not connected")
        message_id = self._next_id
        self._next_id += 1
        self.socket.send(
            json.dumps({"id": message_id, "method": method, "params": params or {}})
        )
        while True:
            message: JsonValue = json.loads(self.socket.receive())
            if not isinstance(message, dict):
                raise DevToolsError(
                    f"{method}: reply was {type(message).__name__}, expected an object"
                )
            if message.get("id") != message_id:
                continue  # an event, not our reply
            if "error" in message:
                raise DevToolsError(f"{method}: {message['error']}")
            result = message.get("result")
            if not isinstance(result, dict):
                return {}
            return result

    def emulate(
        self, width: int, height: int, pixel_ratio: float, mobile: bool = True
    ) -> None:
        """Set the CSS viewport and the device pixel ratio, independently."""
        # The orientation has to match the metrics being set. capture-devices.py swaps width and
        # height for a landscape capture, and a page can read `screen.orientation`, so reporting
        # portraitPrimary there would let an orientation-aware layout settle into the wrong
        # arrangement even though the screenshot itself had the right shape. A square viewport is
        # treated as portrait, which is the conventional default.
        screen_orientation: JsonObject = (
            {"type": "landscapePrimary", "angle": 90}
            if width > height
            else {"type": "portraitPrimary", "angle": 0}
        )
        self.call(
            "Emulation.setDeviceMetricsOverride",
            {
                "width": width,
                "height": height,
                "deviceScaleFactor": pixel_ratio,
                "mobile": mobile,
                # A phone reports a touch screen; the interface does not depend on it, but a
                # layout that did would otherwise be tested in the wrong mode.
                "screenOrientation": screen_orientation,
            },
        )
        self.call(
            "Emulation.setTouchEmulationEnabled",
            {"enabled": mobile, "maxTouchPoints": 5},
        )

    def navigate(self, url: str, settle: float = 2.5) -> None:
        self.call("Page.enable")
        self.call("Page.navigate", {"url": url})
        # No load event is awaited: the page is live and always has a connection open, so
        # waiting for "network idle" would never return. A fixed settle is honest here and is
        # why the captures are reproducible.
        time.sleep(settle)

    def evaluate(self, expression: str) -> JsonValue:
        result = self.call(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": True},
        )
        inner = result.get("result")
        if not isinstance(inner, dict):
            return None
        return inner.get("value")

    def screenshot(self, path: str) -> None:
        result = self.call(
            "Page.captureScreenshot",
            # Beyond the viewport, so a long transcript is captured in full rather than cut
            # off at the fold.
            {"format": "png", "captureBeyondViewport": True},
        )
        data = result.get("data")
        if not isinstance(data, str):
            raise DevToolsError("Page.captureScreenshot returned no image data")
        with open(path, "wb") as handle:
            handle.write(base64.b64decode(data))

    def metrics(self) -> JsonObject:
        """What the page actually measured about itself."""
        value = self.evaluate(
            """(() => {
                const root = document.documentElement;
                const vw = Math.round(window.visualViewport?.width ?? window.innerWidth);
                const vh = Math.round(window.visualViewport?.height ?? window.innerHeight);
                const overflowing = [];
                for (const el of document.querySelectorAll('body *')) {
                    const r = el.getBoundingClientRect();
                    if (r.right > vw + 1 || r.width > vw + 1) {
                        const id = el.id ? '#' + el.id : '';
                        const cls = (typeof el.className === 'string' && el.className)
                            ? '.' + el.className.trim().split(/\\s+/).slice(0,2).join('.') : '';
                        overflowing.push(el.tagName.toLowerCase() + id + cls + '(' + Math.round(r.width) + ')');
                    }
                }
                overflowing.sort((a,b) => (parseInt(b.match(/\\((\\d+)\\)$/)?.[1]||0)) - (parseInt(a.match(/\\((\\d+)\\)$/)?.[1]||0)));
                return {
                    viewport: vw,
                    height: vh,
                    dpr: window.devicePixelRatio,
                    scrollWidth: root.scrollWidth,
                    device: document.body.dataset.device,
                    layout: document.body.dataset.layout,
                    overflowing: overflowing.slice(0, 8),
                    messages: document.querySelectorAll('.msg').length,
                };
            })()"""
        )
        if not isinstance(value, dict):
            raise DevToolsError(
                f"Runtime.evaluate returned {type(value).__name__}, expected an object"
            )
        return value
