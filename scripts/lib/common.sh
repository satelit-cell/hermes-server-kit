#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090
# Общая библиотека для install.sh и модулей. Подключается через `source`.
# Принципы: идемпотентность, понятные сообщения, секреты не сохраняются.

HS_VERSION="0.1.0"
HS_USER="${HS_USER:-hermes}"
HS_STATE_DIR="${HS_STATE_DIR:-/var/lib/hermes-setup}"
HS_ANSWERS="$HS_STATE_DIR/answers.env"      # только НЕсекретные ответы (читаемо для всех)
HS_LOG="${HS_LOG:-/var/log/hermes-setup.log}"
HS_YES="${HS_YES:-0}"                        # 1 = не задавать вопросов, брать значения по умолчанию

if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_0=$'\033[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_0=
fi

_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$HS_LOG" 2>/dev/null || true; }
say()  { printf '%s\n' "$*"; _log "$*"; }
step() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; _log "STEP $*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_G" "$C_0" "$*"; _log "OK $*"; }
warn() { printf '%s[!]%s  %s\n' "$C_Y" "$C_0" "$*" >&2; _log "WARN $*"; }
die()  { printf '%s[ОШИБКА]%s %s\n' "$C_R" "$C_0" "$*" >&2; _log "FAIL $*"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "Нужны права root. Запустите: sudo bash $0"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Запущены ли мы внутри контейнера (для тестов: пропускаем ufw, swap, linger и т.п.)
in_container() { [ -f /.dockerenv ] || { have systemd-detect-virt && systemd-detect-virt -cq 2>/dev/null; }; }

# ask VAR "Вопрос" [по_умолчанию]  -> кладёт ответ в переменную VAR
ask() {
  local var="$1" prompt="$2" def="${3:-}" ans
  if [ "$HS_YES" = "1" ] || [ ! -t 0 ]; then
    printf -v "$var" '%s' "${!var:-$def}"; return 0
  fi
  read -r -p "$prompt${def:+ [$def]}: " ans || true
  printf -v "$var" '%s' "${ans:-$def}"
}

# confirm "Вопрос" [y|n]  -> 0 если да
confirm() {
  local prompt="$1" def="${2:-y}" ans
  if [ "$HS_YES" = "1" ] || [ ! -t 0 ]; then [ "$def" = "y" ]; return; fi
  read -r -p "$prompt [$([ "$def" = y ] && echo Y/n || echo y/N)]: " ans || true
  ans="${ans:-$def}"; [[ "$ans" =~ ^[YyДд] ]]
}

# Несекретные ответы между модулями
ans_set() { mkdir -p "$HS_STATE_DIR"; touch "$HS_ANSWERS"; chmod 644 "$HS_ANSWERS"
  sed -i "/^$1=/d" "$HS_ANSWERS"; printf '%s=%q\n' "$1" "$2" >> "$HS_ANSWERS"; }
ans_get() { [ -f "$HS_ANSWERS" ] && ( . "$HS_ANSWERS"; printf '%s' "${!1:-}" ); }

# Отметки выполненных модулей
mark_done() { mkdir -p "$HS_STATE_DIR/done"; date -Is > "$HS_STATE_DIR/done/$1"; }
is_done()   { [ -f "$HS_STATE_DIR/done/$1" ]; }

# Выполнить команду от имени пользователя hermes (с рабочим systemd --user)
as_user() {
  local uid; uid="$(id -u "$HS_USER")"
  runuser -u "$HS_USER" -- env HOME="/home/$HS_USER" \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    PATH="/home/$HS_USER/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

# systemctl --user, когда мы root или hermes
suser() {
  if [ "$(id -un)" = "$HS_USER" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user "$@"
  else
    as_user systemctl --user "$@"
  fi
}

retry() { local n="$1"; shift; for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 3; done; return 1; }

# apt без вопросов
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >>"$HS_LOG" 2>&1; }

total_ram_mb() { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo; }

# Каждый модуль вызывается как: bash NN-name.sh run | check | info
module_main() {
  case "${1:-run}" in
    run)   mod_run ;;
    check) mod_check ;;
    info)  echo "$MOD_TITLE" ;;
    *) die "Неизвестная команда: $1" ;;
  esac
}
