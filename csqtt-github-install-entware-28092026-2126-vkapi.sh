#!/bin/sh
# -*- coding: utf-8 -*-
# CSQTT — установка клиентского бинарника с GitHub на роутер
# (Keenetic/Entware, OpenWrt) с Авторежимом ВК (auto_js), пулом хешей
# и суточной ротацией (один хеш в сутки, окно 09:30–15:10, случайный порядок).
# tslog-ревизия (26092026, база 1946-watchdog-uninstall): бинарь с таймкодом
#   в каждой строке лога («YYYY-MM-DD HH:MM:SS …», localtime_r/TZ; сборка
#   26092026-2259-tslog: aarch64/mipsel/mipsbe, статичный musl, smoke qemu OK).
#   Обёртка csqtt-run.sh экспортирует TZ (по умолчанию MSK-3, переопределяется
#   в csqtt.conf); обрезка логов в watchdog'е переведена на cat (mv отвязывал
#   fd клиента — лог замирал после обрезки); device-id и VK-токен — строгая
#   валидация из 2325-deviceidfix/1948.
#   SHA256: aarch64   3d4e6988bf8a5f5a115503ff4328e364c5c973bcfe2bb22a130a5115ed4d8805
#           mipsel    51516ac983575be3ef515e47d9dee3a96144049327c0a62f6d09f8d386d716a0
#           mipsbe    138afdff6b285ed46df347cfc7293eb435a3733a5f0fbbcf46502e5bc0a99e7e
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
#   --hashes N            число хешей в пуле 1..6 (по умолч. спрашивает, стандарт 4)
#   --workers N          воркеры 9..162 (по умолч. спрашивает; автоматически
#                         урезается до хеши×27 и выравнивается кратно 9)
#   --no-start           установить, но не запускать
#   --no-rotate          не ставить cron-ротацию хешей
#   --no-watchdog        не ставить cron-watchdog (автоперезапуск при сбое)
#   --mihomo-conf        скачать csqtt-config.yaml в $MIHOMO_DIR (по умолч.
#                         /opt/etc/mihomo, как в csqtt-xkeen-deploy.sh)
#   --mihomo-conf-url URL  свой URL для config.yaml
#   --mihomo-dir ПУТЬ    каталог mihomo (SSClash = /opt/clash)
#   --no-mihomo          не трогать mihomo
#
# VK access token: вечный токен, который приложение CSQTT получает через VK ID.
# Взять его можно в браузере — откройте ссылку из инструкции (INSTALL-*.md),
# войдите в VK и скопируйте access_token из адресной строки после редиректа.
#
# СООТНОШЕНИЕ: на 1 хеш — 27 воркеров (3 группы × 9). Задали воркеров больше
# хешей×27 — они автоматически урежутся: 2 хеша → максимум 54, 4 хеша → 108,
# 6 хешей → 162. Это правило проверяет и клиент при старте.
#
# РОТАЦИЯ: раз в сутки, в случайный момент окна 09:30–15:10, один хеш пула
# заменяется свежим (новый VK-звонок), старый звонок корректно завершается.
# Порядок хешей — случайная перестановка (например 4,1,5,2,6,3), каждый день
# ротируется следующий её элемент; когда перестановка исчерпана — генерируется
# новая. Клиент на время ротации перезапускается (~10–15 секунд простоя).
#
# WATCHDOG: cron каждые 2 минуты проверяет процесс, TUN-интерфейс csqtt0 и
# пинг через него; любой сбой — перезапуск службы. Уважает ручную остановку
# (init stop создаёт stopped-флаг) и не лезет во время рестарта ротацией.
# ДЕИНСТАЛЛЯТОР: команда csqtt-uninstall (или $CSQTT_DIR/uninstall.sh) —
# останавливает службу, чистит cron-строки ротации/watchdog и все файлы.

set -u

CSQTT_REPO="redline-keen/csqtt-xkeen"   # ← поменяйте на свой репозиторий, если выложили
                               #   роутерные бинарники в свой GitHub-релиз
CSQTT_TAG="2.6"
CSQTT_LOCAL_BIN=""
CSQTT_VK_TOKEN=""
CSQTT_HASHES=""
CSQTT_WORKERS=""
CSQTT_START=1
CSQTT_ROTATE=1
CSQTT_WATCHDOG=1
CSQTT_LINK=""
CSQTT_MIHOMO_CONF=""      # "" = спросить; yes/no после разбора
CSQTT_MIHOMO_CONF_URL=""
CSQTT_MIHOMO_DIR=""       # каталог Mihomo; по умолч. /opt/etc/mihomo (SSClash = /opt/clash)
WORKERS_PER_HASH=27
WORKERS_STEP=9
MAX_HASHES=6

# ── разбор аргументов ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)       CSQTT_REPO="$2"; shift 2 ;;
        --tag)        CSQTT_TAG="$2"; shift 2 ;;
        --local-bin)  CSQTT_LOCAL_BIN="$2"; shift 2 ;;
        --vk-token)   CSQTT_VK_TOKEN="$2"; shift 2 ;;
        --hashes)     CSQTT_HASHES="$2"; shift 2 ;;
        --workers)    CSQTT_WORKERS="$2"; shift 2 ;;
        --no-start)   CSQTT_START=0; shift ;;
        --no-rotate)  CSQTT_ROTATE=0; shift ;;
        --no-watchdog) CSQTT_WATCHDOG=0; shift ;;
        --mihomo-conf) CSQTT_MIHOMO_CONF="yes"; shift ;;
        --mihomo-conf-url) CSQTT_MIHOMO_CONF_URL="$2"; shift 2 ;;
        --mihomo-dir) CSQTT_MIHOMO_DIR="$2"; shift 2 ;;
        --no-mihomo)  CSQTT_MIHOMO_CONF="no"; shift ;;
        -h|--help)    sed -n '2,45p' "$0"; exit 0 ;;
        csqtt://*)    CSQTT_LINK="$1"; shift ;;
        *)            echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

log()  { printf '\033[1;32m[CSQTT]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[CSQTT]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[CSQTT ОШИБКА]\033[0m %s\n' "$*"; exit 1; }

# ── 1. каталог установки (Entware → /opt, OpenWrt → /etc) ───────────────────
if [ -d /opt/entware ] || [ -d /opt/etc/init.d ]; then
    CSQTT_DIR="/opt/etc/csqtt"
    INIT_DIR="/opt/etc/init.d"
    LOG_DIR="/opt/var/log"
    INIT_STYLE="entware"
else
    CSQTT_DIR="/etc/csqtt"
    INIT_DIR="/etc/init.d"
    LOG_DIR="/var/log"
    INIT_STYLE="openwrt"
fi
mkdir -p "$CSQTT_DIR" "$INIT_DIR" "$LOG_DIR" 2>/dev/null || die "нет прав на запись (запускайте под root)"
LOG_FILE="$LOG_DIR/csqtt.log"
# лог КЛИЕНТА: обёртка csqtt-run.sh редиректит весь вывод сюда (а $LOG_FILE —
# только сообщения init-скрипта); watchdog и init log смотрят на клиентский
CLIENT_LOG_FILE="$CSQTT_DIR/csqtt-client.log"
PID_FILE="/var/run/csqtt.pid"
# каталог mihomo на Entware/Keenetic (как в csqtt-xkeen-deploy.sh)
MIHOMO_DIR="${CSQTT_MIHOMO_DIR:-/opt/etc/mihomo}"
MIHOMO_DIR="${MIHOMO_DIR%/}"
MIHOMO_CONF_FILE="$MIHOMO_DIR/config.yaml"
if [ "$INIT_STYLE" = "openwrt" ]; then
    INIT_SCRIPT="$INIT_DIR/csqtt"
    INIT_SCRIPT_NAME="service csqtt"
else
    INIT_SCRIPT="$INIT_DIR/S99csqtt"
    INIT_SCRIPT_NAME="$INIT_DIR/S99csqtt"
fi

# ── 1а. остановка предыдущей установки (если была) ───────────────────────────
# Флаг restarting ДО остановки: старый watchdog (cron */2) не должен
# воскресить старый клиент, пока идёт замена. Старые init-скрипты обеих
# линий пробуем по именам; затем контрольный killall.
touch "$CSQTT_DIR/restarting" 2>/dev/null
for init in /opt/etc/init.d/S99csqtt /etc/init.d/csqtt /etc/init.d/S99csqtt; do
    [ -x "$init" ] && "$init" stop >/dev/null 2>&1
done
killall -TERM csqtt-client 2>/dev/null
n=0; while killall -0 csqtt-client 2>/dev/null && [ $n -lt 5 ]; do sleep 1; n=$((n+1)); done
killall -9 csqtt-client 2>/dev/null
rm -f "$PID_FILE" /var/run/csqtt.pid /opt/var/run/csqtt-client.pid
log "Предыдущая установка остановлена (если была)"

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
    rm -f "$BIN_PATH"
    if ! fetch "$asset_url" "$BIN_PATH"; then
        rm -f "$BIN_PATH"   # недокачанный файл не оставляем
        die "скачивание не удалось (curl 23 = ошибка ЗАПИСИ: обычно кончилось место на разделе; см. df -h $CSQTT_DIR). Обход: скачайте бинарник на ПК и поставьте --local-bin /путь/к/файлу"
    fi
fi
verify_bin "$BIN_PATH"

# smoke: бинарник должен ругнуться про -peer (проверка не фатальна, если
# сам запуск невозможен — например, скрипт выполняется не на целевом роутере)
smoke=$("$BIN_PATH" 2>&1 | head -n 1)
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
vk_token_is_valid() {
    _t="$1"
    [ -n "$_t" ] || return 1
    case "$_t" in
        *'"*|*'\'*) return 1 ;;
        *[!A-Za-z0-9_.-]*) return 1 ;;
        *..*) return 1 ;;   # две точки подряд — точно не токен
        .*|*.) return 1 ;;  # точка в начале/конце — тоже не токен
    esac
    [ "${#_t}" -ge 50 ] || return 1
    return 0
}

VK_ATTEMPT=0
while ! vk_token_is_valid "${CSQTT_VK_TOKEN:-}"; do
    VK_ATTEMPT=$((VK_ATTEMPT + 1))
    if [ "$VK_ATTEMPT" -gt 1 ]; then
        warn "Некорректный VK access token (пустой, короткий или с недопустимыми символами) — попробуйте ещё раз (попытка $VK_ATTEMPT)"
    fi
    printf 'Вставьте ВЕЧНЫЙ VK access token (oauth.vk.ru → access_token=...): '
    read -r CSQTT_VK_TOKEN || die "не удалось прочитать токен (нет stdin)"
done
umask 077
printf '%s' "$CSQTT_VK_TOKEN" > "$VK_TOKEN_FILE"
log "VK-токен сохранён в $VK_TOKEN_FILE (права 600; менять — там же)"

# ── 6. параметры пула: хеши и воркеры ───────────────────────────────────────
# хеши: 1..6
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

# воркеры: 9..162, максимум хеши×27, кратно 9
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
# правило 27:1 — на 1 хеш не больше 27 воркеров
if [ "$CSQTT_WORKERS" -gt "$hash_cap" ]; then
    warn "Воркеров $CSQTT_WORKERS → $hash_cap: правило 27 на хеш ($CSQTT_HASHES хешей)"
    CSQTT_WORKERS=$hash_cap
fi
CSQTT_WORKERS=$((CSQTT_WORKERS / WORKERS_STEP * WORKERS_STEP))
[ "$CSQTT_WORKERS" -ge 9 ] || CSQTT_WORKERS=$WORKERS_STEP
log "Хешей: $CSQTT_HASHES · воркеров: $CSQTT_WORKERS ($((CSQTT_WORKERS / WORKERS_PER_HASH)) на хеш, $((CSQTT_WORKERS / WORKERS_STEP)) групп)"

# ── 6а. конфиг mihomo ────────────────────────────────────────────────────────
# Спрашивает: скачать csqtt-config.yaml из ветки main того же репозитория
# (--repo, как в csqtt-xkeen-deploy.sh) в /opt/etc/mihomo/config.yaml — или
# пропустить. Неинтерактивно: --mihomo-conf / --mihomo-conf-url URL /
# --no-mihomo. Прежний конфиг сохраняется бэкапом *.csqtt-bak (однократно);
# скачивание атомарно — при сбое сети существующий конфиг mihomo не портится.
# После успешной загрузки S99mihomo перезапускается (если есть).
[ -n "$CSQTT_MIHOMO_CONF_URL" ] && CSQTT_MIHOMO_CONF="yes"
CSQTT_CONFIG_URL="https://raw.githubusercontent.com/$CSQTT_REPO/main/csqtt-config.yaml"

if [ -z "$CSQTT_MIHOMO_CONF" ] && [ -t 0 ]; then
    # интерактивный выбор: 1) скачать 2) пропустить — каждый пункт на своей строке
    while true; do
        printf 'Загрузить csqtt-config.yaml для mihomo?\n'
        printf ' 1) Скачать config.yaml и разместить в %s\n' "$MIHOMO_DIR"
        printf ' 2) Не скачивать — настроить конфиг самостоятельно\n'
        printf 'Выберите пункт [1-2] (Enter = 1): '
        read -r MIHOMO_CHOICE || MIHOMO_CHOICE=""
        case "$MIHOMO_CHOICE" in
            1|"")  CSQTT_MIHOMO_CONF="yes"; break ;;
            2)     CSQTT_MIHOMO_CONF="no"; break ;;
            *)     warn "Ошибка: выберите 1 или 2." ;;
        esac
    done
fi

if [ "$CSQTT_MIHOMO_CONF" = "yes" ]; then
    [ -n "$CSQTT_MIHOMO_CONF_URL" ] || CSQTT_MIHOMO_CONF_URL="$CSQTT_CONFIG_URL"
    log "mihomo config.yaml ← $CSQTT_MIHOMO_CONF_URL"
    mkdir -p "$MIHOMO_DIR"
    # прежний конфиг — в бэкап (однократно), как просили «перезапись не терять»
    if [ -f "$MIHOMO_CONF_FILE" ] && [ ! -f "$MIHOMO_CONF_FILE.csqtt-bak" ]; then
        cp "$MIHOMO_CONF_FILE" "$MIHOMO_CONF_FILE.csqtt-bak"
        log "Прежний конфиг mihomo сохранён: $MIHOMO_CONF_FILE.csqtt-bak"
    fi
    # атомарная загрузка: сбой сети не портит существующий конфиг
    if fetch "$CSQTT_MIHOMO_CONF_URL" "$MIHOMO_CONF_FILE.new" && [ -s "$MIHOMO_CONF_FILE.new" ]; then
        mv "$MIHOMO_CONF_FILE.new" "$MIHOMO_CONF_FILE"
        log "mihomo config.yaml обновлён: $MIHOMO_CONF_FILE"
        # перезапуск mihomo, если init-скрипт на месте (как в csqtt-xkeen-deploy.sh)
        if [ -x /opt/etc/init.d/S99mihomo ]; then
            /opt/etc/init.d/S99mihomo restart >/dev/null 2>&1 \
                && log "mihomo перезапущен (S99mihomo)" \
                || warn "не удалось перезапустить mihomo — перезапустите вручную"
        fi
    else
        rm -f "$MIHOMO_CONF_FILE.new"
        warn "Не удалось скачать config.yaml — прежний конфиг mihomo не тронут"
    fi
fi

# ── 7. device-id (стабильный) ────────────────────────────────────────────────
sanitize_id() {   # вычитаем мусор: только [A-Za-z0-9:. -], срезаем ведущие/хвостовые разделители
    printf '%s' "$1" | tr -cd 'A-Za-z0-9:.-' | sed 's/^[.:-]*//; s/[.:-]*$//'
}
first_mac() {    # MAC br-lan → eth0 → lan → wan → первый ненулевой в /sys/class/net
    for dev in br-lan eth0 lan wan; do
        [ -f "/sys/class/net/$dev/address" ] || continue
        m=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
        case "$m" in ""|00:00:00:00:00:00) : ;; *) printf '%s' "$m"; return 0 ;; esac
    done
    for f in /sys/class/net/*/address; do
        [ -f "$f" ] || continue
        m=$(cat "$f" 2>/dev/null)
        case "$m" in ""|00:00:00:00:00:00) : ;; *) printf '%s' "$m"; return 0 ;; esac
    done
    return 0
}
random_hex() {   # портативный hex без od: tr -dc из urandom, hexdump как запасной
    r=$(tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 16)
    if [ "${#r}" -lt 8 ] && command -v hexdump >/dev/null 2>&1; then
        r=$(hexdump -n 8 -e '8/1 "%02x"' /dev/urandom 2>/dev/null)
    fi
    printf '%s' "$r"
}

DEVICE_ID=""
# сохранённый принимаем только если он не вырожденный (не пусто, не одно «-»)
if [ -f "$CSQTT_DIR/device_id" ]; then
    DEVICE_ID=$(sanitize_id "$(cat "$CSQTT_DIR/device_id" 2>/dev/null)")
fi
if [ -z "$DEVICE_ID" ]; then
    # формат: Keenetic-<последние 4 hex-цифры MAC>, при недоступности MAC — random
    MAC4=$(first_mac | tr -d ':\n ' | tail -c 4)
    case "$MAC4" in
        *[!0-9a-fA-F]*|"") MAC4="" ;;
        *) MAC4=$(printf '%s' "$MAC4" | tr 'A-F' 'a-f') ;;
    esac
    if [ -n "$MAC4" ]; then
        DEVICE_ID="Keenetic-$MAC4"
    else
        DEVICE_ID="Keenetic-$(random_hex)"
    fi
    printf '%s' "$DEVICE_ID" > "$CSQTT_DIR/device_id"
    chmod 600 "$CSQTT_DIR/device_id" 2>/dev/null
fi
[ -n "$DEVICE_ID" ] || die "не удалось определить device-id (пусто даже после рандома?)"
log "Device ID: $DEVICE_ID"

# ── 8. конфиг ───────────────────────────────────────────────────────────────
# HASHES — число хешей в пуле (звонков), WORKERS — воркеры (≤ HASHES×27).
# Изменение HASHES на существующем пуле: удалите vk_pool и перезапустите —
# клиент создаст новый пул нужного размера.
cat > "$CSQTT_DIR/csqtt.conf" <<EOF
# CSQTT client config — правьте и перезапускайте: $INIT_SCRIPT_NAME start
# VK_HASH_MODE/VK_AUTH_MODE: "api" = «Авто API» (официальный calls.start,
#   безопасно для аккаунта — по умолчанию); "auto_js" = «Авто VK»
#   (браузерная цепочка — ВК блокирует за неё, используйте на свой риск).
PEER="$PEER"
PASSWORD="$PASSWORD"
HASHES="$CSQTT_HASHES"
WORKERS="$CSQTT_WORKERS"
VK_MODE="auto_js"
VK_HASH_MODE="api"
VK_AUTH_MODE="api"
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
log "Конфиг: $CSQTT_DIR/csqtt.conf (HASHES=$CSQTT_HASHES · WORKERS=$CSQTT_WORKERS)"

# ── 9. обёртка запуска (fifo + exec, пул хешей) ─────────────────────────────
cat > "$CSQTT_DIR/csqtt-run.sh" <<'EOF'
#!/bin/sh
# Обёртка: читает csqtt.conf, при Авторежиме ВК подаёт VK_JS_BOOTSTRAP в stdin
# через fifo и делает exec клиента (PID init-скрипта = PID клиента).
# Пул хешей: файл vk_pool (строки «хеш:conversation_id»). Пустой/отсутствующий —
# клиент создаст HASHES звонков при первом старте и заполнит пул сам; дальше
# каждый старт работает по пулю без создания новых звонков.
DIR=$(dirname "$0")
. "$DIR/csqtt.conf"
umask 077

# Часовой пояс для таймкодов лога клиента: musl libc читает только TZ из
# окружения (/etc/localtime не смотрит), без TZ клиент пишет UTC.
# Переопределяется строкой TZ=... в csqtt.conf.
: "${TZ:=MSK-3}"
export TZ

# ВЕСЬ вывод обёртки и клиента — строго в файл лога, с самых первых строк.
# Редирект ставим до любых echo/проверок, чтобы ранние ошибки («нет vk_token»,
# «не удалось создать fifo») тоже попадали в файл.
exec >> "$DIR/csqtt-client.log" 2>&1

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
set -- "$@" --vk-hash-mode "${VK_HASH_MODE:-api}" --vk-auth-mode "${VK_AUTH_MODE:-api}"
FIFO="$DIR/bootstrap.fifo"
[ -p "$FIFO" ] || mkfifo "$FIFO" || { echo "не удалось создать fifo"; exit 1; }
# писатель: одна строка и закрыть (клиент увидит EOF после bootstrap — это норма)
printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" > "$FIFO" &
exec "$@" < "$FIFO"
EOF
chmod +x "$CSQTT_DIR/csqtt-run.sh"

# ── 10. скрипт ротации хешей ────────────────────────────────────────────────
# Запускается cron'ом каждые 5 минут. Раз в сутки, в случайный момент окна
# 09:30–15:10, заменяет один хеш пула: свежий звонок (--vk-regen-call),
# подмена строки, перезапуск клиента, завершение старого звонка (--vk-drop-call).
# Порядок хешей — случайная перестановка; каждый день ротируется её следующий
# элемент, исчерпана — генерируется новая перестановка.
# Состояние — rotate.state (ключ=значение): day, minute, perm, done.
# Случайность — только через awk srand/rand: od в busybox Keenetic отсутствует.
cat > "$CSQTT_DIR/csqtt-rotate-hashes.sh" <<'ROTATE'
#!/bin/sh
# Ротация хешей CSQTT: 1 хеш в сутки, окно 09:30–15:10, случайный порядок.
# Аргумент «force» — ротировать немедленно, игнорируя план/окно (ручной режим).
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

# ── блокировка от параллельных запусков (cron каждые 5 мин) ─────────────────
# lock-каталог пустой (stamp живёт рядом файлом), чтобы rmdir в trap срабатывал;
# протухшая блокировка (>30 мин) забирается принудительно
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
state_write() { # day minute perm done
    printf 'day=%s\nminute=%s\nperm=%s\ndone=%s\n' "$1" "$2" "$3" "$4" > "$STATE.tmp" \
        && mv "$STATE.tmp" "$STATE"
}

gen_perm() { # случайная перестановка 0..N-1 через Фишера–Йетса (awk)
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

# ── дневной план: новая случайная минута на каждый день ────────────────────
day=$(state_get day);   case "$day"   in "") day="";; esac
minute=$(state_get minute)
perm=$(state_get perm)
done_flag=$(state_get done)
if [ "$day" != "$today" ] || [ -z "$minute" ]; then
    # минута так, чтобы следующий 5-минутный тик cron ещё попал в окно
    minute=$(awk -v lo=$window_start -v hi=$((window_end - 4)) \
        'BEGIN { srand(); print lo + int(rand() * (hi - lo + 1)) }')
    # перестановку генерируем только когда исчерпана (порядок живёт днями)
    [ -n "$perm" ] || perm=$(gen_perm "${HASHES:-4}")
    state_write "$today" "$minute" "$perm" "0"
    log "план на $today: ротация в $(printf '%02d:%02d' $((minute / 60)) $((minute % 60))), порядок $perm"
    done_flag=0
fi

# сегодня уже ротировали или время ещё не пришло? (force игнорирует всё это)
if [ "$FORCE" = "0" ]; then
    [ "$done_flag" = "1" ] && exit 0
    [ "$now_min" -lt "$minute" ] && exit 0
    # окно закрылось без ротации (роутер был выключен) — день пропускаем
    [ "$now_min" -gt $window_end ] && exit 0
fi

# ── цель: первый элемент перестановки (0-based индекс строки пула) ─────────
pool_lines=0
[ -f "$POOL" ] && pool_lines=$(wc -l < "$POOL")
if [ "$pool_lines" -eq 0 ]; then
    log "пул пуст — ротация нечего менять (клиент создаст пул при старте)"
    exit 0
fi
[ -n "$perm" ] || perm=$(gen_perm "$pool_lines")
target=$(printf '%s' "$perm" | cut -d, -f1)
rest=$(printf '%s' "$perm" | cut -d, -f2-)
[ "$rest" = "$perm" ] && rest=""   # один элемент — остатка нет
# клэмп: перестановка могла быть шире пула (сменили HASHES без пересоздания)
[ "$target" -ge "$pool_lines" ] && target=$((target % pool_lines))

# ── реген: новый звонок VK ──────────────────────────────────────────────────
TOKEN=$(cat "$DIR/vk_token" 2>/dev/null) || { log "нет vk_token"; exit 1; }
BOOTSTRAP=$(printf '{"token":"%s"}' "$TOKEN" | base64 | tr -d '\n')
new_hash=""; new_id=""
out=$(printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" \
    | "$DIR/csqtt-client" --vk-regen-call --vk-auth-mode "${VK_AUTH_MODE:-api}" \
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

# ── подмена строки пула (target — 0-based, пул — с комментариями можно) ────
old_id=""
if [ "$pool_lines" -gt "$target" ]; then
    old_id=$(sed -n "$((target + 1))p" "$POOL" | cut -d: -f2)
fi
awk -v line=$((target + 1)) -v new="$new_hash:$new_id" '
    NR == line { print new; replaced = 1; next }
    { print }
    END { if (!replaced) print new }   # строка за концом файла — дописать
' "$POOL" > "$POOL.tmp" && mv "$POOL.tmp" "$POOL"

# ── перезапуск клиента на обновлённом пуле ──────────────────────────────────
if [ -x "__INIT_CMD__" ]; then
    touch "$DIR/restarting"   # watchdog не лезет, пока идёт рестарт
    "__INIT_CMD__" restart >>"$LOG" 2>&1
    rm -f "$DIR/restarting"
    log "клиент перезапущен на обновлённом пуле"
else
    log "init-скрипт __INIT_CMD__ не найден — перезапустите клиент вручную"
fi

# ── завершение старого звонка (после рестарта — простой не растёт) ──────────
if [ -n "$old_id" ]; then
    out=$(printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" \
        | "$DIR/csqtt-client" --vk-drop-call "$old_id" --vk-auth-mode "${VK_AUTH_MODE:-api}" \
            --fingerprint "$FINGERPRINT" --device-id "$DEVICE_ID" 2>>"$LOG")
    case "$out" in
        *CALL_DROPPED*) log "старый звонок $old_id завершён" ;;
        *) log "drop $old_id не удался (не критично): $out" ;;
    esac
fi

# ── фиксация: сегодня готово, очередь сдвинута ──────────────────────────────
state_write "$today" "$minute" "$rest" "1"
log "ротация завершена (строка №$((target + 1)) обновлена)"
ROTATE
chmod +x "$CSQTT_DIR/csqtt-rotate-hashes.sh"

# подстановка пути init-скрипта в скрипт ротации (placeholder)
ROTATE_INIT="$INIT_SCRIPT"
sed -i "s|__INIT_CMD__|$ROTATE_INIT|g" "$CSQTT_DIR/csqtt-rotate-hashes.sh" 2>/dev/null \
    || die "не удалось подставить init-путь в скрипт ротации (sed -i недоступен?)"

# ── 11. cron (ротация каждые 5 минут + watchdog каждые 2 минуты) ────────────
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

# ── 11а. watchdog: процесс жив, TUN-интерфейс UP, пинг через TUN ─────────────
# Проверки (по образцу redline-keen): pgrep csqtt-client, ip link show csqtt0 UP,
# ping -I csqtt0. Любой сбой → init-скрипт restart. Отличия от образца:
#  • уважает ручную остановку — init stop/create stopped-флаг, watchdog ждёт;
#  • не лезет, когда идёт рестарт (флаг restarting, ставит init restart и ротация);
#  • работает и в UDP-режиме (без TUN — проверяет только процесс);
#  • OpenWrt: procd сам respawn'ит процесс, watchdog страхует TUN/пинг.
if [ "$CSQTT_WATCHDOG" = "1" ]; then
cat > "$CSQTT_DIR/csqtt-watchdog.sh" <<'WATCHDOG'
#!/bin/sh
# CSQTT watchdog: процесс жив, TUN UP, пинг через TUN. Сбой → restart.
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

# ротация логов (свой + клиентского), как в образце
for log in "$LOG" __LOG_FILE__; do
    [ -f "$log" ] || continue
    FILE_SIZE=$(du -k "$log" 2>/dev/null | awk '{print $1}')
    if [ -n "$FILE_SIZE" ] && [ "$FILE_SIZE" -gt "$MAX_SIZE_KB" ]; then
        tail -n 500 "$log" > "${log}.tmp" && cat "${log}.tmp" > "$log" && rm -f "${log}.tmp"   # НЕ mv: клиент держит лог открытым, mv отвязывает fd
        echo "$(stamp) [WATCHDOG] Лог $log обрезан." >> "$LOG"
    fi
done

# служба остановлена вручную (init stop) — не трогаем
[ -f "$DIR/stopped" ] && exit 0
# идёт рестарт (init restart или ротация) — не мешаем
[ -f "$DIR/restarting" ] && exit 0

# процесс жив?
IS_RUNNING=0
if pgrep csqtt-client >/dev/null 2>&1 || pidof csqtt-client >/dev/null 2>&1; then
    IS_RUNNING=1
fi

# TUN-интерфейс (только в TUN-режиме; пустой TUN_IFACE = UDP-режим)
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

# пинг через TUN (только в TUN-режиме и когда ping есть)
if [ -n "$TUN_IFACE" ] && command -v ping >/dev/null 2>&1; then
    if ! ping -c 2 -W 3 -I "$TUN_IFACE" "$PING_TARGET" >/dev/null 2>&1; then
        echo "$(stamp) [WATCHDOG] Пинг через $TUN_IFACE не прошел. Перезапуск..." >> "$LOG"
        rm -f "$DIR/stopped"
        "$INIT_CMD" restart >> "$LOG" 2>&1
    fi
fi
WATCHDOG
chmod +x "$CSQTT_DIR/csqtt-watchdog.sh"

# подстановка путей (placeholder): init-скрипт и лог клиента (клиентский!)
sed -i -e "s|__INIT_CMD__|$INIT_SCRIPT|g" -e "s|__LOG_FILE__|$CLIENT_LOG_FILE|g" \
    "$CSQTT_DIR/csqtt-watchdog.sh" 2>/dev/null \
    || die "не удалось подставить пути в watchdog (sed -i недоступен?)"

CRON_LINE="*/2 * * * * $CSQTT_DIR/csqtt-watchdog.sh"
grep -q "csqtt-watchdog" "$CRON_FILE" 2>/dev/null \
    || echo "$CRON_LINE" >> "$CRON_FILE"
log "Cron: $CRON_LINE"
fi

# перезапуск cron после добавления строк
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
# CSQTT client (Авторежим ВК, пул хешей)
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
# CSQTT client (Авторежим ВК, пул хешей)
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
        # stopped-флаг: watchdog не должен поднимать вручную остановленное
        touch "\$DIR/stopped"
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
        # restarting-флаг на время рестарта: watchdog не лезет
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

# ── 12а. деинсталлятор (csqtt-uninstall) ─────────────────────────────────────
# Полная очистка: cron-строки ротации+watchdog, init-скрипт, каталог установки.
# Пул vk_pool и VK-звонки: при удалении id звонков теряются — VK уберёт их сам.
if [ "$INIT_STYLE" = "openwrt" ]; then
    UNINST_BIN="/usr/bin/csqtt-uninstall"
else
    UNINST_BIN="/opt/bin/csqtt-uninstall"
fi
mkdir -p "$(dirname "$UNINST_BIN")"
cat > "$CSQTT_DIR/uninstall.sh" <<'UNINSTALL'
#!/bin/sh
# Деинсталляция CSQTT: остановить, вычистить cron, init, файлы.
DIR=$(dirname "$0")
echo "=== Удаление csqtt-client ==="

# cron-строки ротации и watchdog (путь к crontab угадываем по стилю)
CRON_FILE="/opt/var/spool/cron/crontabs/root"
[ -f "$CRON_FILE" ] || CRON_FILE="/etc/crontabs/root"
if [ -f "$CRON_FILE" ]; then
    sed -i '/csqtt-rotate-hashes\.sh/d; /csqtt-watchdog\.sh/d' "$CRON_FILE" 2>/dev/null || true
    for c in /opt/etc/init.d/S10cron /opt/etc/init.d/crond /etc/init.d/cron; do
        [ -x "$c" ] && "$c" restart >/dev/null 2>&1 && break
    done
fi

# остановка и удаление init-скрипта
for init in /opt/etc/init.d/S99csqtt /etc/init.d/csqtt; do
    if [ -x "$init" ]; then
        "$init" stop >/dev/null 2>&1 || true
        rm -f "$init"
    fi
done

killall -9 csqtt-client 2>/dev/null || true
rm -f /var/run/csqtt.pid /opt/var/run/csqtt-client.pid

# самоудаляющиеся обёртки и весь каталог
rm -f /opt/bin/csqtt-uninstall /usr/bin/csqtt-uninstall
rm -rf "$DIR"

echo "Удаление завершено. (VK-звонки пула закроет сам VK по таймауту.)"
UNINSTALL
chmod +x "$CSQTT_DIR/uninstall.sh"

# обёртка в PATH: csqtt-uninstall → uninstall.sh из каталога установки
printf '#!/bin/sh\nexec "%s/uninstall.sh"\n' "$CSQTT_DIR" > "$UNINST_BIN"
chmod +x "$UNINST_BIN"
log "Деинсталлятор: $UNINST_BIN (или $CSQTT_DIR/uninstall.sh)"

# ── 13. запуск ──────────────────────────────────────────────────────────────
if [ "$CSQTT_START" = "1" ]; then
    if [ "$INIT_STYLE" = "openwrt" ]; then
        "$INIT_SCRIPT" restart
        log "Журнал: logread | grep csqtt"
    else
        "$INIT_SCRIPT" restart
        sleep 4
        if grep -q "Пул" "$CLIENT_LOG_FILE" 2>/dev/null; then
            log "Пул хешей создан, воркеры поднимаются"
        else
            warn "Проверьте журнал: $INIT_SCRIPT log"
            tail -n 10 "$CLIENT_LOG_FILE" 2>/dev/null
        fi
    fi
fi

# установка завершена — старому/новому watchdog'у можно работать
rm -f "$CSQTT_DIR/restarting"

log "Готово. Управление: $INIT_SCRIPT start|stop|restart|status|log"
[ "$INIT_STYLE" = "openwrt" ] && log "Управление (OpenWrt): service csqtt start|stop|restart"
log "VK-токен: $VK_TOKEN_FILE · конфиг: $CSQTT_DIR/csqtt.conf · пул: $CSQTT_DIR/vk_pool"
log "Ротация: $CSQTT_DIR/csqtt-rotate-hashes.sh (cron */5; 1 хеш/сутки в 09:30–15:10, случайный порядок)"
[ "$CSQTT_WATCHDOG" = "1" ] && log "Watchdog: $CSQTT_DIR/csqtt-watchdog.sh (cron */2; процесс+TUN+пинг → авторестарт)"
log "Удаление: csqtt-uninstall"
exit 0
