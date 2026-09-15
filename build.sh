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
# Guarded, because the failure mode does not look like what it is: a .swift
# file in a subdirectory is never handed to swiftc, so its types simply do
# not exist, and the error points at the CALLER — "cannot find X in scope" —
# in a file that is perfectly correct.
if find "$ROOT/Sources" -mindepth 2 -name '*.swift' -print -quit | grep -q .; then
  echo "error: Sources/ must stay FLAT — the glob below does not descend into" >&2
  echo "       subdirectories, so these files would silently not be compiled:" >&2
  find "$ROOT/Sources" -mindepth 2 -name '*.swift' >&2
  exit 1
fi

# ============================================================================
# CONTRACT GUARD (source side). Runs BEFORE the compile so a violation costs
# two seconds, not two minutes.
#
# MacPulse links no CFNetwork, no Network.framework and no Security.framework,
# and `otool -L` is asserted below to prove it. But since Sources/PultLink.swift
# added ONE raw POSIX loopback socket — the 3D printer panel on 127.0.0.1:8787
# — otool alone is no longer a sufficient check: libSystem is already linked, so
# a second, less careful socket somewhere else would not show up in the link map
# at all. Hence a source-level guard as well.
#
# Comment lines are stripped first, on purpose: PultLink.swift's header has to
# be able to EXPLAIN why URLSession is forbidden without tripping the rule that
# forbids it.
# ============================================================================
BANNED='URLSession|NSURLConnection|NWConnection|NWBrowser|NWListener|getaddrinfo|gethostbyname|gethostbyaddr|CFHost|CFStream|SecureTransport|SecTrust|CFSocket'
if BAD=$(grep -nE "$BANNED" "$ROOT"/Sources/*.swift | grep -vE ':[0-9]+:[[:space:]]*//'); then
  echo "error: CONTRACT — networking API in Sources/. MacPulse does not do general" >&2
  echo "       networking; the ONE exception is the loopback socket in PultLink.swift." >&2
  echo "$BAD" >&2
  exit 1
fi
# Exactly one file is allowed to open a socket that can carry a byte anywhere.
#
# Sources/TunnelSampler.swift is the one exception, and it is a narrow one: a
# PF_ROUTE descriptor is a kernel routing-table query channel, not a
# connection. It has no peer, it cannot be connected or bound, nothing written
# to it leaves the machine, and RTM_GET is exactly what route(8) does. It is
# excluded from the sweep below and then checked SEPARATELY and more strictly
# — one socket() call, of that exact form, and connect/bind/send/getaddrinfo
# still banned there as everywhere. Exempting the file wholesale would have
# been the weakening; this is not that. Both checks fail CLOSED: rename the
# file and the sweep below catches it; delete the socket call and the count
# check below catches that.
if STRAY=$(grep -nE '(^|[^A-Za-z_])(socket|connect|getaddrinfo)[[:space:]]*\(' \
             "$ROOT"/Sources/*.swift \
           | grep -vE ':[0-9]+:[[:space:]]*//' \
           | grep -v '/PultLink\.swift:' \
           | grep -v '/TunnelSampler\.swift:'); then
  echo "error: CONTRACT — socket()/connect() outside Sources/PultLink.swift." >&2
  echo "       Every byte that leaves this process must go through that one file," >&2
  echo "       which can only ever form the address 127.0.0.1:8787." >&2
  echo "$STRAY" >&2
  exit 1
fi
TUNNEL_SRC="$ROOT/Sources/TunnelSampler.swift"
if [ -f "$TUNNEL_SRC" ]; then
  TUNNEL_CODE=$(grep -vE '^[[:space:]]*//' "$TUNNEL_SRC")
  if [ "$(printf '%s\n' "$TUNNEL_CODE" | grep -cE '(^|[^A-Za-z_])socket[[:space:]]*\(')" != "1" ] \
     || [ "$(printf '%s\n' "$TUNNEL_CODE" | grep -cE 'socket\(PF_ROUTE, SOCK_RAW, 0\)')" != "1" ] \
     || printf '%s\n' "$TUNNEL_CODE" \
          | grep -qE '(^|[^A-Za-z_])(connect|bind|sendto|sendmsg|getaddrinfo)[[:space:]]*\('; then
    echo "error: CONTRACT — Sources/TunnelSampler.swift may open EXACTLY ONE" >&2
    echo "       socket(PF_ROUTE, SOCK_RAW, 0) and must never connect, bind or send." >&2
    exit 1
  fi
fi

# IOKit covers AppleSMC, IOAccelerator, IOBlockStorageDriver, the device tree
# and IOKit.ps. libIOReport is NOT linked here — PowerSampler resolves it with
# dlopen/dlsym so a missing private symbol degrades to "power unavailable"
# instead of failing to launch.
#
# CoreAudio is the microphone half of the privacy rail: the macOS 14+ public
# process-object API (kAudioHardwarePropertyProcessObjectList and friends),
# which names the app holding the input device with no entitlement and no TCC
# grant. CoreMediaIO is the camera half — device-level only; there is no
# unprivileged per-process camera API on macOS. Neither pulls in anything the
# contract forbids; the otool assertion after the build is what proves it.
#
# UserNotifications is the memory-pressure notifier — banners only, no
# entitlement and no Info.plist key. EventKit is the next-meeting section; it
# also drags in libswiftCoreLocation and libswiftCoreGraphics, which are Swift
# overlays and not the frameworks themselves. Nothing here constructs a
# CLLocationManager and no location prompt is possible. Neither framework can
# open a connection, and the otool assertion below still has to pass.
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
  -framework AppKit -framework ServiceManagement -framework IOKit \
  -framework CoreAudio -framework CoreMediaIO \
  -framework UserNotifications -framework EventKit

# ============================================================================
# CONTRACT GUARD (link side). The single most important check in the build.
#
# The reviewed property is "MacPulse cannot do general networking". These three
# frameworks are what a binary needs in order to resolve a hostname, open a TLS
# connection, or talk to anything that is not already a file descriptor. If any
# of them appears here, something in Sources/ started using URLSession, Network
# or TLS and the property is gone — fail the build rather than ship it.
# ============================================================================
if LEAK=$(otool -L "$BIN_PATH" \
          | grep -E '/(CFNetwork|Network|Security)\.framework/'); then
  echo "error: CONTRACT — a networking framework is in the link map:" >&2
  echo "$LEAK" >&2
  rm -f "$BIN_PATH"
  exit 1
fi
echo "==> Contract OK: no CFNetwork, no Network.framework, no Security.framework."

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
