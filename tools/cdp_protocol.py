"""The DevTools transport: loopback validation, the target list, and a text-frame websocket.

Split out of `cdp.py`, which keeps the browser-driving `Chrome` class. Everything here refuses
what it cannot prove safe — a host that is not loopback, a port out of range, a byte count that
is not bounded — because those checks are what make the plaintext, run-time-built endpoint below
a property of the code rather than an assumption.
"""

from __future__ import annotations

import base64
import os
import socket
import struct
import time

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
    anything else is a refusal rather than a URL.
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


class WebSocket:
    """A client WebSocket, text frames only, no fragmentation."""

    sock: socket.socket
    _buffer: bytes

    def __init__(self, url: str, timeout: float = 20) -> None:
        # semgrep's insecure-websocket rule flags the two `ws`-scheme URL literals just below.
        # It is right that they use the unencrypted scheme and not TLS — the peer is Chrome's
        # DevTools endpoint on the loopback interface — and what the rule cannot see is the host
        # check a few lines down, which refuses any endpoint that is not loopback before a
        # socket is opened. This comment records that finding as deliberate rather than ignored; the
        # written waiver is in `tools/analysis-waivers.txt`.
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
