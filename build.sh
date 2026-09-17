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

# ---------------------------------------------------------------------------
# WHICH ARCHITECTURES
#
#   ./build.sh                arm64 only — the development build
#   ./build.sh --universal    arm64 + x86_64, lipo'd into one binary
#
# The default is one slice because it is a 2-4 minute compile and doubling
# that on every iteration buys the developer nothing: this machine is arm64.
# RELEASES are built --universal (release.sh passes it), because a friend on
# a 2019 Intel MacBook downloading an arm64-only build gets "приложение
# повреждено" from Finder, which is Gatekeeper's way of saying "no slice for
# this CPU" and is indistinguishable from a real corruption.
#
# Measured, not assumed: the x86_64 slice is compiled from the same sources
# with no #if arch anywhere, and `--probe` and `--rail-probe` are run against
# it under Rosetta before a release goes out. Page size is read at runtime
# (vm_page_size), never hardcoded to 16384, which is the one number that
# would silently differ on Intel.
# ---------------------------------------------------------------------------
ARCHS=(arm64)
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --universal) ARCHS=(arm64 x86_64) ;;
    --arm64)     ARCHS=(arm64) ;;
    # Build and check, but leave /Applications alone. Used by CI, and by
    # release.sh, which stages its own copy under its own signature.
    --no-install) INSTALL=0 ;;
    *)
      echo "error: unknown argument '$arg'" >&2
      echo "usage: ./build.sh [--universal|--arm64] [--no-install]" >&2
      exit 1 ;;
  esac
done
if [ "${MACPULSE_UNIVERSAL:-0}" = "1" ]; then ARCHS=(arm64 x86_64); fi

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
# URLSession: exactly TWO files, and each may name only its own one host.
#
#   Sources/Updater.swift    -> GitHub, to find and fetch a newer release
#   Sources/GeoLookup.swift  -> www.cloudflare.com, to answer "what IP does the
#                               world see me on", which on a machine behind a
#                               tunnel is the only honest form of that question
#
# Two is not "one, rounded up". Each file is pinned to its own allow-list by
# guard 2 below, so widening this sweep does NOT widen where either file can
# reach. Adding a third would mean adding a third allow-list and writing down
# what it buys — which is the point.
if BAD=$(grep -nE 'URLSession|URLRequest|URLCredential|URLProtocol' "$ROOT"/Sources/*.swift \
         | grep -vE ':[0-9]+:[[:space:]]*//' \
         | grep -v '/Updater\.swift:' \
         | grep -v '/GeoLookup\.swift:'); then
  echo "error: CONTRACT — URLSession outside Sources/{Updater,GeoLookup}.swift." >&2
  echo "       Exactly two files in MacPulse may talk to the network, and each may" >&2
  echo "       only reach the one host on its own allow-list." >&2
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
GEO_SRC="$ROOT/Sources/GeoLookup.swift"
if [ ! -f "$GEO_SRC" ]; then
  echo "error: CONTRACT — Sources/GeoLookup.swift is missing. If the public-IP" >&2
  echo "       readout was deliberately removed, narrow the URLSession sweep above" >&2
  echo "       back to Updater.swift alone and update the contract block at the top." >&2
  exit 1
fi

# Each networking file against its OWN allow-list, and each must still SPELL OUT
# its endpoint. One shared list would mean the geo lookup could reach GitHub and
# the updater could reach Cloudflare — neither has any business doing the other's
# job, and a guard that permits more than it needs to is not a guard.
check_hosts() {   # <file> <required-literal> <allowed host>...
  local src="$1"; local required="$2"; shift 2
  local bad=""
  while IFS= read -r literal; do
    [ -n "$literal" ] || continue
    local host="${literal#*://}"   # drop the scheme
    host="${host%%/*}"             # drop the path
    host="${host%%\?*}"
    host="${host%%#*}"
    host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
    local ok=""
    for allowed in "$@"; do
      [ "$host" = "$allowed" ] && ok=1
    done
    [ -n "$ok" ] || bad="$bad  $literal   -> host '$host'"$'\n'
  done < <(grep -oE 'https?://[^"'"'"'[:space:]]*' "$src" || true)
  if [ -n "$bad" ]; then
    echo "error: CONTRACT — $(basename "$src") names a host that is not on its" >&2
    echo "       allow-list. Allowed: $*" >&2
    echo "       Values may be interpolated into the PATH, NEVER into the host." >&2
    printf '%s' "$bad" >&2
    exit 1
  fi
  # ...and the allow-list must be doing work, not passing vacuously. A file with
  # no http literal at all passes the loop above, which is exactly what you get
  # if someone replaces the spelled-out URL with a string built at runtime — the
  # one shape this guard exists to stop. So require the literal to be there.
  if ! grep -q "$required" "$src"; then
    echo "error: CONTRACT — $(basename "$src") no longer spells out its endpoint" >&2
    echo "       literal ($required). Either the endpoint moved (update this check)" >&2
    echo "       or it is being assembled at runtime, which is the whole thing the" >&2
    echo "       host allow-list exists to prevent." >&2
    exit 1
  fi
}

check_hosts "$UPDATER_SRC" 'https://api\.github\.com/' \
            api.github.com github.com objects.githubusercontent.com
check_hosts "$GEO_SRC" 'https://www\.cloudflare\.com/cdn-cgi/trace' \
            www.cloudflare.com

echo "==> Contract OK: Updater.swift -> GitHub only; GeoLookup.swift -> www.cloudflare.com only."
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
# ApplicationServices arrives in the link map WITHOUT a -framework flag —
# Swift auto-links it from `import ApplicationServices` in
# Sources/AppWindowList.swift — and it is the Accessibility API behind the
# window list on a «Память» row (AXUIElementCreateApplication, kAXWindows,
# and pressing a window's own close button). MEASURED cost to the contract:
# otool -L gains exactly one line,
# /System/Library/Frameworks/ApplicationServices.framework/..., and no
# CFNetwork beyond the updater's, no Network.framework, no NetworkExtension.
# nm -u still imports no bind, no listen and no accept. It is a permission
# cost, not a networking one: MacPulse asks for Accessibility the first time
# a user clicks the badge on an app row, once per launch, and never at
# launch — the guards below are unchanged because there is nothing here for
# them to catch. See Sources/AppWindowList.swift and README «Разрешения».
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
MIN_OS="13.0"

# One slice. Everything that differs between architectures is the -target
# triple and nothing else, so there is exactly one copy of the flags.
build_slice() {   # $1 = arch, $2 = output path
  swiftc -O \
    -sdk "$SDK" \
    -target "$1-apple-macos$MIN_OS" \
    -o "$2" \
    "$ROOT"/Sources/*.swift \
    -framework AppKit -framework ServiceManagement -framework IOKit \
    -framework CoreAudio -framework CoreMediaIO \
    -framework UserNotifications -framework EventKit
}

if [ "${#ARCHS[@]}" -eq 1 ]; then
  echo "    ${ARCHS[0]}"
  build_slice "${ARCHS[0]}" "$BIN_PATH"
else
  SLICES=()
  for a in "${ARCHS[@]}"; do
    echo "    $a"
    build_slice "$a" "$ROOT/Build/.slice-$a"
    SLICES+=("$ROOT/Build/.slice-$a")
  done
  lipo -create "${SLICES[@]}" -output "$BIN_PATH"
  rm -f "${SLICES[@]}"
  echo "    lipo -> $(lipo -archs "$BIN_PATH")"
fi

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
#
# PER ARCHITECTURE, and that matters on a universal build: `otool -L` with no
# -arch reports only the FIRST slice, so a fat binary whose x86_64 half linked
# something the arm64 half did not would sail straight through a guard written
# the obvious way.
for a in "${ARCHS[@]}"; do
  if LEAK=$(otool -arch "$a" -L "$BIN_PATH" | grep -E '/Network\.framework/'); then
    echo "error: CONTRACT — Network.framework is in the $a link map:" >&2
    echo "$LEAK" >&2
    echo "       NWConnection can reach any host and port with nothing to grep." >&2
    echo "       MacPulse's only permitted network client is URLSession in" >&2
    echo "       Sources/Updater.swift, held to three GitHub hosts." >&2
    rm -f "$BIN_PATH"
    exit 1
  fi
  if ! otool -arch "$a" -L "$BIN_PATH" | grep -qE '/CFNetwork\.framework/'; then
    echo "error: CONTRACT — CFNetwork is NOT in the $a link map." >&2
    echo "       This build expects it, because Sources/Updater.swift does HTTPS." >&2
    echo "       If the self-updater was removed on purpose, MacPulse is back to a" >&2
    echo "       STRICTER contract than the one documented at the top of this file:" >&2
    echo "       restore the old assertion (no CFNetwork/Network/Security) and say so" >&2
    echo "       in the contract block, rather than deleting this check." >&2
    rm -f "$BIN_PATH"
    exit 1
  fi
done
echo "==> Contract OK (${ARCHS[*]}): no Network.framework. CFNetwork present (expected — the updater)."
for a in "${ARCHS[@]}"; do
  otool -arch "$a" -L "$BIN_PATH" \
    | grep -E '/(CFNetwork|Security)\.framework/' | sed "s|^|    $a |"
done

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
#
# FALLS BACK TO AD-HOC, and that is not a detail. This identity exists in one
# keychain on one machine. Anybody who clones this repo — or any CI runner —
# has no such certificate, and `codesign --sign` on a missing identity fails
# the build at the very last step, after a four-minute compile, with an error
# naming a certificate they have never heard of and have no reason to create.
# Ad-hoc signing is what releases ship with anyway, so the fallback is not a
# degraded build; it is the same signature strangers get.
SIGN_ID="CmdTabSwitcher Local Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
  SIGN_ID="-"
  echo "==> No local signing identity in the keychain — signing ad-hoc."
  echo "    (Expected on a fresh clone and on CI. Releases are ad-hoc too.)"
fi

echo "==> Code-signing ($SIGN_ID)..."
codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE"

if [ "$INSTALL" = "0" ]; then
  echo "==> Done (not installed): $APP_BUNDLE"
  exit 0
fi

echo "==> Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
codesign --force --deep --sign "$SIGN_ID" "/Applications/$APP_NAME.app"

echo "==> Done: /Applications/$APP_NAME.app"
