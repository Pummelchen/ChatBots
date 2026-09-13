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

# ── Pinned artefact digest ───────────────────────────────────────────────────────────
# SHA-256 of the `Cmlx.xcframework.zip` release asset downloaded below. The value is the
# digest GitHub publishes for that asset in the release metadata
# (https://api.github.com/repos/ml-explore/mlx-swift/releases/tags/0.31.6, `digest` field of
# the `Cmlx.xcframework.zip` asset), and it was checked byte-for-byte against the archive
# this checkout already had cached in .build/mlx-metal/. The archive is not downloaded,
# extracted or embedded unless it matches this value.
#
# The asset name is the same for every mlx-swift release, so the digest is bound to the
# version it was taken from: `CMLX_XCFRAMEWORK_VERSION` has to equal the version resolved
# from .build/workspace-state.json. When `swift package resolve` moves mlx-swift, this fails
# closed with instructions rather than trusting whatever the new release serves.
#
# To update it after a version bump (do this on a trusted machine and network):
#   curl -fsSL "https://api.github.com/repos/ml-explore/mlx-swift/releases/tags/<version>" \
#     | python3 -c 'import json,sys; [print(a["name"], a.get("digest")) for a in json.load(sys.stdin)["assets"]]'
# or, with the archive already downloaded:
#   shasum -a 256 Cmlx.xcframework.zip
CMLX_XCFRAMEWORK_VERSION="0.31.6"
CMLX_XCFRAMEWORK_SHA256="a202bf1dcfe1e64404adabfeb5eb363332e3a6221d18e4289ca0663fa3ab86c9"

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

# Checked unconditionally, before anything is downloaded: an empty pin must never read as
# "no verification needed", and a pin taken from another release must never be applied to
# this one. The metallib ends up ad-hoc signed inside the shipped app, so an unverified
# archive is arbitrary native code, not a cache miss.
if [[ -z "$CMLX_XCFRAMEWORK_SHA256" ]]; then
  cat >&2 <<EOF
error: no SHA-256 is pinned for Cmlx.xcframework.zip, so the Metal kernels cannot be
       verified and will not be downloaded or embedded.

       See the CMLX_XCFRAMEWORK_SHA256 comment in $0 for how to fill it in.
EOF
  exit 1
fi
if [[ "$VERSION" != "$CMLX_XCFRAMEWORK_VERSION" ]]; then
  cat >&2 <<EOF
error: the pinned SHA-256 is for mlx-swift $CMLX_XCFRAMEWORK_VERSION, but SwiftPM has
       resolved $VERSION. The Cmlx.xcframework.zip asset name is the same for every
       release, so the digest cannot be reused across versions.

       Pin the digest for $VERSION (see the CMLX_XCFRAMEWORK_SHA256 comment in $0) before
       this build can fetch the Metal kernels.
EOF
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

  # Verified whether the archive was just downloaded or came from the cache: a cached file
  # is not evidence that it is the expected one.
  if ! actual_sha="$(shasum -a 256 "$ZIP" | awk '{print $1}')"; then
    echo "error: could not compute the SHA-256 of $ZIP" >&2
    rm -f "$ZIP" "$ZIP.partial"
    exit 1
  fi
  if [[ "$actual_sha" != "$CMLX_XCFRAMEWORK_SHA256" ]]; then
    cat >&2 <<EOF
error: Cmlx.xcframework.zip does not match the SHA-256 pinned in this script.
       expected: $CMLX_XCFRAMEWORK_SHA256
       actual:   $actual_sha

       Nothing was extracted or embedded. The archive is removed so a corrupted download
       or a substituted release cannot be retried from the partial file.
EOF
    rm -f "$ZIP" "$ZIP.partial"
    exit 1
  fi
  echo "    sha256 $actual_sha"

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
