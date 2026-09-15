#!/bin/bash
# Builds MacPulse.app from source and installs it to /Applications.
#
# =============================================================================
# THE CONTRACT THIS BUILD ENFORCES
#
# Everything below the compile is a guard. Read this block before changing any
# of them, and if you narrow the contract, narrow it HERE, in writing, at the
# same time — a guard that was quietly relaxed is worse than no guard, because
# the comment above it goes on claiming the old property.
#
# -----------------------------------------------------------------------------
# WHAT MACPULSE PROMISES, AS OF THE SELF-UPDATER
#
#   1. NO SUDO. Nothing in this app ever asks for a password or runs anything
#      privileged. The updater REFUSES to update rather than prompt, if the
#      installed bundle sits somewhere this user cannot write.
#
#   2. NETWORKING IS TWO HOLES IN AN OTHERWISE SEALED BINARY, AND ONLY TWO:
#
#        Sources/PultLink.swift   one raw POSIX socket, address built from the
#                                 INADDR_LOOPBACK constant and a literal port.
#                                 127.0.0.1:8787, unrepresentably anything else.
#
#        Sources/Updater.swift    HTTPS via URLSession, to api.github.com,
#                                 github.com and objects.githubusercontent.com,
#                                 and to nothing else. Owner and repo are
#                                 interpolated into the PATH; the host is always
#                                 a literal.
#
#      (Sources/TunnelSampler.swift also calls socket(), but PF_ROUTE is a
#      kernel routing-table query channel, not a connection — see its guard.)
#
#   3. FILE DELETION stays inside ~/Library/Caches and ~/Library/Logs, with one
#      named exception: the updater replaces the installed MacPulse.app bundle,
#      which is the entire point of an updater. Its download, unzip and staging
#      all happen under ~/Library/Caches/<bundle-id>/Update.
#
#   4. PROCESS TERMINATION is `helpd` and apps the user explicitly clicked Quit
#      on. Nothing else. (The updater LAUNCHES /usr/bin/unzip, /usr/bin/codesign
#      and a /bin/sh swap script; it terminates nothing but itself.)
#
# -----------------------------------------------------------------------------
# WHAT WAS GIVEN UP TO GET THE SELF-UPDATER, STATED PLAINLY
#
# Before Sources/Updater.swift, this binary had a property that had been
# adversarially verified three separate times and is now GONE:
#
#     otool -L showed no CFNetwork, no Network.framework, no Security.framework.
#     nm -u imported only socket/connect/getpeername/poll — not even bind or
#     listen. The only host-shaped string in the whole binary was 127.0.0.1.
#
# Today: CFNetwork IS in the link map, and api.github.com / github.com /
# objects.githubusercontent.com ARE strings in the binary. The app can and does
# open a TLS connection to a machine that is not this one. "MacPulse cannot do
# general networking" is no longer provable by `otool -L` alone, and no amount
# of grepping makes that untrue again. What is still provable, and what the
# guards below were rewritten to prove instead:
#
#     * exactly ONE of ~50 source files may use URLSession;
#     * that file may NAME only three hosts, none of them assembled at runtime;
#     * the raw-socket surface did not grow by a single call — nm -u shows the
#       same four imports it showed before, because CFNetwork does its socket
#       work inside CFNetwork;
#     * Network.framework is still absent, so there is no second, lower-level
#       networking stack in here.
#
# Deleting a guard is how a property dies. Every guard below either still tests
# what it always tested, or tests a narrower successor property that is written
# down above. None of them was removed.
# =============================================================================
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
# CONTRACT GUARD 1 (source side). Runs BEFORE the compile so a violation costs
# two seconds, not two minutes.
#
# Since Sources/PultLink.swift added ONE raw POSIX loopback socket — the 3D
# printer panel on 127.0.0.1:8787 — `otool -L` alone stopped being a sufficient
# check: libSystem is already linked, so a second, less careful socket somewhere
# else would not show up in the link map at all. Hence a source-level guard.
#
# Sources/Updater.swift, which did not exist when this guard was written, is now
# the SECOND hole, and it is the one that costs the most. It may use URLSession.
# Nothing else may — the other ~50 files are held to exactly the rule they were
# always held to, which is why the sweep is an EXCLUSION of one path rather than
# a shortened list of banned symbols. The rest of the list (Network.framework
# types, name resolution, CFStream, TLS primitives) stays banned EVERYWHERE,
# Updater.swift included: URLSession is a high-level client that cannot be
# pointed at an arbitrary socket, whereas NWConnection and getaddrinfo can, and
# the updater has no business doing its own name resolution or TLS.
#
# Comment lines are stripped first, on purpose: PultLink.swift's and
# Updater.swift's headers have to be able to EXPLAIN what is forbidden without
# tripping the rules that forbid it.
# ============================================================================
BANNED_EVERYWHERE='NSURLConnection|NWConnection|NWBrowser|NWListener|getaddrinfo|gethostbyname|gethostbyaddr|CFHost|CFStream|SecureTransport|SecTrust|CFSocket'
if BAD=$(grep -nE "$BANNED_EVERYWHERE" "$ROOT"/Sources/*.swift | grep -vE ':[0-9]+:[[:space:]]*//'); then
  echo "error: CONTRACT — low-level networking API in Sources/. Banned in EVERY file," >&2
  echo "       Updater.swift included: it does HTTPS through URLSession or not at all." >&2
  echo "$BAD" >&2
  exit 1
fi
# URLSession: Sources/Updater.swift and nowhere else.
if BAD=$(grep -nE 'URLSession|URLRequest|URLCredential|URLProtocol' "$ROOT"/Sources/*.swift \
         | grep -vE ':[0-9]+:[[:space:]]*//' \
         | grep -v '/Updater\.swift:'); then
  echo "error: CONTRACT — URLSession outside Sources/Updater.swift. Exactly one file in" >&2
  echo "       MacPulse may talk to the network, and it may only talk to GitHub." >&2
  echo "$BAD" >&2
  exit 1
fi

# ============================================================================
# CONTRACT GUARD 2 (source side, new). WHICH HOSTS Updater.swift MAY NAME.
#
# Letting one file do HTTPS is only a small concession if that file can reach
# exactly three machines. So: every http(s) literal in Updater.swift is pulled
# out and its HOST checked against the allow-list. Anything else fails the
# build.
#
#   api.github.com                 the Releases API
#   github.com                     what browser_download_url points at
#   objects.githubusercontent.com  where GitHub redirects asset downloads
#
# THE INTERPOLATION RULE, which is the real point of this guard: the owner and
# the repo are interpolated into the PATH of the API URL, and that is fine. A
# host must NEVER be interpolated, concatenated or read from anywhere — a host
# assembled at runtime is a host that whoever controls the input gets to
# choose. The extraction below takes everything between "://" and the first
# "/", so an interpolated host contains "\(", matches nothing on the list, and
# fails. So does a bare "https://" with nothing after it (the concatenation
# trick), because its host is empty. So does userinfo smuggling
# ("https://api.github.com@elsewhere/"), because the "@" is part of what gets
# compared. So does a non-443 port. All of them fail CLOSED, by being unequal
# to a member of a three-element list rather than by being recognised.
#
# COMMENTS ARE *NOT* STRIPPED HERE, unlike the sweeps above. This guard is
# about what the file NAMES, and a reviewer reading Updater.swift should not
# find a single non-GitHub URL anywhere in it, prose included. The cost is real
# and deliberate: you cannot cite a non-GitHub documentation link in that file's
# comments. Cite it from another file.
#
# Not applicable to Sources/UpdateProbe.swift, which DOES contain non-GitHub
# URLs — they are the negative rows of its host allow-list table
# (`--update-probe`), i.e. the URLs that must be REFUSED. They are inert by
# construction, and by the two guards above rather than by assertion: that file
# may not use URLSession and may not open a socket, so nothing in the binary
# can act on them.
# ============================================================================
UPDATER_SRC="$ROOT/Sources/Updater.swift"
if [ ! -f "$UPDATER_SRC" ]; then
  echo "error: CONTRACT — Sources/Updater.swift is missing. If the self-updater was" >&2
  echo "       deliberately removed, MacPulse is back to the STRICTER old contract:" >&2
  echo "       revert this guard AND the otool assertion below (which now expects" >&2
  echo "       CFNetwork) and update the contract block at the top of this file." >&2
  exit 1
fi
ALLOWED_HOSTS='api.github.com github.com objects.githubusercontent.com'
BAD_HOSTS=""
while IFS= read -r literal; do
  [ -n "$literal" ] || continue
  host="${literal#*://}"        # drop the scheme
  host="${host%%/*}"            # drop the path
  host="${host%%\?*}"
  host="${host%%#*}"
  host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
  ok=""
  for allowed in $ALLOWED_HOSTS; do
    [ "$host" = "$allowed" ] && ok=1
  done
  [ -n "$ok" ] || BAD_HOSTS="$BAD_HOSTS  $literal   -> host '$host'"$'\n'
done < <(grep -oE 'https?://[^"'"'"'[:space:]]*' "$UPDATER_SRC" || true)
if [ -n "$BAD_HOSTS" ]; then
  echo "error: CONTRACT — Sources/Updater.swift names a host that is not GitHub." >&2
  echo "       Allowed: $ALLOWED_HOSTS" >&2
  echo "       The owner/repo may be interpolated into the PATH, NEVER into the host." >&2
  printf '%s' "$BAD_HOSTS" >&2
  exit 1
fi
# ...and the allow-list must be doing work, not passing vacuously. A file with
# no http literal at all passes the loop above, which is exactly what you get
# if someone replaces the spelled-out API URL with a string built at runtime —
# the one shape this guard exists to stop. So require the literal to be there.
if ! grep -q 'https://api\.github\.com/' "$UPDATER_SRC"; then
  echo "error: CONTRACT — Sources/Updater.swift no longer spells out an" >&2
  echo "       https://api.github.com/ literal. Either the API endpoint moved (update" >&2
  echo "       this check) or it is now being assembled at runtime, which is the whole" >&2
  echo "       thing the host allow-list exists to prevent." >&2
  exit 1
fi
echo "==> Contract OK: Updater.swift names only $ALLOWED_HOSTS."
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
# CONTRACT GUARD 3 (link side). This check used to assert the strongest thing
# in the whole project, and it is the one the self-updater cost.
#
# WHAT IT USED TO SAY: no CFNetwork, no Network.framework, no Security
# framework. Three frameworks, none of them present, and therefore no way for
# this binary to resolve a hostname or open a TLS connection at all. That was
# checkable in one command by anyone, which is what made it worth having.
#
# WHAT IT SAYS NOW, and why each part changed:
#
#   CFNetwork  — EXPECTED, and asserted PRESENT. Sources/Updater.swift calls
#                URLSession, and URLSession is CFNetwork. Measured, not
#                assumed: a four-line spike using URLSession.shared and nothing
#                else adds exactly
#                /System/Library/Frameworks/CFNetwork.framework/... to otool -L.
#                It is asserted present rather than merely tolerated so that
#                this guard stays COUPLED to the source guards above — delete
#                the updater and this line fails too, forcing whoever did it to
#                come back here and restore the stricter contract on purpose
#                instead of leaving a comment that lies.
#
#   Security   — EXPECTED, tolerated if present. TLS needs it, and a binary
#                doing HTTPS is entitled to it. Empirically it does NOT appear
#                in this binary's direct link map on this toolchain: CFNetwork
#                reaches it transitively, so MacPulse never names it. Permitted
#                rather than asserted, because "the toolchain changed where a
#                transitive dependency is recorded" is not a contract
#                violation and must not fail a build.
#
#   Network    — STILL FORBIDDEN, and this is the part that still means
#                something. Network.framework is the modern low-level stack:
#                NWConnection will open a TCP or UDP connection to any host and
#                port you hand it, with no URL, no scheme and no allow-list
#                anyone can grep for. CFNetwork's presence is explained by one
#                file that can only form three hostnames; Network.framework's
#                presence would be explained by nothing, and would mean the
#                host allow-list above had been routed around entirely.
#
# Note that '/Network\.framework/' does not match '/CFNetwork.framework/' — the
# leading slash is load-bearing, since CFNetwork's path segment is "CFNetwork".
# ============================================================================
if LEAK=$(otool -L "$BIN_PATH" | grep -E '/Network\.framework/'); then
  echo "error: CONTRACT — Network.framework is in the link map:" >&2
  echo "$LEAK" >&2
  echo "       NWConnection can reach any host and port with nothing to grep." >&2
  echo "       MacPulse's only permitted network client is URLSession in" >&2
  echo "       Sources/Updater.swift, held to three GitHub hosts." >&2
  rm -f "$BIN_PATH"
  exit 1
fi
if ! otool -L "$BIN_PATH" | grep -qE '/CFNetwork\.framework/'; then
  echo "error: CONTRACT — CFNetwork is NOT in the link map." >&2
  echo "       This build expects it, because Sources/Updater.swift does HTTPS." >&2
  echo "       If the self-updater was removed on purpose, MacPulse is back to a" >&2
  echo "       STRICTER contract than the one documented at the top of this file:" >&2
  echo "       restore the old assertion (no CFNetwork/Network/Security) and say so" >&2
  echo "       in the contract block, rather than deleting this check." >&2
  rm -f "$BIN_PATH"
  exit 1
fi
echo "==> Contract OK: no Network.framework. CFNetwork present (expected — the updater)."
otool -L "$BIN_PATH" | grep -E '/(CFNetwork|Security)\.framework/' | sed 's/^/    /'

cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# The icon. Info.plist names it (CFBundleIconFile = AppIcon) and macOS then
# looks for Contents/Resources/AppIcon.icns; miss either half and the app is
# a blank generic document in Finder and in the Dock, with no error anywhere
# to say why.
#
# Checked explicitly rather than left to `cp` to fail under set -e, because
# the fix is a specific command and not a guessable one: AppIcon.icns is a
# BUILT artifact, rendered from Tools/IconRender.swift.
if [ ! -f "$ROOT/AppIcon.icns" ]; then
  echo "error: AppIcon.icns is missing. Run ./make-icon.sh — it renders" >&2
  echo "       Icon.iconset from Tools/IconRender.swift and packs the .icns." >&2
  exit 1
fi
cp "$ROOT/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

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
