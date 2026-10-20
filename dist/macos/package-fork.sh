#!/bin/sh
# Turn a built Ghostty.app into this fork's app: its own name, bundle ID
# and version, an updater that follows this fork's releases (or none), and
# signed again.
#
# The separate bundle ID keeps the fork's preferences, window state and
# permissions (Accessibility, Automation, Files & Folders, ...) apart from
# the official app's, so both can be installed and run at the same time.
# Both still read the same Ghostty config file.
#
# The official appcast and signing key would happily "update" this build
# into the official release, so the official key is always removed. Given
# FORK_SPARKLE_PUBLIC_KEY, the updater reads this fork's appcast instead
# and accepts only an appcast and updates signed with the matching private
# key; without it, the updater is disabled. The build number
# (CFBundleVersion), which Sparkle compares to find a newer build, counts
# the commits of the checkout, as upstream's releases do, so it grows with
# every commit of main.
#
# Usage: dist/macos/package-fork.sh <built Ghostty.app> <output .app>
#
# Environment:
#   FORK_NAME       app name (default: Ghostty tmux)
#   FORK_BUNDLE_ID  bundle ID (default: com.eliasfloreteng.ghostty-tmux)
#   FORK_BUILD      build number (default: the number of commits in this
#                   checkout's HEAD)
#   FORK_COMMIT     commit shown in About (default: this checkout's HEAD)
#   FORK_SPARKLE_PUBLIC_KEY
#                   Sparkle public EdDSA key to verify updates with
#                   (`generate_keys -p`). Unset: no updates.
#   FORK_FEED_URL   appcast to update from (default: the one attached to
#                   this fork's latest release)
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
public_key="${FORK_SPARKLE_PUBLIC_KEY:-}"
feed_url="${FORK_FEED_URL:-https://github.com/eliasfloreteng/ghostty-tmux/releases/latest/download/appcast.xml}"

repo="$(cd "$(dirname "$0")/../.." && pwd)"
build="${FORK_BUILD:-}"
commit="${FORK_COMMIT:-}"
if git -C "$repo" rev-parse -q --verify HEAD > /dev/null 2>&1; then
  # A shallow clone counts only the commits it fetched.
  if [ -z "$build" ] &&
    [ "$(git -C "$repo" rev-parse --is-shallow-repository)" = false ]; then
    build=$(git -C "$repo" rev-list --count HEAD)
  fi
  [ -n "$commit" ] || commit=$(git -C "$repo" rev-parse --short=9 HEAD)
fi
if [ -n "$public_key" ] && [ -z "$build" ]; then
  echo "error: updates need a build number; set FORK_BUILD or package from a full clone" >&2
  exit 1
fi

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
version=$("$out/Contents/MacOS/ghostty" +version | sed -n 's/^Ghostty //p' | head -1)
if [ -z "$version" ]; then
  echo "error: could not read the version of $built" >&2
  exit 1
fi
# Shown in About and by the updater, rather than Xcode's placeholder.
pb "Set :CFBundleShortVersionString $version"
[ -z "$build" ] || pb "Set :CFBundleVersion $build"
[ -z "$commit" ] || pb "Set :GhosttyCommit $commit"

# The updater. Each of its keys is reset, so nothing of the official
# configuration survives either way.
for key in GhosttyUpdaterDisabled SUPublicEDKey SUFeedURL \
  SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
  pb "Delete :$key" 2>/dev/null || true
done
if [ -n "$public_key" ]; then
  pb "Add :SUPublicEDKey string $public_key"
  pb "Add :SUFeedURL string $feed_url"
  # Also reject an appcast that is not signed with the key, which Sparkle
  # allows only when an update is verified before it is unpacked.
  pb "Add :SURequireSignedFeed bool true"
  pb "Add :SUVerifyUpdateBeforeExtraction bool true"
  # As in upstream's releases: whether to check is then up to the
  # `auto-update` option, or Sparkle's prompt on the second launch.
  pb "Delete :SUEnableAutomaticChecks" 2>/dev/null || true
  updates="updates from $feed_url"
else
  pb "Add :GhosttyUpdaterDisabled bool true"
  updates="no updates"
fi

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
echo "packaged $out ($bundle_id, build ${build:-unnumbered}, $updates, signed by $identity)"
