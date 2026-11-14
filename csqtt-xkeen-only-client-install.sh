#!/bin/sh
# Установка csqtt-client 2.5.x (CSQTT-Rebirth, keenetic native TUN) на Keenetic/OpenWrt.
# Изменения под 2.5.x относительно старого скрипта:
#  - нет --device-id, --vk-pool, --vk-calls (клиент сам управляет звонками по токену)
#  - токен передаётся через --vk-token-file
#  - TUN: --tun-name вместо --tun
#  - воркеры: 10..100, кратно 10 (WORKERS_PER_GROUP=10, MAX_WORKERS=100)
#  - секция ротации хешей удалена
#  - ссылки: понимает зашифрованные csqtt://<blob> (AES-256-GCM, сид "csqtt-chiper-key",
#    расшифровка через openssl CTR), plaintext csqtt://connect?... и URL подписки
#    https://IP:46002/<uuid>/sub (тянет sub.json + страница, curl -k для self-signed).
#    Если в ссылке есть token= (серверный VK-токен пароля) — он пишется в vk_token,
#    свой токен не спрашивается. Если hashes= — режим manual + --vk.

set -u

CSQTT_REPO="redline-keen/csqtt-xkeen"
CSQTT_TAG="2.7"
CSQTT_LOCAL_BIN=""
CSQTT_VK_TOKEN=""
CSQTT_WORKERS=""          # пусто = спросить (Enter = 50); кратно 10, диапазон 10..100
CSQTT_START=1
CSQTT_WATCHDOG=1
CSQTT_LINK=""
DOWNLOAD_CONFIG_AUTO=0

# Расширенные параметры csqtt-client по умолчанию (все поддерживаются 2.5.x)
CSQTT_LISTEN="127.0.0.1:9000"
CSQTT_FINGERPRINT="firefox"
CSQTT_CLIENT_IDS="8202606,6287487"
CSQTT_OBFS="video"
CSQTT_TURN_TRANSPORT="udp"
CSQTT_CAPTCHA_MODE="auto"
CSQTT_VK_HASH_MODE="auto_js"
CSQTT_VK_AUTH_MODE="auto_js"
CSQTT_TUN_IFACE="csqtt0"
CSQTT_TUN_MTU="1300"

WORKERS_PER_GROUP=10
MAX_WORKERS=100

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
        --workers)         CSQTT_WORKERS="$2"; shift 2 ;;
        --listen)          CSQTT_LISTEN="$2"; shift 2 ;;
        --fingerprint)     CSQTT_FINGERPRINT="$2"; shift 2 ;;
        --client-ids)      CSQTT_CLIENT_IDS="$2"; shift 2 ;;
        --obfs)            CSQTT_OBFS="$2"; shift 2 ;;
        --turn-transport)  CSQTT_TURN_TRANSPORT="$2"; shift 2 ;;
        --captcha-mode)    CSQTT_CAPTCHA_MODE="$2"; shift 2 ;;
        --vk-hash-mode)    CSQTT_VK_HASH_MODE="$2"; shift 2 ;;
        --vk-auth-mode)    CSQTT_VK_AUTH_MODE="$2"; shift 2 ;;
        --tun-iface)       CSQTT_TUN_IFACE="$2"; shift 2 ;;
        --tun-mtu)         CSQTT_TUN_MTU="$2"; shift 2 ;;
        --download-config) DOWNLOAD_CONFIG_AUTO=1; shift ;;
        --no-start)        CSQTT_START=0; shift ;;
        --no-watchdog)     CSQTT_WATCHDOG=0; shift ;;
        -h|--help)         sed -n '2,45p' "$0"; exit 0 ;;
        csqtt://*|https://*|http://*) CSQTT_LINK="$1"; shift ;;
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

fetch_url() {   # в stdout
    if command -v curl >/dev/null 2>&1; then
        curl -kfsSL "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -q -O - "$1" 2>/dev/null
    else
        return 1
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
CLIENT_LOG_FILE="$CSQTT_DIR/csqtt-client.log"
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
        warn "Загрузите роутерные бинарники 2.5.x в свой GitHub-релиз и повторите с --repo ВАШ_ЛОГИН/ВАШ_РЕПО,"
        warn "либо передайте скачанный вручную файл: --local-bin /tmp/csqtt-client"
        exit 2
    fi
    log "Скачиваю: $asset_url"
    fetch "$asset_url" "$TMP_BIN_PATH" || die "скачивание не удалось"
fi

verify_bin "$TMP_BIN_PATH"
mv -f "$TMP_BIN_PATH" "$BIN_PATH"

# smoke-тест: клиент 2.5.x без аргументов отвечает «Нужны -peer и хеши VK»
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

# ── 4. ссылка подключения (3 формата) ────────────────────────────────────────
urldecode() {
    s="$1"
    out=""
    while [ -n "$s" ]; do
        c=${s%"${s#?}"}
        s=${s#?}
        case "$c" in
            '%')
                if [ -n "$s" ]; then
                    h1=${s%"${s#?}"}
                    s=${s#?}
                    h2=${s%"${s#?}"}
                    s=${s#?}
                    oct=$(printf '%o' "0x${h1}${h2}" 2>/dev/null)
                    if [ -n "$oct" ]; then
                        out="$out$(printf "\\${oct}")"
                    fi
                else
                    out="$out$c"
                fi
                ;;
            *)
                out="$out$c"
                ;;
        esac
    done
    printf '%s' "$out"
}

# Расшифровка csqtt://<blob>: AES-256-GCM, key = SHA256("csqtt-chiper-key"),
# nonce = первые 12 байт блоба, GCM-тег = последние 16 байт.
# GCM-шифрование это CTR от nonce||0x00000002 — расшифровываем openssl CTR, тег игнорируем.
decrypt_csqtt_link() {
    command -v openssl >/dev/null 2>&1 || { warn "нет openssl — выполните: opkg install openssl"; return 1; }
    _b64=$(printf '%s' "$1" | tr -d ' \r\n\t' | tr '_-' '/+')
    case $(( ${#_b64} % 4 )) in
        2) _b64="${_b64}==" ;;
        3) _b64="${_b64}=" ;;
        1) warn "ссылка повреждена (длина base64 ${#_b64})"; return 1 ;;
    esac
    _tmp="$CSQTT_DIR/.link.bin"
    # сначала openssl base64 (-A = одна строка), busybox base64 как запасной
    printf '%s' "$_b64" | openssl base64 -d -A > "$_tmp" 2>/dev/null \
        || printf '%s' "$_b64" | base64 -d > "$_tmp" 2>/dev/null \
        || { rm -f "$_tmp"; warn "base64-декодирование не удалось"; return 1; }
    _len=$(wc -c < "$_tmp" | tr -d ' ')
    [ "$_len" -ge 29 ] || { rm -f "$_tmp"; warn "блоб слишком короткий ($_len байт)"; return 1; }
    _ct_len=$((_len - 28))
    _key_hex=$(printf '%s' "csqtt-chiper-key" | openssl dgst -sha256 -hex | awk '{print $NF}')
    _iv12=$(dd if="$_tmp" bs=1 skip=0 count=12 2>/dev/null | hexdump -v -e '12/1 "%02x"')
    [ -n "$_iv12" ] || _iv12=$(dd if="$_tmp" bs=1 skip=0 count=12 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
    [ -n "$_iv12" ] || { rm -f "$_tmp"; warn "не удалось прочитать IV из блоба"; return 1; }
    _plain=$(dd if="$_tmp" bs=1 skip=12 count="$_ct_len" 2>/dev/null \
        | openssl enc -d -aes-256-ctr -K "$_key_hex" -iv "${_iv12}00000002" -nopad 2>/dev/null)
    rm -f "$_tmp"
    case "$_plain" in
        connect?*)
            printf '%s' "$_plain"
            return 0
            ;;
    esac
    [ -n "$_plain" ] && warn "расшифровано, но формат неожиданный: $(printf '%s' "$_plain" | head -c 40)"
    [ -n "$_plain" ] && return 0
    warn "openssl CTR не смог расшифровать (openssl $(openssl version 2>/dev/null | awk '{print $2}'))"
    return 1
}

# URL подписки https://IP:46002/<uuid>/sub → достать зашифрованную csqtt:// ссылку
link_from_sub_url() {
    _url="$1"
    _base="${_url%%\?*}"        # срезать query
    case "$_base" in
        */sub|*/sub/|*/api/sub|*/api/sub/) _base="${_base%/}"; _base="${_base%/sub}"; _base="${_base%/api/sub}" ;;
    esac
    _json=$(fetch_url "${_base}/sub.json") || _json=""
    [ -n "$_json" ] || _json=$(fetch_url "${_base}/api/sub") || _json=""
    _link=""
    if [ -n "$_json" ]; then
        _link=$(printf '%s' "$_json" | sed -n 's/.*"link"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    fi
    if [ -z "$_link" ]; then
        _html=$(fetch_url "${_base}/sub") || _html=""
        [ -n "$_html" ] || _html=$(fetch_url "$_url") || _html=""
        if [ -n "$_html" ]; then
            _link=$(printf '%s' "$_html" | grep -oE 'csqtt://[A-Za-z0-9_-]{20,}' | head -n 1)
        fi
    fi
    [ -n "$_link" ] && printf '%s' "$_link"
}

# Разбор payload'а connect?v=2&host=..&peer=..&password=..[&hashes=..|&token=..]
LINK_HOST=""; LINK_PORT=""; LINK_PASSWORD=""; LINK_HASHES=""; LINK_TOKEN=""
parse_payload() {
    _payload="$1"
    _query=$(printf '%s' "$_payload" | sed -n 's/^connect?//p')
    [ -n "$_query" ] || _query="$_payload"
    oldIFS="$IFS"; IFS='&'
    for kv in $_query; do
        k=${kv%%=*}; v=${kv#*=}
        case "$k" in
            host)     LINK_HOST=$(urldecode "$v") ;;
            peer)     LINK_PORT=$(urldecode "$v") ;;
            password) LINK_PASSWORD=$(urldecode "$v") ;;
            hashes)   LINK_HASHES=$(urldecode "$v" | tr '+' ',') ;;
            token)    LINK_TOKEN=$(urldecode "$v") ;;
        esac
    done
    IFS="$oldIFS"
}

LINK_ATTEMPT=0
while :; do
    LINK_ATTEMPT=$((LINK_ATTEMPT + 1))
    if [ -z "$CSQTT_LINK" ]; then
        printf 'Вставьте ссылку подключения (csqtt://... или https://IP:46002/<uuid>/sub): '
        read -r CSQTT_LINK || die "не удалось прочитать ссылку (нет stdin)"
    fi

    case "$CSQTT_LINK" in
        csqtt://*|https://*|http://*) ;;
        *)
            warn "Ожидалась ссылка csqtt:// или URL подписки https://... — попытка $LINK_ATTEMPT"
            CSQTT_LINK=""
            continue
            ;;
    esac

    _payload=""
    case "$CSQTT_LINK" in
        https://*|http://*)
            log "URL подписки: $CSQTT_LINK — забираю ссылку с сервера..."
            _link=$(link_from_sub_url "$CSQTT_LINK")
            if [ -z "$_link" ]; then
                warn "Не удалось получить csqtt:// из подписки — попробуйте ещё раз (попытка $LINK_ATTEMPT)"
                CSQTT_LINK=""
                continue
            fi
            log "Ссылка из подписки получена"
            CSQTT_LINK="$_link"
            ;;
    esac

    case "$CSQTT_LINK" in
        csqtt://connect?*)
            _payload=${CSQTT_LINK#csqtt://} ;;
        csqtt://*)
            _blob=${CSQTT_LINK#csqtt://}
            case "$_blob" in
                connect?*) _payload="$_blob" ;;
                *)
                    log "Расшифровываю ссылку (AES-256-GCM), блоб ${#_blob} симв..."
                    _payload=$(decrypt_csqtt_link "$_blob") || _payload=""
                    ;;
            esac
            ;;
    esac

    if [ -n "$_payload" ]; then
        parse_payload "$_payload"
    fi

    if [ -n "$LINK_HOST" ] && [ -n "$LINK_PORT" ] && [ -n "$LINK_PASSWORD" ]; then
        break
    fi
    warn "В ссылке не найдены host / peer / password — попробуйте ещё раз (попытка $LINK_ATTEMPT)"
    CSQTT_LINK=""
done
PEER="$LINK_HOST:$LINK_PORT"
log "Пир: $PEER"

# ── 5. VK-токен (серверный из ссылки приоритетнее) ───────────────────────────
VK_TOKEN_FILE="$CSQTT_DIR/vk_token"
if [ -n "$LINK_TOKEN" ]; then
    CSQTT_VK_TOKEN="$LINK_TOKEN"
    log "В ссылке передан серверный VK-токен — использую его (свой не нужен)"
elif [ -n "$CSQTT_VK_TOKEN" ]; then
    log "VK-токен передан через --vk-token"
elif [ -t 0 ] && [ -f "$VK_TOKEN_FILE" ]; then
    CSQTT_VK_TOKEN=$(cat "$VK_TOKEN_FILE")
    warn "Использован сохранённый VK-токен из $VK_TOKEN_FILE"
fi

vk_token_is_valid() {
    _t="$1"
    [ -n "$_t" ] || return 1
    case "$_t" in
        *'"'*|*'\'*) return 1 ;;
        *[!A-Za-z0-9_.-]*) return 1 ;;
        *..*) return 1 ;;
        .*|*.) return 1 ;;
    esac
    [ "${#_t}" -ge 50 ] || return 1
    return 0
}

if [ -n "$LINK_HASHES" ]; then
    # сервер передал готовый пул хешей для этого пароля — режим manual
    CSQTT_VK_HASH_MODE="manual"
    CSQTT_VK_AUTH_MODE="vkcalls"
    log "В ссылке переданы хеши ($(printf '%s' "$LINK_HASHES" | tr ',' ' ' | wc -w | tr -d ' ') шт) — режим manual"
    umask 077
    printf '%s' "${CSQTT_VK_TOKEN:-}" > "$VK_TOKEN_FILE" 2>/dev/null || true
elif [ -n "$CSQTT_VK_TOKEN" ]; then
    VK_ATTEMPT=1
    while ! vk_token_is_valid "${CSQTT_VK_TOKEN:-}"; do
        VK_ATTEMPT=$((VK_ATTEMPT + 1))
        warn "Некорректный VK access token — попробуйте ещё раз (попытка $VK_ATTEMPT)"
        printf 'Вставьте ВЕЧНЫЙ VK access token (oauth.vk.ru → access_token=...): '
        read -r CSQTT_VK_TOKEN || die "не удалось прочитать токен (нет stdin)"
        [ -n "$CSQTT_VK_TOKEN" ] || die "токен пуст"
    done
    umask 077
    printf '%s' "$CSQTT_VK_TOKEN" > "$VK_TOKEN_FILE"
    log "VK-токен сохранён в $VK_TOKEN_FILE (права 600)"
else
    VK_ATTEMPT=1
    while :; do
        VK_ATTEMPT=$((VK_ATTEMPT + 1))
        if [ "$VK_ATTEMPT" -gt 1 ]; then
            warn "Нужен непустой VK access token (попытка $VK_ATTEMPT)"
        fi
        printf 'Вставьте ВЕЧНЫЙ VK access token (oauth.vk.ru → access_token=...): '
        read -r CSQTT_VK_TOKEN || die "не удалось прочитать токен (нет stdin)"
        vk_token_is_valid "$CSQTT_VK_TOKEN" && break
    done
    umask 077
    printf '%s' "$CSQTT_VK_TOKEN" > "$VK_TOKEN_FILE"
    log "VK-токен сохранён в $VK_TOKEN_FILE (права 600)"
fi

# ── 6. воркеры (2.5.x: кратно 10, 10..100; пул хешей больше не существует) ──
if [ -z "$CSQTT_WORKERS" ] && [ -t 0 ]; then
    printf 'Воркеров [%d..%d, кратно %d] (Enter = 50): ' "$WORKERS_PER_GROUP" "$MAX_WORKERS" "$WORKERS_PER_GROUP"
    read -r CSQTT_WORKERS || CSQTT_WORKERS=""
fi
case "$CSQTT_WORKERS" in
    "") CSQTT_WORKERS=50 ;;
    *[!0-9]*) die "число воркеров должно быть целым: '$CSQTT_WORKERS'" ;;
esac
[ "$CSQTT_WORKERS" -ge "$WORKERS_PER_GROUP" ] || die "минимум $WORKERS_PER_GROUP воркеров"
if [ "$CSQTT_WORKERS" -gt "$MAX_WORKERS" ]; then
    warn "Максимум воркеров в 2.5.x: $MAX_WORKERS → округляю до $MAX_WORKERS"
    CSQTT_WORKERS=$MAX_WORKERS
fi
CSQTT_WORKERS=$((CSQTT_WORKERS / WORKERS_PER_GROUP * WORKERS_PER_GROUP))
CSQTT_GROUPS=$((CSQTT_WORKERS / WORKERS_PER_GROUP))
log "Воркеров: $CSQTT_WORKERS (групп: $CSQTT_GROUPS по $WORKERS_PER_GROUP)"

# ── 8. конфиг (device-id и HASHES в 2.5.x не существуют) ────────────────────
cat > "$CSQTT_DIR/csqtt.conf" <<EOF
PEER="$PEER"
PASSWORD="$LINK_PASSWORD"
HASHES="$LINK_HASHES"
WORKERS="$CSQTT_WORKERS"
LISTEN="$CSQTT_LISTEN"
FINGERPRINT="$CSQTT_FINGERPRINT"
CLIENT_IDS="$CSQTT_CLIENT_IDS"
OBFS="$CSQTT_OBFS"
TURN_TRANSPORT="$CSQTT_TURN_TRANSPORT"
CAPTCHA_MODE="$CSQTT_CAPTCHA_MODE"
VK_HASH_MODE="$CSQTT_VK_HASH_MODE"
VK_AUTH_MODE="$CSQTT_VK_AUTH_MODE"
TUN_IFACE="$CSQTT_TUN_IFACE"
TUN_MTU="$CSQTT_TUN_MTU"
EOF
chmod 600 "$CSQTT_DIR/csqtt.conf"
log "Конфиг: $CSQTT_DIR/csqtt.conf (WORKERS=$CSQTT_WORKERS · режим VK: $CSQTT_VK_HASH_MODE)"

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
            1|"")
                do_download_config
                break
                ;;
            2)
                log "Пропуск загрузки config.yaml."
                break
                ;;
            *)
                warn "Ошибка: выберите 1 или 2."
                ;;
        esac
    done
fi

# ── 9. обёртка запуска (2.5.x: токен через --vk-token-file, без fifo) ───────
cat > "$CSQTT_DIR/csqtt-run.sh" <<'EOF'
#!/bin/sh
DIR=$(dirname "$0")
. "$DIR/csqtt.conf"
umask 077

# ВЕСЬ вывод обёртки и клиента — строго в файл лога, с самых первых строк.
exec >> "$DIR/csqtt-client.log" 2>&1

# Клиент 2.5.x (Rebirth): пул хешей и device-id отсутствуют; токен — файлом.
# Auto JS сам создаёт звонок и получает хеши/TURN-креды (credential broker).
set -- "$DIR/csqtt-client" \
    --peer "$PEER" \
    --password "$PASSWORD" \
    -n "$WORKERS" \
    --listen "$LISTEN" \
    --fingerprint "$FINGERPRINT" \
    --client-ids "$CLIENT_IDS" \
    --obfs "$OBFS" \
    --turn-transport "$TURN_TRANSPORT" \
    --captcha-mode "$CAPTCHA_MODE" \
    --vk-hash-mode "${VK_HASH_MODE:-auto_js}" \
    --vk-auth-mode "${VK_AUTH_MODE:-auto_js}"

if [ -n "${HASHES:-}" ]; then
    # сервер выдал готовые хеши для этого пароля → manual режим, свой токен не нужен
    set -- "$@" --vk "$HASHES"
else
    [ -s "$DIR/vk_token" ] || { echo "нет vk_token и нет хешей"; exit 1; }
    set -- "$@" --vk-token-file "$DIR/vk_token"
fi

# Native TUN: интерфейс создаёт сам клиент (/dev/net/tun + TUNSETIFF),
# IP выдаёт сервер через TUNCONF — клиенту IP не задаётся.
if [ -n "${TUN_IFACE:-}" ]; then
    set -- "$@" --tun-name "$TUN_IFACE" --tun-mtu "${TUN_MTU:-1300}"
fi

exec "$@"
EOF
chmod +x "$CSQTT_DIR/csqtt-run.sh"

# ── 11. cron (только watchdog; ротация хешей в 2.5.x отсутствует) ───────────
CRON_FILE=""
if [ "$INIT_STYLE" = "entware" ]; then
    CRON_FILE="/opt/var/spool/cron/crontabs/root"
else
    CRON_FILE="/etc/crontabs/root"
fi
mkdir -p "$(dirname "$CRON_FILE")"
touch "$CRON_FILE"

# подчистить cron-строки старой ротации, если апгрейд со старой версии
sed -i '/csqtt-rotate-hashes\.sh/d' "$CRON_FILE" 2>/dev/null || true

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
        tail -n 500 "$log" > "${log}.tmp" && cat "${log}.tmp" > "$log" && rm -f "${log}.tmp"   # НЕ mv: клиент держит лог открытым, mv отвязывает fd
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

sed -i -e "s|__INIT_CMD__|$INIT_SCRIPT|g" -e "s|__LOG_FILE__|$CLIENT_LOG_FILE|g" \
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
        nohup "\$DIR/csqtt-run.sh" >>"$CLIENT_LOG_FILE" 2>&1 &
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
        tail -n 100 "$CLIENT_LOG_FILE" 2>/dev/null || echo "лог пуст: $CLIENT_LOG_FILE"
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
        if grep -qE "TUN|КЛИЕНТ|Пул" "$CLIENT_LOG_FILE" 2>/dev/null; then
            log "Клиент стартовал, воркеры поднимаются (TUNCONF придёт от сервера)"
        else
            warn "Проверьте журнал: $INIT_SCRIPT log"
            tail -n 10 "$CLIENT_LOG_FILE" 2>/dev/null
        fi
    fi
fi

log "Готово. Управление: $INIT_SCRIPT start|stop|restart|status|log"
[ "$INIT_STYLE" = "openwrt" ] && log "Управление (OpenWrt): service csqtt start|stop|restart"
log "VK-токен: $VK_TOKEN_FILE · конфиг: $CSQTT_DIR/csqtt.conf"
log "IP туннеля выдаёт сервер (TUNCONF) — смотреть: ip addr show $CSQTT_TUN_IFACE"
log "Удаление клиента: csqtt-uninstall"
exit 0
