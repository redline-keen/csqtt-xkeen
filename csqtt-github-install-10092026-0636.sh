#!/bin/sh
# -*- coding: utf-8 -*-
# CSQTT — установка клиентского бинарника с GitHub на роутер
# (Keenetic/Entware, OpenWrt) с поддержкой Авторежима ВК (auto_js).
#
# Использование:
#   ./csqtt-github-install.sh 'csqtt://connect?...' [опции]
#   sh csqtt-github-install.sh --repo ВАШ_ЛОГИН/ВАШ_РЕПО ...
#
# Опции:
#   --repo OWNER/REPO     GitHub-репозиторий с бинарниками (по умолч. amurcanov/csqtt)
#   --tag TAG             тег релиза (по умолч. последний)
#   --local-bin ПУТЬ      не скачивать, использовать локальный файл
#   --vk-token ТОКЕН      VK access token (иначе скрипт спросит интерактивно)
#   --mode auto_js|manual режим хешей: Авто ВК (по умолч.) или ручные хеши из ссылки
#   --workers N          воркеры (по умолч. 18)
#   --no-start           установить, но не запускать
#
# VK access token: вечный токен, который приложение CSQTT получает через VK ID.
# Взять его можно в браузере — откройте ссылку из инструкции (INSTALL-*.md),
# войдите в VK и скопируйте access_token из адресной строки после редиректа.

set -u

CSQTT_REPO="redline-keen/csqtt-xkeen"   # ← поменяйте на свой репозиторий, если выложили
                               #   роутерные бинарники в свой GitHub-релиз
CSQTT_TAG="2.0"
CSQTT_LOCAL_BIN=""
CSQTT_VK_TOKEN=""
CSQTT_MODE="auto_js"
CSQTT_WORKERS="54"
CSQTT_START=1
CSQTT_LINK=""

# ── разбор аргументов ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)         CSQTT_REPO="$2"; shift 2 ;;
        --tag)          CSQTT_TAG="$2"; shift 2 ;;
        --local-bin)    CSQTT_LOCAL_BIN="$2"; shift 2 ;;
        --vk-token)     CSQTT_VK_TOKEN="$2"; shift 2 ;;
        --mode)         CSQTT_MODE="$2"; shift 2 ;;
        --workers)      CSQTT_WORKERS="$2"; shift 2 ;;
        --no-start)     CSQTT_START=0; shift ;;
        -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
        csqtt://*)      CSQTT_LINK="$1"; shift ;;
        *)              echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

log()  { printf '\033[1;32m[CSQTT]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[CSQTT]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[CSQTT ОШИБКА]\033[0m %s\n' "$*"; exit 1; }

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

# ── 2. архитектура ───────────────────────────────────────────────────────────
ARCH_KEY=""
case "$(uname -m)" in
    aarch64|arm64)
        # 64-бит LE — MT7981 (Keenetic), AN7581 (OpenWrt)
        ARCH_KEY="aarch64" ;;
    mips)
        # MT7621 — little-endian; редкие BE-роутеры не поддерживаются этим скриптом
        ARCH_KEY="mipsel" ;;
    *)
        die "Архитектура $(uname -m) не поддерживается (собраны aarch64 и mipsel)" ;;
esac
log "Архитектура: $ARCH_KEY ($(uname -m)) · стиль инициализации: $INIT_STYLE"

# ── 3. получение бинарника ──────────────────────────────────────────────────
BIN_PATH="$CSQTT_DIR/csqtt-client"

fetch() { # fetch URL DEST
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "Нужен curl или wget"
    fi
}

verify_bin() { # verify_bin ПУТЬ — ELF + разрядность/endianness совпадают
    # без od (в busybox его нет): чистый sh — побайтово через dd+hexdump-free способ
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

hexdump_bin() { # один байт из stdin → две hex-цифры; только POSIX-утилиты
    # путь 1: hexdump (busybox/entware обычно есть)
    if command -v hexdump >/dev/null 2>&1; then
        hexdump -n 1 -e '1/1 "%02x"'
    # путь 2: od классический (не у всех busybox)
    elif command -v od >/dev/null 2>&1 && od -An -tx1 -N1 </dev/null >/dev/null 2>&1; then
        od -An -tx1 -N1 | tr -d ' \n'
    # путь 3: printf анализ — последний рубеж
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

if [ -n "$CSQTT_LOCAL_BIN" ]; then
    [ -f "$CSQTT_LOCAL_BIN" ] || die "локальный файл не найден: $CSQTT_LOCAL_BIN"
    cp "$CSQTT_LOCAL_BIN" "$BIN_PATH" || die "не удалось скопировать бинарник"
    log "Бинарник скопирован из $CSQTT_LOCAL_BIN"
else
    [ -n "$CSQTT_REPO" ] || die "не задан --repo"
    # тег: последний релиз через редирект
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
    # полный URL из относительного
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
    fetch "$asset_url" "$BIN_PATH" || die "скачивание не удалось"
fi
verify_bin "$BIN_PATH"

# smoke: бинарник должен ругнуться про -peer (проверка не фатальна, если
# сам запуск невозможен — например, скрипт выполняется не на целевом роутере)
smoke=$("$BIN_PATH" 2>&1 | head -n 1)
smoke_rc_unknown=0
case "$smoke" in
    *peer*)  log "Бинарник установлен и отвечает: $smoke" ;;
    *"Exec format error"*|*"not found"*|*"Syntax error"*|*"syntax error"*)
        # ELF корректен по заголовку, но здесь не исполняется — предупреждаем, не роняем
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
PEER_HOST=""; PEER_PORT=""; PASSWORD=""; HASHES=""
oldIFS="$IFS"; IFS='&'
for kv in $query; do
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in
        host)     PEER_HOST=$(urldecode "$v") ;;
        peer)     PEER_PORT=$(urldecode "$v") ;;
        password) PASSWORD=$(urldecode "$v") ;;
        hashes)   HASHES=$(urldecode "$v") ;;
    esac
done
IFS="$oldIFS"
[ -n "$PEER_HOST" ] && [ -n "$PEER_PORT" ] && [ -n "$PASSWORD" ] \
    || die "в ссылке не найдены host / peer / password"
PEER="$PEER_HOST:$PEER_PORT"
log "Пир: $PEER · хешей в ссылке: $(printf '%s' "$HASHES" | awk -F',' '{print NF}')"

# ── 5. VK-токен (только для режима auto_js) ─────────────────────────────────
VK_TOKEN_FILE="$CSQTT_DIR/vk_token"
if [ "$CSQTT_MODE" = "auto_js" ]; then
    if [ -z "$CSQTT_VK_TOKEN" ] && [ -t 0 ] && [ -f "$VK_TOKEN_FILE" ]; then
        CSQTT_VK_TOKEN=$(cat "$VK_TOKEN_FILE")
        warn "Использован сохранённый VK-токен из $VK_TOKEN_FILE"
    fi
    if [ -z "$CSQTT_VK_TOKEN" ]; then
        printf 'Вставьте ВЕЧНЫЙ VK access token (oauth.vk.ru → access_token=...): '
        read -r CSQTT_VK_TOKEN
    fi
    [ -n "$CSQTT_VK_TOKEN" ] || die "для Авторежима ВК нужен VK access token"
    case "$CSQTT_VK_TOKEN" in
        *'"*|*'\'*) die "токен содержит недопустимые символы" ;;
    esac
    umask 077
    printf '%s' "$CSQTT_VK_TOKEN" > "$VK_TOKEN_FILE"
    log "VK-токен сохранён в $VK_TOKEN_FILE (права 600; менять — там же)"
fi

# ── 6. device-id (стабильный) ────────────────────────────────────────────────
DEVICE_ID=""
if [ -f "$CSQTT_DIR/device_id" ]; then
    DEVICE_ID=$(cat "$CSQTT_DIR/device_id" 2>/dev/null)
fi
if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(cat /sys/firmware/devicetree/base/serial-number 2>/dev/null | tr -d '\0')
    [ -n "$DEVICE_ID" ] || DEVICE_ID=$(cat /etc/serial 2>/dev/null)
    [ -n "$DEVICE_ID" ] || DEVICE_ID=$(hostname)-$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || hostname)
    printf '%s' "$DEVICE_ID" > "$CSQTT_DIR/device_id"
fi
log "Device ID: $DEVICE_ID"

# ── 7. конфиг ───────────────────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt.conf" <<EOF
# CSQTT client config — правьте и перезапускайте: $INIT_STYLE start
PEER="$PEER"
PASSWORD="$PASSWORD"
HASHES="$HASHES"
VK_MODE="$CSQTT_MODE"
WORKERS="$CSQTT_WORKERS"
DEVICE_ID="$DEVICE_ID"
LISTEN="127.0.0.1:9000"
FINGERPRINT="firefox"
CLIENT_IDS="8202606,6287487"
OBFS="video"
TURN_TRANSPORT="udp"
CAPTCHA_MODE="auto"
# Собственный TUN-интерфейс (схема XKeen/mihomo как в старых линейках).
# Пусто = UDP-режим 127.0.0.1:9000 без интерфейса.
TUN_IFACE="csqtt0"
TUN_MTU="1300"
EOF
chmod 600 "$CSQTT_DIR/csqtt.conf"
log "Конфиг: $CSQTT_DIR/csqtt.conf"

# ── 8. обёртка запуска (подача VK_JS_BOOTSTRAP в stdin через fifo + exec) ───
cat > "$CSQTT_DIR/csqtt-run.sh" <<'EOF'
#!/bin/sh
# Обёртка: читает csqtt.conf, при Авторежиме ВК подаёт VK_JS_BOOTSTRAP в stdin
# через fifo и делает exec клиента (PID init-скрипта = PID клиента).
DIR=$(dirname "$0")
. "$DIR/csqtt.conf"

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
    --captcha-mode "$CAPTCHA_MODE"

if [ -n "$TUN_IFACE" ]; then
    set -- "$@" --tun "$TUN_IFACE" --tun-mtu "$TUN_MTU"
fi

if [ "$VK_MODE" = "auto_js" ]; then
    TOKEN=$(cat "$DIR/vk_token" 2>/dev/null) || { echo "нет vk_token"; exit 1; }
    BOOTSTRAP=$(printf '{"token":"%s"}' "$TOKEN" | base64 | tr -d '\n')
    set -- "$@" --vk-hash-mode auto_js --vk-auth-mode auto_js --allow-hash-redistribution
    FIFO="$DIR/bootstrap.fifo"
    [ -p "$FIFO" ] || mkfifo "$FIFO" || { echo "не удалось создать fifo"; exit 1; }
    # писатель: одна строка и закрыть (клиент увидит EOF после bootstrap — это норма)
    printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" > "$FIFO" &
    exec "$@" < "$FIFO"
else
    [ -n "$HASHES" ] || { echo "нет хешей VK"; exit 1; }
    set -- "$@" --vk "$HASHES"
    exec "$@" < /dev/null
fi
EOF
chmod +x "$CSQTT_DIR/csqtt-run.sh"

# ── 9. init-скрипт ───────────────────────────────────────────────────────────
if [ "$INIT_STYLE" = "openwrt" ]; then
cat > "$INIT_DIR/csqtt" <<EOF
#!/bin/sh /etc/rc.common
# CSQTT client (Авторежим ВК)
USE_PROCD=1
START=99
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh "$CSQTT_DIR/csqtt-run.sh"
    procd_set_param respawn "\${threshold:-60}" "\${timeout:-5}" "\${retry:-0}"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file "$CSQTT_DIR/csqtt.conf"
    procd_close_instance
}
EOF
else
cat > "$INIT_DIR/S99csqtt" <<EOF
#!/bin/sh
# CSQTT client (Авторежим ВК)
case "\$1" in
    start)
        printf 'Starting CSQTT: '
        if [ -f "$PID_FILE" ] && kill -0 "\$(cat "$PID_FILE")" 2>/dev/null; then
            echo "уже запущен"; exit 0
        fi
        nohup "$CSQTT_DIR/csqtt-run.sh" >>"$LOG_FILE" 2>&1 &
        echo \$! > "$PID_FILE"
        echo "OK (PID \$(cat "$PID_FILE"))"
        ;;
    stop)
        printf 'Stopping CSQTT: '
        if [ -f "$PID_FILE" ]; then
            PID=\$(cat "$PID_FILE")
            # SIGINT = graceful: клиент корректно завершит звонок VK
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
        \$0 stop; sleep 1; \$0 start
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
[ "$INIT_STYLE" = "openwrt" ] && INIT_SCRIPT="$INIT_DIR/csqtt" || INIT_SCRIPT="$INIT_DIR/S99csqtt"
chmod +x "$INIT_SCRIPT"
log "Init-скрипт: $INIT_SCRIPT"

# ── 10. запуск ──────────────────────────────────────────────────────────────
if [ "$CSQTT_START" = "1" ]; then
    if [ "$INIT_STYLE" = "openwrt" ]; then
        "$INIT_SCRIPT" restart
        log "Журнал: logread | grep csqtt  (или $CSQTT_DIR/../..: см. procd)"
    else
        "$INIT_SCRIPT" restart
        sleep 4
        if grep -q "Звонок создан" "$LOG_FILE" 2>/dev/null; then
            log "Авторежим ВК: звонок создан, воркеры поднимаются"
        elif [ "$CSQTT_MODE" = "auto_js" ]; then
            warn "Проверьте журнал: $INIT_SCRIPT log"
            tail -n 10 "$LOG_FILE" 2>/dev/null
        fi
    fi
fi

log "Готово. Управление: $INIT_SCRIPT start|stop|restart|status|log"
[ "$INIT_STYLE" = "openwrt" ] && log "Управление (OpenWrt): service csqtt start|stop|restart"
log "VK-токен: $VK_TOKEN_FILE · конфиг: $CSQTT_DIR/csqtt.conf"
exit 0
