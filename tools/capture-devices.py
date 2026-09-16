#!/usr/bin/env python3
"""Capture the web interface at every device profile, offscreen.

Uses headless Chrome, so nothing appears on the desktop, and drives it over the DevTools protocol
(`tools/cdp.py`) rather than Chrome's command line: `Emulation.setDeviceMetricsOverride` sets each
profile's CSS viewport, device pixel ratio and touch emulation, and `Page.captureScreenshot` writes
the image straight to a file. Each profile is captured at its real CSS viewport and device pixel
ratio, which is the whole point — a layout that looks right at 390 points can still break at 360,
and those are the widths real entry-level phones report.

    python3 tools/capture-devices.py                  # every profile
    python3 tools/capture-devices.py --class phone    # one class
    python3 tools/capture-devices.py --id galaxy-a13  # one device
    python3 tools/capture-devices.py --common         # one per distinct shape

Output goes to `captures/`: the capture itself, a display-sized copy of it when ImageMagick is
installed, and an index page that tiles the display copies and links each full one, so the results
can be compared side by side. Exits non-zero if any capture fails or renders no messages, so it can
be wired into a check.

The server is started and stopped by this script, on its own ports, and it seeds the
conversation so there is realistic content to lay out.
"""

from __future__ import annotations

import argparse
import pathlib
import sys
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from capture_render import build_index, capture, downscale
from capture_setup import (
    CHROME,
    OUT,
    PORT,
    JsonObject,
    caddy_process,
    output_directory,
    profiles,
    start_servers,
)
from cdp import Chrome, DevToolsError


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
        # capturing at once — cannot collide or reach each other's browser.
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

                    display = downscale(file)
                    row: JsonObject = {
                        "file": file,
                        # The display copy's name, shown by the index; None means there is none and
                        # the index falls back to the capture itself.
                        "thumb": display.name if display else None,
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
