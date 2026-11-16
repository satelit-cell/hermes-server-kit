#!/usr/bin/env bash
# shellcheck disable=SC2088,SC2155
# Освободить память: остановить необязательные службы или запустить обратно.
#   bash save-resources.sh off   - остановить gigastt, dashboard, индексацию Obsidian
#   bash save-resources.sh on    - запустить обратно
# Рабочий стол (xrdp) выключается отдельно: sudo bash rdp-off.sh
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
UNITS=(gigastt.service hermes-dashboard.service obsn-reindex.timer free-models-diff.timer)
case "${1:-}" in
  off) for u in "${UNITS[@]}"; do systemctl --user stop "$u" 2>/dev/null && echo "остановлено: $u"; done ;;
  on)  for u in "${UNITS[@]}"; do systemctl --user start "$u" 2>/dev/null && echo "запущено: $u"; done ;;
  *) echo "Использование: bash $0 off|on"; exit 1 ;;
esac
free -h | sed -n 1,2p
