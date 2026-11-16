#!/usr/bin/env bash
# Отключить вход в SSH по паролю (остаётся только вход по ключу).
# Запускайте ТОЛЬКО когда вход по ключу уже проверен в ОТДЕЛЬНОМ окне: иначе потеряете доступ к серверу!
# Запуск: sudo bash harden-ssh.sh
[ "$(id -u)" -eq 0 ] || { echo "Нужен root: sudo bash $0"; exit 1; }
echo "ВНИМАНИЕ: после этого войти по паролю будет нельзя."
echo "Проверьте СЕЙЧАС в другом окне: ssh hermes@<IP>  (должен пускать без пароля, по ключу)."
read -rp "Вход по ключу проверен и работает? (напишите yes): " a
[ "$a" = "yes" ] || { echo "Отмена."; exit 1; }
f=/etc/ssh/sshd_config.d/99-hermes-hardening.conf
printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\n' > "$f"
if sshd -t; then systemctl reload ssh 2>/dev/null || systemctl reload sshd; echo "Готово. Вход по паролю отключён."
else rm -f "$f"; echo "Ошибка конфигурации, изменения отменены."; exit 1; fi
