#!/bin/bash
# =============================================================================
# MacPulse — установка одной командой.
#
#     curl -fsSL https://raw.githubusercontent.com/borissharikoff-droid/MacPulse/main/install.sh | bash
#
# Удалить:
#
#     curl -fsSL .../install.sh | bash -s -- --uninstall
#
# -----------------------------------------------------------------------------
# WHY THIS EXISTS AT ALL, since there is a perfectly good .dmg next to it.
#
# MacPulse is signed ad-hoc: no paid Apple Developer account, no notarisation.
# A .dmg downloaded in a browser therefore arrives with the quarantine
# attribute set, and on macOS 15 and later Gatekeeper will not open such an app
# at all from Finder — the old right-click ▸ Открыть escape hatch was removed.
# The user has to go to System Settings ▸ Приватность и безопасность, scroll to
# a line about a blocked app and press «Открыть всё равно». Three steps, in a
# place nobody looks, after a dialog that says the app is damaged.
#
# A file fetched with curl is NOT quarantined — quarantine is applied by the
# thing that downloads it, and curl does not apply it. So an installer that
# downloads and installs the app itself produces a working app with no dialog,
# no Settings trip and no lie about damage. This is exactly what a Homebrew
# cask does with `--no-quarantine`, and it is the reason this file exists.
#
# WHAT IT REFUSES TO DO. It does not use sudo, ever. It does not touch anything
# outside the app bundle it installs. It deletes an existing MacPulse only
# after confirming that what is there IS MacPulse, by reading its bundle
# identifier — a script that rm -rf's a path built from a variable should have
# to prove the path is what it thinks it is.
# =============================================================================
set -euo pipefail

OWNER="borissharikoff-droid"
REPO="MacPulse"
APP_NAME="MacPulse"
BUNDLE_ID="io.github.borissharikoff-droid.MacPulse"
MIN_MACOS_MAJOR=13

# `releases/latest/download/<asset>` is a permanent redirect GitHub maintains
# to the newest release's asset. No API call, no JSON, no jq — one less thing
# to be installed and one less thing to parse.
ZIP_URL="https://github.com/$OWNER/$REPO/releases/latest/download/$APP_NAME.zip"

# Overridable so this exact script can be run end to end against a build that
# has NOT been released yet — `MACPULSE_ZIP_URL=file:///…/MacPulse.zip ./install.sh`.
# That is the only way to test the installer without publishing something to
# test it with, and testing a different code path than the one people run is
# not testing it. The verification below does not care where the zip came
# from: it checks the bundle identifier and the code signature either way.
ZIP_URL="${MACPULSE_ZIP_URL:-$ZIP_URL}"

# ---------------------------------------------------------------------------
# Output. Short lines, no jargon: whoever runs this is installing a menu-bar
# app, not debugging a build.
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'
if [ ! -t 1 ]; then BOLD=""; DIM=""; RED=""; GREEN=""; OFF=""; fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s▸%s %s\n' "$BOLD" "$OFF" "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$OFF" "$*"; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$OFF" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Where to put it.
#
# /Applications is drwxrwxr-x root:admin on a normal Mac, so an admin user
# writes to it without sudo. A managed or non-admin account cannot, and for
# those ~/Applications works identically for everything MacPulse does —
# including the login item, which SMAppService registers from either location.
# ---------------------------------------------------------------------------
pick_destination() {
  if [ -w /Applications ]; then
    echo "/Applications"
  else
    mkdir -p "$HOME/Applications"
    echo "$HOME/Applications"
  fi
}

# ---------------------------------------------------------------------------
# Never delete a path just because it matches a name.
# ---------------------------------------------------------------------------
is_macpulse_bundle() {   # $1 = path to a .app
  local plist="$1/Contents/Info.plist"
  [ -f "$plist" ] || return 1
  local id
  id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null) || return 1
  [ "$id" = "$BUNDLE_ID" ]
}

quit_running() {
  pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
  step "Закрываю запущенный MacPulse…"
  # Ask politely first: a running copy that is replaced underneath itself keeps
  # running from a deleted bundle, and then the version in the menu is a lie.
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    sleep 0.3
  done
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.5
}

uninstall() {
  local removed=0
  for dir in /Applications "$HOME/Applications"; do
    local app="$dir/$APP_NAME.app"
    if [ -d "$app" ] && is_macpulse_bundle "$app"; then
      quit_running
      rm -rf "$app"
      ok "Удалено: $app"
      removed=1
    fi
  done
  # The login item survives the app bundle, and a registered login item
  # pointing at nothing is exactly the kind of leftover people complain about.
  /bin/launchctl bootout "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1 || true
  # Everything MacPulse itself writes lives here.
  rm -rf "$HOME/Library/Application Support/$APP_NAME" 2>/dev/null || true
  rm -f  "$HOME/Library/Preferences/$BUNDLE_ID.plist" 2>/dev/null || true
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  [ "$removed" = 1 ] || say "MacPulse не найден — нечего удалять."
  ok "Готово."
  exit 0
}

# An `if`, not `[ … ] && uninstall`: the && form leaves the script's exit
# status at 1 on the normal path, which is invisible until someone chains
# something onto the installer.
if [ "${1:-}" = "--uninstall" ]; then uninstall; fi

# ---------------------------------------------------------------------------
# Checks BEFORE downloading 3 MB, so a machine that cannot run it is told so
# immediately and with the reason.
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "MacPulse — приложение для macOS."
[ "$(id -u)" != "0" ] || die "Не запускайте установщик через sudo — он ему не нужен."

OS_VER=$(sw_vers -productVersion)
OS_MAJOR=${OS_VER%%.*}
if [ "$OS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]; then
  die "Нужна macOS $MIN_MACOS_MAJOR (Ventura) или новее. У вас $OS_VER."
fi

# `uname -m` says x86_64 when the shell itself is running under Rosetta on an
# Apple Silicon Mac, which would pick the wrong slice to verify. This asks the
# hardware.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
  HOST_ARCH="arm64"
else
  HOST_ARCH="x86_64"
fi

say ""
say "${BOLD}MacPulse${OFF} ${DIM}— монитор системы в вырезе MacBook${OFF}"
say "${DIM}macOS $OS_VER · $HOST_ARCH${OFF}"
say ""

TMP=$(mktemp -d "${TMPDIR:-/tmp}/macpulse-install.XXXXXX")
STAGED=""

# `rc=$?` FIRST, and an explicit `exit`. A bash EXIT trap that does not exit
# leaves the shell's status set by the LAST command in the trap — so a plain
# `trap 'rm -rf "$TMP"' EXIT` turns every failure into a successful-looking
# exit 0, because rm succeeded. Measured here: the installer died on an
# unbound variable and still reported 0.
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  [ -n "$STAGED" ] && rm -rf "$STAGED"
  exit "$rc"
}
trap cleanup EXIT

step "Скачиваю последнюю версию…"
curl -fL --progress-bar "$ZIP_URL" -o "$TMP/$APP_NAME.zip" \
  || die "Не удалось скачать. Проверьте интернет, или скачайте вручную:
    https://github.com/$OWNER/$REPO/releases/latest"

step "Распаковываю…"
# ditto, not unzip: the archive is made with `ditto -c -k --keepParent`, and
# ditto is the one tool guaranteed to restore the bundle exactly, symlinks and
# extended attributes included.
ditto -x -k "$TMP/$APP_NAME.zip" "$TMP/unpacked" \
  || die "Архив повреждён — попробуйте ещё раз."

SRC="$TMP/unpacked/$APP_NAME.app"
[ -d "$SRC" ] || die "В архиве нет $APP_NAME.app."

# ---------------------------------------------------------------------------
# Verify BEFORE installing. Three separate questions:
#
#   1. Is it MacPulse?              — bundle identifier
#   2. Is it intact?                — codesign --verify walks every file in the
#                                     bundle and checks it against the sealed
#                                     hashes. A truncated download or a
#                                     tampered bundle fails here. This is a
#                                     much better integrity check than a
#                                     checksum published beside the file, which
#                                     anyone who could swap the file could swap
#                                     too.
#   3. Will it run on this CPU?     — the fat binary must contain this slice
# ---------------------------------------------------------------------------
step "Проверяю, что скачалось именно то…"
is_macpulse_bundle "$SRC" || die "Это не MacPulse — установка отменена."

codesign --verify --deep --strict "$SRC" 2>/dev/null \
  || die "Подпись приложения не сходится — файл скачался не целиком или был изменён.
    Попробуйте ещё раз."

EXE="$SRC/Contents/MacOS/$APP_NAME"
[ -x "$EXE" ] || die "В приложении нет исполняемого файла."
ARCHS=$(lipo -archs "$EXE" 2>/dev/null || echo "")
case " $ARCHS " in
  *" $HOST_ARCH "*) : ;;
  *) die "Эта сборка не поддерживает ваш процессор ($HOST_ARCH). В файле: ${ARCHS:-неизвестно}." ;;
esac

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          "$SRC/Contents/Info.plist" 2>/dev/null || echo "?")
ok "MacPulse $VERSION · $ARCHS"

DEST_DIR=$(pick_destination)
DEST="$DEST_DIR/$APP_NAME.app"

if [ -e "$DEST" ] && ! is_macpulse_bundle "$DEST"; then
  die "В $DEST_DIR уже лежит что-то другое с таким именем. Уберите его сами."
fi

step "Устанавливаю в ${DEST_DIR}…"

# COPY FIRST, REMOVE SECOND. The obvious order — delete the old app, then
# copy the new one — has a window in which the user has no app at all, and
# anything that goes wrong inside it (full disk, a failed copy, or, as
# happened here, a script bug) leaves them with nothing and no way to tell
# what to do about it. Measured, once, on this machine: the installer removed
# /Applications/MacPulse.app, died on the next line, and reported success.
#
# So the new copy is assembled next to the old one under a temporary name and
# put in place with a rename. The window where neither exists is now the
# length of one `mv` on the same filesystem.
STAGED="$DEST_DIR/.$APP_NAME.app.installing.$$"
rm -rf "$STAGED"
ditto "$SRC" "$STAGED" || die "Не удалось скопировать в $DEST_DIR."

if [ -e "$DEST" ]; then
  quit_running
  rm -rf "$DEST"
fi
mv "$STAGED" "$DEST" || die "Не удалось переместить приложение в $DEST_DIR."
STAGED=""

# THE LINE THE WHOLE FILE IS FOR. Nothing curl downloads is quarantined, so
# this is belt-and-braces for the case where someone downloaded the .dmg by
# hand first and is now running the installer to fix it.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Tell LaunchServices about it now rather than whenever it next scans, so the
# icon is right in Finder and Spotlight finds it immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

step "Запускаю…"
open "$DEST"

say ""
ok "Установлено: $DEST"
say ""
say "  Точка в вырезе сверху — это MacPulse. Наведите на неё мышь."
say "  Её цвет — вердикт macOS о давлении на память: серый спокойно,"
say "  жёлтый напряжённо, красный уже тормозит."
say ""
say "${DIM}  Автозапуск: значок в строке меню ▸ «Запускать при входе»${OFF}"
say "${DIM}  Удалить:    curl -fsSL https://raw.githubusercontent.com/$OWNER/$REPO/main/install.sh | bash -s -- --uninstall${OFF}"
say ""
