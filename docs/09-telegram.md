# 09. Telegram-бот

1. В Telegram откройте @BotFather → `/newbot` → придумайте имя → скопируйте **токен**. [СКРИН: BotFather]
2. Откройте @userinfobot → `/start` → запомните ваш **числовой ID**.
3. На сервере: `sudo bash scripts/install.sh --only 08` → введите токен (ввод не виден) и ID.
4. Напишите своему боту `/start`.

Только пользователь с вашим ID сможет общаться с ботом. Токен хранится в `~/.hermes/.env` (600). Если токен утёк: @BotFather → /revoke.

Не отвечает: `journalctl --user -u hermes-gateway -n 50`.
