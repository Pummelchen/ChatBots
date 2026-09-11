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

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product ChatBots

BIN="$(swift build -c "$CONFIG" --product ChatBots --show-bin-path)"

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
if [ -x "$BIN/chatbots-cli" ]; then
  cp "$BIN/chatbots-cli" "$APP/Contents/MacOS/chatbots-cli"
else
  echo "    ! chatbots-cli was not built; the app will not be able to start an engine" >&2
  echo "      Build it with: swift build -c $CONFIG --product chatbots-cli" >&2
fi

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
# macOS applies its own rounded mask to app icons, so the artwork is used as drawn rather
# than pre-cropped to a transparent rounded rectangle: masking it here would have meant
# cutting about a tenth of the image away to remove the white ring the artwork already has
# around its rounded square.
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
    <string>14.0</string>
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
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "    (codesign skipped)"

echo
echo "Built: $APP"
echo "Run:   open '$APP'"
