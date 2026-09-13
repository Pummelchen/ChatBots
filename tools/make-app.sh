#!/usr/bin/env bash
# Builds ChatBots.app — a double-clickable bundle around the SwiftPM executable.
#
# SwiftPM builds a plain Mach-O binary, which runs fine from a terminal but does not
# register as a proper GUI app (no Dock presence, no reliable activation). This wraps
# it in the minimal bundle structure macOS wants.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/ChatBots.app"

# Indent captured multi-line output so it reads as part of the warning above it.
#
# What SC2001 suggests — `${variable//search/replace}` — does not apply here: a parameter
# expansion can only prefix the *first* line of a multi-line value, so
# `${out//$'\n'/$'\n'      }` would leave every later line unindented. The previous form,
# `echo "$out" | sed 's/^/      /'`, hands the whole value to sed, which is what does the
# per-line work. Feeding sed from a here-string is flagged by SC2001 as well, so the value
# goes to awk instead. That also keeps `echo`'s option parsing out of the path: `echo "$out"`
# silently drops a value that begins with `-n`.
indent_output() { awk '{ print "      " $0 }'; }

echo "==> Building ($CONFIG)"
# All three products, not only the app. The bundle carries the engine and the transport probe,
# and a bundle without them is broken in a way the user finds at launch: the window opens, says
# it cannot reach its engine, and nothing else works.
#
# This used to build the app alone and then copy the other two *if they happened to be present*,
# warning otherwise. On a clean checkout they never are, so `tools/make-app.sh` on its own — and
# `tools/install.sh` with it — produced exactly that broken bundle. The copies below fail loudly
# instead.
#
# One invocation per product on purpose: `swift build` takes a single `--product`, and passing
# several silently builds only the last one. That is what produced a bundle containing the probe
# and not the engine while writing this fix.
for product in ChatBots chatbots-cli chatbots-probe; do
  swift build -c "$CONFIG" --product "$product"
done

BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ChatBots" "$APP/Contents/MacOS/ChatBots"

# The engine travels with the app. The app is a client of the engine rather than containing
# one, so something has to run the engine, and a shipped app that depended on a developer
# checkout being present would be useless to anyone who installed it.
#
# It sits in MacOS/ rather than Resources/ because it is an executable. The app finds it by
# looking beside its own binary, which is where this puts it.
if [ ! -x "$BIN/chatbots-cli" ]; then
  echo "error: chatbots-cli was not built, so the bundle could not start an engine." >&2
  echo "       try: swift build -c $CONFIG --product chatbots-cli" >&2
  exit 1
fi
cp "$BIN/chatbots-cli" "$APP/Contents/MacOS/chatbots-cli"

# The app's own transport client, runnable from a terminal. It travels with the app so the
# diagnostic the troubleshooting notes tell you to run exists on a machine that installed a
# bundle rather than a checkout — which is exactly the machine that needs it. It is the same
# client the app uses, so what it reports is what the app sees.
if [ ! -x "$BIN/chatbots-probe" ]; then
  echo "error: chatbots-probe was not built, so the bundle has no transport diagnostic." >&2
  echo "       try: swift build -c $CONFIG --product chatbots-probe" >&2
  exit 1
fi
cp "$BIN/chatbots-probe" "$APP/Contents/MacOS/chatbots-probe"

# swift-transformers and swift-crypto ship resources as SwiftPM bundles next to the
# binary. MLX's default.metallib is fetched separately, because mlx-swift's SwiftPM
# build does not compile the Metal kernels (see tools/fetch-metal.sh).
shopt -s nullglob
for bundle in "$BIN"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# The app icon, built from the master artwork in the app target.
#
# The master has a transparent surround: its rounded square sits on nothing, rather than on a
# white background that would show as a pale frame around the icon in the Dock. It was
# produced from the original artwork, which was opaque with the rounded square drawn on white,
# by flood-filling that background to transparent from each corner. Redo it the same way if the
# artwork is ever replaced:
#
#   magick AppIcon-1024.png -alpha set -fuzz 12% -fill none \
#     -draw 'alpha 0,0 floodfill' -draw 'alpha 1253,0 floodfill' \
#     -draw 'alpha 0,1253 floodfill' -draw 'alpha 1253,1253 floodfill' AppIcon-1024.png
#
# The flood fill rather than a global "remove white" matters: the robots have white eyes, and
# replacing every white pixel would hollow them out.
ICON_MASTER="$ROOT/Sources/ChatBotsApp/Resources/AppIcon-1024.png"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif [[ -f "$ICON_MASTER" ]]; then
  echo "==> Building AppIcon.icns from the master artwork"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
else
  echo "warning: no icon artwork found; the app will use the generic icon" >&2
fi

"$ROOT/tools/fetch-metal.sh" --bin "$BIN" --into "$APP"

# `LSMinimumSystemVersion` below must match `platforms: [.macOS(.v26)]` in Package.swift. It said
# 14.0 while the app needs 26 for WebTransport, so macOS would happily launch it on Sonoma and
# Sequoia and the app would then fail at the transport — the confusing failure the README warns
# about, instead of the system saying which version it needs.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ChatBots</string>
    <key>CFBundleDisplayName</key>
    <string>ChatBots</string>
    <key>CFBundleIdentifier</key>
    <string>local.chatbots.twollms</string>
    <key>CFBundleExecutable</key>
    <string>ChatBots</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Local build — two MLX models in conversation.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
# Inside out, and `mlx.metallib` first.
#
# It sits in MacOS/ beside the executables, and `codesign` counts it as nested code for
# everything in that folder: signing `ChatBots` while the metallib was unsigned failed with
# "code object is not signed at all — in subcomponent: …/mlx.metallib". Signing the metallib
# before the binaries is what makes the rest work. Leaving the failure unhandled, as this script
# used to, produced an app whose signature did not match its contents.
#
# Each component is allowed to fail on its own — the bundle signature below is what is actually
# checked, and it names the reason if something is still unsigned.
for nested in mlx.metallib chatbots-cli chatbots-probe ChatBots; do
  component="$APP/Contents/MacOS/$nested"
  [ -e "$component" ] || continue
  codesign --force --sign - "$component" >/dev/null 2>&1 || true
done

# Reported rather than swallowed. A failure does not stop the app running where it was built,
# but a downloaded copy would be refused by Gatekeeper, and silently skipping it is how the
# problem above stayed hidden.
if ! sign_output="$(codesign --force --sign - "$APP" 2>&1)"; then
  echo "    ! the app could not be signed; a downloaded copy would be refused" >&2
  indent_output <<< "$sign_output" >&2
elif ! verify_output="$(codesign --verify --strict "$APP" 2>&1)"; then
  echo "    ! the app is signed but does not verify:" >&2
  indent_output <<< "$verify_output" >&2
fi

echo
echo "Built: $APP"
echo "Run:   open '$APP'"
