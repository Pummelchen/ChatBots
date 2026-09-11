#!/usr/bin/env bash
# Fetches MLX's compiled Metal kernel library (mlx.metallib).
#
# Why this is needed: mlx-swift's SwiftPM build compiles the C/C++ core but NOT the
# Metal kernels — those are produced by the CMake/Xcode build and shipped inside the
# `Cmlx.xcframework` attached to each mlx-swift release. Without a metallib, MLX throws
# "Failed to load the default metallib" the moment it touches the GPU.
#
# MLX looks for the library next to the running binary (it tries `mlx.metallib` first),
# so we place it in the SwiftPM bin directory and inside the .app bundle.
#
# Usage: tools/fetch-metal.sh [--bin <dir>] [--into <app>]...

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# mlx-swift is a transitive dependency of mlx-swift-lm, so read the resolved
# version from SwiftPM's workspace state rather than `package describe`.
VERSION="$(python3 - <<'PYEOF'
import json
try:
    with open(".build/workspace-state.json") as handle:
        state = json.load(handle)
    for dep in state["object"]["dependencies"]:
        if dep["packageRef"]["identity"] == "mlx-swift":
            print(dep["state"].get("checkoutState", {}).get("version", ""))
            break
except Exception:
    pass
PYEOF
)"

if [[ -z "${VERSION:-}" ]]; then
  echo "error: could not determine the resolved mlx-swift version." >&2
  echo "       run 'swift package resolve' first." >&2
  exit 1
fi

CACHE="$ROOT/.build/mlx-metal"
ZIP="$CACHE/Cmlx-$VERSION.xcframework.zip"
LIB="$CACHE/default.metallib"

mkdir -p "$CACHE"

if [[ ! -f "$LIB" ]]; then
  if [[ ! -f "$ZIP" ]]; then
    URL="https://github.com/ml-explore/mlx-swift/releases/download/$VERSION/Cmlx.xcframework.zip"
    echo "==> Downloading Metal kernels for mlx-swift $VERSION (≈190 MB, one time)"
    curl -fL --retry 3 --progress-bar -o "$ZIP.partial" "$URL"
    mv "$ZIP.partial" "$ZIP"
  fi

  echo "==> Extracting default.metallib"
  rm -rf "$CACHE/extract"
  mkdir -p "$CACHE/extract"
  unzip -q -o "$ZIP" -d "$CACHE/extract"
  found="$(find "$CACHE/extract" -path "*macos*" -name "default.metallib" | head -1)"
  if [[ -z "$found" ]]; then
    echo "error: no macOS metallib inside $ZIP" >&2
    exit 1
  fi
  cp "$found" "$LIB"
  rm -rf "$CACHE/extract"
fi

echo "==> Metal library: $LIB ($(du -h "$LIB" | cut -f1))"

# Install next to the built binaries so `swift run` works. An explicit --bin wins over
# the default build path (which would be the debug directory even for a release build).
BIN=""
INSTALL_TARGETS=()
expect=""
for argument in "$@"; do
  if [[ -n "$expect" ]]; then
    case "$expect" in
      bin) BIN="$argument" ;;
      into) INSTALL_TARGETS+=("$argument") ;;
    esac
    expect=""
    continue
  fi
  case "$argument" in
    --bin) expect="bin" ;;
    --into) expect="into" ;;
  esac
done

if [[ -z "$BIN" ]]; then
  BIN="$(swift build --show-bin-path 2>/dev/null || true)"
fi
if [[ -n "$BIN" && -d "$BIN" ]]; then
  cp "$LIB" "$BIN/mlx.metallib"
  echo "    installed: $BIN/mlx.metallib"
fi

for target in "${INSTALL_TARGETS[@]:-}"; do
  [[ -n "$target" ]] || continue
  if [[ -d "$target/Contents/MacOS" ]]; then
    cp "$LIB" "$target/Contents/MacOS/mlx.metallib"
    echo "    installed: $target/Contents/MacOS/mlx.metallib"
  fi
done
