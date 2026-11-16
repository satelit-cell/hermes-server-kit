# 04. Hermes Desktop на ПК

1. Скачайте и установите Hermes Desktop для Windows по официальной инструкции: https://hermes-agent.nousresearch.com/docs/user-guide/desktop [СКРИН: установка]
2. Запустите и добавьте подключение к удалённому серверу по SSH (порядок и названия пунктов смотрите в https://hermes-agent.nousresearch.com/docs/user-guide/multi-connection-desktop): адрес `<IP-СЕРВЕРА>`, пользователь `hermes`, ваш SSH-ключ. [СКРИН: окно подключения]
3. Выберите модель и провайдера: после входа в Claude (docs/05) появится провайдер **Claude Subscription**.

**Ожидаемый результат:** окно чата открывается, агент отвечает.

Если подключение не проходит: проверьте, что вход `ssh hermes@<IP>` из PowerShell работает без пароля.
