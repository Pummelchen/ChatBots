#!/bin/bash
#
# ChatBots — does this Mac have a Metal compiler that actually runs?
#
# Xcode 27 does not ship the Metal compiler. It is a separate downloadable component, and without it
# `swift build` stops on the first `.metal` kernel it compiles — mlx-swift's — with an error that
# names a file rather than the missing component:
#
#     error: CompileMetalFile .../steel_attention.metal failed with a nonzero exit code
#     error: cannot execute tool 'metal' due to missing Metal Toolchain
#
# Checking that the compiler *exists* is not a check: on a machine where the component is absent,
# `xcrun --find metal` prints a path and exits 0. Running it is the only honest test (A133).
#
#   usage: tools/check-metal.sh [--quiet]
#
# Exit status: 0 when the compiler runs — the first line of its version is printed — and 1 when it
# does not, with what to do about it on stderr.

set -u
set -o pipefail

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1
say() { [ "$quiet" = "1" ] || printf '%s\n' "$*"; }

if ! command -v xcrun >/dev/null 2>&1; then
  printf '%s\n' "xcrun is not on this Mac, so neither is the Metal compiler this package needs." >&2
  printf '%s\n' "Install the developer tools first:  xcode-select --install" >&2
  exit 1
fi

if output="$(xcrun -sdk macosx metal --version 2>&1)"; then
  say "${output%%$'\n'*}"
  exit 0
fi

detail="$(printf '%s\n' "$output" | sed 's/^/  /')"

cat >&2 <<EOF
This Mac cannot compile Metal kernels, and this package contains them: the build stops on the
first one mlx-swift compiles, with an error that names the .metal file rather than the cause.

$detail

Xcode 27 does not ship the Metal compiler; it is a separate component. Install it once:

  xcodebuild -downloadComponent MetalToolchain

That is about 840 MB, and it needs the full Xcode — the command line tools cannot install it. If
Xcode is not installed yet, install it from the App Store first, then run the command above.
EOF
exit 1
