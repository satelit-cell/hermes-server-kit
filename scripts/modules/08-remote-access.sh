#!/usr/bin/env bash
# RUN_AS: root
# Модуль 08: удалённый доступ для Hermes Android (и Desktop с другого ПК) через Tailscale.
# Порты gateway (8642) и dashboard (9119) привязываются ТОЛЬКО к адресу Tailscale, в интернет не смотрят.
# shellcheck disable=SC2034,SC2088
MOD_TITLE="Удалённый доступ: Tailscale для Hermes Android"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

HOME_U="/home/$HS_USER"
ENVF="$HOME_U/.hermes/.env"

mod_run() {
  need_root
  id "$HS_USER" >/dev/null 2>&1 || die "Сначала модуль 01"
  [ -x "$HOME_U/.local/bin/hermes" ] || die "Сначала модуль 02"

  step "Tailscale"
  if have tailscale; then ok "Tailscale уже установлен"
  else curl -fsSL https://tailscale.com/install.sh | sh >>"$HS_LOG" 2>&1 || die "Tailscale не установился"; fi
  in_container && { warn "Контейнер: tailscale up пропускаем"; return 0; }
  systemctl enable --now tailscaled >>"$HS_LOG" 2>&1 || true

  if ! tailscale ip -4 >/dev/null 2>&1; then
    say "Сейчас появится ссылка. Откройте её в браузере на ПК и войдите в Tailscale (бесплатный аккаунт)."
    tailscale up || die "tailscale up не завершился"
  fi
  local ip; ip="$(tailscale ip -4 | head -1)"
  [ -n "$ip" ] || die "Нет адреса Tailscale"
  ok "Адрес этого сервера в Tailscale: $ip"
  ans_set TAILSCALE_IP "$ip"
  ufw allow in on tailscale0 >>"$HS_LOG" 2>&1 || true

  step "Ключи доступа (хранятся в ~/.hermes/.env, права 600)"
  touch "$ENVF"; chown "$HS_USER:$HS_USER" "$ENVF"; chmod 600 "$ENVF"
  grep -q '^API_SERVER_KEY=' "$ENVF" || echo "API_SERVER_KEY=$(openssl rand -hex 24)" >> "$ENVF"
  grep -q '^HERMES_DASHBOARD_SESSION_TOKEN=' "$ENVF" || echo "HERMES_DASHBOARD_SESSION_TOKEN=$(openssl rand -hex 24)" >> "$ENVF"
  ok "Ключи созданы. Посмотреть: grep -E 'API_SERVER_KEY|DASHBOARD_SESSION_TOKEN' ~/.hermes/.env"

  step "Привязка gateway и dashboard к адресу Tailscale"
  as_user bash -c "~/.local/bin/hermes config set platforms.api_server.enabled true; ~/.local/bin/hermes config set gateway.api_server.host $ip" >>"$HS_LOG" 2>&1 || true
  local unit="$HOME_U/.config/systemd/user/hermes-dashboard.service"
  [ -f "$unit" ] && sed -i "s|--host [0-9.]*|--host $ip|" "$unit"
  as_user systemctl --user daemon-reload
  as_user systemctl --user restart hermes-gateway.service hermes-dashboard.service >>"$HS_LOG" 2>&1 || warn "Службы не перезапустились"
  sleep 5
  say ""
  say "Для Hermes Android (docs/11): установите Tailscale на телефон, войдите в тот же аккаунт;"
  say "  адрес сервера: $ip, порт Gateway 8642 (ключ API_SERVER_KEY), порт панели 9119 (токен HERMES_DASHBOARD_SESSION_TOKEN)."
}

mod_check() {
  have tailscale || { warn "Tailscale не установлен"; return 1; }
  in_container && return 0
  tailscale ip -4 >/dev/null 2>&1 || { warn "Tailscale не подключён (tailscale up)"; return 1; }
  if ss -tln | grep -E ':(8642|9119)\b' | grep -E '0\.0\.0\.0|\*:' >/dev/null; then
    warn "Порт 8642 или 9119 слушает на всех интерфейсах! Проверьте: ss -tlnp | grep -E '8642|9119'"; return 1
  fi
  ok "Доступ только по Tailscale"
}

module_main "${1:-run}"
