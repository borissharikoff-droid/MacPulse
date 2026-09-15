#!/bin/bash
# Regenerates EVERY piece of MacPulse's visual identity from Tools/IconRender.swift:
#
#   Icon.iconset/          the ten PNGs macOS wants (16/32/128/256/512 + @2x)
#   AppIcon.icns           what build.sh copies into Contents/Resources
#   dmg-assets/            the installer window background, 1x and 2x
#
# Nothing here is hand-edited art. If the icon needs to change, change the
# numbers in Tools/IconRender.swift and run this again.
#
# Usage: ./make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same SDK pin as build.sh, for the same expensively-learned reason: left
# to itself swiftc picks the highest-numbered SDK in CommandLineTools/SDKs,
# which can be a beta built by a NEWER Swift than the installed compiler,
# and then every compile dies with "this SDK is not supported by the
# compiler". MacOSX.sdk is the symlink Apple keeps pointed at the release
# SDK matching the installed tools. Same deployment target as build.sh too.
SDK="${MACPULSE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
TARGET="arm64-apple-macos13.0"

BIN="$(mktemp -d)/render-icon"
trap 'rm -rf "$(dirname "$BIN")"' EXIT

echo "==> Compiling the renderer..."
swiftc -O -sdk "$SDK" -target "$TARGET" -o "$BIN" "$ROOT/Tools/IconRender.swift"

echo "==> Rendering Icon.iconset..."
rm -rf "$ROOT/Icon.iconset"
"$BIN" icons --out "$ROOT/Icon.iconset"

# iconutil is strict: the directory must be named *.iconset and must
# contain exactly the names it knows. A stray file (a .DS_Store, a
# leftover preview) makes it fail with an unhelpful "Unable to parse".
echo "==> Packing AppIcon.icns..."
rm -f "$ROOT/AppIcon.icns"
iconutil -c icns -o "$ROOT/AppIcon.icns" "$ROOT/Icon.iconset"

echo "==> Rendering the DMG background..."
mkdir -p "$ROOT/dmg-assets"
"$BIN" dmg --out "$ROOT/dmg-assets"

echo
echo "==> Done."
ls -l "$ROOT/AppIcon.icns"
echo "    Icon.iconset/        $(ls "$ROOT/Icon.iconset" | wc -l | tr -d ' ') entries"
echo "    dmg-assets/          background 640x400 and 1280x800"
echo
echo "    The app picks the icon up on the next ./build.sh (Info.plist's"
echo "    CFBundleIconFile is AppIcon and build.sh copies AppIcon.icns into"
echo "    Contents/Resources). Finder caches icons aggressively — if a"
echo "    rebuilt app still shows the old one, touch the bundle or log out."
