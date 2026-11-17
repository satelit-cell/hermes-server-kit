#!/usr/bin/env bash
# RUN_AS: hermes
# OPTIONAL
# Модуль 07: распознавание речи (gigastt, GigaAM v3) для голосовых сообщений. Работает локально, ~0.8 ГБ RAM.
# shellcheck disable=SC2034
MOD_TITLE="Голос: распознавание речи gigastt (Ubuntu 24.04, RAM >= 6 ГБ)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

BIN="$HOME/.local/bin"
HERMES_BIN="$BIN/hermes"

mod_run() {
  [ "$(id -un)" = "$HS_USER" ] || die "Модуль запускается от пользователя $HS_USER"
  [ -x "$HERMES_BIN" ] || die "Сначала модуль 02"
  local ram; ram="$(total_ram_mb)"
  if [ "$ram" -lt 5500 ]; then
    warn "RAM сервера ${ram} МБ. gigastt занимает около 0.8-1.6 ГБ; на маленьком сервере лучше не ставить."
    confirm "Всё равно поставить?" n || { warn "Пропущено по выбору"; return 0; }
  fi
  [ "$(uname -m)" = "x86_64" ] || die "Готовая сборка gigastt есть только для x86_64"
  local glibc; glibc="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')"
  if [ -n "$glibc" ] && [ "$(printf '%s\n2.38\n' "$glibc" | sort -V | head -1)" != "2.38" ]; then
    warn "gigastt требует glibc 2.38+ (Ubuntu 24.04). У вас glibc $glibc (Ubuntu 22.04): голос на этом сервере не поддерживается."
    warn "Варианты: ставьте Ubuntu 24.04, либо используйте облачное распознавание (docs/08)."
    return 0
  fi
  mkdir -p "$BIN" "$HOME/.config/systemd/user"

  step "Установка gigastt (последний релиз с GitHub)"
  if [ -x "$BIN/gigastt" ]; then ok "gigastt уже установлен"
  else
    local tag asset tmp; tmp="$(mktemp -d)"
    tag="$(curl -fsS 'https://api.github.com/repos/ekhodzitsky/gigastt/releases?per_page=30' \
          | jq -r '[.[] | select(.tag_name|test("^v[0-9]")) | select(.prerelease==false)][0].tag_name')"
    [ -n "$tag" ] && [ "$tag" != null ] || die "Не удалось определить версию gigastt"
    asset="gigastt-${tag#v}-x86_64-unknown-linux-gnu.tar.gz"
    curl -fsSL "https://github.com/ekhodzitsky/gigastt/releases/download/$tag/$asset" -o "$tmp/$asset" || die "Не скачался $asset"
    if curl -fsSL "https://github.com/ekhodzitsky/gigastt/releases/download/$tag/$asset.sha256" -o "$tmp/$asset.sha256" 2>/dev/null; then
      ( cd "$tmp" && sha256sum -c "$asset.sha256" >/dev/null 2>&1 ) || die "Контрольная сумма gigastt не совпала"
      ok "Контрольная сумма совпала"
    else warn "Файл контрольной суммы не найден, пропускаю проверку"; fi
    tar -xzf "$tmp/$asset" -C "$tmp" && install -m 755 "$(find "$tmp" -name gigastt -type f | head -1)" "$BIN/gigastt" || die "Не распаковалось"
    rm -rf "$tmp"; ok "gigastt $tag установлен"
  fi

  step "Модель (около 222 МБ)"
  "$BIN/gigastt" download --model-variant e2e_rnnt --skip-diarization >>"$HS_LOG" 2>&1 || die "Модель не скачалась, см. $HS_LOG"
  ok "Модель загружена"

  step "Служба gigastt (только localhost:9876)"
  cat > "$HOME/.config/systemd/user/gigastt.service" <<'EOF'
[Unit]
Description=gigastt - local Russian STT server (GigaAM v3 e2e_rnnt) on 127.0.0.1:9876
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=%h/.local/bin/gigastt serve --host 127.0.0.1 --port 9876 --model-variant e2e_rnnt --profile edge --log-level warn
Restart=always
RestartSec=5
Nice=5
MemoryHigh=1200M
MemoryMax=1600M

[Install]
WantedBy=default.target
EOF
  cat > "$BIN/gigastt-stt" <<'EOF'
#!/usr/bin/env bash
# Обёртка для Hermes: отправляет аудио в gigastt и печатает текст.
curl --fail -s --data-binary @"$1" -H 'Content-Type: application/octet-stream' http://127.0.0.1:9876/v1/transcribe \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])'
EOF
  chmod +x "$BIN/gigastt-stt"
  suser daemon-reload; suser enable --now gigastt.service >>"$HS_LOG" 2>&1 || warn "gigastt не запущен (контейнер?)"
  local i; for i in $(seq 1 30); do curl -sf http://127.0.0.1:9876/ready >/dev/null 2>&1 && break; sleep 2; done

  step "Подключение к Hermes"
  local c="$HERMES_BIN config set"
  $c stt.providers.gigastt.type command --force >>"$HS_LOG" 2>&1
  $c stt.providers.gigastt.command "$BIN/gigastt-stt {input_path}" --force >>"$HS_LOG" 2>&1
  $c stt.providers.gigastt.timeout 900 --force >>"$HS_LOG" 2>&1
  $c stt.provider gigastt --force >>"$HS_LOG" 2>&1
  $c stt.language ru >>"$HS_LOG" 2>&1
  suser restart hermes-gateway.service >>"$HS_LOG" 2>&1 || true
  ok "Hermes использует gigastt для голосовых"
  say "Совет: чтобы освободить память, выключайте: systemctl --user stop gigastt (docs/12)."
}

mod_check() {
  [ -x "$BIN/gigastt" ] || { warn "gigastt не установлен (пропущен: мало RAM, Ubuntu 22.04 или выбор пользователя)"; return 1; }
  if curl -sf http://127.0.0.1:9876/ready >/dev/null 2>&1; then ok "gigastt отвечает"
  else warn "gigastt не отвечает на /ready (запущена ли служба?)"; fi
  return 0
}

module_main "${1:-run}"
