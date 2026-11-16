#!/usr/bin/env bash
# shellcheck disable=SC2088,SC2155
# Быстрая проверка состояния сервера. Запуск от пользователя hermes: bash healthcheck.sh
# (от root: sudo -iu hermes bash healthcheck.sh)
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export PATH="$HOME/.local/bin:$PATH"
g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; n=$'\033[0m'
okf() { printf '%s[ОК]%s    %s\n' "$g" "$n" "$1"; }
bad() { printf '%s[НЕТ]%s   %s\n' "$r" "$n" "$1"; }
skp() { printf '%s[-]%s     %s\n' "$y" "$n" "$1"; }

echo "== Hermes =="
command -v hermes >/dev/null && okf "hermes: $(hermes --version 2>/dev/null | head -1)" || bad "hermes не найден"
for u in hermes-gateway hermes-dashboard; do
  systemctl --user is-active --quiet "$u" && okf "служба $u работает" || bad "служба $u не работает (journalctl --user -u $u -n 30)"
done
echo "== Claude =="
command -v claude >/dev/null && { claude auth status >/dev/null 2>&1 && okf "вход в Claude выполнен" || bad "вход в Claude не выполнен (docs/05)"; } || bad "Claude CLI не найден"
echo "== Хранилище =="
mountpoint -q "$HOME/cloud" && okf "~/cloud смонтирован (Яндекс.Диск)" || skp "~/cloud не смонтирован (модуль 04)"
systemctl --user is-active --quiet media-offload.timer && okf "media-offload.timer активен" || skp "media-offload.timer не активен"
echo "== Опционально =="
systemctl --user is-active --quiet gigastt && okf "gigastt работает" || skp "gigastt не запущен"
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx freellmapi && okf "FreeLLMAPI работает" || skp "FreeLLMAPI не запущен или нет доступа к docker"
grep -qE '^TELEGRAM_BOT_TOKEN=.+' "$HOME/.hermes/.env" 2>/dev/null && okf "Telegram настроен" || skp "Telegram не настроен"
echo "== Безопасность =="
if ss -tln 2>/dev/null | grep -E ':(3389|8642|9119|3001)\b' | grep -qE '0\.0\.0\.0|\*:'; then bad "Есть порты, открытые на все интерфейсы: ss -tlnp"; else okf "нет лишних открытых портов (3389/8642/9119/3001)"; fi
echo "== Ресурсы =="
free -h | sed -n 1,2p; df -h / | tail -1
