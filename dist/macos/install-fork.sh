#!/bin/sh
# Build a release Ghostty.app from this checkout and install it next to
# the official Ghostty as this fork's app (see package-fork.sh for what
# that changes, and for FORK_NAME, FORK_BUNDLE_ID and SIGN_IDENTITY).
#
# Usage: dist/macos/install-fork.sh [destination-dir]
#
# Environment, besides package-fork.sh's:
#   ZIG       zig binary to build with (default: .toolchain/zig in the
#             repository if present, else zig)
#   OPTIMIZE  Zig optimize mode (default: ReleaseFast)
#
# To keep macOS permissions across updates, sign with a certificate, e.g.:
#   SIGN_IDENTITY="Apple Development" dist/macos/install-fork.sh
#
# A local build does not update itself: it would replace what you built
# with the next release of the fork's main. To have it do that anyway,
# give it the fork's public update key (`generate_keys -p`):
#   FORK_SPARKLE_PUBLIC_KEY=<key> dist/macos/install-fork.sh
# It then updates to the first release built from a later commit of main
# than the checkout's.

set -eu

dest_dir="${1:-/Applications}"
name="${FORK_NAME:-Ghostty tmux}"

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

if [ -z "${ZIG:-}" ]; then
  if [ -x "$repo/.toolchain/zig" ]; then
    ZIG="$repo/.toolchain/zig"
  else
    ZIG=zig
  fi
fi

"$ZIG" build -Doptimize="${OPTIMIZE:-ReleaseFast}"

# Stage next to the build output so a failure never leaves a half-made
# app in the destination.
staged="$repo/macos/build/ReleaseLocal/$name.app"
"$repo/dist/macos/package-fork.sh" "$repo/macos/build/ReleaseLocal/Ghostty.app" "$staged"

target="$dest_dir/$name.app"
if pgrep -qf "^$target/Contents/MacOS/" 2>/dev/null; then
  echo "error: $target is running; quit it first" >&2
  exit 1
fi
rm -rf "$target"
mv "$staged" "$target"
echo "installed $target"
