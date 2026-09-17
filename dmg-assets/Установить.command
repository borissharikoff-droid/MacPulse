#!/bin/bash
# Двойной клик по этому файлу ставит MacPulse в «Программы» и запускает его.
#
# Зачем это нужно: MacPulse подписан ad-hoc подписью, без платного сертификата
# Apple Developer ID ($99/год). Файл, скачанный браузером, получает пометку
# com.apple.quarantine, и из-за неё Gatekeeper отказывается его запускать. Этот
# скрипт снимает пометку — дальше приложение работает как любое другое.
#
# ЕСЛИ И ЭТОТ ФАЙЛ НЕ ОТКРЫВАЕТСЯ. Пометка карантина висит и на нём тоже, и на
# свежих macOS Gatekeeper блокирует такие скрипты ровно так же. Тогда надёжный
# путь — одна команда в Терминале, которая скачивает и ставит всё сама:
#
#   curl -fsSL https://raw.githubusercontent.com/borissharikoff-droid/MacPulse/main/install.sh | bash
#
# Скачанное через curl карантин не получает, поэтому там этой проблемы нет
# в принципе.
set -e
cd "$(dirname "$0")"

BUNDLE_ID="io.github.borissharikoff-droid.MacPulse"

# Куда ставить: /Applications, если туда можно писать (обычный админ может),
# иначе ~/Applications — для MacPulse это равноценно, включая автозапуск.
if [ -w /Applications ]; then
  DEST_DIR="/Applications"
else
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  echo "Нет прав на /Applications — ставлю в $DEST_DIR"
fi
DEST="$DEST_DIR/MacPulse.app"

# Не удалять папку только потому, что она совпала по имени.
if [ -d "$DEST" ]; then
  EXISTING=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
             "$DEST/Contents/Info.plist" 2>/dev/null || echo "")
  if [ "$EXISTING" != "$BUNDLE_ID" ]; then
    echo "В $DEST_DIR уже лежит что-то другое с именем MacPulse.app."
    echo "Уберите его сами — этот скрипт чужое не трогает."
    exit 1
  fi
fi

echo "Устанавливаю MacPulse в ${DEST_DIR}…"

# СНАЧАЛА КОПИЯ, ПОТОМ ЗАМЕНА. Очевидный порядок — удалить старое, потом
# скопировать новое — оставляет промежуток, в котором приложения нет вообще,
# и всё, что пойдёт не так внутри этого промежутка, оставит человека без
# приложения и без единой подсказки, что теперь делать. Проверено на живом
# запуске install.sh: он удалил приложение, упал на следующей строке и
# отрапортовал об успехе.
STAGED="$DEST_DIR/.MacPulse.app.installing.$$"
rm -rf "$STAGED"
# ditto, а не cp -R: восстанавливает бандл в точности, вместе с симлинками.
ditto "MacPulse.app" "$STAGED"

if [ -d "$DEST" ]; then
  echo "  (нахожу старую версию — закрываю её)"
  osascript -e 'tell application "MacPulse" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x MacPulse >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$DEST"
fi
mv "$STAGED" "$DEST"

echo "Снимаю пометку карантина (иначе Gatekeeper заблокирует запуск)…"
# Именно карантин, а не `xattr -cr`: чистить все атрибуты подряд незачем.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Проверяем, что скопировалось целиком: подпись покрывает каждый файл бандла.
if ! codesign --verify --deep --strict "$DEST" 2>/dev/null; then
  echo ""
  echo "Приложение скопировалось не полностью — подпись не сходится."
  echo "Скачайте образ заново или поставьте одной командой:"
  echo "  curl -fsSL https://raw.githubusercontent.com/borissharikoff-droid/MacPulse/main/install.sh | bash"
  exit 1
fi

echo "Готово! Запускаю…"
open "$DEST"

echo ""
echo "MacPulse живёт в вырезе экрана сверху — наведи туда мышь."
echo "Если выреза нет, панель появится «пилюлей» по центру строки меню."
echo "Маленький индикатор в строке меню — это меню настроек и выход."
echo ""
echo "Разрешений при запуске не просит ни одного. Календарь и уведомления —"
echo "только если сам включишь их в меню."
echo ""
echo "Это окно можно закрыть."
sleep 5
