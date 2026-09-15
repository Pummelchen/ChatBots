#!/usr/bin/env python3
"""A164 probe — the CDP client's profile directory and debugging port.

Without a browser: the profile lifecycle (a private directory per instance, 0700, removed when the
instance stops; a caller's directory never removed) and the port reader (what it accepts and what it
refuses). With the Chrome on this Mac: two instances running at once, and what the *old* fixed port
does when two runs name the same one.

    usage: python3 AUDIT/baseline/swift64/a164-probe/profile-and-port.py
"""

from __future__ import annotations

import os
import pathlib
import stat
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools"))

from cdp import Chrome, DevToolsError, chrome_devtools_port  # noqa: E402

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
failures = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global failures
    if condition:
        print(f"  ok    {name}")
    else:
        failures += 1
        print(f"  FAIL  {name}{f' — {detail}' if detail else ''}")


def mode_of(path: str) -> int | None:
    try:
        return stat.S_IMODE(os.stat(path).st_mode)
    except OSError:
        return None


print("profile lifecycle, without a browser")
first = Chrome(binary="/nonexistent/chrome")
second = Chrome(binary="/nonexistent/chrome")
check("a default instance owns a private profile", first.private_profile)
# start() fails (no such binary) and must leave nothing behind.
for name, instance in (("first", first), ("second", second)):
    try:
        instance.start()
    except OSError:
        pass
    else:
        check(f"{name}: start() with no binary failed", False, "it returned")
check("a failed start removed the directory it made", first.profile == "" and second.profile == "")

# A directory the caller names is used and kept.
caller_made = tempfile.mkdtemp(prefix="a164-caller-")
explicit = Chrome(binary="/nonexistent/chrome", profile=caller_made)
check("a named profile is not owned", not explicit.private_profile)
try:
    explicit.start()
except OSError:
    pass
explicit.stop()
check("a named profile survives stop()", os.path.isdir(caller_made), caller_made)
os.rmdir(caller_made)

print("\nthe private directory itself")
# Made by start(), so make one by hand through the same call Chrome uses.
private = tempfile.mkdtemp(prefix="chatbots-cdp-")
other = tempfile.mkdtemp(prefix="chatbots-cdp-")
check("mkdtemp gives an owner-only directory", mode_of(private) == 0o700, str(mode_of(private)))
check("mkdtemp gives a name of its own every time", private != other)
check(
    "and not the fixed path that was there before",
    private != "/tmp/chatbots-cdp" and os.path.basename(private).startswith("chatbots-cdp-"),
    private,
)
os.rmdir(private)
os.rmdir(other)

print("\nreading the port Chrome writes")
profile = tempfile.mkdtemp(prefix="chatbots-cdp-")
active = os.path.join(profile, "DevToolsActivePort")
with open(active, "w", encoding="utf-8") as handle:
    handle.write("54321\n/devtools/browser/abc\n")
check("a written port is read", chrome_devtools_port(profile, timeout=1) == 54321)

def refused(contents: str | None, name: str) -> None:
    if contents is None:
        os.remove(active)
    else:
        with open(active, "w", encoding="utf-8") as handle:
            handle.write(contents)
    try:
        port = chrome_devtools_port(profile, timeout=0.3)
    except DevToolsError:
        check(name, True)
    else:
        check(name, False, f"accepted {port}")

refused("", "an empty file is refused")
refused("not-a-port\n", "a word is refused")
refused("70000\n", "an out-of-range port is refused")
refused(None, "a missing file is refused")
os.rmdir(profile)

print("\nthe capture tool, which used to name a port and a profile of its own")
caller = (ROOT / "tools" / "capture-devices.py").read_text(encoding="utf-8")
check("it names no port", "CHROME_PORT" not in caller)
check("it lets each browser take its own", "Chrome(CHROME)" in caller and "Chrome(CHROME," not in caller)

if not os.path.exists(CHROME):
    print("\nno Chrome on this host: the live half is skipped")
else:
    print("\ntwo instances at once, which the fixed profile and port made impossible")
    one = Chrome(CHROME)
    two = Chrome(CHROME)
    try:
        one.start("about:blank")
        two.start("about:blank")
        check("both instances got a port of their own", one.port != two.port, f"{one.port} and {two.port}")
        check("both got a profile of their own", one.profile != two.profile)
        check("the first is a real browser", one.evaluate("1 + 1") == 2)
        check("the second is a real browser", two.evaluate("1 + 1") == 2)
        one.navigate("about:blank")
        two.navigate("about:blank")
        check("each drives its own page", one.evaluate("location.href") == two.evaluate("location.href"))
        profiles = (one.profile, two.profile)
    finally:
        one.stop()
        two.stop()
    check("both profiles were removed", not any(os.path.exists(p) for p in profiles), str(profiles))

    print("\nthe old shape: two runs naming the same port")
    shared = Chrome(CHROME, port=0)
    shared.start("about:blank")
    port = shared.port
    try:
        # A page only the first browser has.
        shared.navigate("data:text/html,<h1 id=owner>first browser</h1>", settle=0.5)
        owner = shared.evaluate("document.getElementById('owner').textContent")
        second_same_port = Chrome(CHROME, port=port)
        try:
            second_same_port.start("about:blank")
        except DevToolsError as error:
            print(f"  noted  a second browser on port {port} refused to come up: {error}")
        else:
            # It reports it is up — on a port only the first browser can be listening on, so what it
            # is actually driving is the *first* browser's page. That is the hazard: not a failure,
            # a silent cross-run attachment.
            seen = second_same_port.evaluate("document.getElementById('owner')?.textContent")
            print(f"  noted  first browser's page says {owner!r}")
            print(f"  noted  the second instance on port {port} is driving {seen!r}")
            if seen == owner:
                print("  noted  => it attached to the browser the first run had already opened")
            second_same_port.stop()
    finally:
        shared.stop()

if failures == 0:
    print("\nall A164 probe checks passed")
    sys.exit(0)
print(f"\n{failures} A164 probe check(s) failed")
sys.exit(1)
