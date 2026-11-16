#!/usr/bin/env bash
# RUN_AS: hermes
# Модуль 02: Hermes Agent (последняя версия), плагины, службы gateway и dashboard.
# shellcheck disable=SC2034
MOD_TITLE="Hermes Agent, плагины, службы"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

HERMES_BIN="$HOME/.local/bin/hermes"

mod_run() {
  [ "$(id -un)" = "$HS_USER" ] || die "Модуль запускается от пользователя $HS_USER (install.sh делает это сам)"

  step "Установка Hermes Agent (официальный установщик, последняя версия)"
  if [ -x "$HERMES_BIN" ]; then ok "Hermes уже установлен: $("$HERMES_BIN" --version 2>/dev/null | head -1)"
  else
    retry 2 bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive' >>"$HS_LOG" 2>&1 \
      || die "Установщик Hermes не отработал. Смотрите $HS_LOG"
    [ -x "$HERMES_BIN" ] || die "После установки не найден $HERMES_BIN"
    ok "Hermes установлен"
  fi

  step "PATH для hermes"
  for f in "$HOME/.profile" "$HOME/.bashrc"; do
    grep -q '.local/bin' "$f" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$f"
  done
  export PATH="$HOME/.local/bin:$PATH"

  step "Плагины: cost-sentinel (каталог), provider-limits (сторонний, из GitHub)"
  # формат: имя_в_списке=идентификатор_для_установки
  local pair name id
  for pair in "cost-sentinel=cost-sentinel" "provider-limits=JaimeMarques/hermes-provider-limits"; do
    name="${pair%%=*}"; id="${pair#*=}"
    if "$HERMES_BIN" plugins list 2>/dev/null | grep -q "$name"; then ok "$name уже установлен"
    else "$HERMES_BIN" plugins install "$id" --enable </dev/null >>"$HS_LOG" 2>&1 && ok "$name установлен" \
         || warn "Плагин $name не поставился (не критично, см. $HS_LOG)"; fi
  done

  step "Служба gateway (связь Desktop/Telegram/Android с агентом)"
  "$HERMES_BIN" gateway install >>"$HS_LOG" 2>&1 || warn "gateway install вернул ошибку, см. $HS_LOG"
  suser daemon-reload 2>/dev/null || true
  suser enable --now hermes-gateway.service >>"$HS_LOG" 2>&1 || warn "gateway не запущен (в контейнере без systemd это нормально)"

  step "Служба dashboard (веб-панель только на localhost)"
  local unit_dir="$HOME/.config/systemd/user"; mkdir -p "$unit_dir"
  cat > "$unit_dir/hermes-dashboard.service" <<EOF
[Unit]
Description=Hermes Web Dashboard (только localhost)
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open
Restart=always
RestartSec=5
Nice=5
MemoryHigh=600M
MemoryMax=900M

[Install]
WantedBy=default.target
EOF
  suser daemon-reload 2>/dev/null || true
  suser enable --now hermes-dashboard.service >>"$HS_LOG" 2>&1 || warn "dashboard не запущен (в контейнере без systemd это нормально)"

  say ""
  say "Дальше: модуль 03 - вход в Claude. Полезная проверка: $HERMES_BIN doctor"
}

mod_check() {
  [ -x "$HERMES_BIN" ] || { warn "Hermes не найден"; return 1; }
  "$HERMES_BIN" --version >/dev/null 2>&1 || { warn "hermes --version не работает"; return 1; }
  if suser is-system-running >/dev/null 2>&1 || suser list-units >/dev/null 2>&1; then
    suser is-active hermes-gateway.service >/dev/null 2>&1 || { warn "hermes-gateway не активен"; return 1; }
  else warn "systemd --user недоступен (контейнер?): проверка служб пропущена"; fi
  ok "Hermes: $("$HERMES_BIN" --version 2>/dev/null | head -1)"
}

module_main "${1:-run}"
