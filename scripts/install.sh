#!/usr/bin/env bash
# Оркестратор установки. Запуск (от root или через sudo):
#   sudo bash scripts/install.sh            - интерактивное меню
#   sudo bash scripts/install.sh --all      - все рекомендуемые модули подряд
#   sudo bash scripts/install.sh --only 01,02
#   sudo bash scripts/install.sh --list     - показать модули и статус
# Флаги: --yes (без вопросов, значения по умолчанию)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
need_root
mkdir -p "$HS_STATE_DIR"; touch "$HS_LOG"; chmod 600 "$HS_LOG"

MODE="menu"; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE="all" ;;
    --only) MODE="only"; ONLY="${2:-}"; shift ;;
    --list) MODE="list" ;;
    --yes|-y) export HS_YES=1 ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Неизвестный флаг: $1" ;;
  esac
  shift
done

# Модули: файл, рекомендуется ли по умолчанию
mapfile -t MODULES < <(ls "$HERE"/modules/[0-9][0-9]-*.sh 2>/dev/null | sort)
[ "${#MODULES[@]}" -gt 0 ] || die "Не найдены модули в $HERE/modules"

mod_id()    { basename "$1" | cut -c1-2; }
mod_name()  { basename "$1" .sh; }
mod_title() { grep -m1 '^MOD_TITLE=' "$1" | cut -d'"' -f2; }
mod_user()  { grep -m1 '^# RUN_AS:' "$1" | awk '{print $3}'; }
mod_opt()   { grep -qm1 '^# OPTIONAL' "$1"; }

list_modules() {
  echo "Модули:"
  local m st
  for m in "${MODULES[@]}"; do
    if is_done "$(mod_name "$m")"; then st="${C_G}установлен${C_0}"; else st="не установлен"; fi
    printf '  %s  %-48s %s%s\n' "$(mod_id "$m")" "$(mod_title "$m")" "$st" "$(mod_opt "$m" && echo '  (по желанию)')"
  done
}

run_module() {
  local m="$1" name user rc
  name="$(mod_name "$m")"; user="$(mod_user "$m")"; user="${user:-root}"
  step "Модуль $name ($(mod_title "$m"))"
  if [ "$user" = "root" ]; then
    bash "$m" run; rc=$?
  else
    id "$HS_USER" >/dev/null 2>&1 || die "Пользователь $HS_USER ещё не создан. Сначала запустите модуль 01."
    cp -r "$HERE" "/home/$HS_USER/.hermes-setup-scripts" 2>/dev/null || true
    chown -R "$HS_USER:$HS_USER" "/home/$HS_USER/.hermes-setup-scripts" 2>/dev/null || true
    as_user env HS_YES="${HS_YES:-0}" HS_STATE_DIR="$HS_STATE_DIR" HS_LOG="/home/$HS_USER/hermes-setup-user.log" \
      bash "/home/$HS_USER/.hermes-setup-scripts/modules/$(basename "$m")" run; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    warn "Модуль $name завершился с ошибкой (код $rc). Подробности: $HS_LOG"
    return "$rc"
  fi
  # Проверка результата
  if [ "$user" = "root" ]; then bash "$m" check; rc=$?
  else as_user env HS_STATE_DIR="$HS_STATE_DIR" HS_LOG="/home/$HS_USER/hermes-setup-user.log" \
         bash "/home/$HS_USER/.hermes-setup-scripts/modules/$(basename "$m")" check; rc=$?; fi
  if [ "$rc" -eq 0 ]; then mark_done "$name"; ok "Модуль $name готов"; else warn "Проверка модуля $name не пройдена"; fi
  return "$rc"
}

select_modules() {
  local ids="$1" m id out=()
  for id in ${ids//,/ }; do
    for m in "${MODULES[@]}"; do [ "$(mod_id "$m")" = "$(printf '%02d' "$((10#$id))")" ] && out+=("$m"); done
  done
  printf '%s\n' "${out[@]}"
}

case "$MODE" in
  list) list_modules; exit 0 ;;
  all)
    for m in "${MODULES[@]}"; do
      if mod_opt "$m" && ! confirm "Установить «$(mod_title "$m")»?" n; then continue; fi
      run_module "$m" || { warn "Остановлено на модуле $(mod_name "$m"). Исправьте и запустите снова: повторный запуск безопасен."; exit 1; }
    done ;;
  only)
    [ -n "$ONLY" ] || die "Укажите номера модулей: --only 01,02"
    while IFS= read -r m; do [ -n "$m" ] && { run_module "$m" || exit 1; }; done < <(select_modules "$ONLY") ;;
  menu)
    while true; do
      echo; list_modules
      echo "  a  - установить всё по порядку, q - выход"
      read -r -p "Что установить? (номера через запятую, a, q): " choice || exit 0
      case "$choice" in
        q|Q) exit 0 ;;
        a|A) exec bash "${BASH_SOURCE[0]}" --all ;;
        "") ;;
        *) while IFS= read -r m; do [ -n "$m" ] && { run_module "$m" || true; }; done < <(select_modules "$choice") ;;
      esac
    done ;;
esac
