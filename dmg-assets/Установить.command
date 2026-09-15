#!/bin/bash
# Двойной клик по этому файлу ставит MacPulse в «Программы» и запускает его.
#
# Зачем это вообще нужно: MacPulse подписан ad-hoc подписью, без платного
# сертификата Apple Developer ID ($99/год). Файл, скачанный из интернета,
# получает пометку com.apple.quarantine, и из-за неё Gatekeeper блокирует
# запуск как «неизвестный разработчик». Скрипт снимает эту пометку — дальше
# приложение работает как любое другое, без предупреждений.
set -e
cd "$(dirname "$0")"

echo "Устанавливаю MacPulse в /Applications…"
if [ -d "/Applications/MacPulse.app" ]; then
  echo "  (нахожу старую версию — закрываю её)"
  osascript -e 'tell application "MacPulse" to quit' >/dev/null 2>&1 || true
  pkill -x MacPulse >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/MacPulse.app"
fi
cp -R "MacPulse.app" "/Applications/MacPulse.app"

echo "Снимаю карантин macOS (иначе Gatekeeper заблокирует запуск)…"
xattr -cr "/Applications/MacPulse.app"

echo "Готово! Запускаю…"
open "/Applications/MacPulse.app"

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
