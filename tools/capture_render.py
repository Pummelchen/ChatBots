"""Capture one device profile, and build the index page that tiles every capture.

The rendering half of `capture-devices.py`: `capture()` drives one emulated profile through the
DevTools client, `downscale()` writes the display copy the index shows, and `build_index()` writes
the page. All three write through `output_directory()` so the directory exists first.
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess

from capture_setup import PORT, JsonObject, output_directory
from cdp import Chrome, DevToolsError


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


def downscale(name: str) -> pathlib.Path | None:
    """Write the display copy of one capture and return its path, or None if there is none.

    A 3x phone capture is three thousand pixels tall and unreasonable in an index page, so the index
    shows this copy and links the capture itself (this used to write a `-thumb.png` that
    nothing used, while the index embedded the full-size capture it exists to avoid).

    `name` is resolved through `output_directory()` for the same reason `capture()` does it:
    the thumbnail is written next to the capture, into a directory this function does not
    otherwise know has been created.

    None means "the caller shows the capture itself": ImageMagick is not installed, or the
    conversion failed. The caller puts the answer in the row rather than assuming a thumbnail
    exists, because this tool runs on Macs without `magick` and an index pointing at a file that is
    not there would be worse than a large one.
    """
    shot = output_directory() / name
    thumb = shot.with_name(shot.stem + "-thumb.png")
    if not shutil.which("magick"):
        return None
    result = subprocess.run(
        ["magick", str(shot), "-resize", "420x", str(thumb)],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0 or not thumb.exists():
        return None
    return thumb


def build_index(rows: list[JsonObject]) -> None:
    """A page that tiles every capture, for comparing profiles at a glance.

    Each card shows the display copy and links the full-size capture; the figcaption says when it is
    showing the capture itself because there is no thumbnail.
    """
    cards = "\n".join(
        f"""  <figure>
    <a href="{r["file"]}"><img src="{r.get("thumb") or r["file"]}" alt="{r["name"]}" loading="lazy"></a>
    <figcaption><b>{r["name"]}</b><br>{r["width"]}×{r["height"]} @{r["pixelRatio"]}x · {r["class"]} · {r["mode"]}{" · landscape" if r["orientation"] == "landscape" else ""}{"" if r.get("thumb") else " · full size"}</figcaption>
  </figure>"""
        for r in rows
    )
    (output_directory() / "index.html").write_text(
        f"""<!DOCTYPE html>
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
""",
        encoding="utf-8",
    )
