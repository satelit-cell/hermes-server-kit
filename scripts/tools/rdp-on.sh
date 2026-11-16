#!/usr/bin/env bash
# Включить рабочий стол (xrdp). Запуск: sudo bash rdp-on.sh
[ "$(id -u)" -eq 0 ] || { echo "Нужен root: sudo bash $0"; exit 1; }
systemctl enable --now xrdp 2>/dev/null && echo "xrdp включён (слушает только 127.0.0.1:3389)."
echo "На своём ПК: ssh -L 3389:127.0.0.1:3389 hermes@<IP сервера>, затем mstsc -> 127.0.0.1"
