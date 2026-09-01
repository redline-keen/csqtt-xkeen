#!/bin/sh
# Установка XKeen, сжатие mihomo через UPX и деплой config.yaml под csqtt
set -e

CONFIG_URL="https://raw.githubusercontent.com/redline-keen/csqtt-xkeen/refs/heads/main/csqtt-config.yaml"
MIHOMO_DIR="/opt/etc/mihomo"

echo "=== 1. Установка пакетов и XKeen ==="
opkg update && opkg upgrade && opkg install curl tar upx wget-ssl ca-bundle && cd /tmp

# Интерактивная установка XKeen со вводом строго через /dev/tty
sh -c "$(curl -sSL https://raw.githubusercontent.com/jameszeroX/XKeen/main/install.sh)" < /dev/tty

echo "=== 3. Загрузка конфигурации для csqtt (до победного) ==="
mkdir -p "$MIHOMO_DIR"

TRY_COUNT=1
while true; do
    echo "Попытка #${TRY_COUNT} загрузки config.yaml..."
    
    if command -v curl >/dev/null 2>&1; then
        curl -sSL --connect-timeout 5 --max-time 15 -o "$MIHOMO_DIR/config.yaml" "$CONFIG_URL" || true
    else
        wget --no-check-certificate -T 10 -t 1 -O "$MIHOMO_DIR/config.yaml" "$CONFIG_URL" || true
    fi

    if [ -s "$MIHOMO_DIR/config.yaml" ]; then
        echo "✅ Конфиг успешно загружен в $MIHOMO_DIR/config.yaml"
        break
    else
        echo "⚠️ Файл не загружен или пуст. Повтор через 3 сек..."
        rm -f "$MIHOMO_DIR/config.yaml"
        sleep 3
        TRY_COUNT=$((TRY_COUNT + 1))
    fi
done

echo "=== 4. Запуск служб ==="
if command -v xkeen >/dev/null 2>&1; then
    xkeen -start || true
elif [ -x /opt/etc/init.d/S99mihomo ]; then
    /opt/etc/init.d/S99mihomo start || true
fi

echo "🎉 Готово! XKeen+mihomo установлены."
