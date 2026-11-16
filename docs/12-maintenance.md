# 12. Обслуживание

## Обновление Hermes
`sudo -iu hermes hermes update` (затем `systemctl --user restart hermes-gateway`).

## Экономия ресурсов
| Что | Выключить | Включить |
|---|---|---|
| Рабочий стол | `sudo bash scripts/tools/rdp-off.sh` | `sudo bash scripts/tools/rdp-on.sh` |
| Голос, панель, индексация | `bash scripts/tools/save-resources.sh off` | `... on` |
| FreeLLMAPI | `docker stop freellmapi` (от root) | `docker start freellmapi` |

## Диагностика
- `bash scripts/tools/healthcheck.sh` (от пользователя hermes)
- `journalctl --user -u hermes-gateway -n 50`
- `free -h`, `df -h`
- Лог установки: `/var/log/hermes-setup.log`

## Резервные копии
- Заметки и проекты уже на Яндекс.Диске.
- Важное на сервере: `~/.hermes/` (настройки, память), `~/services/freellmapi/.env` (без него ключи провайдеров не расшифровать).

## Частые проблемы
| Симптом | Что делать |
|---|---|
| `hermes: command not found` по ssh | `~/.local/bin/hermes` или перелогиньтесь |
| Службы пропадают после выхода из SSH | `sudo loginctl enable-linger hermes` |
| `~/cloud` пустая | `systemctl --user restart rclone-yandex` |
| Бот Telegram молчит | docs/09, проверьте токен и ID |
| Сервер не отвечает | перезагрузка из панели хостинга |
