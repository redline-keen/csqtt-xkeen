#!/bin/sh

set -u

CSQTT_REPO="redline-keen/csqtt-xkeen"
CSQTT_TAG="2.0"
CSQTT_LOCAL_BIN=""
CSQTT_VK_TOKEN=""
CSQTT_HASHES=""
CSQTT_WORKERS="54"
CSQTT_START=1
CSQTT_ROTATE=1
CSQTT_WATCHDOG=1
CSQTT_LINK=""
DOWNLOAD_CONFIG_AUTO=0

WORKERS_PER_HASH=27
WORKERS_STEP=9
MAX_HASHES=6

CONFIG_URL="https://raw.githubusercontent.com/${CSQTT_REPO}/main/csqtt-config.yaml"
MIHOMO_DIR="/opt/etc/mihomo"
MIHOMO_CONF_FILE="${MIHOMO_DIR}/config.yaml"

# ── разбор аргументов ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)            CSQTT_REPO="$2"; shift 2 ;;
        --tag)             CSQTT_TAG="$2"; shift 2 ;;
        --local-bin)       CSQTT_LOCAL_BIN="$2"; shift 2 ;;
        --vk-token)        CSQTT_VK_TOKEN="$2"; shift 2 ;;
        --hashes)          CSQTT_HASHES="$2"; shift 2 ;;
        --workers)         CSQTT_WORKERS="$2"; shift 2 ;;
        --download-config) DOWNLOAD_CONFIG_AUTO=1; shift ;;
        --no-start)        CSQTT_START=0; shift ;;
        --no-rotate)       CSQTT_ROTATE=0; shift ;;
        --no-watchdog)     CSQTT_WATCHDOG=0; shift ;;
        -h|--help)         sed -n '2,45p' "$0"; exit 0 ;;
        csqtt://*)         CSQTT_LINK="$1"; shift ;;
        *)                 echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

log()  { printf '\033[1;32m[CSQTT]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[CSQTT]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[CSQTT ОШИБКА]\033[0m %s\n' "$*"; exit 1; }

download_file() {
    _url="$1"
    _out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -kfsSL -o "$_out" "$_url"
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -q -O "$_out" "$_url"
    else
        die "Нужен curl или wget для скачивания файлов"
    fi
}

# ── 1. каталог установки (Entware → /opt, OpenWrt → /etc) ───────────────────
if [ -d /opt/entware ] || [ -d /opt/etc/init.d ]; then
    CSQTT_DIR="/opt/etc/csqtt"
    INIT_DIR="/opt/etc/init.d"
    LOG_DIR="/opt/etc/csqtt"
    INIT_STYLE="entware"
else
    CSQTT_DIR="/etc/csqtt"
    INIT_DIR="/etc/init.d"
    LOG_DIR="/var/log"
    INIT_STYLE="openwrt"
fi
mkdir -p "$CSQTT_DIR" "$INIT_DIR" "$LOG_DIR" 2>/dev/null || die "нет прав на запись (запускайте под root)"
LOG_FILE="$LOG_DIR/csqtt.log"
PID_FILE="/var/run/csqtt.pid"
if [ "$INIT_STYLE" = "openwrt" ]; then
    INIT_SCRIPT="$INIT_DIR/csqtt"
    INIT_SCRIPT_NAME="service csqtt"
else
    INIT_SCRIPT="$INIT_DIR/S99csqtt"
    INIT_SCRIPT_NAME="$INIT_DIR/S99csqtt"
fi

# ── 2. архитектура ───────────────────────────────────────────────────────────
ARCH_KEY=""
case "$(uname -m)" in
    aarch64|arm64)
        ARCH_KEY="aarch64" ;;
    mips)
        ARCH_KEY="mipsel" ;;
    *)
        die "Архитектура $(uname -m) не поддерживается (собраны aarch64 и mipsel)" ;;
esac
log "Архитектура: $ARCH_KEY ($(uname -m)) · стиль инициализации: $INIT_STYLE"

# ── 3. получение бинарника ──────────────────────────────────────────────────
BIN_PATH="$CSQTT_DIR/csqtt-client"
TMP_BIN_PATH="$CSQTT_DIR/csqtt-client.tmp"

if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop >/dev/null 2>&1
fi
killall -9 csqtt-client >/dev/null 2>&1

fetch() { download_file "$1" "$2"; }

hexdump_bin() {
    if command -v hexdump >/dev/null 2>&1; then
        hexdump -n 1 -e '1/1 "%02x"' 2>/dev/null
    elif command -v xxd >/dev/null 2>&1; then
        xxd -l 1 -p 2>/dev/null
    else
        b=$(dd bs=1 count=1 2>/dev/null | tr -d '\n')
        case "$b" in
            $'\x7f') printf '7f' ;;
            $'\x45') printf '45' ;;
            $'\x4c') printf '4c' ;;
            $'\x46') printf '46' ;;
            $'\x02') printf '02' ;;
            $'\x01') printf '01' ;;
            *) printf '??' ;;
        esac
    fi
}

verify_bin() {
    [ -s "$1" ] || die "Файл $1 пуст/отсутствует"
    magic=""
    i=0
    while [ $i -lt 6 ]; do
        b=$(dd if="$1" bs=1 skip=$i count=1 2>/dev/null | hexdump_bin)
        magic="$magic$b"
        i=$((i + 1))
    done
    [ -n "$magic" ] || die "не удалось прочитать заголовок $1 (dd недоступен?)"
    case "$ARCH_KEY" in
        aarch64) want="7f454c460201" ;;
        mipsel)  want="7f454c460101" ;;
    esac
    [ "$magic" = "$want" ] \
        || die "$1 не является корректным ELF для $ARCH_KEY (получено: ${magic:-пусто}; ожидалось $want)"
    chmod +x "$1"
}

if [ -n "$CSQTT_LOCAL_BIN" ]; then
    [ -f "$CSQTT_LOCAL_BIN" ] || die "локальный файл не найден: $CSQTT_LOCAL_BIN"
    cp "$CSQTT_LOCAL_BIN" "$TMP_BIN_PATH" || die "не удалось скопировать бинарник"
    log "Бинарник скопирован из $CSQTT_LOCAL_BIN"
else
    [ -n "$CSQTT_REPO" ] || die "не задан --repo"
    if [ -z "$CSQTT_TAG" ]; then
        page=$(curl -fsSL -w '%{url_effective}' -o /dev/null \
               "https://github.com/$CSQTT_REPO/releases/latest" 2>/dev/null) \
            || die "не удалось узнать последний релиз $CSQTT_REPO (нет curl или нет сети?)"
        CSQTT_TAG=$(printf '%s' "$page" | sed 's|.*/tag/||')
        [ -n "$CSQTT_TAG" ] || die "в $CSQTT_REPO не найдено ни одного релиза"
    fi
    log "Релиз: $CSQTT_REPO $CSQTT_TAG"
    assets_html=$(curl -fsSL "https://github.com/$CSQTT_REPO/releases/expanded_assets/$CSQTT_TAG" 2>/dev/null) \
        || die "не удалось получить список файлов релиза"
    asset_url=$(printf '%s' "$assets_html" \
        | grep -o 'href="[^"]*releases/download/[^"]*"' \
        | sed 's/^href="//; s/"$//' \
        | grep "csqtt-client-$ARCH_KEY" \
        | tail -n 1)
    case "$asset_url" in
        /*) asset_url="https://github.com$asset_url" ;;
    esac
    if [ -z "$asset_url" ]; then
        warn "В релизе $CSQTT_TAG репозитория $CSQTT_REPO нет файла csqtt-client-$ARCH_KEY-*"
        warn "Загрузите роутерные бинарники в свой GitHub-релиз и повторите с --repo ВАШ_ЛОГИН/ВАШ_РЕПО,"
        warn "либо передайте скачанный вручную файл: --local-bin /tmp/csqtt-client"
        exit 2
    fi
    log "Скачиваю: $asset_url"
    fetch "$asset_url" "$TMP_BIN_PATH" || die "скачивание не удалось"
fi

verify_bin "$TMP_BIN_PATH"
mv -f "$TMP_BIN_PATH" "$BIN_PATH"

# smoke-тест
smoke=$("$BIN_PATH" 2>&1 | head -n 1)
case "$smoke" in
    *peer*)  log "Бинарник установлен и отвечает: $smoke" ;;
    *"Exec format error"*|*"not found"*|*"Syntax error"*|*"syntax error"*)
        warn "ELF-заголовок корректен, но запустить здесь не удалось: $smoke"
        warn "Если это целевой роутер — проверьте архитектуру вручную: file $BIN_PATH"
        ;;
    *)
        [ -n "$smoke" ] || smoke="(пустой вывод)"
        warn "Неожиданный ответ бинарника: $smoke (продолжаем)" ;;
esac

# ── 4. ссылка подключения ────────────────────────────────────────────────────
urldecode() {
    s="$1"; out=""; i=0; n=${#s}
    while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        if [ "$c" = "%" ] && [ $((i + 2)) -lt "$n" ]; then
            out="$out$(printf '\\x'${s:$((i+1)):2})"
            i=$((i + 3))
        else
            out="$out$c"; i=$((i + 1))
        fi
    done
    printf '%s' "$out"
}

if [ -z "$CSQTT_LINK" ]; then
    printf 'Вставьте ссылку подключения (csqtt://connect?...): '
    read -r CSQTT_LINK
fi
[ -n "$CSQTT_LINK" ] || die "ссылка подключения не указана"

query=$(printf '%s' "$CSQTT_LINK" | sed 's|^csqtt://[^?]*?||')
PEER_HOST=""; PEER_PORT=""; PASSWORD=""
oldIFS="$IFS"; IFS='&'
for kv in $query; do
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in
        host)     PEER_HOST=$(urldecode "$v") ;;
        peer)     PEER_PORT=$(urldecode "$v") ;;
        password) PASSWORD=$(urldecode "$v") ;;
    esac
done
IFS="$oldIFS"
[ -n "$PEER_HOST" ] && [ -n "$PEER_PORT" ] && [ -n "$PASSWORD" ] \
    || die "в ссылке не найдены host / peer / password"
PEER="$PEER_HOST:$PEER_PORT"
log "Пир: $PEER"

# ── 5. VK-токен ──────────────────────────────────────────────────────────────
VK_TOKEN_FILE="$CSQTT_DIR/vk_token"
if [ -z "$CSQTT_VK_TOKEN" ] && [ -t 0 ] && [ -f "$VK_TOKEN_FILE" ]; then
    CSQTT_VK_TOKEN=$(cat "$VK_TOKEN_FILE")
    warn "Использован сохранённый VK-токен из $VK_TOKEN_FILE"
fi
if [ -z "$CSQTT_VK_TOKEN" ]; then
    printf 'Вставьте ВЕЧНЫЙ VK access token (oauth.vk.ru → access_token=...): '
    read -r CSQTT_VK_TOKEN
fi
[ -n "$CSQTT_VK_TOKEN" ] || die "нужен VK access token"
case "$CSQTT_VK_TOKEN" in
    *'"*|*'\'*) die "токен содержит недопустимые символы" ;;
esac
umask 077
printf '%s' "$CSQTT_VK_TOKEN" > "$VK_TOKEN_FILE"
log "VK-токен сохранён в $VK_TOKEN_FILE (права 600; менять — там же)"

# ── 6. параметры пула: хеши и воркеры ───────────────────────────────────────
if [ -z "$CSQTT_HASHES" ]; then
    printf 'Хешей в пуле [1..6] (Enter = 4): '
    read -r CSQTT_HASHES
fi
case "$CSQTT_HASHES" in
    "") CSQTT_HASHES=4 ;;
    *[!0-9]*) die "число хешей должно быть целым 1..6: '$CSQTT_HASHES'" ;;
    *) [ "$CSQTT_HASHES" -ge 1 ] && [ "$CSQTT_HASHES" -le $MAX_HASHES ] \
        || die "число хешей должно быть 1..$MAX_HASHES: $CSQTT_HASHES" ;;
esac

hash_cap=$((CSQTT_HASHES * WORKERS_PER_HASH))
if [ -z "$CSQTT_WORKERS" ]; then
    printf 'Воркеров [9..162, максимум %d для %d хешей] (Enter = максимум): ' "$hash_cap" "$CSQTT_HASHES"
    read -r CSQTT_WORKERS
fi
case "$CSQTT_WORKERS" in
    "") CSQTT_WORKERS=$hash_cap ;;
    *[!0-9]*) die "число воркеров должно быть целым: '$CSQTT_WORKERS'" ;;
esac
[ "$CSQTT_WORKERS" -ge 9 ] || die "минимум 9 воркеров"

if [ "$CSQTT_WORKERS" -gt "$hash_cap" ]; then
    warn "Воркеров $CSQTT_WORKERS → $hash_cap: правило 27 на хеш ($CSQTT_HASHES хешей)"
    CSQTT_WORKERS=$hash_cap
fi
CSQTT_WORKERS=$((CSQTT_WORKERS / WORKERS_STEP * WORKERS_STEP))
[ "$CSQTT_WORKERS" -ge 9 ] || CSQTT_WORKERS=$WORKERS_STEP
log "Хешей: $CSQTT_HASHES · воркеров: $CSQTT_WORKERS ($((CSQTT_WORKERS / WORKERS_PER_HASH)) на хеш, $((CSQTT_WORKERS / WORKERS_STEP)) групп)"

# ── 7. device-id (стабильный) ────────────────────────────────────────────────
DEVICE_ID=""
if [ -f "$CSQTT_DIR/device_id" ]; then
    DEVICE_ID=$(cat "$CSQTT_DIR/device_id" 2>/dev/null)
fi
if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(cat /sys/firmware/devicetree/base/serial-number 2>/dev/null | tr -d '\0')
    [ -n "$DEVICE_ID" ] || DEVICE_ID=$(cat /etc/serial 2>/dev/null)
    [ -n "$DEVICE_ID" ] || DEVICE_ID=$(hostname)-$(head -c 4 /dev/urandom 2>/dev/null | hexdump -ve '1/1 "%02x"' 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 8 || hostname)
    printf '%s' "$DEVICE_ID" > "$CSQTT_DIR/device_id"
fi
log "Device ID: $DEVICE_ID"

# ── 8. конфиг ───────────────────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt.conf" <<EOF
PEER="$PEER"
PASSWORD="$PASSWORD"
HASHES="$CSQTT_HASHES"
WORKERS="$CSQTT_WORKERS"
VK_MODE="auto_js"
DEVICE_ID="$DEVICE_ID"
LISTEN="127.0.0.1:9000"
FINGERPRINT="firefox"
CLIENT_IDS="8202606,6287487"
OBFS="video"
TURN_TRANSPORT="udp"
CAPTCHA_MODE="auto"
TUN_IFACE="csqtt0"
TUN_MTU="1300"
EOF
chmod 600 "$CSQTT_DIR/csqtt.conf"
log "Конфиг: $CSQTT_DIR/csqtt.conf (HASHES=$CSQTT_HASHES · WORKERS=$CSQTT_WORKERS)"

# ── 8a. Загрузка config.yaml для Mihomo ─────────────────────────────────────
do_download_config() {
    mkdir -p "$MIHOMO_DIR" 2>/dev/null

    if [ -f "${MIHOMO_CONF_FILE}" ]; then
        cp -f "${MIHOMO_CONF_FILE}" "${MIHOMO_CONF_FILE}.bak"
        log "Обнаружен существующий файл. Бэкап сохранён в: ${MIHOMO_CONF_FILE}.bak"
    fi

    log "Загрузка config.yaml в ${MIHOMO_CONF_FILE}..."
    download_file "${CONFIG_URL}" "${MIHOMO_CONF_FILE}"
    log "Файл конфигурации сохранён: ${MIHOMO_CONF_FILE}"
}

if [ "$DOWNLOAD_CONFIG_AUTO" -eq 1 ]; then
    do_download_config
elif [ -t 0 ]; then
    printf '\nВыберите действие для csqtt-config.yaml (Mihomo):\n'
    printf ' 1) Скачать и поместить config.yaml в %s\n' "$MIHOMO_DIR"
    printf ' 2) Пропустить и долго мучаться с конфигом самому\n'
    while true; do
        printf 'Выберите пункт [1-2] (Enter = 1): '
        read -r CONFIG_CHOICE
        case "$CONFIG_CHOICE" in
            1)
                do_download_config
                break
                ;;
            2|"")
                log "Пропуск загрузки config.yaml."
                break
                ;;
            *)
                warn "Ошибка: выберите 1 или 2."
                ;;
        esac
    done
fi

# ── 9. обёртка запуска (fifo + exec, пул хешей) ─────────────────────────────
cat > "$CSQTT_DIR/csqtt-run.sh" <<'EOF'
#!/bin/sh
DIR=$(dirname "$0")
. "$DIR/csqtt.conf"
umask 077

set -- "$DIR/csqtt-client" \
    --peer "$PEER" \
    --password "$PASSWORD" \
    --device-id "$DEVICE_ID" \
    -n "$WORKERS" \
    --listen "$LISTEN" \
    --fingerprint "$FINGERPRINT" \
    --client-ids "$CLIENT_IDS" \
    --obfs "$OBFS" \
    --turn-transport "$TURN_TRANSPORT" \
    --captcha-mode "$CAPTCHA_MODE" \
    --vk-pool "$DIR/vk_pool" \
    --vk-calls "$HASHES"

if [ -n "$TUN_IFACE" ]; then
    set -- "$@" --tun "$TUN_IFACE" --tun-mtu "$TUN_MTU"
fi

TOKEN=$(cat "$DIR/vk_token" 2>/dev/null) || { echo "нет vk_token"; exit 1; }
BOOTSTRAP=$(printf '{"token":"%s"}' "$TOKEN" | base64 | tr -d '\n')
set -- "$@" --vk-hash-mode auto_js --vk-auth-mode auto_js
FIFO="$DIR/bootstrap.fifo"
[ -p "$FIFO" ] || mkfifo "$FIFO" || { echo "не удалось создать fifo"; exit 1; }
printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" > "$FIFO" &
exec "$@" < "$FIFO"
EOF
chmod +x "$CSQTT_DIR/csqtt-run.sh"

# ── 10. скрипт ротации хешей ────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt-rotate-hashes.sh" <<'ROTATE'
#!/bin/sh
DIR=$(dirname "$0")
CONF="$DIR/csqtt.conf"
POOL="$DIR/vk_pool"
STATE="$DIR/rotate.state"
[ -f "$CONF" ] || exit 0
. "$CONF"
umask 077

FORCE=0
[ "${1:-}" = "force" ] && FORCE=1

LOG="$DIR/rotate.log"
log() { printf '[%s] [CSQTT-ROTATE] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

window_start=$((9 * 60 + 30))   # 09:30
window_end=$((15 * 60 + 10))    # 15:10

LOCK="$DIR/rotate.lock"
STAMP="$DIR/rotate.lock.stamp"
if ! mkdir "$LOCK" 2>/dev/null; then
    lock_age=$(( $(date +%s) - $(cat "$STAMP" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -gt 1800 ]; then
        rm -rf "$LOCK" "$STAMP"
        mkdir "$LOCK" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
date +%s > "$STAMP"
trap 'rm -f "$STAMP" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

state_get() { grep "^$1=" "$STATE" 2>/dev/null | tail -n 1 | cut -d= -f2; }
state_write() {
    printf 'day=%s\nminute=%s\nperm=%s\ndone=%s\n' "$1" "$2" "$3" "$4" > "$STATE.tmp" \
        && mv "$STATE.tmp" "$STATE"
}

gen_perm() {
    awk -v N="$1" 'BEGIN {
        srand()
        for (i = 0; i < N; i++) p[i] = i
        for (j = N - 1; j > 0; j--) {
            k = int(rand() * (j + 1))
            t = p[j]; p[j] = p[k]; p[k] = t
        }
        out = p[0]
        for (i = 1; i < N; i++) out = out "," p[i]
        print out
    }'
}

today=$(date +%Y-%m-%d)
now_min=$(( $(date +%H) * 60 + $(date +%M) ))

day=$(state_get day);   case "$day"   in "") day="";; esac
minute=$(state_get minute)
perm=$(state_get perm)
done_flag=$(state_get done)
if [ "$day" != "$today" ] || [ -z "$minute" ]; then
    minute=$(awk -v lo=$window_start -v hi=$((window_end - 4)) \
        'BEGIN { srand(); print lo + int(rand() * (hi - lo + 1)) }')
    [ -n "$perm" ] || perm=$(gen_perm "${HASHES:-4}")
    state_write "$today" "$minute" "$perm" "0"
    log "план на $today: ротация в $(printf '%02d:%02d' $((minute / 60)) $((minute % 60))), порядок $perm"
    done_flag=0
fi

if [ "$FORCE" = "0" ]; then
    [ "$done_flag" = "1" ] && exit 0
    [ "$now_min" -lt "$minute" ] && exit 0
    [ "$now_min" -gt $window_end ] && exit 0
fi

pool_lines=0
[ -f "$POOL" ] && pool_lines=$(wc -l < "$POOL")
if [ "$pool_lines" -eq 0 ]; then
    log "пул пуст — ротация нечего менять"
    exit 0
fi
[ -n "$perm" ] || perm=$(gen_perm "$pool_lines")
target=$(printf '%s' "$perm" | cut -d, -f1)
rest=$(printf '%s' "$perm" | cut -d, -f2-)
[ "$rest" = "$perm" ] && rest=""
[ "$target" -ge "$pool_lines" ] && target=$((target % pool_lines))

TOKEN=$(cat "$DIR/vk_token" 2>/dev/null) || { log "нет vk_token"; exit 1; }
BOOTSTRAP=$(printf '{"token":"%s"}' "$TOKEN" | base64 | tr -d '\n')
new_hash=""; new_id=""
out=$(printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" \
    | "$DIR/csqtt-client" --vk-regen-call \
        --fingerprint "$FINGERPRINT" --device-id "$DEVICE_ID" 2>>"$LOG")
for line in $out; do
    case "$line" in
        CALL_HASH:*) new_hash=${line#CALL_HASH:} ;;
        CALL_ID:*)   new_id=${line#CALL_ID:} ;;
    esac
done
if [ -z "$new_hash" ] || [ -z "$new_id" ]; then
    log "regen не дал хеш: $out"
    exit 1
fi
log "новый звонок: хеш $new_hash id $new_id → строка пула №$((target + 1))"

old_id=""
if [ "$pool_lines" -gt "$target" ]; then
    old_id=$(sed -n "$((target + 1))p" "$POOL" | cut -d: -f2)
fi
awk -v line=$((target + 1)) -v new="$new_hash:$new_id" '
    NR == line { print new; replaced = 1; next }
    { print }
    END { if (!replaced) print new }
' "$POOL" > "$POOL.tmp" && mv "$POOL.tmp" "$POOL"

if [ -x "__INIT_CMD__" ]; then
    touch "$DIR/restarting"
    "__INIT_CMD__" restart >>"$LOG" 2>&1
    rm -f "$DIR/restarting"
    log "клиент перезапущен на обновлённом пуле"
else
    log "init-скрипт __INIT_CMD__ не найден"
fi

if [ -n "$old_id" ]; then
    out=$(printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" \
        | "$DIR/csqtt-client" --vk-drop-call "$old_id" \
            --fingerprint "$FINGERPRINT" --device-id "$DEVICE_ID" 2>>"$LOG")
    case "$out" in
        *CALL_DROPPED*) log "старый звонок $old_id завершён" ;;
        *) log "drop $old_id не удался (не критично): $out" ;;
    esac
fi

state_write "$today" "$minute" "$rest" "1"
log "ротация завершена (строка №$((target + 1)) обновлена)"
ROTATE
chmod +x "$CSQTT_DIR/csqtt-rotate-hashes.sh"

sed -i "s|__INIT_CMD__|$INIT_SCRIPT|g" "$CSQTT_DIR/csqtt-rotate-hashes.sh" 2>/dev/null \
    || die "не удалось подставить init-путь в скрипт ротации"

# ── 11. cron (ротация + watchdog) ───────────────────────────────────────────
CRON_FILE=""
if [ "$INIT_STYLE" = "entware" ]; then
    CRON_FILE="/opt/var/spool/cron/crontabs/root"
else
    CRON_FILE="/etc/crontabs/root"
fi
mkdir -p "$(dirname "$CRON_FILE")"
touch "$CRON_FILE"

if [ "$CSQTT_ROTATE" = "1" ]; then
    CRON_LINE="*/5 * * * * $CSQTT_DIR/csqtt-rotate-hashes.sh"
    grep -q "csqtt-rotate-hashes" "$CRON_FILE" 2>/dev/null \
        || echo "$CRON_LINE" >> "$CRON_FILE"
    log "Cron: $CRON_LINE"
fi

# ── 11а. watchdog ───────────────────────────────────────────────────────────
if [ "$CSQTT_WATCHDOG" = "1" ]; then
cat > "$CSQTT_DIR/csqtt-watchdog.sh" <<'WATCHDOG'
#!/bin/sh
DIR=$(dirname "$0")
CONF="$DIR/csqtt.conf"
[ -f "$CONF" ] || exit 0
. "$CONF"
umask 077

LOG="$DIR/watchdog.log"
MAX_SIZE_KB=1024
TUN_IFACE="${TUN_IFACE:-}"
INIT_CMD="__INIT_CMD__"
PING_TARGET="77.88.8.8"

stamp() { date '+%Y-%m-%d %H:%M:%S'; }

for log in "$LOG" __LOG_FILE__; do
    [ -f "$log" ] || continue
    FILE_SIZE=$(du -k "$log" 2>/dev/null | awk '{print $1}')
    if [ -n "$FILE_SIZE" ] && [ "$FILE_SIZE" -gt "$MAX_SIZE_KB" ]; then
        tail -n 500 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"
        echo "$(stamp) [WATCHDOG] Лог $log обрезан." >> "$LOG"
    fi
done

[ -f "$DIR/stopped" ] && exit 0
[ -f "$DIR/restarting" ] && exit 0

IS_RUNNING=0
if pgrep csqtt-client >/dev/null 2>&1 || pidof csqtt-client >/dev/null 2>&1; then
    IS_RUNNING=1
fi

IS_UP=1
if [ -n "$TUN_IFACE" ]; then
    IS_UP=0
    if ip link show "$TUN_IFACE" 2>/dev/null | grep -q "UP"; then
        IS_UP=1
    fi
fi

if [ "$IS_RUNNING" -eq 0 ] || [ "$IS_UP" -eq 0 ]; then
    echo "$(stamp) [WATCHDOG] Сбой службы (процесс=$IS_RUNNING, $TUN_IFACE=$IS_UP). Перезапуск..." >> "$LOG"
    rm -f "$DIR/stopped"
    "$INIT_CMD" restart >> "$LOG" 2>&1
    exit 0
fi

if [ -n "$TUN_IFACE" ] && command -v ping >/dev/null 2>&1; then
    if ! ping -c 2 -W 3 -I "$TUN_IFACE" "$PING_TARGET" >/dev/null 2>&1; then
        echo "$(stamp) [WATCHDOG] Пинг через $TUN_IFACE не прошел. Перезапуск..." >> "$LOG"
        rm -f "$DIR/stopped"
        "$INIT_CMD" restart >> "$LOG" 2>&1
    fi
fi
WATCHDOG
chmod +x "$CSQTT_DIR/csqtt-watchdog.sh"

sed -i -e "s|__INIT_CMD__|$INIT_SCRIPT|g" -e "s|__LOG_FILE__|$LOG_FILE|g" \
    "$CSQTT_DIR/csqtt-watchdog.sh" 2>/dev/null \
    || die "не удалось подставить пути в watchdog"

CRON_LINE="*/2 * * * * $CSQTT_DIR/csqtt-watchdog.sh"
grep -q "csqtt-watchdog" "$CRON_FILE" 2>/dev/null \
    || echo "$CRON_LINE" >> "$CRON_FILE"
log "Cron: $CRON_LINE"
fi

if [ "$INIT_STYLE" = "entware" ]; then
    for c in /opt/etc/init.d/S10cron /opt/etc/init.d/crond; do
        [ -x "$c" ] && "$c" restart >/dev/null 2>&1 && break
    done
else
    [ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1
fi

# ── 12. init-скрипт ─────────────────────────────────────────────────────────
if [ "$INIT_STYLE" = "openwrt" ]; then
cat > "$INIT_DIR/csqtt" <<EOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

start_service() {
    rm -f "$CSQTT_DIR/stopped" "$CSQTT_DIR/restarting"
    procd_open_instance
    procd_set_param command /bin/sh "$CSQTT_DIR/csqtt-run.sh"
    procd_set_param respawn "\${threshold:-60}" "\${timeout:-5}" "\${retry:-0}"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file "$CSQTT_DIR/csqtt.conf"
    procd_close_instance
}

stop_service() {
    touch "$CSQTT_DIR/stopped"
}
EOF
else
cat > "$INIT_DIR/S99csqtt" <<EOF
#!/bin/sh
DIR="$CSQTT_DIR"
case "\$1" in
    start)
        printf 'Starting CSQTT: '
        rm -f "\$DIR/stopped"
        if [ -f "$PID_FILE" ] && kill -0 "\$(cat "$PID_FILE")" 2>/dev/null; then
            echo "уже запущен"; exit 0
        fi
        nohup "\$DIR/csqtt-run.sh" >>"$LOG_FILE" 2>&1 &
        echo \$! > "$PID_FILE"
        echo "OK (PID \$(cat "$PID_FILE"))"
        ;;
    stop)
        printf 'Stopping CSQTT: '
        touch "\$DIR/stopped"
        if [ -f "$PID_FILE" ]; then
            PID=\$(cat "$PID_FILE")
            kill -INT "\$PID" 2>/dev/null
            n=0
            while kill -0 "\$PID" 2>/dev/null && [ \$n -lt 10 ]; do
                sleep 1; n=\$((n+1))
            done
            kill -9 "\$PID" 2>/dev/null
            rm -f "$PID_FILE"
        fi
        echo "OK"
        ;;
    restart)
        touch "\$DIR/restarting"
        \$0 stop; sleep 1; \$0 start
        rm -f "\$DIR/restarting"
        ;;
    status)
        if [ -f "$PID_FILE" ] && kill -0 "\$(cat "$PID_FILE")" 2>/dev/null; then
            echo "CSQTT работает (PID \$(cat "$PID_FILE"))"
        else
            echo "CSQTT остановлен"
        fi
        ;;
    log)
        tail -n 100 "$LOG_FILE"
        ;;
    *)
        echo "Usage: \$0 start|stop|restart|status|log"
        ;;
esac
EOF
fi
chmod +x "$INIT_SCRIPT"
log "Init-скрипт: $INIT_SCRIPT"

# ── 12а. деинсталлятор ─────────────────────────────────────────────────────
if [ "$INIT_STYLE" = "openwrt" ]; then
    UNINST_BIN="/usr/bin/csqtt-uninstall"
else
    UNINST_BIN="/opt/bin/csqtt-uninstall"
fi
mkdir -p "$(dirname "$UNINST_BIN")"
cat > "$CSQTT_DIR/uninstall.sh" <<'UNINSTALL'
#!/bin/sh
DIR=$(dirname "$0")
echo "=== Удаление csqtt-client ==="

CRON_FILE="/opt/var/spool/cron/crontabs/root"
[ -f "$CRON_FILE" ] || CRON_FILE="/etc/crontabs/root"
if [ -f "$CRON_FILE" ]; then
    sed -i '/csqtt-rotate-hashes\.sh/d; /csqtt-watchdog\.sh/d' "$CRON_FILE" 2>/dev/null || true
    for c in /opt/etc/init.d/S10cron /opt/etc/init.d/crond /etc/init.d/cron; do
        [ -x "$c" ] && "$c" restart >/dev/null 2>&1 && break
    done
fi

for init in /opt/etc/init.d/S99csqtt /etc/init.d/csqtt; do
    if [ -x "$init" ]; then
        "$init" stop >/dev/null 2>&1 || true
        rm -f "$init"
    fi
done

killall -9 csqtt-client 2>/dev/null || true
rm -f /var/run/csqtt.pid /opt/var/run/csqtt-client.pid

rm -f /opt/bin/csqtt-uninstall /usr/bin/csqtt-uninstall
rm -rf "$DIR"

echo "Удаление завершено."
UNINSTALL
chmod +x "$CSQTT_DIR/uninstall.sh"

printf '#!/bin/sh\nexec "%s/uninstall.sh"\n' "$CSQTT_DIR" > "$UNINST_BIN"
chmod +x "$UNINST_BIN"
log "Деинсталлятор: $UNINST_BIN"

# ── 13. запуск ──────────────────────────────────────────────────────────────
if [ "$CSQTT_START" = "1" ]; then
    if [ "$INIT_STYLE" = "openwrt" ]; then
        "$INIT_SCRIPT" restart
        log "Журнал: logread | grep csqtt"
    else
        "$INIT_SCRIPT" restart
        sleep 4
        if grep -q "Пул" "$LOG_FILE" 2>/dev/null; then
            log "Пул хешей создан, воркеры поднимаются"
        else
            warn "Проверьте журнал: $INIT_SCRIPT log"
            tail -n 10 "$LOG_FILE" 2>/dev/null
        fi
    fi
fi

log "Готово. Управление: $INIT_SCRIPT start|stop|restart|status|log"
[ "$INIT_STYLE" = "openwrt" ] && log "Управление (OpenWrt): service csqtt start|stop|restart"
log "VK-токен: $VK_TOKEN_FILE · конфиг: $CSQTT_DIR/csqtt.conf · пул: $CSQTT_DIR/vk_pool"
log "Удаление клиента: csqtt-uninstall"
exit 0
