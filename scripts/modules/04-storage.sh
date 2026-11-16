#!/usr/bin/env bash
# RUN_AS: hermes
# Модуль 04: хранилище документов. Яндекс.Диск (WebDAV) монтируется через rclone в ~/cloud,
# выгрузка медиа (media-offload), Obsidian-индекс (плагин obsidian-rag).
# Секреты: пароль приложения Яндекса вводится скрыто и хранится только в ~/.config/rclone/rclone.conf (600).
# shellcheck disable=SC2034,SC2088
MOD_TITLE="Хранилище: Яндекс.Диск (rclone), media-offload, Obsidian"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

RCLONE="$HOME/.local/bin/rclone"
HERMES_BIN="$HOME/.local/bin/hermes"
CLOUD="$HOME/cloud"

install_rclone() {
  [ -x "$RCLONE" ] && { ok "rclone уже установлен: $("$RCLONE" version | head -1)"; return 0; }
  local arch; case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "Архитектура $(uname -m) не поддерживается" ;; esac
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "https://downloads.rclone.org/rclone-current-linux-$arch.zip" -o "$tmp/r.zip" || die "rclone не скачался"
  unzip -q -o "$tmp/r.zip" -d "$tmp" || die "rclone не распаковался"
  mkdir -p "$HOME/.local/bin"; install -m 755 "$tmp"/rclone-*/rclone "$RCLONE"; rm -rf "$tmp"
  ok "rclone установлен: $("$RCLONE" version | head -1)"
}

configure_yandex() {
  if "$RCLONE" listremotes 2>/dev/null | grep -q '^yandex:'; then ok "Remote «yandex» уже настроен"; return 0; fi
  say "Нужен ПАРОЛЬ ПРИЛОЖЕНИЯ Яндекса для «Файлы (WebDAV)». Как создать: docs/06-yandex-obsidian.md"
  local login="${YANDEX_LOGIN:-}" pw="${YANDEX_APP_PASSWORD:-}"
  if [ -z "$login" ] || [ -z "$pw" ]; then
    [ "$HS_YES" = "1" ] || [ ! -t 0 ] && { warn "Автоматический режим без YANDEX_LOGIN/YANDEX_APP_PASSWORD: настройку Яндекс.Диска пропускаем"; return 1; }
    read -rp "Логин Яндекса (без @yandex.ru): " login
    read -rsp "Пароль приложения (ввод не виден): " pw; echo
  fi
  [ -n "$login" ] && [ -n "$pw" ] || { warn "Пустой логин или пароль"; return 1; }
  mkdir -p "$HOME/.config/rclone"; umask 077
  {
    echo "[yandex]"; echo "type = webdav"; echo "url = https://webdav.yandex.ru"; echo "vendor = other"
    echo "user = $login"; printf 'pass = %s\n' "$(printf '%s' "$pw" | "$RCLONE" obscure -)"
  } > "$HOME/.config/rclone/rclone.conf"
  chmod 600 "$HOME/.config/rclone/rclone.conf"; unset pw
  if "$RCLONE" lsd yandex: >/dev/null 2>&1; then ok "Доступ к Яндекс.Диску подтверждён"
  else rm -f "$HOME/.config/rclone/rclone.conf"; warn "Яндекс не принял логин/пароль приложения. Проверьте и запустите модуль заново."; return 1; fi
}

mod_run() {
  [ "$(id -un)" = "$HS_USER" ] || die "Модуль запускается от пользователя $HS_USER"
  [ -x "$HERMES_BIN" ] || die "Сначала модуль 02"
  mkdir -p "$HOME/.config/systemd/user" "$HOME/.local/bin" "$HOME/.cache"

  step "rclone"; install_rclone
  step "Подключение к Яндекс.Диску"; configure_yandex || return 1
  "$RCLONE" mkdir yandex:Hermes >>"$HS_LOG" 2>&1 || true

  step "Монтирование Яндекс.Диска (папка Hermes) в ~/cloud"
  cat > "$HOME/.config/systemd/user/rclone-yandex.service" <<'EOF'
[Unit]
Description=Mount Yandex Disk (WebDAV) folder Hermes at ~/cloud via rclone
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p %h/cloud
ExecStart=%h/.local/bin/rclone mount yandex:Hermes %h/cloud \
  --vfs-cache-mode full \
  --vfs-cache-max-size 500M \
  --vfs-cache-max-age 24h \
  --vfs-cache-poll-interval 5m \
  --vfs-write-back 10s \
  --dir-cache-time 1m \
  --poll-interval 0 \
  --tpslimit 8 \
  --timeout 2m \
  --low-level-retries 10 \
  --log-level NOTICE
ExecStop=/usr/bin/fusermount3 -uz %h/cloud
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
  if [ ! -e /dev/fuse ]; then warn "Нет /dev/fuse (контейнер?): монтирование пропускаем"
  else
    suser daemon-reload; suser enable --now rclone-yandex.service >>"$HS_LOG" 2>&1 || warn "Служба монтирования не стартовала, см. journalctl --user -u rclone-yandex"
    sleep 4; mountpoint -q "$CLOUD" && ok "Яндекс.Диск смонтирован в $CLOUD" || warn "~/cloud пока не смонтирован"
  fi
  mkdir -p "$CLOUD/projects" "$CLOUD/media" 2>/dev/null || true

  step "media-offload: перенос медиа на Яндекс.Диск каждые 15 минут"
  cat > "$HOME/.local/bin/media-offload" <<'EOF'
#!/usr/bin/env bash
# Выгрузка вложений и сгенерированных файлов на Яндекс.Диск (Hermes/media/server/...).
# Удаление локально только после успешной передачи (rclone move).
set -uo pipefail
RCLONE="$HOME/.local/bin/rclone"
H="${HERMES_HOME:-$HOME/.hermes}"
DEST="yandex:Hermes/media/server"
MONTH="$(date +%Y-%m)"
exec 9>"$HOME/.cache/media-offload.lock"; flock -n 9 || exit 0
COMMON=(--tpslimit 4 --log-level NOTICE --delete-empty-src-dirs)
[ -d "$H/images" ] && "$RCLONE" move "$H/images" "$DEST/uploads/$MONTH" --min-age 24h "${COMMON[@]}"
# Голосовые сообщения не хранятся нигде: локально удаляются через 30 минут (без копии в облаке)
for d in "$H/cache/audio" "$H/audio_cache"; do
  [ -d "$d" ] && find "$d" -type f -mmin +30 -delete
done
for d in generated images videos documents screenshots; do
  [ -d "$H/cache/$d" ] || continue
  "$RCLONE" move "$H/cache/$d" "$DEST/$d/$MONTH" --min-age 30m "${COMMON[@]}"
  mkdir -p "$H/cache/$d"
done
mkdir -p "$H/images"
EOF
  chmod +x "$HOME/.local/bin/media-offload"
  cat > "$HOME/.config/systemd/user/media-offload.service" <<'EOF'
[Unit]
Description=Offload Hermes uploads/generated media to Yandex Disk
After=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/media-offload
Nice=10
EOF
  cat > "$HOME/.config/systemd/user/media-offload.timer" <<'EOF'
[Unit]
Description=Run media-offload every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  suser daemon-reload; suser enable --now media-offload.timer >>"$HS_LOG" 2>&1 && ok "Таймер media-offload включён" || warn "Таймер не включился"

  step "Obsidian: плагин obsidian-rag (поиск по заметкам)"
  if [ ! -d "$HOME/obsn-engine/.git" ]; then
    retry 2 git clone --depth 1 https://github.com/kastormdz/obsidian-rag.git "$HOME/obsn-engine" >>"$HS_LOG" 2>&1 || { warn "obsidian-rag не склонировался"; return 0; }
  fi
  if [ ! -x "$HOME/obsn-engine/.venv/bin/obsn" ]; then
    python3 -m venv "$HOME/obsn-engine/.venv" && "$HOME/obsn-engine/.venv/bin/pip" install -q -e "$HOME/obsn-engine" >>"$HS_LOG" 2>&1 \
      || { warn "pip install obsidian-rag не прошёл, см. $HS_LOG"; return 0; }
  fi
  "$HERMES_BIN" plugins list 2>/dev/null | grep -q obsidian-rag || \
    "$HERMES_BIN" plugins install obsidian-rag --enable </dev/null >>"$HS_LOG" 2>&1 || warn "Плагин obsidian-rag не поставился"
  "$HERMES_BIN" config set plugins.entries.obsidian-rag.obsn "$HOME/obsn-engine/.venv/bin/obsn" >>"$HS_LOG" 2>&1 || warn "Не удалось прописать путь obsn"
  "$HERMES_BIN" config set plugins.entries.obsidian-rag.vault "$CLOUD" >>"$HS_LOG" 2>&1 || warn "Не удалось прописать vault"
  grep -q '^OBSIDIAN_VAULT_PATH=' "$HOME/.hermes/.env" 2>/dev/null || echo "OBSIDIAN_VAULT_PATH=$CLOUD" >> "$HOME/.hermes/.env"

  cat > "$HOME/.config/systemd/user/obsn-reindex.service" <<EOF
[Unit]
Description=obsidian-rag incremental reindex

[Service]
Type=oneshot
ExecStart=%h/obsn-engine/.venv/bin/obsn reindex
Environment=OBS_RAG_VAULT=$CLOUD
Nice=10
IOSchedulingClass=idle
EOF
  cat > "$HOME/.config/systemd/user/obsn-reindex.timer" <<'EOF'
[Unit]
Description=Run obsn reindex every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=obsn-reindex.service

[Install]
WantedBy=timers.target
EOF
  suser daemon-reload; suser enable --now obsn-reindex.timer >>"$HS_LOG" 2>&1 && ok "Таймер индексации включён" || warn "Таймер индексации не включился"
}

mod_check() {
  [ -x "$RCLONE" ] || { warn "rclone не найден"; return 1; }
  "$RCLONE" listremotes 2>/dev/null | grep -q '^yandex:' || { warn "remote yandex не настроен"; return 1; }
  if [ -e /dev/fuse ]; then mountpoint -q "$CLOUD" || { warn "~/cloud не смонтирован"; return 1; }; fi
  [ -x "$HOME/.local/bin/media-offload" ] || { warn "нет media-offload"; return 1; }
  ok "Хранилище готово"
}

module_main "${1:-run}"
