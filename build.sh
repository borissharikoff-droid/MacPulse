#!/bin/bash
# Builds MacPulse.app from source and installs it to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="MacPulse"
APP_BUNDLE="$ROOT/Build/$APP_NAME.app"
BIN_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> Compiling..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

# Pin the SDK explicitly. Left to itself, swiftc picks the highest-numbered SDK
# in CommandLineTools/SDKs — which can be a beta SDK built by a NEWER Swift
# than the installed compiler, and then every build dies with "this SDK is not
# supported by the compiler". The MacOSX.sdk symlink is the one Apple keeps
# pointed at the release SDK matching the installed tools.
SDK="${MACPULSE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"

# Sources stay FLAT on purpose: this glob does not descend into subdirectories.
# If you ever add Sources/Foo/Bar.swift you must switch to a find-based list
# (or `shopt -s globstar` + **) or the file will silently not be compiled.
#
# IOKit covers AppleSMC, IOAccelerator, IOBlockStorageDriver, the device tree
# and IOKit.ps. libIOReport is NOT linked here — PowerSampler resolves it with
# dlopen/dlsym so a missing private symbol degrades to "power unavailable"
# instead of failing to launch.
# Pin the DEPLOYMENT TARGET too. Without it swiftc stamps the binary with
# whatever the host OS is (minos 26.0 was measured here) while Info.plist
# advertised LSMinimumSystemVersion 13.0 — the two disagreeing is how you
# ship something that launchd will happily start on a machine the binary
# cannot actually run on. 13.0 matches Info.plist and is enough for
# everything used here (NSScreen.safeAreaInsets / auxiliaryTopLeftArea are
# macOS 12+, SMAppService is 13+).
DEPLOY_TARGET="arm64-apple-macos13.0"

swiftc -O \
  -sdk "$SDK" \
  -target "$DEPLOY_TARGET" \
  -o "$BIN_PATH" \
  "$ROOT"/Sources/*.swift \
  -framework AppKit -framework ServiceManagement -framework IOKit

cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# A stable local signing identity (not ad-hoc "-") so the code signature's
# designated requirement stays the same across rebuilds — matches the
# identity CmdTabSwitcher already uses; one local dev cert can sign
# multiple different apps fine.
SIGN_ID="CmdTabSwitcher Local Dev"

echo "==> Code-signing ($SIGN_ID)..."
codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE"

echo "==> Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
codesign --force --deep --sign "$SIGN_ID" "/Applications/$APP_NAME.app"

echo "==> Done: /Applications/$APP_NAME.app"
