#!/bin/bash
# =============================================================================
# Builds the "drag MacPulse into Applications" .dmg.
#
# Input:  Build/dist-stage/MacPulse.app — the AD-HOC SIGNED distribution copy
#         that release.sh stages. Deliberately NOT Build/MacPulse.app and NOT
#         /Applications/MacPulse.app: both of those are signed with the local
#         dev certificate, which is the one signature a stranger's Mac can
#         escalate to "damaged" instead of the survivable "unidentified
#         developer". See the long comment in release.sh.
#
# Output: Build/MacPulse-<version>.dmg, containing
#           MacPulse.app
#           Applications           (symlink, the drag target)
#           Установить.command     (does the whole install incl. un-quarantine)
#           Если не открывается.txt
#           .background/           (only when dmg-assets has a background)
#
# Run it directly for a packaging-only rebuild:
#   ./release.sh 1.0.0 --local --no-build     (stages, then calls this)
#   ./make-dmg.sh                             (re-wraps the existing stage)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="MacPulse"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Info.plist")
VOL_NAME="$APP_NAME $VERSION"
DMG_PATH="$ROOT/Build/$APP_NAME-$VERSION.dmg"
STAGE="$ROOT/Build/dmg-stage"
RW_DMG="$ROOT/Build/$APP_NAME-rw.dmg"
MOUNT_POINT="/Volumes/$VOL_NAME"

SOURCE_APP="$ROOT/Build/dist-stage/$APP_NAME.app"
if [ ! -d "$SOURCE_APP" ]; then
  echo "!! Build/dist-stage/$APP_NAME.app not found." >&2
  echo "   That is the ad-hoc-signed distribution copy release.sh stages." >&2
  echo "   Run:  ./release.sh <version> --local" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Optional background. The icon agent produces this; the DMG must build
# perfectly well without it, because a missing picture is not a reason to be
# unable to ship.
#
# Design note for whoever draws it: the app icon is placed in the LEFT half
# and the Applications alias in the RIGHT half, both at 52% of the window
# height. Override any of that by dropping a dmg-assets/layout.conf with
# WINDOW_W / WINDOW_H / ICON_SIZE / APP_X / APP_Y / APPS_X / APPS_Y.
# A file named *@2x.png is treated as Retina and laid out at half its pixels.
# ---------------------------------------------------------------------------
BG_1X=""; BG_2X=""
for candidate in "dmg-assets/dmg-background.png" "dmg-assets/background.png"; do
  [ -f "$ROOT/$candidate" ] && { BG_1X="$ROOT/$candidate"; break; }
done
for candidate in "dmg-assets/dmg-background@2x.png" "dmg-assets/background@2x.png"; do
  [ -f "$ROOT/$candidate" ] && { BG_2X="$ROOT/$candidate"; break; }
done
# The @1x file is what sizes the window; if only the @2x exists, its pixels are
# halved below.
BACKGROUND="${BG_1X:-$BG_2X}"

# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------
echo "==> Staging"
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
rm -rf "$STAGE" "$DMG_PATH" "$RW_DMG"
mkdir -p "$STAGE"
cp -R "$SOURCE_APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

for asset in "Установить.command" "Если не открывается.txt"; do
  if [ ! -f "$ROOT/dmg-assets/$asset" ]; then
    echo "!! dmg-assets/$asset is missing — it is not optional." >&2
    echo "   Every ad-hoc-signed download hits the unidentified-developer" >&2
    echo "   prompt on first launch; that file is the only instructions a" >&2
    echo "   friend gets." >&2
    exit 1
  fi
  cp "$ROOT/dmg-assets/$asset" "$STAGE/$asset"
done
chmod +x "$STAGE/Установить.command"

# RETINA, and the reason this is not just a `cp`. Finder draws a DMG background
# picture at ONE POINT PER PIXEL, so handing it the 1280x800 @2x file in a
# 640x400 window shows the top-left quarter of the artwork, not a crisp
# version of it. The one thing Finder does understand is a multi-representation
# TIFF, which is what `tiffutil -cathidpicheck` builds out of the two PNGs. If
# that fails or only one size exists, the @1x PNG is used as-is: slightly soft
# on a Retina display, never wrong.
BG_STAGED=""
if [ -n "$BACKGROUND" ]; then
  mkdir -p "$STAGE/.background"
  if [ -n "$BG_1X" ] && [ -n "$BG_2X" ] && command -v tiffutil >/dev/null 2>&1 \
     && tiffutil -cathidpicheck "$BG_1X" "$BG_2X" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1; then
    BG_STAGED="background.tiff"
    echo "==> Background: ${BG_1X#$ROOT/} + ${BG_2X#$ROOT/} -> background.tiff (1x + 2x)"
  else
    BG_STAGED="background.${BACKGROUND##*.}"
    rm -f "$STAGE/.background/background.tiff"
    cp "$BACKGROUND" "$STAGE/.background/$BG_STAGED"
    echo "==> Background: ${BACKGROUND#$ROOT/}"
  fi
else
  echo "==> No background in dmg-assets/ — building a plain DMG"
fi

# ---------------------------------------------------------------------------
# Plain path: no background, no Finder involvement, always works.
# ---------------------------------------------------------------------------
if [ -z "$BACKGROUND" ]; then
  echo "==> Creating $(basename "$DMG_PATH")"
  hdiutil create -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  echo "==> Done: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
  exit 0
fi

# ---------------------------------------------------------------------------
# Laid-out path: a read/write image, a Finder pass that sets the background
# and the icon positions, then a compressed read-only copy.
#
# THE FINDER PASS IS BEST-EFFORT ON PURPOSE. Driving Finder needs an
# Automation (AppleEvents) TCC grant, which on a machine that has never given
# one shows a consent dialog — and on a build server there is nobody to click
# it. So it runs under a watchdog, and if it is denied, times out, or fails
# for any other reason, the DMG is still produced: it just opens as a plain
# icon view instead of the designed one. A missing background must never be
# able to fail a release.
# ---------------------------------------------------------------------------
WINDOW_W=""; WINDOW_H=""
if command -v sips >/dev/null 2>&1; then
  PW=$(sips -g pixelWidth  "$BACKGROUND" 2>/dev/null | awk '/pixelWidth/{print $2}')
  PH=$(sips -g pixelHeight "$BACKGROUND" 2>/dev/null | awk '/pixelHeight/{print $2}')
  if [ -n "${PW:-}" ] && [ -n "${PH:-}" ]; then
    case "$BACKGROUND" in
      *@2x.*) WINDOW_W=$((PW / 2)); WINDOW_H=$((PH / 2)) ;;
      *)      WINDOW_W="$PW";       WINDOW_H="$PH" ;;
    esac
    echo "==> Artwork ${PW}x${PH} -> window ${WINDOW_W}x${WINDOW_H} pt"
  fi
fi
WINDOW_W="${WINDOW_W:-640}"
WINDOW_H="${WINDOW_H:-400}"
# Defaults, expressed as fractions of the window so they survive a differently
# sized background — and tuned so that at the 640x400 the artwork is actually
# drawn for they come out at exactly the slots dmg-assets/dmg-layout.txt
# specifies: 168,208 and 472,208 at icon size 128. The arrow in the artwork
# points from one slot to the other, so these are not decoration.
ICON_SIZE=128
APP_X=$((WINDOW_W * 2625 / 10000))
APPS_X=$((WINDOW_W * 7375 / 10000))
APP_Y=$((WINDOW_H * 52 / 100))
APPS_Y=$APP_Y

# The artwork owns the numbers. dmg-assets/layout.conf is the machine-readable
# half of dmg-layout.txt; if the icon is ever redrawn against a different
# layout, that file is the one place this script needs to learn about it.
if [ -f "$ROOT/dmg-assets/layout.conf" ]; then
  # shellcheck disable=SC1090
  . "$ROOT/dmg-assets/layout.conf"
  echo "==> Layout from dmg-assets/layout.conf: ${WINDOW_W}x${WINDOW_H}, icons $ICON_SIZE, app $APP_X,$APP_Y, alias $APPS_X,$APPS_Y"
fi

STAGE_MB=$(du -sm "$STAGE" | cut -f1)
SIZE_MB=$((STAGE_MB + 60))

echo "==> Creating a read/write image (${SIZE_MB}M)"
hdiutil create -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ -format UDRW -size "${SIZE_MB}m" \
  -ov "$RW_DMG" >/dev/null

echo "==> Mounting"
hdiutil attach "$RW_DMG" -nobrowse -noautoopen >/dev/null
# hdiutil renames the mount point if something is already at /Volumes/<name>;
# resolve what we actually got rather than assuming.
if [ ! -d "$MOUNT_POINT" ]; then
  MOUNT_POINT=$(hdiutil info | awk -v v="$VOL_NAME" '$0 ~ "/Volumes/"v {sub(/^.*\/Volumes/, "/Volumes"); print; exit}')
fi

BG_FILE="$BG_STAGED"

echo "==> Laying out the window (Finder, best-effort, ${WINDOW_W}x${WINDOW_H})"
cat > "$ROOT/Build/dmg-layout.applescript" <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, $((200 + WINDOW_W)), $((140 + WINDOW_H))}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON_SIZE
    set background picture of theViewOptions to file ".background:$BG_FILE"
    set position of item "$APP_NAME.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
    update without registering applications
    close
  end tell
end tell
APPLESCRIPT

LAYOUT_OK=0
osascript "$ROOT/Build/dmg-layout.applescript" >/dev/null 2>&1 &
OSA_PID=$!
WAITED=0
while kill -0 "$OSA_PID" 2>/dev/null && [ "$WAITED" -lt 45 ]; do
  sleep 1
  WAITED=$((WAITED + 1))
done
if kill -0 "$OSA_PID" 2>/dev/null; then
  # Almost always an Automation consent dialog nobody is there to answer.
  kill -9 "$OSA_PID" 2>/dev/null || true
  echo "!! Finder layout timed out after ${WAITED}s — shipping an unstyled DMG."
else
  if wait "$OSA_PID"; then
    LAYOUT_OK=1
  else
    echo "!! Finder layout failed (Automation permission?) — shipping an unstyled DMG."
  fi
fi
[ "$LAYOUT_OK" = "1" ] && echo "==> Layout applied"

sync
echo "==> Unmounting"
hdiutil detach "$MOUNT_POINT" -quiet || hdiutil detach "$MOUNT_POINT" -force -quiet

echo "==> Compressing to $(basename "$DMG_PATH")"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

rm -rf "$STAGE" "$RW_DMG" "$ROOT/Build/dmg-layout.applescript"
echo "==> Done: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
