#!/usr/bin/env bash
# RUN_AS: root
# OPTIONAL
# Модуль 09: Amnezia VPN. Сам VPN ставится на ПК клиентом Amnezia (он сам развернёт сервер по SSH).
# Этот модуль только готовит сервер (Docker) и печатает пошаговую памятку.
# shellcheck disable=SC2034
MOD_TITLE="Amnezia VPN: подготовка и памятка (клиент ставится на ПК)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

mod_run() {
  need_root
  step "Подготовка сервера"
  if have docker; then ok "Docker уже есть"; else apt_install docker.io || warn "Docker не поставился, Amnezia поставит его сама"; fi
  cat <<'EOF'

 AMNEZIA VPN - что делать на своём ПК (подробно: docs/10-amnezia.md)
  1. Скачайте клиент для Windows с официального сайта: https://amnezia.org (раздел Download)
     или с GitHub: https://github.com/amnezia-vpn/amnezia-client/releases
  2. В клиенте: «Свой сервер» -> введите IP сервера, пользователя root (или hermes с sudo) и пароль/ключ.
  3. Выберите протокол (рекомендуется AmneziaWG) и нажмите установить. Клиент сам поставит всё на сервер.
  4. Подключитесь и проверьте, что сайт 2ip.ru показывает IP сервера.
  5. Только после этого (по желанию) ужесточите SSH: sudo bash scripts/tools/harden-ssh.sh
EOF
}

mod_check() {
  ok "Памятка выведена. Установка VPN выполняется клиентом Amnezia на ПК"
}

module_main "${1:-run}"
