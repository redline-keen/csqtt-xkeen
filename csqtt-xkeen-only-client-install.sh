#!/bin/sh

set -e

INSTALL_DIR="/opt/etc/csqtt"
BIN_NAME="csqtt-client"
REPO_RELEASE_URL="https://github.com/redline-keen/csqtt-xkeen/releases/download/1.0"
TARGET_PATH="${INSTALL_DIR}/${BIN_NAME}"
CONF_FILE="${INSTALL_DIR}/csqtt.conf"
LOG_FILE="${INSTALL_DIR}/csqtt-client.log"
WATCHDOG_SCRIPT="${INSTALL_DIR}/watchdog.sh"
INIT_SCRIPT="/opt/etc/init.d/S99csqtt"
UNINSTALL_BIN="/opt/bin/csqtt-uninstall"

echo "=== Установка и настройка csqtt-client ==="

# Проверка наличия среды Entware
if [ ! -d "/opt" ]; then
    echo "Ошибка: Каталог /opt не найден. Убедитесь, что Entware установлен." >&2
    exit 1
fi

# 0. Определение архитектуры процессора
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    aarch64*|arm64*)
        ARCH="arm64"
        ;;
    armv7*|armv8l*|arm*)
        ARCH="armv7"
        ;;
    mips64el*|mipsel*)
        ARCH="mipsel"
        ;;
    mips64*|mips*)
        if [ -f /bin/busybox ] && /bin/busybox hexdump -s 5 -n 1 -e '1/1 "%d"' /bin/busybox 2>/dev/null | grep -q "1"; then
            ARCH="mipsel"
        elif [ -f /bin/sh ] && hexdump -s 5 -n 1 -e '1/1 "%d"' /bin/sh 2>/dev/null | grep -q "1"; then
            ARCH="mipsel"
        else
            ARCH="mips"
        fi
        ;;
    *)
        echo "Ошибка: Неподдерживаемая архитектура процессора: ${ARCH_RAW}" >&2
        exit 1
        ;;
esac

BIN_URL="${REPO_RELEASE_URL}/${BIN_NAME}-${ARCH}"
echo "Обнаружена архитектура: ${ARCH} (${ARCH_RAW})"
echo "URL загрузки: ${BIN_URL}"

URI="$1"

# 1. Цикл валидации ссылки с поддержкой TTY
while true; do
    if [ -z "$URI" ]; then
        if [ -t 0 ]; then
            printf "Вставьте ссылку конфигурации csqtt:// : "
            read -r URI
        else
            printf "Вставьте ссылку конфигурации csqtt:// : " > /dev/tty
            read -r URI < /dev/tty
        fi
    fi

    HOST=$(echo "$URI" | sed -n 's/.*[?&]host=\([^&]*\).*/\1/p')
    PORT=$(echo "$URI" | sed -n 's/.*[?&]peer=\([^&]*\).*/\1/p')
    PASSWORD=$(echo "$URI" | sed -n 's/.*[?&]password=\([^&]*\).*/\1/p')
    HASHES_RAW=$(echo "$URI" | sed -n 's/.*[?&]hashes=\([^&]*\).*/\1/p')

    if [ -n "$HOST" ] && [ -n "$PORT" ] && [ -n "$PASSWORD" ] && [ -n "$HASHES_RAW" ]; then
        echo " Ссылка принята."
        break
    else
        echo " Некорректная ссылка! Отсутствуют обязательные параметры."
        URI=""
    fi
done

VK=$(echo "$HASHES_RAW" | tr '+' ',')
PEER="${HOST}:${PORT}"
TUN="csqtt0"

# 2. Запрос потоков (от 9 до 162)
while true; do
    if [ -t 0 ]; then
        printf "Введите количество потоков [-n] (по умолчанию 108, диапазон от 9 до 162): "
        read -r THREADS_INPUT
    else
        printf "Введите количество потоков [-n] (по умолчанию 108, диапазон от 9 до 162): " > /dev/tty
        read -r THREADS_INPUT < /dev/tty
    fi
    
    if [ -z "$THREADS_INPUT" ]; then
        N="108"
        break
    fi

    case "$THREADS_INPUT" in
        ''|*[!0-9]*)
            echo " Ошибка: введите целое число от 9 до 162."
            ;;
        *)
            if [ "$THREADS_INPUT" -ge 9 ] && [ "$THREADS_INPUT" -le 162 ]; then
                N="$THREADS_INPUT"
                break
            else
                echo " Ошибка: значение должно быть в диапазоне от 9 до 162."
            fi
            ;;
    esac
done

echo "Количество потоков установлено: $N"

# 3. Сохранение конфигурации
echo "[1/6] Сохранение конфигурации в ${CONF_FILE}..."
mkdir -p "${INSTALL_DIR}"

printf "PEER='%s'\nPASSWORD='%s'\nVK='%s'\nTUN='%s'\nN='%s'\n" \
    "$PEER" "$PASSWORD" "$VK" "$TUN" "$N" > "${CONF_FILE}"
chmod 600 "${CONF_FILE}"

# 4. Загрузка бинарника
echo "[2/6] Загрузка бинарного файла (${ARCH})..."
if command -v curl >/dev/null 2>&1; then
    curl -fL -o "${TARGET_PATH}" "${BIN_URL}"
elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate -O "${TARGET_PATH}" "${BIN_URL}"
fi
chmod +x "${TARGET_PATH}"

# 5. Создание init-скрипта
echo "[3/6] Создание init-скрипта ${INIT_SCRIPT}..."
mkdir -p /opt/etc/init.d

cat > "${INIT_SCRIPT}" << 'EOF'
#!/bin/sh

DESC="csqtt-client daemon"
NAME="csqtt-client"
DIR="/opt/etc/csqtt"
PROG="${DIR}/csqtt-client"
CONF="${DIR}/csqtt.conf"
LOGFILE="${DIR}/csqtt-client.log"
PIDFILE="/opt/var/run/csqtt-client.pid"
MAX_LOG_SIZE=1048576 # 1 МБ

if [ ! -x "$PROG" ]; then
    echo "$PROG not found or not executable"
    exit 1
fi

if [ ! -f "$CONF" ]; then
    echo "Config $CONF not found"
    exit 1
fi

. "$CONF"

start() {
    echo -n "Starting $DESC: $NAME... "
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "already running."
        exit 0
    fi

    mkdir -p /opt/var/run "$DIR"
    > "$LOGFILE"

    # Ожидание готовности WAN, DNS и NTP
    WAIT_COUNT=30
    while [ $WAIT_COUNT -gt 0 ]; do
        if nslookup api.vk.me >/dev/null 2>&1 && [ "$(date +%Y)" -ge 2024 ]; then
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT - 1))
    done

    (
        "$PROG" --peer "$PEER" --password "$PASSWORD" --vk "$VK" --tun "$TUN" -n "$N" 2>&1 | while IFS= read -r line; do
            echo "$line" >> "$LOGFILE"
            count=$((count + 1))
            if [ "$count" -ge 100 ]; then
                count=0
                size=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
                if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
                    tail -n 2000 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
                fi
            fi
        done
    ) &
    PID=$!
    echo $PID > "$PIDFILE"

    sleep 1
    if kill -0 "$PID" 2>/dev/null; then
        echo "done."
    else
        echo "failed."
        rm -f "$PIDFILE"
        exit 1
    fi
}

stop() {
    echo -n "Stopping $DESC: $NAME... "
    if [ ! -f "$PIDFILE" ]; then
        killall -q "$NAME" 2>/dev/null || true
        echo "not running."
        return
    fi

    PID=$(cat "$PIDFILE")
    kill "$PID" 2>/dev/null || true
    
    TIMEOUT=10
    while kill -0 "$PID" 2>/dev/null && [ $TIMEOUT -gt 0 ]; do
        sleep 1
        TIMEOUT=$((TIMEOUT - 1))
    done

    if kill -0 "$PID" 2>/dev/null; then
        kill -9 "$PID" 2>/dev/null || true
    fi

    killall -q "$NAME" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "done."
}

status() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "$DESC is running (PID $(cat "$PIDFILE"))."
    else
        echo "$DESC is stopped."
    fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    status) status ;;
    *) echo "Usage: $0 {start|stop|restart|status}" ; exit 1 ;;
esac

exit 0
EOF

chmod +x "${INIT_SCRIPT}"

# 6. Создание Watchdog и регистрация в Cron с перезапуском демона
echo "[4/6] Создание скрипта watchdog и настройка Cron..."

cat > "${WATCHDOG_SCRIPT}" << 'EOF'
#!/bin/sh

PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/bin:/usr/bin:/sbin:/sbin:/usr/sbin
export PATH

CONF_DIR="/opt/etc/csqtt"
LOG_FILE="${CONF_DIR}/csqtt-client.log"
WD_LOG="${CONF_DIR}/watchdog.log"
MAX_SIZE_KB=1024
TUN_IFACE="csqtt0"
INIT_SCRIPT="/opt/etc/init.d/S99csqtt"
PING_TARGET="77.88.8.8"

# 1. Ротация логов
for log in "$LOG_FILE" "$WD_LOG"; do
    if [ -f "$log" ]; then
        FILE_SIZE=$(du -k "$log" 2>/dev/null | awk '{print $1}')
        if [ -n "$FILE_SIZE" ] && [ "$FILE_SIZE" -gt "$MAX_SIZE_KB" ]; then
            tail -n 500 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] Лог $log превысил $MAX_SIZE_KB КБ и был обрезан." >> "$WD_LOG"
        fi
    fi
done

# 2. Проверка процесса и интерфейса
IS_RUNNING=0
if pgrep csqtt-client >/dev/null 2>&1 || pidof csqtt-client >/dev/null 2>&1; then
    IS_RUNNING=1
fi

IS_UP=0
if ip link show "$TUN_IFACE" 2>/dev/null | grep -q "UP"; then
    IS_UP=1
fi

if [ $IS_RUNNING -eq 0 ] || [ $IS_UP -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] Процесс или интерфейс $TUN_IFACE лежит (proc=$IS_RUNNING, if=$IS_UP). Перезапуск..." >> "$WD_LOG"
    rm -f /opt/var/run/csqtt-client.pid
    "$INIT_SCRIPT" restart >> "$WD_LOG" 2>&1
    exit 0
fi

# 3. Проверка пинга через интерфейс csqtt0
if ! ping -c 2 -W 3 -I "$TUN_IFACE" "$PING_TARGET" >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] Пинг через $TUN_IFACE не прошел. Перезапуск..." >> "$WD_LOG"
    rm -f /opt/var/run/csqtt-client.pid
    "$INIT_SCRIPT" restart >> "$WD_LOG" 2>&1
fi
EOF

chmod +x "${WATCHDOG_SCRIPT}"

mkdir -p /opt/var/spool/cron/crontabs
touch /opt/var/spool/cron/crontabs/root

CRON_JOB="*/2 * * * * /opt/etc/csqtt/watchdog.sh >/dev/null 2>&1"
if ! grep -Fq "/opt/etc/csqtt/watchdog.sh" /opt/var/spool/cron/crontabs/root 2>/dev/null; then
    # Очищаем возможные битые пустые строки и дописываем задачу
    sed -i '/^[[:space:]]*$/d' /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    echo "$CRON_JOB" >> /opt/var/spool/cron/crontabs/root
fi

# Перезапуск cron для обязательного перечитывания спойла
if [ -x "/opt/etc/init.d/S10cron" ]; then
    /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true
fi

# 7. Создание скрипта удаления csqtt-uninstall
echo "[5/6] Создание скрипта удаления ${UNINSTALL_BIN}..."
mkdir -p /opt/bin

cat > "${INSTALL_DIR}/uninstall.sh" << 'EOF'
#!/bin/sh

echo "=== Удаление csqtt-client и всех его компонентов ==="

# Удаление из crontab и перезапуск cron
if [ -f "/opt/var/spool/cron/crontabs/root" ]; then
    sed -i '/\/opt\/etc\/csqtt\/watchdog\.sh/d' /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    if [ -x "/opt/etc/init.d/S10cron" ]; then
        /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true
    fi
fi

# Остановка службы
if [ -x "/opt/etc/init.d/S99csqtt" ]; then
    echo "Остановка службы..."
    /opt/etc/init.d/S99csqtt stop 2>/dev/null || true
fi

killall -9 csqtt-client 2>/dev/null || true

rm -f /opt/etc/init.d/S99csqtt
rm -f /opt/var/run/csqtt-client.pid
rm -f /opt/bin/csqtt-uninstall
rm -rf /opt/etc/csqtt

echo "csqtt-client, watchdog и все хвосты успешно удалены."
EOF

chmod +x "${INSTALL_DIR}/uninstall.sh"

cat > "${UNINSTALL_BIN}" << 'EOF'
#!/bin/sh
exec /opt/etc/csqtt/uninstall.sh
EOF

chmod +x "${UNINSTALL_BIN}"

# 8. Запуск службы и ожидание
echo "[6/6] Запуск службы и ожидание инициализации воркеров..."
"${INIT_SCRIPT}" restart

COUNT=0
READY=0
printf "Ожидание готовности интерфейса %s (до 25 сек)" "$TUN"

while [ $COUNT -lt 25 ]; do
    if ip addr show "$TUN" 2>/dev/null | grep -q "inet "; then
        READY=1
        break
    fi
    printf "."
    sleep 1
    COUNT=$((COUNT + 1))
done
echo ""

if [ $READY -eq 1 ]; then
    TUN_IP=$(ip addr show "$TUN" | sed -n 's/.*inet \([0-9.]*\).*/\1/p')
    echo "=== УСПЕХ: Служба запущена в фоне, интерфейс ${TUN} готов (IP: ${TUN_IP}) ==="
    echo "=== Удаление клиента: csqtt-uninstall ==="
    sleep 5
    echo "=== Лог работы клиента (последние 300 строк, Ctrl+C для выхода) ==="
    echo ""
    tail -n 300 -f "${LOG_FILE}"
else
    echo "=== ОШИБКА: Интерфейс ${TUN} не поднялся! ===" >&2
    echo "--- Хвост лога (150 строк) ---"
    tail -n 150 "${LOG_FILE}" 2>/dev/null || true
    exit 1
fi
