#!/usr/bin/env bash
# RUN_AS: root
# Модуль 01: базовая подготовка сервера (пользователь, SSH-ключ, firewall, swap, автообновления).
# shellcheck disable=SC2034
MOD_TITLE="База: пользователь, firewall, swap, обновления"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

mod_run() {
  need_root
  . /etc/os-release
  case "$VERSION_ID" in 22.04|24.04) ;; *) warn "Проверено на Ubuntu 22.04/24.04, у вас $PRETTY_NAME. Продолжаем на свой риск." ;; esac

  step "Обновление списка пакетов и установка базовых программ"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$HS_LOG" 2>&1 || die "apt update не прошёл"
  apt_install curl git ca-certificates jq unzip tmux htop ufw fuse3 build-essential \
              python3 python3-venv python3-pip unattended-upgrades sudo openssl || die "Не удалось поставить пакеты"
  ok "Пакеты установлены"

  step "Пользователь $HS_USER"
  if id "$HS_USER" >/dev/null 2>&1; then ok "Пользователь $HS_USER уже есть"
  else
    adduser --disabled-password --gecos "" "$HS_USER" >>"$HS_LOG" 2>&1 || die "Не удалось создать пользователя"
    ok "Пользователь $HS_USER создан (входить будем по SSH-ключу)"
  fi

  step "SSH-ключ для $HS_USER"
  local ssh_dir="/home/$HS_USER/.ssh" auth="/home/$HS_USER/.ssh/authorized_keys"
  install -d -m 700 -o "$HS_USER" -g "$HS_USER" "$ssh_dir"
  touch "$auth"; chmod 600 "$auth"; chown "$HS_USER:$HS_USER" "$auth"
  if [ -s "$auth" ]; then ok "Ключ уже добавлен"
  elif [ -s /root/.ssh/authorized_keys ] && confirm "Скопировать SSH-ключи root для пользователя $HS_USER?" y; then
    cat /root/.ssh/authorized_keys >> "$auth"; ok "Ключи скопированы"
  else
    local key=""
    say "Вставьте ПУБЛИЧНЫЙ ключ (одна строка, начинается с ssh-ed25519 или ssh-rsa). Как его получить - см. docs/02."
    ask key "Публичный ключ" ""
    if [[ "$key" =~ ^ssh-(ed25519|rsa)\ |^ecdsa- ]]; then echo "$key" >> "$auth"; ok "Ключ добавлен"
    else warn "Ключ не добавлен. Позже: добавьте строку в $auth. Пока вход пользователя $HS_USER по SSH не заработает."; fi
  fi

  step "Автозапуск пользовательских служб (linger)"
  if in_container; then warn "Контейнер: linger пропускаем"
  else loginctl enable-linger "$HS_USER" && ok "linger включён (службы Hermes переживут выход из SSH и перезагрузку)"; fi

  step "Firewall (ufw): открыт только SSH"
  if in_container; then warn "Контейнер: ufw пропускаем"
  else
    ufw allow OpenSSH >>"$HS_LOG" 2>&1 || ufw allow 22/tcp >>"$HS_LOG" 2>&1
    ufw default deny incoming >>"$HS_LOG" 2>&1; ufw default allow outgoing >>"$HS_LOG" 2>&1
    ufw --force enable >>"$HS_LOG" 2>&1 && ok "ufw включён: входящие закрыты, кроме SSH (22)"
  fi

  step "Swap"
  if in_container; then warn "Контейнер: swap пропускаем"
  elif swapon --show | grep -q .; then ok "Swap уже есть"
  elif [ "$(total_ram_mb)" -le 8192 ]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >>"$HS_LOG" 2>&1 && swapon /swapfile \
      && { grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; } && ok "Swap 2 ГБ создан" \
      || warn "Swap создать не удалось (не критично)"
  fi

  step "Автоматические обновления безопасности"
  dpkg-reconfigure -f noninteractive unattended-upgrades >>"$HS_LOG" 2>&1 && ok "Включены"

  ans_set HS_USER "$HS_USER"
}

mod_check() {
  id "$HS_USER" >/dev/null 2>&1 || { warn "Нет пользователя $HS_USER"; return 1; }
  have git && have curl && have jq || { warn "Не хватает базовых пакетов"; return 1; }
  [ -d "/home/$HS_USER/.ssh" ] || { warn "Нет ~/.ssh"; return 1; }
  in_container || { ufw status | grep -q 'Status: active' || { warn "ufw не активен"; return 1; }; }
  ok "База в порядке"
}

module_main "${1:-run}"
