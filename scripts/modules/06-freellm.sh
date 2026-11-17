#!/usr/bin/env bash
# RUN_AS: root
# Модуль 06: бесплатные LLM-провайдеры. Docker + FreeLLMAPI (шлюз с общим /v1 для Hermes),
# скрипты поиска провайдеров и ежедневный отчёт об изменениях бесплатных моделей.
# Всё слушает ТОЛЬКО 127.0.0.1. Ключи провайдеров вводятся через дашборд (SSH-туннель), не через скрипт.
# shellcheck disable=SC2034,SC2088
MOD_TITLE="Бесплатные провайдеры: Docker, FreeLLMAPI, поиск провайдеров"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

FL_REPO="https://github.com/tashfeenahmed/freellmapi.git"
FL_SHA="${FREELLMAPI_SHA:-bce469c3994f460b97cbf0e2b32fc2e47fcd4e88}"   # проверенный (прочитанный) коммит
FL_DIR="/home/$HS_USER/services/freellmapi"
TOOLS_DIR="/home/$HS_USER/services/free-llm-tools"
FL_NAME="freellmapi"

fl_api() { # fl_api METHOD PATH [json] [token]
  local m="$1" p="$2" d="${3:-}" t="${4:-}"
  curl -fsS -X "$m" "http://127.0.0.1:3001$p" -H 'Content-Type: application/json' \
    ${t:+-H "Authorization: Bearer $t"} ${d:+-d "$d"}
}

mod_run() {
  need_root
  id "$HS_USER" >/dev/null 2>&1 || die "Сначала модуль 01"
  [ -x "/home/$HS_USER/.local/bin/hermes" ] || die "Сначала модуль 02"

  step "Docker"
  if have docker; then ok "Docker уже есть"
  else apt_install docker.io docker-buildx || apt_install docker.io || die "Docker не установился"; fi
  if in_container || ! docker info >/dev/null 2>&1; then
    systemctl enable --now docker >>"$HS_LOG" 2>&1 || true
    docker info >/dev/null 2>&1 || { warn "Docker-демон недоступен (контейнер?). FreeLLMAPI не запускаем."; install_tools; return 0; }
  fi

  step "Исходники FreeLLMAPI (коммит ${FL_SHA:0:7})"
  install -d -o "$HS_USER" -g "$HS_USER" "/home/$HS_USER/services" "$FL_DIR"
  if [ ! -d "$FL_DIR/src/.git" ]; then
    as_user git clone -q "$FL_REPO" "$FL_DIR/src" >>"$HS_LOG" 2>&1 || die "git clone не удался"
  fi
  as_user git -C "$FL_DIR/src" fetch -q origin >>"$HS_LOG" 2>&1 || true
  as_user git -C "$FL_DIR/src" checkout -q "$FL_SHA" >>"$HS_LOG" 2>&1 || die "Нет коммита $FL_SHA"
  ok "Код на проверенном коммите"

  step "Секрет шифрования ключей (.env)"
  if [ ! -f "$FL_DIR/.env" ]; then
    ( umask 077; printf 'ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)" > "$FL_DIR/.env" )
    chown "$HS_USER:$HS_USER" "$FL_DIR/.env"; ok ".env создан (600). НЕ теряйте: без него сохранённые ключи не расшифровать"
  else ok ".env уже есть"; fi

  step "Сборка образа (несколько минут)"
  local tag="freellmapi:${FL_SHA:0:7}" dockerfile="$FL_DIR/src/Dockerfile"
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    if ! docker buildx version >/dev/null 2>&1; then
      warn "Нет BuildKit: собираю по упрощённому Dockerfile"
      dockerfile="$FL_DIR/Dockerfile.classic"
      sed -E '/^# syntax=/d; s/^COPY --chmod=([0-9]+) ([^ ]+) ([^ ]+)$/COPY \2 \3\nRUN chmod \1 \3/' "$FL_DIR/src/Dockerfile" > "$dockerfile"
    fi
    DOCKER_BUILDKIT=1 docker build -q -t "$tag" -f "$dockerfile" --build-arg "FREELLMAPI_COMMIT_SHA=$FL_SHA" "$FL_DIR/src" >>"$HS_LOG" 2>&1 \
      || die "Сборка не удалась, смотрите $HS_LOG"
  fi
  ok "Образ $tag готов"

  step "Запуск контейнера (только 127.0.0.1:3001)"
  if docker ps -a --format '{{.Names}}' | grep -qx "$FL_NAME"; then
    docker rm -f "$FL_NAME" >/dev/null 2>&1
  fi
  docker run -d --name "$FL_NAME" --restart unless-stopped --memory 768m --cpus 1.5 \
    --log-opt max-size=10m --log-opt max-file=3 --env-file "$FL_DIR/.env" \
    -e NODE_ENV=production -e TZ=UTC -e FREEAPI_BLOCK_PRIVATE_PROVIDER_URLS=true \
    -p 127.0.0.1:3001:3001 -v freellmapi-data:/app/server/data \
    --security-opt no-new-privileges:true "$tag" >>"$HS_LOG" 2>&1 || die "Контейнер не запустился"
  local i; for i in $(seq 1 30); do curl -fsS -o /dev/null http://127.0.0.1:3001/ && break; sleep 2; done
  curl -fsS -o /dev/null http://127.0.0.1:3001/ && ok "FreeLLMAPI отвечает" || die "FreeLLMAPI не отвечает, см. docker logs $FL_NAME"

  bootstrap_account
  install_tools
}

bootstrap_account() {
  step "Первичная настройка шлюза (аккаунт дашборда и ключ для Hermes)"
  local cred="$FL_DIR/dashboard.cred"
  if [ -s "$cred" ]; then ok "Аккаунт дашборда уже создан ($cred)"; return 0; fi
  local code pass email="admin@freellmapi.local" tok key
  code="$(docker logs "$FL_NAME" 2>&1 | grep -i 'setup code' | tail -1 | sed -E 's/.*setup code: *//I' | tr -d '[:space:]')"
  pass="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  if ! fl_api POST /api/auth/setup "$(python3 -c 'import json,sys;print(json.dumps({"email":sys.argv[1],"password":sys.argv[2],"setupCode":sys.argv[3]}))' "$email" "$pass" "$code")" >/dev/null 2>&1; then
    warn "Автоматическая настройка не удалась. Создайте аккаунт вручную: docs/07 (через SSH-туннель на порт 3001)."; return 0
  fi
  ( umask 077; printf 'email=%s\npassword=%s\n' "$email" "$pass" > "$cred" ); chown "$HS_USER:$HS_USER" "$cred"
  tok="$(fl_api POST /api/auth/login "$(python3 -c 'import json,sys;print(json.dumps({"email":sys.argv[1],"password":sys.argv[2]}))' "$email" "$pass")" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("token") or d.get("sessionToken") or "")')"
  [ -n "$tok" ] || { warn "Не получен токен сессии: ключ для Hermes создайте в дашборде"; return 0; }
  key="$(fl_api POST /api/client-profiles '{"name":"hermes"}' "$tok" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("key") or d.get("apiKey") or "")')"
  [ -n "$key" ] || { warn "Ключ клиента не получен: создайте в дашборде (Client profiles)"; return 0; }
  local envf="/home/$HS_USER/.hermes/.env"
  grep -q '^FREELLMAPI_KEY=' "$envf" 2>/dev/null || { printf 'FREELLMAPI_KEY=%s\n' "$key" >> "$envf"; chown "$HS_USER:$HS_USER" "$envf"; chmod 600 "$envf"; }
  as_user bash -c '~/.local/bin/hermes config set providers.freellmapi.api http://127.0.0.1:3001/v1 && ~/.local/bin/hermes config set providers.freellmapi.key_env FREELLMAPI_KEY' >>"$HS_LOG" 2>&1 \
    && ok "FreeLLMAPI зарегистрирован в Hermes как провайдер freellmapi (модель по умолчанию НЕ менялась)" \
    || warn "Не удалось зарегистрировать провайдера в Hermes"
  say "Данные для входа в дашборд: $cred (читает только пользователь $HS_USER)"
}

install_tools() {
  step "Скрипты поиска провайдеров и ежедневный отчёт"
  install -d -o "$HS_USER" -g "$HS_USER" "$TOOLS_DIR" "$TOOLS_DIR/research"
  install -m 644 -o "$HS_USER" -g "$HS_USER" "$HERE/../assets/freellm/find_free_llm.py" "$HERE/../assets/freellm/daily_free_diff.py" "$HERE/../assets/freellm/probe_providers.py" "$TOOLS_DIR/"
  install -m 644 -o "$HS_USER" -g "$HS_USER" "$HERE/../assets/freellm/research/models_free.py" "$TOOLS_DIR/research/"
  local ud="/home/$HS_USER/.config/systemd/user"; install -d -o "$HS_USER" -g "$HS_USER" "$ud"
  cat > "$ud/free-models-diff.service" <<EOF
[Unit]
Description=Daily snapshot + diff of free LLM models

[Service]
Type=oneshot
WorkingDirectory=$TOOLS_DIR
ExecStart=/usr/bin/python3 -I $TOOLS_DIR/daily_free_diff.py --quiet
SuccessExitStatus=0 10
Nice=10
EOF
  cat > "$ud/free-models-diff.timer" <<'EOF'
[Unit]
Description=Run free-models-diff daily

[Timer]
OnCalendar=*-*-* 10:30:00 UTC
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chown "$HS_USER:$HS_USER" "$ud"/free-models-diff.*
  suser daemon-reload 2>/dev/null; suser enable --now free-models-diff.timer >>"$HS_LOG" 2>&1 \
    && ok "Ежедневный отчёт включён. Поиск: python3 -I $TOOLS_DIR/find_free_llm.py -q 'qwen|gpt-oss'" \
    || warn "Таймер отчёта не включился (контейнер?)"
}

mod_check() {
  [ -f "$TOOLS_DIR/find_free_llm.py" ] || { warn "Нет скриптов поиска провайдеров"; return 1; }
  if docker info >/dev/null 2>&1; then
    docker ps --format '{{.Names}}' | grep -qx "$FL_NAME" || { warn "Контейнер $FL_NAME не запущен"; return 1; }
    curl -fsS -o /dev/null http://127.0.0.1:3001/ || { warn "FreeLLMAPI не отвечает"; return 1; }
    ss -tln | grep -q '127.0.0.1:3001' || { warn "Порт 3001 должен слушать только 127.0.0.1"; return 1; }
  else warn "Docker недоступен: проверка контейнера пропущена"; fi
  ok "Бесплатные провайдеры: готово. Дальше: ключи провайдеров (docs/07)"
}

module_main "${1:-run}"
