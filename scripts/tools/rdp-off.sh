#!/usr/bin/env bash
# Выключить рабочий стол (xrdp) и освободить память. Запуск: sudo bash rdp-off.sh
[ "$(id -u)" -eq 0 ] || { echo "Нужен root: sudo bash $0"; exit 1; }
systemctl disable --now xrdp xrdp-sesman 2>/dev/null
# закрыть забытые сеансы рабочего стола
pkill -u hermes -f 'xfce4-session|Xorg|xrdp-chansrv' 2>/dev/null || true
echo "Рабочий стол выключен. Включить обратно: sudo bash $(dirname "$0")/rdp-on.sh"
free -h | sed -n 1,2p
