#!/bin/sh

set -e

# ==========================================
# Переменные конфигурации
# ==========================================
GITHUB_REPO="redline-keen/csqtt-xkeen"
REPO_RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/1.0"
CONFIG_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/csqtt-config.yaml"

INSTALL_DIR="/opt/etc/csqtt"
BIN_NAME="csqtt-client"
TARGET_PATH="${INSTALL_DIR}/${BIN_NAME}"
CONF_FILE="${INSTALL_DIR}/csqtt.conf"
LOG_FILE="${INSTALL_DIR}/csqtt-client.log"
WATCHDOG_SCRIPT="${INSTALL_DIR}/watchdog.sh"
UNINSTALL_SCRIPT="${INSTALL_DIR}/uninstall.sh"
INIT_SCRIPT="/opt/etc/init.d/S99csqtt"
UNINSTALL_BIN="/opt/bin/csqtt-uninstall"

MIHOMO_DIR="/opt/etc/mihomo"
MIHOMO_CONF_FILE="${MIHOMO_DIR}/config.yaml"

TMP_DIR="/tmp/csqtt_install_$$"

# ==========================================
# Вспомогательные функции
# ==========================================
cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log_info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[33m[WARN]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
}

download_file() {
    _url="$1"
    _out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -kfsSL -o "$_out" "$_url"
    elif [ -x /opt/bin/wget ]; then
        /opt/bin/wget --no-check-certificate -q -O "$_out" "$_url"
    else
        wget --no-check-certificate -q -O "$_out" "$_url"
    fi
}

# ==========================================
# Проверки окружения
# ==========================================
echo "=== Установка и настройка csqtt-client ==="

if [ ! -d "/opt" ]; then
    log_error "Каталог /opt не найден. Убедитесь, что Entware установлен."
    exit 1
fi

mkdir -p "$TMP_DIR" "$INSTALL_DIR" /opt/bin /opt/etc/init.d

if ! command -v curl >/dev/null 2>&1 && ! opkg list-installed 2>/dev/null | grep -q "^wget-ssl "; then
    log_info "Установка сетевых зависимостей (curl, wget-ssl, ca-bundle)..."
    opkg update >/dev/null 2>&1 || true
    opkg install curl wget-ssl ca-bundle >/dev/null 2>&1 || true
    opkg remove wget-nossl 2>/dev/null 2>&1 || true
fi

# Определение архитектуры
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
        log_error "Неподдерживаемая архитектура процессора: ${ARCH_RAW}"
        exit 1
        ;;
esac

BIN_URL="${REPO_RELEASE_URL}/${BIN_NAME}-${ARCH}"
log_info "Архитектура: ${ARCH} (${ARCH_RAW})"

# ==========================================
# Парсинг URI конфигурации
# ==========================================
URI="$1"

while true; do
    if [ -z "$URI" ]; then
        printf "Вставьте ссылку конфигурации csqtt:// : " > /dev/tty
        read -r URI < /dev/tty
    fi

    HOST=$(echo "$URI" | sed -n 's/.*[?&]host=\([^&]*\).*/\1/p')
    PORT=$(echo "$URI" | sed -n 's/.*[?&]peer=\([^&]*\).*/\1/p')
    PASSWORD=$(echo "$URI" | sed -n 's/.*[?&]password=\([^&]*\).*/\1/p')
    HASHES_RAW=$(echo "$URI" | sed -n 's/.*[?&]hashes=\([^&]*\).*/\1/p')

    if [ -n "$HOST" ] && [ -n "$PORT" ] && [ -n "$PASSWORD" ] && [ -n "$HASHES_RAW" ]; then
        DECODED_HASHES=$(echo "$HASHES_RAW" | sed -e 's/%3A/:/g' -e 's/%2F/\//g' -e 's/%3a/:/g' -e 's/%2f/\//g')
        VK=$(echo "$DECODED_HASHES" | tr '+' '\n' | sed -n 's/.*\/join\///p; t; p' | awk 'NF {if (NR!=1) {printf ","}; printf "%s", $0} END {print ""}')

        if [ -n "$VK" ]; then
            HASH_COUNT=$(echo "$VK" | tr ',' '\n' | wc -l | tr -d ' ')
            log_info "Ссылка принята. Извлечено хешей: ${HASH_COUNT}"
            break
        fi
    fi

    log_warn "Некорректная ссылка! Отсутствуют обязательные параметры."
    URI=""
done

PEER="${HOST}:${PORT}"
TUN="csqtt0"

# ==========================================
# Запрос настроек потоков и конфига
# ==========================================
while true; do
    printf "Введите количество потоков [-n] (по умолчанию 108, диапазон 9-162): " > /dev/tty
    read -r THREADS_INPUT < /dev/tty

    if [ -z "$THREADS_INPUT" ]; then
        N="108"
        break
    fi

    case "$THREADS_INPUT" in
        ''|*[!0-9]*)
            log_warn "Введите целое число от 9 до 162."
            ;;
        *)
            if [ "$THREADS_INPUT" -ge 9 ] && [ "$THREADS_INPUT" -le 162 ]; then
                N="$THREADS_INPUT"
                break
            else
                log_warn "Значение должно быть в диапазоне от 9 до 162."
            fi
            ;;
    esac
done

echo "" > /dev/tty
echo "Выберите действие для csqtt-config.yaml:" > /dev/tty
echo "1) Скачать и поместить config.yaml в ${MIHOMO_DIR}" > /dev/tty
echo "2) Пропустить (настроить самостоятельно позже)" > /dev/tty

while true; do
    printf "Выберите пункт [1-2]: " > /dev/tty
    read -r CONFIG_CHOICE < /dev/tty

    case "$CONFIG_CHOICE" in
        1)
            if [ ! -d "$MIHOMO_DIR" ]; then
                log_info "Создание директории ${MIHOMO_DIR}..."
                mkdir -p "$MIHOMO_DIR"
            fi

            log_info "Загрузка config.yaml в ${MIHOMO_CONF_FILE}..."
            download_file "${CONFIG_URL}" "${MIHOMO_CONF_FILE}"
            log_info "Файл конфигурации успешно сохранен/перезаписан: ${MIHOMO_CONF_FILE}"
            break
            ;;
        2)
            log_info "Пропуск загрузки config.yaml."
            break
            ;;
        *)
            log_warn "Ошибка: выберите 1 или 2."
            ;;
    esac
done

# ==========================================
# Установка компонента
# ==========================================
log_info "[1/6] Сохранение конфигурации в ${CONF_FILE}..."
printf "PEER='%s'\nPASSWORD='%s'\nVK='%s'\nTUN='%s'\nN='%s'\n" \
    "$PEER" "$PASSWORD" "$VK" "$TUN" "$N" > "${CONF_FILE}"
chmod 600 "${CONF_FILE}"

log_info "[2/6] Загрузка бинарного файла (${ARCH})..."
download_file "${BIN_URL}" "${TARGET_PATH}"
chmod +x "${TARGET_PATH}"

log_info "[3/6] Создание init-скрипта ${INIT_SCRIPT}..."
cat > "${INIT_SCRIPT}" << 'EOF'
#!/bin/sh

DESC="csqtt-client daemon"
NAME="csqtt-client"
DIR="/opt/etc/csqtt"
PROG="${DIR}/csqtt-client"
CONF="${DIR}/csqtt.conf"
LOGFILE="${DIR}/csqtt-client.log"
PIDFILE="/opt/var/run/csqtt-client.pid"
MAX_LOG_SIZE=1048576

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

log_info "[4/6] Настройка watchdog и Cron..."
cat > "${WATCHDOG_SCRIPT}" << 'EOF'
#!/bin/sh

PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/bin:/usr/bin:/sbin:/usr/sbin
export PATH

CONF_DIR="/opt/etc/csqtt"
LOG_FILE="${CONF_DIR}/csqtt-client.log"
WD_LOG="${CONF_DIR}/watchdog.log"
MAX_SIZE_KB=1024
TUN_IFACE="csqtt0"
INIT_SCRIPT="/opt/etc/init.d/S99csqtt"
PING_TARGET="77.88.8.8"

for log in "$LOG_FILE" "$WD_LOG"; do
    if [ -f "$log" ]; then
        FILE_SIZE=$(du -k "$log" 2>/dev/null | awk '{print $1}')
        if [ -n "$FILE_SIZE" ] && [ "$FILE_SIZE" -gt "$MAX_SIZE_KB" ]; then
            tail -n 500 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] Лог $log обрезан." >> "$WD_LOG"
        fi
    fi
done

IS_RUNNING=0
if pgrep csqtt-client >/dev/null 2>&1 || pidof csqtt-client >/dev/null 2>&1; then
    IS_RUNNING=1
fi

IS_UP=0
if ip link show "$TUN_IFACE" 2>/dev/null | grep -q "UP"; then
    IS_UP=1
fi

if [ $IS_RUNNING -eq 0 ] || [ $IS_UP -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] Сбой службы ($TUN_IFACE). Перезапуск..." >> "$WD_LOG"
    rm -f /opt/var/run/csqtt-client.pid
    "$INIT_SCRIPT" restart >> "$WD_LOG" 2>&1
    exit 0
fi

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
    sed -i '/^[[:space:]]*$/d' /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    echo "$CRON_JOB" >> /opt/var/spool/cron/crontabs/root
fi

if [ -x "/opt/etc/init.d/S10cron" ]; then
    /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true
fi

log_info "[5/6] Создание утилиты удаления..."
cat > "${UNINSTALL_SCRIPT}" << 'EOF'
#!/bin/sh

echo "=== Удаление csqtt-client ==="

if [ -f "/opt/var/spool/cron/crontabs/root" ]; then
    sed -i '/\/opt\/etc\/csqtt\/watchdog\.sh/d' /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    if [ -x "/opt/etc/init.d/S10cron" ]; then
        /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true
    fi
fi

if [ -x "/opt/etc/init.d/S99csqtt" ]; then
    /opt/etc/init.d/S99csqtt stop 2>/dev/null || true
fi

killall -9 csqtt-client 2>/dev/null || true

rm -f /opt/etc/init.d/S99csqtt
rm -f /opt/var/run/csqtt-client.pid
rm -f /opt/bin/csqtt-uninstall
rm -rf /opt/etc/csqtt

echo "Удаление завершено."
EOF
chmod +x "${UNINSTALL_SCRIPT}"

cat > "${UNINSTALL_BIN}" << 'EOF'
#!/bin/sh
exec /opt/etc/csqtt/uninstall.sh
EOF
chmod +x "${UNINSTALL_BIN}"

# ==========================================
# Запуск и проверка
# ==========================================
log_info "[6/6] Запуск службы и проверка интерфейса..."
"${INIT_SCRIPT}" restart

COUNT=0
READY=0
printf "Ожидание интерфейса %s (до 25 сек)" "$TUN"

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
    log_info "Служба успешно запущена! Интерфейс ${TUN} готов (IP: ${TUN_IP})"
    echo -e "\nДля удаления используйте команду: \033[36mcsqtt-uninstall\033[0m"
    sleep 3
    echo -e "\n=== Мониторинг логов (Ctrl+C для выхода) ===\n"
    tail -n 300 -f "${LOG_FILE}"
else
    log_error "Интерфейс ${TUN} не поднялся!"
    echo "--- Лог работы: ---"
    tail -n 150 "${LOG_FILE}" 2>/dev/null || true
    exit 1
fi
