#!/usr/bin/env bash
# RUN_AS: root
# Модуль 03: лёгкий рабочий стол (xfce + xrdp + Firefox) для входа в Claude и прохождения KYC,
# плюс Claude Code CLI и плагин провайдера подписки Claude для Hermes.
# Порт 3389 НАРУЖУ НЕ ОТКРЫВАЕТСЯ: xrdp слушает только 127.0.0.1, заходим через SSH-туннель.
# shellcheck disable=SC2034,SC2088
MOD_TITLE="Рабочий стол (xfce+xrdp), Claude CLI, плагин подписки Claude"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

mod_run() {
  need_root
  id "$HS_USER" >/dev/null 2>&1 || die "Сначала модуль 01 (нет пользователя $HS_USER)"
  [ -x "/home/$HS_USER/.local/bin/hermes" ] || die "Сначала модуль 02 (Hermes не установлен)"

  step "Рабочий стол xfce + xrdp (около 400 МБ памяти, когда включён)"
  apt_install xfce4 xfce4-terminal xorg dbus-x11 xrdp xorgxrdp || die "Не удалось поставить рабочий стол"
  adduser xrdp ssl-cert >>"$HS_LOG" 2>&1 || true
  echo "startxfce4" > "/home/$HS_USER/.xsession"; chown "$HS_USER:$HS_USER" "/home/$HS_USER/.xsession"

  step "xrdp слушает только localhost"
  if grep -q '^address=' /etc/xrdp/xrdp.ini; then sed -i 's/^address=.*/address=127.0.0.1/' /etc/xrdp/xrdp.ini
  else sed -i '0,/^port=/s//address=127.0.0.1\nport=/' /etc/xrdp/xrdp.ini; fi
  ok "xrdp привязан к 127.0.0.1:3389 (снаружи недоступен)"

  step "Пароль пользователя $HS_USER для входа в рабочий стол"
  say "Этот пароль нужен ТОЛЬКО для RDP. Придумайте длинный (12+ символов)."
  local p1="" p2=""
  if [ "$HS_YES" = "1" ] || [ ! -t 0 ]; then
    p1="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)"
    warn "Автоматический режим: пароль сгенерирован: $p1 (запишите, он показывается один раз)"
  else
    while :; do
      read -rsp "Пароль: " p1; echo; read -rsp "Повторите: " p2; echo
      [ "${#p1}" -ge 12 ] && [ "$p1" = "$p2" ] && break
      warn "Пароли не совпали или короче 12 символов, ещё раз."
    done
  fi
  printf '%s:%s\n' "$HS_USER" "$p1" | chpasswd && ok "Пароль установлен"
  unset p1 p2

  step "Firefox (официальный репозиторий Mozilla, без snap)"
  if have firefox; then ok "Firefox уже есть"
  else
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc || warn "Ключ Mozilla не скачался"
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$HS_LOG" 2>&1
    apt_install firefox && ok "Firefox установлен" || warn "Firefox не поставился: можно открыть ссылку входа в браузере на своём ПК (см. docs/05)"
  fi

  step "Claude Code CLI"
  if [ -x "/home/$HS_USER/.local/bin/claude" ]; then ok "Claude CLI уже установлен"
  else
    as_user bash -c 'curl -fsSL https://claude.ai/install.sh | bash' >>"$HS_LOG" 2>&1 \
      && ok "Claude CLI установлен" || die "Claude CLI не установился, см. $HS_LOG"
  fi

  step "Плагин провайдера подписки Claude для Hermes"
  if as_user "/home/$HS_USER/.local/bin/hermes" plugins list 2>/dev/null | grep -q claude-subscription-directsdk-experimental; then ok "Плагин уже установлен"
  else
    as_user bash -c '~/.local/bin/hermes plugins install claude-subscription-directsdk --enable </dev/null' >>"$HS_LOG" 2>&1 \
      && ok "Плагин установлен" || warn "Плагин не поставился, см. $HS_LOG"
  fi

  step "Включаю рабочий стол"
  if in_container; then warn "Контейнер: службу xrdp не запускаем"
  else systemctl enable --now xrdp >>"$HS_LOG" 2>&1 && ok "xrdp запущен"; fi

  say ""
  say "============================================================"
  say " ДАЛЬШЕ ВЫ ДЕЛАЕТЕ РУКАМИ (подробно: docs/05-claude-login.md):"
  say "  1. На ПК: ssh -L 3389:127.0.0.1:3389 $HS_USER@<IP сервера>   (окно не закрывать)"
  say "  2. Подключение к рабочему столу (mstsc) на адрес 127.0.0.1, логин $HS_USER"
  say "  3. В терминале рабочего стола: claude   -> войти в аккаунт Claude (пройти KYC при запросе)"
  say "  4. Затем на сервере: sudo bash scripts/install.sh --only 03   (проверка и настройка провайдера)"
  say "  5. Освободить память: sudo bash scripts/tools/rdp-off.sh"
  say "============================================================"

  # Если вход в Claude уже выполнен, включаем провайдера в Hermes
  if as_user "/home/$HS_USER/.local/bin/claude" auth status >/dev/null 2>&1; then
    as_user "/home/$HS_USER/.local/bin/hermes" config set model.provider claude-subscription-directsdk-experimental >>"$HS_LOG" 2>&1 \
      && ok "Провайдер Hermes: подписка Claude" || warn "Не удалось выставить провайдера: hermes model"
  else
    warn "Вход в Claude ещё не выполнен. После входа запустите этот модуль повторно."
  fi
}

mod_check() {
  [ -x "/home/$HS_USER/.local/bin/claude" ] || { warn "Claude CLI не найден"; return 1; }
  have xrdp || { warn "xrdp не установлен"; return 1; }
  grep -q '^address=127.0.0.1' /etc/xrdp/xrdp.ini || { warn "xrdp не привязан к localhost!"; return 1; }
  as_user "/home/$HS_USER/.local/bin/hermes" plugins list 2>/dev/null | grep -q claude-subscription-directsdk-experimental \
    || { warn "Плагин подписки Claude не установлен"; return 1; }
  as_user "/home/$HS_USER/.local/bin/claude" auth status >/dev/null 2>&1 \
    && ok "Вход в Claude выполнен" || warn "Вход в Claude ещё не выполнен (docs/05) - это шаг для человека, не ошибка установки"
  ok "Рабочий стол и Claude CLI готовы"
}

module_main "${1:-run}"
