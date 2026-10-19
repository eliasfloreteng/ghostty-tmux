#!/bin/sh
# Build a release Ghostty.app from this checkout and install it next to
# the official Ghostty under its own name and bundle ID.
#
# The separate bundle ID keeps this build's preferences, window state and
# permissions (Accessibility, Automation, ...) apart from the official
# app's, so both can be installed and running at the same time. The
# updater is disabled: the official appcast and signing key would
# otherwise happily "update" this build into the official release.
#
# Both apps still read the same Ghostty config file.
#
# Usage: dist/macos/install-fork.sh [name] [bundle-id] [destination-dir]
#
# Environment:
#   ZIG       zig binary to build with (default: zig, or .toolchain/zig
#             in the repository if present)
#   OPTIMIZE  Zig optimize mode (default: ReleaseFast)

set -eu

name="${1:-Ghostty tmux}"
bundle_id="${2:-com.eliasfloreteng.ghostty-tmux}"
dest_dir="${3:-/Applications}"

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

built="$repo/macos/build/ReleaseLocal/Ghostty.app"
if [ ! -d "$built" ]; then
  echo "error: expected app bundle at $built" >&2
  exit 1
fi

# Stage next to the build output so a failure never leaves a half-made
# app in the destination.
staged="$repo/macos/build/ReleaseLocal/$name.app"
rm -rf "$staged"
cp -R "$built" "$staged"

plist="$staged/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$plist"; }
pb "Set :CFBundleIdentifier $bundle_id"
pb "Set :CFBundleName $name" 2>/dev/null || pb "Add :CFBundleName string $name"
pb "Delete :CFBundleDisplayName" 2>/dev/null || true
pb "Add :CFBundleDisplayName string $name"
pb "Delete :GhosttyUpdaterDisabled" 2>/dev/null || true
pb "Add :GhosttyUpdaterDisabled bool true"

# Changing Info.plist invalidates the existing signature. Re-sign ad hoc,
# which is what a local release build is signed with anyway.
codesign --force --deep --sign - "$staged"
codesign --verify --deep --strict "$staged"

target="$dest_dir/$name.app"
rm -rf "$target"
mv "$staged" "$target"
echo "installed $target ($bundle_id)"
