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

# swift-transformers and swift-crypto ship resources as SwiftPM bundles next to the
# binary. MLX's default.metallib is fetched separately, because mlx-swift's SwiftPM
# build does not compile the Metal kernels (see tools/fetch-metal.sh).
shopt -s nullglob
for bundle in "$BIN"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

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
