#!/bin/sh
# Turn a built Ghostty.app into this fork's app: its own name and bundle
# ID, the updater disabled, and signed again.
#
# The separate bundle ID keeps the fork's preferences, window state and
# permissions (Accessibility, Automation, Files & Folders, ...) apart from
# the official app's, so both can be installed and run at the same time.
# Both still read the same Ghostty config file. The updater is disabled:
# the official appcast and signing key would otherwise happily "update"
# this build into the official release.
#
# Usage: dist/macos/package-fork.sh <built Ghostty.app> <output .app>
#
# Environment:
#   FORK_NAME       app name (default: Ghostty tmux)
#   FORK_BUNDLE_ID  bundle ID (default: com.eliasfloreteng.ghostty-tmux)
#   SIGN_IDENTITY   codesign identity (default: "-", ad hoc). Ad hoc is
#                   enough to run the app, but every build is a new
#                   identity to macOS, so it asks for permissions again
#                   after each update. A certificate keeps them. Use an
#                   "Apple Development" identity to run builds on your own
#                   Macs, or a "Developer ID Application" one to hand
#                   builds to other Macs (and notarize them).

set -eu

if [ $# -ne 2 ]; then
  echo "usage: $0 <built Ghostty.app> <output .app>" >&2
  exit 2
fi

built="$1"
out="$2"
name="${FORK_NAME:-Ghostty tmux}"
bundle_id="${FORK_BUNDLE_ID:-com.eliasfloreteng.ghostty-tmux}"
identity="${SIGN_IDENTITY:--}"

if [ ! -d "$built/Contents" ]; then
  echo "error: $built is not an app bundle" >&2
  exit 1
fi

rm -rf "$out"
# ditto, not cp: it keeps the bundle's symlinks, modes and extended
# attributes exactly.
ditto "$built" "$out"

plist="$out/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$plist"; }
pb "Set :CFBundleIdentifier $bundle_id"
pb "Set :CFBundleName $name" 2>/dev/null || pb "Add :CFBundleName string $name"
pb "Delete :CFBundleDisplayName" 2>/dev/null || true
pb "Add :CFBundleDisplayName string $name"
pb "Delete :GhosttyUpdaterDisabled" 2>/dev/null || true
pb "Add :GhosttyUpdaterDisabled bool true"

# Changing Info.plist invalidates the signature, so sign again: nested
# code first, inside out, then the app. Every piece must carry the same
# identity, because the hardened runtime's library validation refuses to
# load a framework signed by anyone else. Each piece keeps the
# entitlements and flags (hardened runtime) Xcode gave it.
sign() {
  codesign --force --sign "$identity" \
    --preserve-metadata=entitlements,flags,runtime \
    ${SIGN_TIMESTAMP:+--timestamp} \
    "$1"
}

#
# Loose helper executables inside frameworks (Sparkle's Autoupdate) are
# not bundles of their own, so they go first: signing one after its
# framework would break the framework's seal.
find "$out/Contents/Frameworks" -type f -perm -u+x ! -name '*.dylib' \
  ! -path '*.app/*' ! -path '*.xpc/*' -print 2>/dev/null |
  while IFS= read -r exe; do
    # A framework's own binary (Foo.framework/Versions/A/Foo) is signed
    # with the framework.
    case "$exe" in */"$(basename "$exe")".framework/*) continue ;; esac
    if file -b "$exe" | grep -q '^Mach-O'; then
      sign "$exe"
    fi
  done
# Then every nested bundle, innermost first (-depth), then the app.
find "$out/Contents" -depth \
  \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \
  -o -name '*.plugin' -o -name '*.app' -o -name '*.dylib' \) -print |
  while IFS= read -r nested; do
    sign "$nested"
  done
sign "$out"

codesign --verify --deep --strict "$out"
echo "packaged $out ($bundle_id, signed by $identity)"
