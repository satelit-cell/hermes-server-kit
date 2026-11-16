#!/usr/bin/env bash
# RUN_AS: hermes
# OPTIONAL
# Модуль 07: Telegram-бот Hermes. Токен бота получаете у @BotFather, ваш числовой ID у @userinfobot.
# Токен вводится скрыто и пишется только в ~/.hermes/.env (права 600).
# shellcheck disable=SC2034
MOD_TITLE="Telegram-бот"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

ENVF="$HOME/.hermes/.env"
HERMES_BIN="$HOME/.local/bin/hermes"

set_env() { # set_env KEY VALUE : заменить или добавить строку, не печатая значение
  local k="$1" v="$2"
  touch "$ENVF"; chmod 600 "$ENVF"
  if grep -qE "^#?[[:space:]]*$k=" "$ENVF"; then
    python3 - "$ENVF" "$k" "$v" <<'PY'
import re, sys
p, k, v = sys.argv[1:4]
lines = open(p).read().splitlines()
out, done = [], False
for ln in lines:
    if not done and re.match(rf"^#?\s*{re.escape(k)}=", ln):
        out.append(f"{k}={v}"); done = True
    elif re.match(rf"^{re.escape(k)}=", ln):
        continue
    else:
        out.append(ln)
open(p, "w").write("\n".join(out) + "\n")
PY
  else printf '%s=%s\n' "$k" "$v" >> "$ENVF"; fi
}

mod_run() {
  [ "$(id -un)" = "$HS_USER" ] || die "Модуль запускается от пользователя $HS_USER"
  [ -x "$HERMES_BIN" ] || die "Сначала модуль 02"
  local token="${TELEGRAM_BOT_TOKEN:-}" uid="${TELEGRAM_ALLOWED_USERS:-}"
  if [ -z "$token" ] || [ -z "$uid" ]; then
    if [ "$HS_YES" = "1" ] || [ ! -t 0 ]; then warn "Нет TELEGRAM_BOT_TOKEN/TELEGRAM_ALLOWED_USERS: пропускаем"; return 0; fi
    say "Создайте бота у @BotFather (команда /newbot) и скопируйте токен. Подробно: docs/09-telegram.md"
    read -rsp "Токен бота (ввод не виден): " token; echo
    say "Узнайте свой числовой ID у бота @userinfobot. Только этот пользователь сможет писать вашему боту."
    read -rp "Ваш числовой Telegram ID: " uid
  fi
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || die "Токен выглядит неправильно (формат 123456:ABC...)"
  [[ "$uid" =~ ^[0-9]+$ ]] || die "ID должен состоять только из цифр"

  step "Запись настроек"
  set_env TELEGRAM_BOT_TOKEN "$token"
  set_env TELEGRAM_ALLOWED_USERS "$uid"
  set_env TELEGRAM_HOME_CHANNEL "$uid"
  unset token
  ok "Настройки Telegram сохранены в ~/.hermes/.env (600)"

  step "Перезапуск gateway"
  suser restart hermes-gateway.service >>"$HS_LOG" 2>&1 && ok "gateway перезапущен" || warn "Перезапустите вручную: systemctl --user restart hermes-gateway"
  say "Напишите своему боту в Telegram /start. Если молчит: journalctl --user -u hermes-gateway -n 50"
}

mod_check() {
  grep -qE '^TELEGRAM_BOT_TOKEN=.+' "$ENVF" 2>/dev/null || { warn "Токен бота не задан"; return 1; }
  ok "Telegram настроен (проверьте, ответил ли бот)"
}

module_main "${1:-run}"
