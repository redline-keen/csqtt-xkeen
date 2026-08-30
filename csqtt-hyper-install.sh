#!/bin/sh
# csqtt-hyper-install.sh — Единый скрипт установки csqtt + nfqws2 + XKeen + Mihomo
set -e

REPO_URL="https://raw.githubusercontent.com/redline-keen/csqtt-xkeen/main"

echo "════════════════════════════════════════════════════"
echo " 🚀 ЭТАП 1/2: Установка csqtt-клиента"
echo "════════════════════════════════════════════════════"

printf "Устанавливать csqtt-клиент? [Y (Enter)/n]: "
read INSTALL_CSQTT < /dev/tty

# Если нажали Enter или Y/y — запускаем установку клиента
if [ -z "$INSTALL_CSQTT" ] || [ "$INSTALL_CSQTT" = "Y" ] || [ "$INSTALL_CSQTT" = "y" ]; then
    opkg update
    opkg install wget-ssl ca-bundle curl

    echo "Скачиваю csqtt-xkeen-install.sh..."
    wget --no-check-certificate -O /tmp/csqtt-xkeen-install.sh "${REPO_URL}/csqtt-xkeen-install.sh"
    sh /tmp/csqtt-xkeen-install.sh < /dev/tty
else
    echo "⏭️ Установка csqtt пропущена пользователем."
fi

echo ""
echo "════════════════════════════════════════════════════"
echo " 🚀 ЭТАП 2/2: Запуск установки nfqws2 + XKeen/Mihomo"
echo "════════════════════════════════════════════════════"

echo "Скачиваю csqtt-install-all.sh..."
curl -sSL -o /tmp/csqtt-install-all.sh "${REPO_URL}/csqtt-install-all.sh"
sh /tmp/csqtt-install-all.sh < /dev/tty

echo ""
echo "════════════════════════════════════════════════════"
echo "🎉 Установка csqtt + XKeen УСПЕШНО ЗАВЕРШЕНА!"
echo "════════════════════════════════════════════════════"
