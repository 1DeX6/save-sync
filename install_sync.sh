#!/bin/bash

################################################
# Save Sync Installer v1.4.7
# Облачная синхронизация сохранений и ромов
# Batocera / KNULLI / Recalbox
#
# Команды:
#  install_sync.sh      - установка / обновление
#  install_sync.sh --info          - диагностика
#  install_sync.sh --config   - центр управления
#  install_sync.sh --web         - веб-интерфейс
################################################

# Очистка временных файлов при выходе
trap 'rm -rf /tmp/rclone.zip /tmp/rclone-* /tmp/save_sync_web' EXIT

# --- Глобальные переменные (будут определены после detect_system) ---
BASE=""
CONFIG_FILE=""
LOG_DIR=""
LOG_FILE=""
SCRIPT_DIR=""
BIN_DIR=""
RCLONE_PATH=""
CONFIG_DIR=""
RCLONE_CONF=""
SAVE_DIR=""
ROMS_DIR=""
DOWNLOAD_SCRIPT=""
UPLOAD_SCRIPT=""
DOWNLOAD_ROMS=""
UPLOAD_ROMS=""
ROMS_FILTER_FILE=""

# Файлы статуса (не зависят от системы)
STATUS_FILE="/tmp/save_sync_last_status"
LAST_SYNC_TIME="/tmp/save_sync_last_time"

# --- Настройки по умолчанию (будут переопределены из конфига) ---
SYNC_INTERVAL=0
MAX_RETRIES=3
CONFLICT_KEEP_DAYS=3
NOTIFICATIONS="true"
SKIP_UNCHANGED="true"
SYNC_MODE=""
MIN_FREE_KB=51200
MAX_LOG_SIZE=102400
ROMS_SYNC_DIRS=""
ROMS_SYNC_MEDIA="false"
EXCLUDED_SYSTEMS=""
LOG_ENABLED="true"
LOG_LEVEL="info"
LOG_KEEP_COUNT=3

# --- Переменные для облака ---
REMOTE_NAME="cloud"
REMOTE_FOLDER="GameSaves"
REMOTE=""
REMOTE_ROMS=""
FIRST_SYNC_MARKER=""

# Функция паузы
pause() {
    echo
    read -p "Нажмите Enter для продолжения..."
}

############################################
# Проверка реальной исполняемости rclone
############################################
# На некоторых системах (в частности на Recalbox) раздел
# /recalbox/share смонтирован с флагом noexec (или на нём
# файловая система, не поддерживающая биты исполнения).
# chmod +x в этом случае отрабатывает без ошибки, но сам
# бинарник запустить нельзя ("Permission denied").
# Если это обнаружено — копируем rclone во временный
# каталог в /tmp (tmpfs, всегда исполняемый) и переключаем
# RCLONE_PATH на эту копию. Функцию нужно вызывать заново
# при каждом запуске скрипта, так как /tmp очищается при
# перезагрузке устройства.
ensure_rclone_executable() {
    [ -f "$RCLONE_BIN" ] || return 1

    if "$RCLONE_BIN" version >/dev/null 2>&1; then
        RCLONE_PATH="$RCLONE_BIN"
        return 0
    fi

    mkdir -p /tmp/save_sync_bin 2>/dev/null
    cp -f "$RCLONE_BIN" /tmp/save_sync_bin/rclone 2>/dev/null
    chmod +x /tmp/save_sync_bin/rclone 2>/dev/null

    if /tmp/save_sync_bin/rclone version >/dev/null 2>&1; then
        RCLONE_PATH="/tmp/save_sync_bin/rclone"
        return 0
    fi

    return 1
}

############################################
# Функции работы с конфигом
############################################

create_default_config() {
    cat > "$CONFIG_FILE" << 'EOF'
# ========================================
# Save Sync v1.4.7 - Главный конфиг
# ========================================

# ── НАСТРОЙКИ СИНХРОНИЗАЦИИ ──
# 0 = всегда, 300 = 5 мин, 900 = 15 мин, 3600 = 1 час
SYNC_INTERVAL="0"

# Количество попыток при ошибке
MAX_RETRIES="3"

# Сколько дней хранить в облаке копии сохранений, проигравших конфликт (0 = не хранить)
CONFLICT_KEEP_DAYS="3"

# Уведомления на экране (Batocera, KNULLI): о полученных/отправленных сохранениях и ошибках. true / false
NOTIFICATIONS="true"

# Синхронизация после игры: economy (только при изменениях), fast (после каждой игры) или full (полная)
SYNC_MODE="economy"

# Порог свободного места (КБ) — при котором синхронизация не выполняется
MIN_FREE_KB="51200"

# ── НАСТРОЙКИ РОМОВ ──
ROMS_SYNC_DIRS=""
ROMS_SYNC_MEDIA="false"
EXCLUDED_SYSTEMS=""

# ── НАСТРОЙКИ ЛОГИРОВАНИЯ ──
LOG_ENABLED="true"
MAX_LOG_SIZE="102400"
LOG_LEVEL="info"
LOG_KEEP_COUNT="3"
EOF
    chmod 644 "$CONFIG_FILE"
}

sync_stats_counts() {
    SYNC_OK=$(grep -cE "Сохранения загружены|Выгрузка сохранений|Синхронизация( вручную)? \(" "$LOG_FILE" 2>/dev/null); SYNC_OK=${SYNC_OK:-0}
    # "with changes" = the log line says what was moved: "(sent: 1, ...)"; a plain line or "(нет изменений)" means nothing was transferred
    SYNC_NOTED=$(grep -cE "(Сохранения загружены|Выгрузка сохранений|Синхронизация( вручную)?) \(" "$LOG_FILE" 2>/dev/null); SYNC_NOTED=${SYNC_NOTED:-0}
    SYNC_EMPTY=$(grep -cE "(Сохранения загружены|Выгрузка сохранений|Синхронизация( вручную)?) \((изменений нет|нет изменений)\)" "$LOG_FILE" 2>/dev/null); SYNC_EMPTY=${SYNC_EMPTY:-0}
    SYNC_CHG=$((SYNC_NOTED - SYNC_EMPTY))
    SYNC_NOCHG=$((SYNC_OK - SYNC_CHG))
    SYNC_ERR=$(grep -cE "Ошибка (загрузки|выгрузки) сохранений|Ошибка первой (загрузки|выгрузки)|Ошибка отправки невыгруженных сохранений|Облако недоступно \(нет сети" "$LOG_FILE" 2>/dev/null); SYNC_ERR=${SYNC_ERR:-0}
}

ask_cloud_config() {
    # asks for the cloud service and login, writes an rclone config to $1;
    # $2 = "cancel": a "0 - Cancel" choice is offered (returns 2)
    local CONF_OUT="$1"
    echo ""
    echo "Выберите облачный сервис"
    echo ""
    echo " 1 - Яндекс.Диск"
    echo " 2 - Облако Mail.ru"
    echo " 3 - pCloud"
    echo " 4 - Koofr"
    echo " 5 - Nextcloud / OwnCloud / другой WebDAV-сервер"
    echo " 6 - Fastmail Files"
    echo " 7 - Mega"
    [ "$2" = "cancel" ] && echo " 0 - Отмена"
    echo ""

    if [ "$2" = "cancel" ]; then read -p "Введите номер (0-7): " CHOICE; else read -p "Введите номер (1-7): " CHOICE; fi
    if [ "$2" = "cancel" ] && [ "$CHOICE" = "0" ]; then echo "❌ Отменено. Облако не изменено."; echo ""; return 2; fi

    BACKEND_TYPE="webdav"

    case "$CHOICE" in
    1) URL="https://webdav.yandex.ru"; VENDOR="yandex" ;;
    2) URL="https://webdav.cloud.mail.ru"; VENDOR="other" ;;
    3)
        echo ""
        echo "Для pCloud: логин — email аккаунта, пароль — обычный пароль"
        echo "от аккаунта. Регион (США или Европа) определится сам."
        echo "Если включена двухфакторная защита, подключение может"
        echo "не сработать."
        URL="https://webdav.pcloud.com"; VENDOR="other"
        ;;
    4) URL="https://app.koofr.net/dav/Koofr"; VENDOR="other" ;;
    5)
        echo ""
        read -p "Введите URL вашего WebDAV-сервера: " URL
        echo ""
        echo "Что именно вы используете?"
        echo " 1 - Nextcloud"
        echo " 2 - ownCloud"
        echo " 3 - Другой WebDAV-сервер"
        read -p "Введите номер (1-3): " NC_CHOICE
        case "$NC_CHOICE" in
            2) VENDOR="owncloud" ;;
            3) VENDOR="other" ;;
            *) VENDOR="nextcloud" ;;
        esac
        ;;
    6)
        echo ""
        echo "Для Fastmail: логин — это ваш email на Fastmail, пароль —"
        echo "отдельный пароль приложения с доступом к Files (WebDAV),"
        echo "создать можно в настройках аккаунта Fastmail."
        URL="https://webdav.fastmail.com/"
        VENDOR="fastmail"
        ;;
    7)
        echo ""
        echo "Для Mega: логин — email вашего аккаунта, пароль — обычный"
        echo "пароль от аккаунта."
        echo ""
        echo "⚠️  Если аккаунт Mega совсем новый - зайдите в него хотя бы"
        echo "    один раз через обычный браузер перед этим шагом (Mega"
        echo "    должна сгенерировать ключи шифрования на своей стороне,"
        echo "    иначе подключение не сработает)."
        BACKEND_TYPE="mega"
        ;;
    *) echo "❌ Неверный выбор."; return 1 ;;
    esac

    echo ""
    echo "Введите логин:"
    IFS= read -r YUSER
    echo ""
    echo "Введите пароль (или пароль приложения):"
    IFS= read -rs YPASS
    echo ""

    PASS=$("$RCLONE_PATH" obscure "$YPASS")

    if [ "$BACKEND_TYPE" = "mega" ]; then
        cat > "$CONF_OUT" <<EOF
[$REMOTE_NAME]
type = mega
user = $YUSER
pass = $PASS
EOF
    else
        cat > "$CONF_OUT" <<EOF
[$REMOTE_NAME]
type = webdav
url = $URL
vendor = $VENDOR
user = $YUSER
pass = $PASS
EOF
    fi

    chmod 600 "$CONF_OUT"

    # pCloud keeps accounts in the US or the EU, and each region has its own
    # WebDAV address: if the US one does not let us in, the EU one is tried
    if [ "$CHOICE" = "3" ] && ! "$RCLONE_PATH" --config "$CONF_OUT" lsd "$REMOTE_NAME:" >/dev/null 2>&1; then
        sed -i 's|^url = https://webdav.pcloud.com$|url = https://ewebdav.pcloud.com|' "$CONF_OUT"
        "$RCLONE_PATH" --config "$CONF_OUT" lsd "$REMOTE_NAME:" >/dev/null 2>&1 && echo "ℹ️  pCloud: аккаунт в европейском регионе."
    fi
    return 0
}

cloud_check() {
    # checks the connection with the rclone config $1; on failure the reason
    # (in words, for the user) is left in CLOUD_ERR
    local out
    CLOUD_ERR=""
    out=$("$RCLONE_PATH" --config "$1" lsd "$REMOTE_NAME:" 2>&1 >/dev/null) && return 0
    case "$out" in
        *"401 Unauthorized"*|*"403 Forbidden"*|*[Cc]redentials*|*"password is incorrect"*|*"invalid username or password"*)
            CLOUD_ERR="неверный логин или пароль (для этого сервиса может быть нужен пароль приложения)"
            grep -q "pcloud" "$1" 2>/dev/null && CLOUD_ERR="неверный логин или пароль. Если аккаунт pCloud создан через Google, Apple или Facebook - сначала задайте пароль на сайте pCloud («Забыли пароль?»)" ;;
        *"no such host"*|*"i/o timeout"*|*"connection refused"*|*"network is unreachable"*|*"dial tcp"*)
            CLOUD_ERR="сервер не отвечает - проверьте интернет и адрес сервера" ;;
        *)
            CLOUD_ERR=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1 \
                | sed -E 's#^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]+ [A-Z]+ *: ##' | cut -c1-200) ;;
    esac
    return 1
}

cloud_about() {
    # volume of the cloud as "Total: / Used: / Free:" lines (empty when the service
    # does not report it)
    SS_RCLONE="$RCLONE_PATH" python3 "$ENGINE_SCRIPT" about 2>/dev/null
}

cloud_free_unknown() {
    # what to show when the cloud does not give its volume: pCloud never reports it
    # over WebDAV, for other services it is just unknown at the moment
    if [ "$(cloud_service "$RCLONE_CONF")" = "pCloud" ]; then echo "не сообщается"; else echo "неизвестно"; fi
}

sync_busy() {
    # true while a save sync holds its lock
    ! ( flock -n 8 && flock -n 9 ) 8>/tmp/save_sync_download.lock 9>/tmp/save_sync_upload.lock
}

stop_sync() {
    # stops a running save sync (for example one that hangs on an unreachable cloud):
    # the scripts and the engine get TERM (they log the cancel themselves), their
    # rclone children too - the children keep the lock open otherwise
    local pids kids p i
    pids=$(pgrep -f "sync_engine\.py sync|download_sync\.sh|upload_sync\.sh" 2>/dev/null)
    kids=""
    for p in $pids; do kids="$kids $(pgrep -P "$p" 2>/dev/null)"; done
    # the children are collected first: once a parent is gone they cannot be found by it
    # shellcheck disable=SC2086
    [ -n "$pids" ] && kill -TERM $kids $pids 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        sync_busy || return 0
        sleep 1
    done
    return 1
}

cloud_label() {
    # short name of the cloud service in the rclone config $1
    local f="$1" u url
    [ -f "$f" ] || { echo "не настроено"; return; }
    u=$(sed -n 's/^user = //p' "$f" | head -1)
    url=$(sed -n 's/^url = //p' "$f" | head -1)
    if grep -q "^type = mega" "$f"; then echo "Mega${u:+ ($u)}"; return; fi
    case "$url" in
        *yandex*) echo "Яндекс.Диск${u:+ ($u)}" ;;
        *mail.ru*) echo "Облако Mail.ru${u:+ ($u)}" ;;
        *pcloud*) echo "pCloud${u:+ ($u)}" ;;
        *koofr*) echo "Koofr${u:+ ($u)}" ;;
        *fastmail*) echo "Fastmail${u:+ ($u)}" ;;
        *) echo "WebDAV${url:+ $url}${u:+ ($u)}" ;;
    esac
}

cloud_service() {
    # just the service name (no login) of the rclone config $1
    cloud_label "$1" | sed 's/ ([^)]*)$//'
}

cloud_header_label() {
    # the service name as the label of the cloud line in the menu header, padded
    # by hand to the column of the other lines (a shell cannot count Cyrillic letters reliably)
    case "$(cloud_service "$RCLONE_CONF")" in
        "Яндекс.Диск") echo "Яндекс.Диск:    " ;;
        "Облако Mail.ru") echo "Облако Mail.ru: " ;;
        "pCloud") echo "pCloud:         " ;;
        "Koofr") echo "Koofr:          " ;;
        "Fastmail") echo "Fastmail:       " ;;
        "Mega") echo "Mega:           " ;;
        WebDAV*) echo "WebDAV:         " ;;
        *) echo "Облако:         " ;;
    esac
}

notify_label() {
    if [ "${NOTIFICATIONS:-true}" = "false" ]; then echo "выключены"; else echo "включены"; fi
}

sync_mode_label() {
    case "${SYNC_MODE:-economy}" in
        full) echo "полная" ;;
        fast) echo "после каждой игры" ;;
        *) echo "только при изменениях" ;;
    esac
}

keep_days_label() {
    if [ "${CONFLICT_KEEP_DAYS:-3}" = "0" ]; then echo "не хранить"; else echo "${CONFLICT_KEEP_DAYS:-3} дн."; fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # Безопасная загрузка конфига - читаем построчно
        while IFS='=' read -r key value; do
            # Пропускаем комментарии и пустые строки
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            
            # Убираем пробелы и кавычки
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs | sed -e 's/^"//' -e 's/"$//')
            
            # Присваиваем переменную
            case "$key" in
                SYNC_INTERVAL) SYNC_INTERVAL="$value" ;;
                MAX_RETRIES) MAX_RETRIES="$value" ;;
                CONFLICT_KEEP_DAYS) CONFLICT_KEEP_DAYS="$value" ;;
                NOTIFICATIONS) NOTIFICATIONS="$value" ;;
                SKIP_UNCHANGED) SKIP_UNCHANGED="$value" ;;
                SYNC_MODE) SYNC_MODE="$value" ;;
                MIN_FREE_KB) MIN_FREE_KB="$value" ;;
                ROMS_SYNC_DIRS) ROMS_SYNC_DIRS="$value" ;;
                ROMS_SYNC_MEDIA) ROMS_SYNC_MEDIA="$value" ;;
                EXCLUDED_SYSTEMS) EXCLUDED_SYSTEMS="$value" ;;
                LOG_ENABLED) LOG_ENABLED="$value" ;;
                MAX_LOG_SIZE) MAX_LOG_SIZE="$value" ;;
                LOG_LEVEL) LOG_LEVEL="$value" ;;
                LOG_KEEP_COUNT) LOG_KEEP_COUNT="$value" ;;
            esac
        done < "$CONFIG_FILE"
        case "$SYNC_MODE" in
            full|fast|economy) ;;
            *) if [ "$SKIP_UNCHANGED" = "false" ]; then SYNC_MODE="full"; else SYNC_MODE="economy"; fi ;;
        esac
        return 0
    else
        create_default_config
        # После создания конфига загружаем его безопасно
        load_config
        return 1
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# ========================================
# Save Sync v1.4.7 - Главный конфиг
# ========================================

# ── НАСТРОЙКИ СИНХРОНИЗАЦИИ ──
SYNC_INTERVAL="$SYNC_INTERVAL"
MAX_RETRIES="$MAX_RETRIES"
CONFLICT_KEEP_DAYS="$CONFLICT_KEEP_DAYS"
NOTIFICATIONS="${NOTIFICATIONS:-true}"
SYNC_MODE="${SYNC_MODE:-economy}"
MIN_FREE_KB="$MIN_FREE_KB"

# ── НАСТРОЙКИ РОМОВ ──
ROMS_SYNC_DIRS="$ROMS_SYNC_DIRS"
ROMS_SYNC_MEDIA="$ROMS_SYNC_MEDIA"
EXCLUDED_SYSTEMS="$EXCLUDED_SYSTEMS"

# ── НАСТРОЙКИ ЛОГИРОВАНИЯ ──
LOG_ENABLED="$LOG_ENABLED"
MAX_LOG_SIZE="$MAX_LOG_SIZE"
LOG_LEVEL="$LOG_LEVEL"
LOG_KEEP_COUNT="$LOG_KEEP_COUNT"
EOF
    chmod 644 "$CONFIG_FILE"
}

############################################
# Автоопределение системы
############################################

detect_system() {
    # 1. Проверяем через /etc/os-release
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        case "$ID" in
            batocera)
                SYSTEM="Batocera"
                BASE="/userdata/system"
                SAVE_DIR="/userdata/saves"
                ROMS_DIR="/userdata/roms"
                return 0
                ;;
            recalbox)
                SYSTEM="Recalbox"
                BASE="/recalbox/share/system"
                SAVE_DIR="/recalbox/share/saves"
                ROMS_DIR="/recalbox/share/roms"
                return 0
                ;;
            arkos|emuelec)
                echo "❌ Обнаружена система ArkOS/EmuELEC."
                echo ""
                echo "К сожалению, ArkOS и EmuELEC больше не поддерживаются этим скриптом:"
                echo "на этих системах папка сохранений совпадает с папкой ромов, из-за"
                echo "чего синхронизация 'сохранений' попыталась бы выгрузить в облако"
                echo "всю вашу коллекцию ромов целиком."
                echo ""
                echo "Поддерживаемые системы: Batocera, KNULLI, Recalbox."
                exit 1
                ;;
            knulli)
                SYSTEM="KNULLI"
                BASE="/userdata/system"
                SAVE_DIR="/userdata/saves"
                ROMS_DIR="/userdata/roms"
                return 0
                ;;
        esac
    fi
    
    # 2. Проверка через файлы KNULLI
    if [ -f "/usr/share/knulli/knulli.version" ] || [ -f "/etc/knulli-release" ] || [ -f "/boot/knulli" ]; then
        SYSTEM="KNULLI"
        BASE="/userdata/system"
        SAVE_DIR="/userdata/saves"
        ROMS_DIR="/userdata/roms"
        return 0
    fi
    
    # 3. Проверка на Batocera
    if [ -f "/boot/batocera" ] || [ -f "/etc/batocera-release" ] || [ -f "/usr/bin/batocera-es-swissknife" ]; then
        SYSTEM="Batocera"
        BASE="/userdata/system"
        SAVE_DIR="/userdata/saves"
        ROMS_DIR="/userdata/roms"
        return 0
    fi

    # 4. ArkOS/EmuELEC больше не поддерживаются - явно сообщаем и выходим,
    # чтобы не проваливаться в generic "система не определена"
    if [ -f "/etc/emuelec-release" ] || [ -d "/storage/.config/emuelec" ] || [ -f "/etc/arkos-release" ] || [ -f "/opt/.arkos" ]; then
        echo "❌ Обнаружена система ArkOS/EmuELEC."
        echo ""
        echo "К сожалению, ArkOS и EmuELEC больше не поддерживаются этим скриптом:"
        echo "на этих системах папка сохранений совпадает с папкой ромов, из-за"
        echo "чего синхронизация 'сохранений' попыталась бы выгрузить в облако"
        echo "всю вашу коллекцию ромов целиком."
        echo ""
        echo "Поддерживаемые системы: Batocera, KNULLI, Recalbox."
        exit 1
    fi
    
    # 5. Проверка на Recalbox
    if [ -f "/etc/recalbox-release" ] || [ -f "/recalbox/recalbox" ]; then
        SYSTEM="Recalbox"
        BASE="/recalbox/share/system"
        SAVE_DIR="/recalbox/share/saves"
        ROMS_DIR="/recalbox/share/roms"
        return 0
    fi
    
    # 6. Проверка по наличию характерных файлов
    if [ -f "/usr/bin/batocera-es-swissknife" ]; then
        SYSTEM="Batocera"
        BASE="/userdata/system"
        SAVE_DIR="/userdata/saves"
        ROMS_DIR="/userdata/roms"
        return 0
    fi
    
    if [ -f "/usr/bin/recalbox" ]; then
        SYSTEM="Recalbox"
        BASE="/recalbox/share/system"
        SAVE_DIR="/recalbox/share/saves"
        ROMS_DIR="/recalbox/share/roms"
        return 0
    fi
    
    # 7. Проверка по наличию папок (как запасной вариант)
    if [ -d "/userdata/saves" ]; then
        if [ -d "/recalbox" ]; then
            SYSTEM="Recalbox"
            BASE="/recalbox/share/system"
            SAVE_DIR="/recalbox/share/saves"
            ROMS_DIR="/recalbox/share/roms"
        elif [ -f "/usr/share/knulli/knulli.version" ]; then
            SYSTEM="KNULLI"
            BASE="/userdata/system"
            SAVE_DIR="/userdata/saves"
            ROMS_DIR="/userdata/roms"
        elif [ -f "/boot/batocera" ] || [ -f "/usr/bin/batocera-es-swissknife" ]; then
            SYSTEM="Batocera"
            BASE="/userdata/system"
            SAVE_DIR="/userdata/saves"
            ROMS_DIR="/userdata/roms"
        else
            SYSTEM="Batocera/KNULLI"
            BASE="/userdata/system"
            SAVE_DIR="/userdata/saves"
            ROMS_DIR="/userdata/roms"
        fi
        return 0
    fi
    
    if [ -d "/recalbox/share/saves" ]; then
        SYSTEM="Recalbox"
        BASE="/recalbox/share/system"
        SAVE_DIR="/recalbox/share/saves"
        ROMS_DIR="/recalbox/share/roms"
        return 0
    fi
    
    # Система не определена
    return 1
}

# Запускаем определение системы
if detect_system; then
    echo "✅ Определена система: $SYSTEM"
    
    # Получаем IP-адрес для отображения (глобально)
    IP_ADDR=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR="localhost"
    fi
    
    # На Batocera/KNULLI раздел с install_sync.sh обычно ext4 - "bash"
    # перед командой не нужен. На Recalbox раздел может быть смонтирован
    # так, что напрямую файл не запускается (см. fix_recalbox_boot_hook) -
    # поэтому в подсказках для пользователя показываем "bash" только там,
    # где это действительно требуется.
    if [ "$SYSTEM" = "Recalbox" ]; then
        RUN_PREFIX="bash "
    else
        RUN_PREFIX=""
    fi
else
    echo "❌ Система не определена"
    echo ""
    echo "Информация для добавления поддержки:"
    echo "Скопируйте вывод ниже и пришлите на форум 4pda - https://clck.ru/3V3gTJ."
    echo "══════════════════════════════════════════════════════════"
    echo ">>> Сохранения:"
    find / -name "*.srm" -o -name "*.state" -o -name "*.sav" -o -name "*.mcd" -o -name "*.eep" -o -name "*.fla" -o -name "*.mcr" 2>/dev/null | head -10
    echo ""
    echo ">>> /etc/os-release:"
    cat /etc/os-release 2>/dev/null || echo "Файл не найден"
    echo ""
    echo ">>> Доступные папки:"
    ls -la /userdata/ /recalbox/ /roms/ /opt/ /MUOS/ /.userdata/ /storage/ 2>/dev/null
    echo ""
    echo ">>> Все .sh файлы в системных папках:"
    find / \( -path "/userdata" -o -path "/recalbox" -o -path "/opt" -o -path "/MUOS" -o -path "/mnt" -o -path "/storage" \) -name "*.sh" 2>/dev/null | head -15
    echo ""
    echo ">>> Папки для скриптов:"
    ls -la /etc/init.d/*custom* /etc/init.d/*user* 2>/dev/null
    echo ""
    echo ">>> Версия системы:"
    cat /etc/os-release 2>/dev/null | head -5 || cat /etc/release 2>/dev/null || uname -a
    echo ""
    echo ">>> События эмуляторов:"
    ls -la /userdata/system/scripts/ /recalbox/share/system/scripts/ /opt/system/scripts/ 2>/dev/null
    echo "══════════════════════════════════════════════════════════"
    exit 1
fi

# ============================================
# ОПРЕДЕЛЕНИЕ УСТРОЙСТВА
# ============================================

detect_device() {
    # 1. ОПРЕДЕЛЕНИЕ УСТРОЙСТВА
    if [ -z "$DEVICE_NAME" ]; then
        if [ -f "/proc/device-tree/model" ]; then
            DEVICE_NAME=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
        elif [ -f "/sys/firmware/devicetree/base/model" ]; then
            DEVICE_NAME=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
        fi
    fi
    
    if [ -z "$DEVICE_NAME" ] || [ "$DEVICE_NAME" = "неизвестно" ]; then
        case $(uname -m) in
            aarch64) DEVICE_NAME="ARM64 устройство" ;;
            armv7l)  DEVICE_NAME="ARMv7 устройство" ;;
            x86_64)  DEVICE_NAME="x86_64 устройство" ;;
            *)       DEVICE_NAME="неизвестно ($(uname -m))" ;;
        esac
    fi
    
    # 2. ОПРЕДЕЛЕНИЕ ПРОЦЕССОРА (АВТОМАТИЧЕСКИ)
    if [ -z "$DEVICE_CPU" ] || [ "$DEVICE_CPU" = "неизвестно" ]; then
        # Пробуем через /proc/device-tree/compatible
        if [ -f "/proc/device-tree/compatible" ]; then
            COMPATIBLE=$(cat /proc/device-tree/compatible 2>/dev/null | tr -d '\0')
            case "$COMPATIBLE" in
                # Raspberry Pi
                *"bcm2711"*) DEVICE_CPU="BCM2711" ;;
                *"bcm2712"*) DEVICE_CPU="BCM2712" ;;
                *"bcm2837"*) DEVICE_CPU="BCM2837" ;;
                *"bcm2836"*) DEVICE_CPU="BCM2836" ;;
                *"bcm2835"*) DEVICE_CPU="BCM2835" ;;
                # Rockchip
                *"rk3326"*)  DEVICE_CPU="RK3326" ;;
                *"rk3399"*)  DEVICE_CPU="RK3399" ;;
                # Allwinner (Anbernic RG40XX-H)
                *"allwinner,h616"*) DEVICE_CPU="H616" ;;
                *"sun50iw9p1"*)     DEVICE_CPU="H616" ;;
                # Anbernic
                *"h700"*)    DEVICE_CPU="h700" ;;
                *"anbernic,rg40xx"*) DEVICE_CPU="H616" ;;
                *"anbernic"*)        DEVICE_CPU="H616" ;;
            esac
        fi
        
        # Если не определили — пробуем /proc/cpuinfo
        if [ -z "$DEVICE_CPU" ] || [ "$DEVICE_CPU" = "неизвестно" ]; then
            if [ -f "/proc/cpuinfo" ]; then
                DEVICE_CPU=$(grep -m1 "^Hardware" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
                if [ -z "$DEVICE_CPU" ] || [ "$DEVICE_CPU" = "aarch64" ] || [ "$DEVICE_CPU" = "armv7l" ]; then
                    DEVICE_CPU=$(grep -m1 "^model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
                fi
                if [ -z "$DEVICE_CPU" ] || [ "$DEVICE_CPU" = "aarch64" ] || [ "$DEVICE_CPU" = "armv7l" ]; then
                    DEVICE_CPU=$(grep -m1 "^CPU model" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
                fi
                if [ -z "$DEVICE_CPU" ]; then
                    DEVICE_CPU=$(uname -m)
                fi
            else
                DEVICE_CPU=$(uname -m)
            fi
        fi
    fi
    
    # 3. АРХИТЕКТУРА
    if [ -z "$DEVICE_ARCH" ]; then
        DEVICE_ARCH=$(uname -m)
    fi
    
    # 4. ВЕРСИЯ ПРОШИВКИ
    if [ -z "$CFW_VERSION" ] || [ "$CFW_VERSION" = "неизвестно" ]; then
        for RELEASE_FILE in \
            "/etc/knulli-release" \
            "/usr/share/knulli/knulli.version" \
            "/etc/batocera-release" \
            "/usr/share/batocera/batocera.version" \
            "/recalbox/recalbox.version" \
            "/etc/recalbox-release" \
            "/etc/jelos-release"; do
            if [ -f "$RELEASE_FILE" ]; then
                CFW_VERSION=$(cat "$RELEASE_FILE" 2>/dev/null | head -1 | xargs)
                break
            fi
        done
        
        if [ -z "$CFW_VERSION" ] || [ "$CFW_VERSION" = "неизвестно" ]; then
            if [ -f "/etc/os-release" ]; then
                . /etc/os-release
                if [ -n "$VERSION_ID" ]; then
                    CFW_VERSION="$VERSION_ID"
                elif [ -n "$VERSION" ]; then
                    CFW_VERSION="$VERSION"
                fi
            fi
        fi
    fi
    
    # 5. ДОПОЛНИТЕЛЬНАЯ ИНФОРМАЦИЯ
    if [ -z "$CPU_CORES" ]; then
        CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null)
        [ -z "$CPU_CORES" ] && CPU_CORES="неизвестно"
    fi
    
    if [ -z "$CPU_FREQ" ]; then
        if [ -f "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq" ]; then
            CPU_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
            CPU_FREQ="$((CPU_FREQ / 1000)) MHz"
        fi
        [ -z "$CPU_FREQ" ] && CPU_FREQ="неизвестно"
    fi
    
    if [ -z "$DEVICE_TEMP" ]; then
        if [ -f "/sys/class/thermal/thermal_zone0/temp" ]; then
            DEVICE_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
            DEVICE_TEMP="$((DEVICE_TEMP / 1000))°C"
        fi
        [ -z "$DEVICE_TEMP" ] && DEVICE_TEMP="неизвестно"
    fi
    
    if [ -z "$MEM_INFO" ]; then
        MEM_TOTAL=$(grep "MemTotal" /proc/meminfo 2>/dev/null | awk '{print $2}')
        MEM_AVAIL=$(grep "MemAvailable" /proc/meminfo 2>/dev/null | awk '{print $2}')
        if [ -n "$MEM_TOTAL" ] && [ -n "$MEM_AVAIL" ]; then
            MEM_INFO="$((MEM_AVAIL / 1024))/$((MEM_TOTAL / 1024)) MB"
        fi
        [ -z "$MEM_INFO" ] && MEM_INFO="неизвестно"
    fi
}
# Запускаем определение устройства
detect_device

# --- ИНИЦИАЛИЗАЦИЯ ВСЕХ ПУТЕЙ ПОСЛЕ ОПРЕДЕЛЕНИЯ СИСТЕМЫ ---
CONFIG_FILE="$BASE/sync.conf"
LOG_DIR="$BASE/logs"
LOG_FILE="$LOG_DIR/save_sync.log"
SCRIPT_DIR="$BASE/scripts"
BIN_DIR="$BASE/bin"
RCLONE_BIN="$BIN_DIR/rclone"
RCLONE_PATH="$RCLONE_BIN"
CONFIG_DIR="$BASE/.config/rclone"
RCLONE_CONF="$CONFIG_DIR/rclone.conf"
DOWNLOAD_SCRIPT="$BASE/download_sync.sh"
UPLOAD_SCRIPT="$BASE/upload_sync.sh"
DOWNLOAD_ROMS="$BASE/download_roms.sh"
UPLOAD_ROMS="$BASE/upload_roms.sh"
ROMS_FILTER_FILE="$BASE/roms_filter_sync"
# Постоянное состояние синхронизации (переживает перезагрузку, в отличие от /tmp):
# PENDING_UPLOAD=1 - сохранения на устройстве изменились, но ещё не выгружены
# LAST_GOOD_SYNC=<unix-время> - когда устройство и облако последний раз совпадали
STATE_FILE="$BASE/.sync_state"
LINK_SCRIPT="$BASE/link_download.py"
ENGINE_SCRIPT="$BASE/sync_engine.py"

# --- ИНИЦИАЛИЗАЦИЯ ПЕРЕМЕННЫХ ОБЛАКА ---
REMOTE_NAME="cloud"
REMOTE_FOLDER="GameSaves"
REMOTE="$REMOTE_NAME:$REMOTE_FOLDER"
REMOTE_ROMS="$REMOTE_NAME:GameROMs"
# Имя облака обязательно: без "cloud:" rclone считает путь ЛОКАЛЬНЫМ,
# и маркер никогда не попадает в облако.
FIRST_SYNC_MARKER="$REMOTE_NAME:$REMOTE_FOLDER/.first_sync_done"

# Загружаем конфиг
load_config

# Если rclone уже установлен ранее, но раздел смонтирован noexec —
# сразу переключаемся на исполняемую копию во временном каталоге.
ensure_rclone_executable

# Автоопределение архитектуры
SYS_ARCH=$(uname -m)
case "$SYS_ARCH" in
    armv6*|armv7*)  SYS_ARCH="arm" ;;
    aarch64|arm64)  SYS_ARCH="arm64" ;;
    i386|i686)      SYS_ARCH="386" ;;
    x86_64)         SYS_ARCH="amd64" ;;
    *) echo "Архитектура не поддерживается."; exit 1 ;;
esac

RCLONE_URL="https://downloads.rclone.org/rclone-current-linux-${SYS_ARCH}.zip"

# Проверка зависимостей
MISSING=""
for CMD in curl unzip flock; do
    command -v $CMD >/dev/null 2>&1 || MISSING="$MISSING $CMD"
done

if [ -n "$MISSING" ]; then
    echo "Отсутствуют необходимые утилиты:$MISSING"
    echo "Установите вручную и запустите скрипт снова."
    exit 1
fi

############################################
# Функции
############################################

rotate_log() {
    # Загружаем конфиг для получения MAX_LOG_SIZE
    load_config
    
    mkdir -p "$LOG_DIR" || return 1
    if [ -f "$LOG_FILE" ] && [ $(wc -c < "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
    fi
}

log_msg() {
    # Проверяем включено ли логирование
    if [ "$LOG_ENABLED" != "true" ]; then
        return 0
    fi
    
    rotate_log
    echo "$(date '+%d.%m %H:%M:%S') $1" >> "$LOG_FILE"
}

save_status() {
    echo "$1 $(date +%s)" > "$STATUS_FILE"
}

download_rclone() {
    curl -fsSL -o /tmp/rclone.zip "$RCLONE_URL"
    [ ! -f /tmp/rclone.zip ] && { echo "Ошибка скачивания rclone."; return 1; }
    unzip -o /tmp/rclone.zip -d /tmp || { echo "Ошибка распаковки rclone."; return 1; }
    DIR_NAME=$(find /tmp -maxdepth 1 -type d -name "rclone-*-linux-${SYS_ARCH}" 2>/dev/null | head -1)
    [ -z "$DIR_NAME" ] && { echo "Ошибка распаковки rclone."; return 1; }
    cp "$DIR_NAME/rclone" "$RCLONE_BIN" || return 1
    chmod +x "$RCLONE_BIN" || return 1
    ensure_rclone_executable
}

############################################
# Функция определения версии системы
############################################

get_system_version() {
    local SYSTEM_VER="неизвестно"
    
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        if [ -n "$PRETTY_NAME" ]; then
            SYSTEM_VER="$PRETTY_NAME"
        elif [ -n "$VERSION_ID" ]; then
            SYSTEM_VER="$VERSION_ID"
        elif [ -n "$VERSION" ]; then
            SYSTEM_VER="$VERSION"
        fi
    fi
    
    if [ "$SYSTEM" = "Batocera" ]; then
        if [ -f "/etc/batocera-release" ] && [ -s "/etc/batocera-release" ]; then
            local BATOCERA_VER=$(cat /etc/batocera-release 2>/dev/null | head -1)
            [ -n "$BATOCERA_VER" ] && SYSTEM_VER="Batocera $BATOCERA_VER"
        fi
    fi
    
    if [ "$SYSTEM" = "KNULLI" ]; then
        if [ -f "/usr/share/knulli/knulli.version" ]; then
            local KNULLI_VER=$(cat /usr/share/knulli/knulli.version 2>/dev/null | head -1)
            [ -n "$KNULLI_VER" ] && SYSTEM_VER="KNULLI $KNULLI_VER"
        elif [ -f "/etc/knulli-release" ]; then
            local KNULLI_VER=$(cat /etc/knulli-release 2>/dev/null | head -1)
            [ -n "$KNULLI_VER" ] && SYSTEM_VER="KNULLI $KNULLI_VER"
        fi
    fi
    
    if [ "$SYSTEM" = "Recalbox" ]; then
        if [ -f "/recalbox/recalbox.version" ]; then
            local RECALBOX_VER=$(cat /recalbox/recalbox.version 2>/dev/null | head -1 | xargs)
            [ -n "$RECALBOX_VER" ] && SYSTEM_VER="Recalbox $RECALBOX_VER"
        fi
    fi
    
    # Добавляем информацию об устройстве
    if [ -n "$DEVICE_NAME" ] && [ "$DEVICE_NAME" != "неизвестно" ]; then
        SYSTEM_VER="$SYSTEM_VER ($DEVICE_NAME)"
    fi
    
    echo "$SYSTEM_VER"
}

############################################
# create_engine_script - двусторонняя синхронизация сохранений (Python)
############################################

create_engine_script() {
    cat > "$ENGINE_SCRIPT" << 'ENGEOF'
#!/usr/bin/env python3
# Save Sync - two-way save synchronisation (called by download_sync.sh / upload_sync.sh).
#
# Remembers what every save looked like at the last successful sync ("base")
# and compares BOTH sides against it:
#   changed only here      -> uploaded
#   changed only in cloud  -> downloaded (never overwritten by a stale copy)
#   changed on both sides  -> the newer one is kept; the older one can be kept for a
#                             few days in <folder>_conflicts/ (CONFLICT_KEEP_DAYS, 0 = off)
#   deleted here           -> deleted in the cloud
#   deleted on another dev -> deleted here too
#   new on another device  -> downloaded (never deleted as "missing here")
# Nothing is asked: everything is decided automatically.
#
# Also syncs saves of PortMaster ports: roms/ports/<port>/{saves,conf,gamedata}
# (only files that look like saves, see port_accept) -> <folder>/_ports/<port>/.
#
# Usage: sync_engine.py sync [--fast | --mirror] [--web-progress] [--verbose]
#        (--fast: quick sync after a game - see run())
#        sync_engine.py check   (exit 0 = nothing changed on this device since the
#                                last good sync; looks at the local disk only)
# Env:   SS_RCLONE (rclone binary), SS_EXCLUDED ("snes|PortMaster"), SS_RETRIES

import errno
import fcntl
import fnmatch
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta

LANG = "__SS_LANG__"
SAVE_DIR = "__SS_SAVE_DIR__"
ROMS_DIR = "__SS_ROMS_DIR__"
REMOTE = "__SS_REMOTE__"            # cloud:GameSaves
BASE_DIR = "__SS_BASE__"
LOG_FILE = "__SS_LOG_FILE__"
RCLONE_CONF = "__SS_RCLONE_CONF__"
STATE_FILE = "__SS_STATE_FILE__"
SYSTEM = "__SS_SYSTEM__"

BASE_FILE = os.path.join(BASE_DIR, ".sync_base.json")
MANIFEST = ".sync_manifest.json"
CONFLICTS = REMOTE.rstrip("/") + "_conflicts"
PORTS_CLOUD = "_ports"
PORTS_KEY = "PortMaster"                  # one exclusion entry for the saves of all ports
PORT_NOT_GAMES = {"PortMaster", "autoinstall", "images", "videos", "manuals"}
PROGRESS_LOG = "/tmp/save_sync_progress.log"
ENGINE_LOCK = "/tmp/save_sync_engine.lock"
SANE_TIME = 1704067200               # 2024-01-01: clocks before that are not trusted

SKIP_NAMES = [".first_sync_done", ".DS_Store", "Thumbs.db", "desktop.ini", "._*", "*:Zone.Identifier",
              "*.log", "*.cache", ".keep", "*.keep", ".gitkeep", "*.tmp", "*.crdownload",
              MANIFEST, "*.partial", ".ss_tmp*"]
# folders that copying from a Mac, Windows or a NAS leaves behind (lower case): never synced,
# and they do not make a system "in use" (.Trash-1000 and the like are checked by prefix)
JUNK_DIRS = {"__macosx", "@eadir", "#recycle", "$recycle.bin", "system volume information", ".trashes",
             ".spotlight-v100", ".fseventsd", ".documentrevisions-v100", ".stfolder"}
# Big data that some emulators keep in the saves folder next to the saves (Batocera on a PC):
# installed games, updates, add-ons, graphic packs. Only the saves themselves are synced.
HEAVY_PATHS = ("ps3/*dev_hdd0/game/*", "psvita/*ux0/app/*", "psvita/*ux0/patch/*", "psvita/*ux0/addcont/*",
               "wiiu/*usr/title/*", "wiiu/*graphicpacks/*", "3ds/*/title/*/content/*")
SAVE_MAX = 512 * 1024 * 1024        # a bigger file is a disk image or a game, not a save
SKIPPED = {"heavy": set(), "big": {}}
# saves folders of standalone emulators named not like the ROM folder of their system
SAVE_DIR_ROMS = {"dolphin-emu": ("gamecube", "wii", "triforce"), "duckstation": ("psx",),
                 "ymir": ("saturn",), "nanoboyadvance": ("gba",)}
PORT_SAVE_DIRS = ("saves", "conf")
# caches of the graphics driver and of emulators: created by every device for its
# own GPU, useless elsewhere and can grow large - never synced, wherever they are
CACHE_DIRS = {"mesa_shader_cache", "mesa_shader_cache_db", ".cache", "shader_cache", "shadercache"}
PORT_SKIP_DIRS = {"textures", "screenshots", "cache", "shaders", "logs", "tmp", "temp"} | CACHE_DIRS
PORT_SKIP_WORDS = ("settings", "config", "options", "controls", "keymap", "gptk")
PORT_GAMEDATA_EXT = (".ini", ".sav", ".dat", ".json")
PORT_MAX = 10 * 1024 * 1024
PORT_GAMEDATA_MAX = 1024 * 1024
RENAME_MIN = 1024 * 1024                  # renamed in the cloud instead of sent again from this size

MSG = {
    "en": {
        "conflict_local": "Save conflict: {rel} was changed on different devices - kept the newer version from this device",
        "conflict_cloud": "Save conflict: {rel} was changed on different devices - kept the newer version from {dev}",
        "copy_kept": ", the older one is kept for {days} d. in {dir} (it can be restored in the web interface)",
        "restored": "Restored the version of {file} from {dev} ({time}); the previous version is kept with the conflicts",
        "conflict_dropped": "Deleted the conflict copy of {file} ({dev}, {time})",
        "time_unknown": "time unknown",
        "deleted_here": "Removed here (deleted on another device): {rel}",
        "deleted_cloud": "Removed from the cloud: {rel}",
        "sent_file": "Sent: {rel}", "recv_file": "Received: {rel}",
        "renamed": "Renamed in the cloud (not sent again): {old} -> {new}",
        "copied": "Copied in the cloud (not sent again): {old} -> {new}",
        "guard": "Warning: {n} files look deleted at once ({where}) - that looks like a failure, not a deletion; nothing was deleted",
        "where_here": "on this device", "where_cloud": "in the cloud",
        "summary": "Downloaded: {d}, uploaded: {u}, conflicts: {c}, deleted: {x}",
        "n_sent": "sent: {n}", "n_recv": "received: {n}", "n_del": "deleted: {n}", "n_conf": "conflicts: {n}",
        "no_changes": "no changes",
        "st_scan": "Checking the saves on the device", "st_compare": "Comparing with the cloud",
        "st_send": "Sending files: {n}", "st_recv": "Receiving files: {n}",
        "st_delete": "Deleting files: {n}", "st_finish": "Saving the sync state",
        "n_guard": "deletion stopped",
        "n_failed": "not downloaded: {n}",
        "dl_failed": "Not downloaded (the cloud did not give the file, will try again next time): {rel}",
        "other_device": "another device",
        "heavy_skip": "{sys}: installed games, updates and add-ons are not synced - only the saves",
        "big_skip": "Skipped {rel} ({mb} MB): larger than {max} MB - looks like a disk image or an installed game, not a save",
    },
    "ru": {
        "conflict_local": "Конфликт сохранений: {rel} изменён на разных устройствах - оставлена более новая версия с этого устройства",
        "conflict_cloud": "Конфликт сохранений: {rel} изменён на разных устройствах - оставлена более новая версия с {dev}",
        "copy_kept": ", более старая хранится {days} дн. в {dir} (её можно вернуть в веб-интерфейсе)",
        "restored": "Возвращена версия {file} с {dev} ({time}); прежняя версия сохранена в конфликтах",
        "conflict_dropped": "Удалена копия при конфликте: {file} ({dev}, {time})",
        "time_unknown": "время неизвестно",
        "deleted_here": "Удалено здесь (удалено на другом устройстве): {rel}",
        "deleted_cloud": "Удалено из облака: {rel}",
        "sent_file": "Отправлено: {rel}", "recv_file": "Получено: {rel}",
        "renamed": "Переименовано в облаке (без повторной отправки): {old} -> {new}",
        "copied": "Скопировано в облаке (без повторной отправки): {old} -> {new}",
        "guard": "Предупреждение: сразу {n} файлов выглядят удалёнными ({where}) - похоже на сбой, а не на удаление; ничего не удалено",
        "where_here": "на устройстве", "where_cloud": "в облаке",
        "summary": "Скачано: {d}, выгружено: {u}, конфликтов: {c}, удалено: {x}",
        "n_sent": "отправлено: {n}", "n_recv": "получено: {n}", "n_del": "удалено: {n}", "n_conf": "конфликтов: {n}",
        "no_changes": "нет изменений",
        "st_scan": "Проверка сохранений на устройстве", "st_compare": "Сравнение с облаком",
        "st_send": "Отправка файлов: {n}", "st_recv": "Получение файлов: {n}",
        "st_delete": "Удаление файлов: {n}", "st_finish": "Сохранение состояния синхронизации",
        "n_guard": "удаление остановлено",
        "n_failed": "не удалось скачать: {n}",
        "dl_failed": "Не удалось скачать (облако не отдало файл, попробую в следующий раз): {rel}",
        "other_device": "другого устройства",
        "heavy_skip": "{sys}: установленные игры, обновления и дополнения не синхронизируются - только сохранения",
        "big_skip": "Пропущен файл {rel} ({mb} МБ): больше {max} МБ - похоже на образ диска или установленную игру, а не на сохранение",
    },
}

VERBOSE = False
WEB = False
FLAGS = {"guard": False, "full": False}     # the guard worked / the cloud has no space left

FULL_RE = re.compile(r"storagequotaexceeded|insufficient[ _]?(storage|space)|over quota|quota[ _]?(is |was )?(exceeded|reached|exhausted)|quotalimitreached|\b507\b|disk[ _]?full|no space left|not enough (free )?space|storage (is )?full", re.I)
NOT_FULL_RE = re.compile(r"rate[ _]?limit|queries|per minute|per user|too many requests", re.I)


def looks_full(text):
    """Does the rclone error text say that the cloud storage is full (not a request rate limit)?"""
    return any(FULL_RE.search(line) and not NOT_FULL_RE.search(line) for line in (text or "").splitlines())


def keep_days():
    """Days to keep conflict copies (setting CONFLICT_KEEP_DAYS); 0 = no copies."""
    try:
        return max(0, int(os.environ.get("SS_KEEP_DAYS", "3")))
    except ValueError:
        return 3


def t(key, **kw):
    text = MSG.get(LANG, MSG["en"])[key]
    return text.format(**kw) if kw else text


STAGE_FILE = "/tmp/save_sync_stage.json"


def stage(kind, n=0):
    """What the sync is doing now, for the progress bar of the web interface (saves are
    small: most of the time goes to comparing with the cloud, not to the transfer)."""
    if not WEB:
        return
    try:
        tmp = STAGE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"kind": kind, "n": n, "text": t("st_" + kind, n=n)}, f, ensure_ascii=False)
        os.replace(tmp, STAGE_FILE)
    except OSError:
        pass


def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write("%s %s\n" % (datetime.now().strftime("%d.%m %H:%M:%S"), msg))
    except OSError:
        pass
    if VERBOSE:
        print(msg)


class SyncError(Exception):
    pass


# ================================================================== rclone
def rclone_cmd(args):
    # повторы целиком делает движок (MAX_RETRIES), rclone не повторяет сам:
    # иначе при плохой сети попытки умножаются и синхронизация висит минутами
    return ([os.environ.get("SS_RCLONE") or "rclone", "--config", RCLONE_CONF] + args +
            ["--retries", "1", "--contimeout", "15s", "--timeout", "2m"])


TIMING = os.environ.get("SS_TIMING") == "1"
TIMES = {}


TIMES_LOCK = threading.Lock()


def timed(name, t0):
    with TIMES_LOCK:
        e = TIMES.setdefault(name, [0, 0.0])
        e[0] += 1
        e[1] += time.monotonic() - t0


def rclone(args, check=True, stats=False, timeout=3600):
    """Same as _rclone; with SS_TIMING=1 (LOG_LEVEL="debug") it also counts the time per rclone command."""
    t0 = time.monotonic()
    try:
        return _rclone(args, check, stats, timeout)
    finally:
        if TIMING:
            timed(args[0], t0)


def _rclone(args, check=True, stats=False, timeout=3600):
    """-> (returncode, stdout). Transfers show progress (terminal or Web UI)."""
    cmd = rclone_cmd(args)
    retries = max(1, int(os.environ.get("SS_RETRIES") or "3"))
    for attempt in range(retries):
        if stats and WEB:
            with open(PROGRESS_LOG, "w") as err:
                r = subprocess.run(cmd + ["--stats", "1s", "--stats-log-level", "NOTICE", "--use-json-log"],
                                   stdout=subprocess.DEVNULL, stderr=err, timeout=timeout)
            out = ""
        elif stats and VERBOSE:
            r = subprocess.run(cmd + ["--progress"], timeout=timeout)
            out = ""
        else:
            r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
            out = r.stdout.decode("utf-8", "replace")
        if r.returncode == 0 or not check:
            return r.returncode, out
        err_text = r.stderr.decode("utf-8", "replace") if getattr(r, "stderr", None) else ""
        if not err_text and stats and WEB:
            try:
                with open(PROGRESS_LOG) as ef:
                    err_text = ef.read()[-4000:]
            except OSError:
                pass
        if looks_full(err_text):
            FLAGS["full"] = True
        if attempt < retries - 1:
            time.sleep(10)
    raise SyncError("rclone %s: code %d" % (args[0], r.returncode))


def cloud_list(remote):
    """{rel: (size, modtime-string)}; {} if the folder does not exist yet."""
    rc, out = rclone(["lsjson", "-R", "--files-only", "--no-mimetype", remote], check=False)
    if rc == 3:           # directory not found
        return {}
    if rc != 0:
        rc, out = rclone(["lsjson", "-R", "--files-only", "--no-mimetype", remote])
    try:
        items = json.loads(out or "[]")
    except ValueError:
        raise SyncError("lsjson: bad output")
    return {i["Path"]: (i.get("Size", -1), i.get("ModTime", "")) for i in items}


def refresh_listing(root, C, uploaded, deleted):
    """The cloud listing after our own changes: only the files we just sent are asked
    for again (a full listing of a big cloud folder takes long); if that does not
    work out, the whole folder is listed again."""
    C2 = {r: v for r, v in C.items() if r not in deleted}
    if uploaded:
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
            f.write("\n".join(sorted(uploaded)) + "\n")
        try:
            rc, out = rclone(["lsjson", "-R", "--files-only", "--no-mimetype", "--files-from-raw", f.name, root.remote], check=False)
        finally:
            os.remove(f.name)
        try:
            got = {i["Path"]: (i.get("Size", -1), i.get("ModTime", "")) for i in json.loads(out or "[]")} if rc == 0 else {}
        except (ValueError, KeyError, TypeError):
            got = {}
        if all(r in got for r in uploaded):
            for r in uploaded:
                if root.accept(r, got[r][0]):
                    C2[r] = got[r]
                else:
                    C2.pop(r, None)
            return C2
        return {r: v for r, v in cloud_list(root.remote).items() if root.accept(r, v[0])}
    return C2


def cloud_list_files(root, rels):
    """({rel: (size, modtime)}, folder_found) for the given files only (missing ones are
    left out). folder_found=False: the cloud said the whole folder does not exist."""
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
        f.write("\n".join(sorted(rels)) + "\n")
    try:
        args = ["lsjson", "-R", "--files-only", "--no-mimetype", "--files-from-raw", f.name, root.remote]
        rc, out = rclone(args, check=False)
        if rc == 3:           # the folder does not exist in the cloud
            return {}, False
        if rc != 0:
            rc, out = rclone(args)
    finally:
        os.remove(f.name)
    try:
        return {i["Path"]: (i.get("Size", -1), i.get("ModTime", "")) for i in json.loads(out or "[]")}, True
    except (ValueError, KeyError, TypeError):
        raise SyncError("lsjson: bad output")


def fast_candidates(root, base, L, M):
    """Files the quick sync looks at: changed or deleted here, the ones the manifest says
    another device changed or added, and the ones missing from the manifest (deleted on
    another device - or a manifest that is not complete: the cloud itself is asked about
    all of them, and only a file the cloud really does not have is deleted here)."""
    cand = set()
    for rel, l in L.items():
        b = base.get(rel)
        if not b or b.get("h") != l["h"]:
            cand.add(rel)
    cand.update(rel for rel in base if rel not in L)
    for rel, m in M.items():
        if not isinstance(m, dict) or not m.get("h") or not root.accept(rel, m.get("s")):
            continue
        b = base.get(rel)
        if not b or b.get("h") != m["h"]:
            cand.add(rel)
    cand.update(rel for rel in base if rel not in M)
    return cand


def download_some(remote, dest, rels, stats=False, want=None):
    """Downloads the files; returns the ones that did not arrive. The cloud sometimes
    refuses single files for a while (Yandex: "503 Service Unavailable"): one such file
    must not stop the whole sync or hang it for minutes - it is tried once more and
    then left for the next sync."""
    left = list(rels)
    for attempt in range(2):
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
            f.write("\n".join(left) + "\n")
        try:
            rc, _ = rclone(["copy", remote, dest, "--files-from-raw", f.name, "--ignore-times",
                            "--low-level-retries", "3"], check=False, stats=stats)
        finally:
            os.remove(f.name)
        if rc == 0:
            return []
        def arrived(r):
            p = os.path.join(dest, *r.split("/"))
            # a file that was here before counts only with the expected content
            return os.path.isfile(p) and (not (want or {}).get(r) or md5(p) == want[r])
        left = [r for r in left if not arrived(r)]
        if not left:
            return []
        if attempt == 0:
            time.sleep(5)
    return left


def parse_time(s):
    """rclone ModTime (RFC3339, any precision) -> epoch seconds, 0 if unknown."""
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)?", s or "")
    if not m:
        return 0
    y, mo, d, h, mi, se, tz = m.groups()
    off = timedelta(0)
    if tz and tz != "Z":
        sign = 1 if tz[0] == "+" else -1
        off = sign * timedelta(hours=int(tz[1:3]), minutes=int(tz[4:6]))
    dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(se), tzinfo=timezone.utc) - off
    return int(dt.timestamp())


# ================================================================== roots
def excluded():
    return {x.strip() for x in (os.environ.get("SS_EXCLUDED") or "").split("|") if x.strip()}


def skip_name(name):
    return any(fnmatch.fnmatch(name, p) for p in SKIP_NAMES)


def junk_dir(name):
    low = name.lower()
    return low in JUNK_DIRS or low.startswith(".trash-")


def skip_path(parts):
    """Leftovers of an interrupted run, cache folders and junk folders are never synced."""
    return any(p.startswith(".ss_tmp") or p.lower() in CACHE_DIRS or junk_dir(p) for p in parts[:-1])


QUIET_EXT = (".png", ".jpg", ".jpeg", ".bmp")


def quiet_in_log(rel):
    """Pictures (save-state thumbnails like game.state.png, screenshots) are synced
    like everything else, but not mentioned in the log: only the saves themselves."""
    return rel.lower().endswith(QUIET_EXT)


class Root:
    def __init__(self, name, local, remote, accept):
        self.name, self.local, self.remote, self.accept = name, local, remote, accept

    def label(self, rel):
        return rel if self.name == "saves" else "%s/%s" % (self.name, rel)

    def conflict_path(self, rel, tag):
        sub = rel if self.name == "saves" else "%s/%s/%s" % (PORTS_CLOUD, self.name[len("ports/"):], rel)
        return "%s/%s.%s" % (CONFLICTS, sub, tag)


# What in a ROM folder is not a game. Not .png and .json: PICO-8 games are .p8.png pictures.
NOT_ROMS_EXT = (".xml", ".txt", ".dat", ".log", ".cache", ".jpg", ".jpeg", ".gif", ".bmp", ".webp",
                ".mp4", ".avi", ".mkv", ".webm", ".pdf", ".nfo", ".md", ".db", ".tmp", ".bak",
                ".crdownload", ".partial")
NOT_ROMS_NAMES = {".ds_store", "thumbs.db", "desktop.ini", ".keep", ".gitkeep", ".localized"}
# scraped media (Batocera, KNULLI, ES-DE, Skraper)
NOT_ROMS_DIRS = {"images", "media", "videos", "manuals", "bezels", "covers", "backcovers", "3dboxes", "fanart",
                 "marquees", "miximages", "miximages_v2", "physicalmedia", "screenshots", "thumbnails",
                 "titlescreens", "wheel", "boxart", "snaps", "downloaded_images", "downloaded_videos",
                 "downloaded_media"}


def _not_a_game(name):
    low = name.lower()
    return (low.endswith(NOT_ROMS_EXT) or low in NOT_ROMS_NAMES or low.startswith("._")
            or low.endswith(":zone.identifier"))


def _has_files(path, skip_media):
    for root, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if not junk_dir(d) and d.lower() not in CACHE_DIRS
                   and not (skip_media and (d.lower() in NOT_ROMS_DIRS or d.startswith(".")))]
        if any(not _not_a_game(f) for f in files):
            return True
    return False


def make_system_active():
    """A system's saves are synced only if the system is in use on this device: it has
    games (ROMs) here, or its saves are already here. Saves of systems this device has
    no games for are not downloaded (they can be big); once ROMs or saves appear
    here, the system joins the next sync and the cloud saves come down first."""
    cache = {}
    roms_known = os.path.isdir(ROMS_DIR)

    def active(system):
        if system not in cache:
            ok = not roms_known             # no ROMs folder to judge by: sync everything
            if not ok:
                for name in (system,) + SAVE_DIR_ROMS.get(system, ()):
                    d = os.path.join(ROMS_DIR, name)
                    if os.path.isdir(d) and _has_files(d, True):
                        ok = True
                        break
            if not ok:
                d = os.path.join(SAVE_DIR, system)
                ok = os.path.isdir(d) and _has_files(d, False)
            cache[system] = ok
        return cache[system]
    return active


def saves_accept(ex):
    active = make_system_active()

    def accept(rel, size):
        parts = rel.split("/")
        if parts[0] in ex or (len(parts) > 1 and parts[0] == PORTS_CLOUD) or skip_path(parts):
            return False
        if len(parts) > 1 and not active(parts[0]):
            return False
        if skip_name(parts[-1]):
            return False
        if len(parts) > 2 and any(fnmatch.fnmatchcase(rel.lower(), p) for p in HEAVY_PATHS):
            SKIPPED["heavy"].add(parts[0])
            return False
        if size is not None and size > SAVE_MAX:
            SKIPPED["big"][rel] = size
            return False
        return True
    return accept


SKIPPED_FILE = os.path.join(BASE_DIR, ".sync_skipped.json")


def note_skipped():
    """Says once in the log what is not synced on purpose (installed games of PS3, PS Vita,
    Wii U, 3DS; files too big for a save), and again only in the detailed log mode."""
    seen = set(load_json(SKIPPED_FILE, []))
    now = {"heavy:" + x for x in SKIPPED["heavy"]} | {"big:" + x for x in SKIPPED["big"]}
    for key in sorted(now):
        if key in seen and not VERBOSE:
            continue
        kind, what = key.split(":", 1)
        if kind == "heavy":
            log(t("heavy_skip", sys=what))
        else:
            log(t("big_skip", rel=what, mb=SKIPPED["big"][what] // (1024 * 1024), max=SAVE_MAX // (1024 * 1024)))
    if now - seen:
        save_json(SKIPPED_FILE, sorted(seen | now))


def port_accept(rel, size):
    """What of a port folder looks like a save (checked on real PortMaster ports:
    saves/<...>, conf/godot/app_userdata/<game>/..., gamedata/savedata.ini)."""
    parts = rel.split("/")
    name = parts[-1]
    low = name.lower()
    if skip_path(parts) or skip_name(name) or low in ("log.txt", ".gitkeep") or low.endswith(".log"):
        return False
    stem = os.path.splitext(low)[0]
    if any(w in stem for w in PORT_SKIP_WORDS):
        return False                    # device-specific settings (resolution, controls)
    if parts[0] in PORT_SAVE_DIRS and len(parts) > 1:
        if any(p.lower() in PORT_SKIP_DIRS for p in parts[1:-1]):
            return False
        return size is None or size < 0 or size <= PORT_MAX
    if parts[0] == "gamedata" and len(parts) == 2:
        return low.endswith(PORT_GAMEDATA_EXT) and (size is None or size < 0 or size <= PORT_GAMEDATA_MAX)
    return False


def roots():
    ex = excluded()
    out = [Root("saves", SAVE_DIR, REMOTE, saves_accept(ex))]
    if PORTS_KEY in ex:
        return out                      # "PortMaster" excluded: no port saves at all
    ports = os.path.join(ROMS_DIR, "ports")
    try:
        names = sorted(os.listdir(ports))
    except OSError:
        names = []
    for n in names:
        d = os.path.join(ports, n)
        if not os.path.isdir(d) or os.path.islink(d) or n.startswith(".") or n in PORT_NOT_GAMES:
            continue
        if not any(os.path.isdir(os.path.join(d, s)) for s in PORT_SAVE_DIRS + ("gamedata",)):
            continue
        out.append(Root("ports/" + n, d, "%s/%s/%s" % (REMOTE, PORTS_CLOUD, n), port_accept))
    return out


# ================================================================== local side
def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def local_list(root, base):
    t0 = time.monotonic()
    try:
        return _local_list(root, base)
    finally:
        if TIMING:
            timed("scan", t0)


def _local_list(root, base):
    """{rel: {"h","s","m"}}; the hash is reused when size and mtime did not change."""
    out = {}
    if not os.path.isdir(root.local):
        return out
    for dp, dns, fns in os.walk(root.local):
        dns[:] = [d for d in dns if not os.path.islink(os.path.join(dp, d))]
        for fn in fns:
            full = os.path.join(dp, fn)
            if os.path.islink(full):
                continue
            rel = os.path.relpath(full, root.local).replace(os.sep, "/")
            try:
                st = os.stat(full)
            except OSError:
                continue
            if not root.accept(rel, st.st_size):
                continue
            b = base.get(rel)
            m = int(st.st_mtime)
            ns = st.st_mtime_ns
            # the stored hash is reused only for a file untouched since then; a file
            # written in the last seconds is always re-read (coarse FAT timestamps)
            fresh = abs(time.time() - st.st_mtime) < 10
            if b and b.get("h") and b.get("s") == st.st_size and b.get("ns") == ns and not fresh:
                h = b["h"]
            else:
                h = md5(full)
            out[rel] = {"h": h, "s": st.st_size, "m": m, "ns": ns}
    return out


def unchanged_here():
    """True when nothing on this device changed since the last good sync: the same saves,
    with the same size and modification time as in the base (a file whose time differs is
    read and compared by content). Looks at the local disk only - no cloud, no manifest.
    Any doubt gives False, and then the normal sync runs."""
    base_roots = load_json(BASE_FILE, {}).get("roots")
    if not isinstance(base_roots, dict) or not base_roots:
        return False                    # no successful sync yet
    now = time.time()
    for root in roots():
        base = base_roots.get(root.name) or {}
        seen = 0
        if os.path.isdir(root.local):
            for dp, dns, fns in os.walk(root.local):
                dns[:] = [d for d in dns if not os.path.islink(os.path.join(dp, d))]
                for fn in fns:
                    full = os.path.join(dp, fn)
                    if os.path.islink(full):
                        continue
                    rel = os.path.relpath(full, root.local).replace(os.sep, "/")
                    try:
                        st = os.stat(full)
                    except OSError:
                        return False
                    if not root.accept(rel, st.st_size):
                        continue
                    b = base.get(rel)
                    if not b or not b.get("h"):
                        return False    # a new file
                    if b.get("s") == st.st_size and b.get("ns") == st.st_mtime_ns and abs(now - st.st_mtime) >= 10:
                        seen += 1
                        continue
                    try:
                        same = md5(full) == b["h"]      # rewritten by the emulator with the same content?
                    except OSError:
                        return False
                    if not same:
                        return False
                    seen += 1
        if seen != len(base):
            return False                # something was deleted here (or the filters changed)
    return True


# ================================================================== state
def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


def device_name():
    """Short, stable name of this device (for conflict copies): <system>-<4 hex>."""
    name = ""
    try:
        with open(STATE_FILE) as f:
            for line in f:
                if line.startswith("DEVICE_NAME="):
                    name = line.split("=", 1)[1].strip()
    except OSError:
        pass
    if name:
        return name
    sysname = re.sub(r"[^A-Za-z0-9]+", "", SYSTEM.split("/")[0]) or "device"
    name = "%s-%04x" % (sysname, random.randint(0, 0xFFFF))
    try:
        with open("/tmp/save_sync_state.lock", "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            with open(STATE_FILE, "a") as f:
                f.write("DEVICE_NAME=%s\n" % name)
    except OSError:
        pass
    return name


# ================================================================== the sync
def run(fast=False):
    now = int(time.time())
    clock_ok = now > SANE_TIME
    dev = device_name()
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S") if clock_ok else "time-unknown-%d" % random.randint(0, 99999)
    base_all = load_json(BASE_FILE, {})
    base_roots = base_all.get("roots", {})
    new_base_roots = {}
    total = {"d": 0, "u": 0, "c": 0, "x": 0, "f": 0}

    # the cloud folder is listed once (it holds the port folders too) and the manifests of
    # all folders are read at the same time: every read is a request of its own
    all_roots = roots()
    stage("compare")

    # Quick sync (after a game, setting "Sync after a game" = quick/economy): no full
    # listing of the cloud folder. What other devices changed, added or deleted comes
    # from the manifests; the cloud itself is asked only about those files and the ones
    # changed here (a file is deleted here only when the cloud confirms it is gone).
    # Anything unusual - first sync, a folder without a manifest - gives the full sync.
    manifest_reads = None
    if fast:
        if not base_roots:
            fast = False
        else:
            def read_any_manifest(root):
                if not base_roots.get(root.name):
                    return 1, ""        # nothing synced in this folder yet: new saves there come with the full sync
                return rclone(["cat", root.remote + "/" + MANIFEST], check=False)
            if len(all_roots) > 1:
                with ThreadPoolExecutor(max_workers=4) as pool:
                    manifest_reads = dict(zip([r.name for r in all_roots], pool.map(read_any_manifest, all_roots)))
            else:
                manifest_reads = {r.name: read_any_manifest(r) for r in all_roots}
            for root in all_roots:
                if root.name not in base_roots or (manifest_reads[root.name][0] != 0 and base_roots[root.name]):
                    fast = False
                    break
    listings = {r.name: {} for r in all_roots}
    saves_listing = None
    for root in ([] if fast else all_roots):
        if root.name == "saves":
            saves_listing = cloud_list(root.remote)
            listings[root.name] = saves_listing
        elif saves_listing is not None and root.remote.startswith(REMOTE + "/"):
            prefix = root.remote[len(REMOTE) + 1:] + "/"
            listings[root.name] = {r[len(prefix):]: v for r, v in saves_listing.items() if r.startswith(prefix)}
        else:
            listings[root.name] = cloud_list(root.remote)

    def read_manifest(root):
        if MANIFEST in listings[root.name]:
            return rclone(["cat", root.remote + "/" + MANIFEST], check=False)
        return 1, ""                    # the listing shows there is no manifest yet

    if fast:
        pass                            # already read above
    elif len(all_roots) > 1:
        with ThreadPoolExecutor(max_workers=4) as pool:
            manifest_reads = dict(zip([r.name for r in all_roots], pool.map(read_manifest, all_roots)))
    else:
        manifest_reads = {r.name: read_manifest(r) for r in all_roots}

    for root in all_roots:
        base = base_roots.get(root.name, {})
        L = local_list(root, base)
        if root.name == "saves" and not fast:
            note_skipped()
        listing = listings[root.name]
        C = {r: v for r, v in listing.items() if root.accept(r, v[0])}
        rc, mout = manifest_reads[root.name]
        try:
            M = json.loads(mout) if rc == 0 and mout.strip() else {}
        except ValueError:
            M = {}
        M = M.get("files", {}) if isinstance(M, dict) else {}
        cand = None
        cloud_seen = True
        if fast:
            cand = fast_candidates(root, base, L, M)
            listed, cloud_seen = cloud_list_files(root, cand) if cand else ({}, True)
            C = {r: v for r, v in listed.items() if root.accept(r, v[0])}

        # ---- what is in the cloud, by CONTENT (cloud file dates are not reliable:
        # some services report another date later, some none at all).
        # 1) the manifest written by Save Sync (same size) gives the content hash;
        # 2) a file with exactly the size and date seen at the last sync is unchanged;
        # 3) anything else is fetched once and its content compared.
        known = {}
        for rel, c in C.items():
            m, b = M.get(rel), base.get(rel)
            if m and m.get("h") and m.get("s") == c[0]:
                known[rel] = m["h"]
            elif b and c[0] == b.get("cs") and c[1] == b.get("ct"):
                known[rel] = b["h"]

        def cloud_hash(rel):
            return known.get(rel)

        fetched = {}
        tmpdir = None
        need = [r for r in C if r not in known and (r in base or r in L)]
        if need:
            tmpdir = tempfile.mkdtemp(prefix=".ss_tmp", dir=BASE_DIR if os.path.isdir(BASE_DIR) else None)
            lst = os.path.join(tmpdir, ".list")
            with open(lst, "w") as f:
                f.write("\n".join(need) + "\n")
            os.remove(lst)
            download_some(root.remote, tmpdir, need)
            for rel in need:
                p = os.path.join(tmpdir, *rel.split("/"))
                if os.path.isfile(p):
                    known[rel] = md5(p)
                    fetched[rel] = p

        up, down, del_cloud, del_local, same = [], [], [], [], []
        deferred = []
        renamed = []                    # (old name, new name) moved inside the cloud
        copied = []                     # (source, new name) copied inside the cloud
        conflicts = []

        # a cloud file whose content could not be fetched is not decided about this time
        unfetched = {r for r in need if r not in known}
        failed_down = set()
        for rel in sorted(unfetched):
            if not quiet_in_log(rel):
                log(t("dl_failed", rel=root.label(rel)))

        for rel in sorted(cand if fast else set(L) | set(C) | set(base)):
            if rel in unfetched:
                continue
            b, l, c = base.get(rel), L.get(rel), C.get(rel)
            ch = known.get(rel)
            lc = (l is None) != (b is None) or (l is not None and b is not None and l["h"] != b["h"])
            cc = (c is None) != (b is None) or (c is not None and b is not None and ch != b["h"])
            if not lc and not cc:
                if l is not None and c is not None:
                    same.append(rel)
                continue
            if lc and not cc:
                if l is not None:
                    up.append(rel)
                elif c is not None:
                    del_cloud.append(rel)
                continue
            if cc and not lc:
                if c is not None:
                    down.append(rel)
                elif l is not None:
                    del_local.append(rel)
                continue
            # changed on both sides
            if l is None and c is None:
                continue
            if l is None:
                down.append(rel)            # deleted here, changed elsewhere: keep the data
                continue
            if c is None:
                up.append(rel)              # changed here, deleted elsewhere: keep the data
                continue
            if ch is not None and ch == l["h"]:
                same.append(rel)
            else:
                conflicts.append(rel)

        try:
            # decide the winner of every conflict: the newer save
            won_local, won_cloud = [], []
            for rel in conflicts:
                m = M.get(rel)
                m = m if m and m.get("h") == known.get(rel) else None
                ct = (m or {}).get("t") or parse_time(C[rel][1])
                lt = L[rel]["m"] if clock_ok else -1
                (won_local if lt > ct else won_cloud).append(rel)

            # quick sync: if the cloud said that the whole folder is missing, nothing is
            # deleted here on that word - the full sync looks at it
            if fast and del_local and not cloud_seen:
                deferred, del_local = del_local, []

            # mass-deletion guard: an empty listing is a failure, not a deletion
            limit = max(5, len(base) // 2)
            if len(del_local) > limit:
                log(t("guard", n=len(del_local), where=t("where_cloud")))
                FLAGS["guard"] = True
                del_local = []
            if len(del_cloud) > limit:
                log(t("guard", n=len(del_cloud), where=t("where_here")))
                FLAGS["guard"] = True
                del_cloud = []

            done = set()
            # 1. the losing version of a conflict is kept for a while (if enabled)
            keep = keep_days()
            if keep:
                for rel in won_local:
                    rclone(["copyto", root.remote + "/" + rel, root.conflict_path(rel, "%s.%s" % (
                        (M.get(rel) or {}).get("d") or "cloud", stamp))])
                for rel in won_cloud:
                    rclone(["copyto", os.path.join(root.local, *rel.split("/")), root.conflict_path(rel, "%s.%s" % (dev, stamp))])

            # 2. a file that only got another name (save slots shift when one is
            # deleted: .state2 becomes .state1) is already in the cloud under the old
            # name: a big one is renamed there instead of being sent again. A rename is
            # not free on a slow cloud (several seconds each), so small files - and the
            # slot pictures - simply go with the other uploads in one call.
            if up and del_cloud:
                gone = {}
                for rel in del_cloud:
                    b = base.get(rel)
                    if b and b.get("h"):
                        gone.setdefault((b["h"], b.get("s")), []).append(rel)
                pairs = []
                for rel in up:
                    if L[rel]["s"] < RENAME_MIN:
                        continue
                    pool = gone.get((L[rel]["h"], L[rel]["s"]))
                    if pool:
                        pairs.append((pool.pop(), rel))

                def move(pair):
                    src, dst = pair
                    # --ignore-times: without it rclone takes a same-size file with a close date
                    # for "the same" and only deletes the old name - the new content would be lost
                    return rclone(["moveto", root.remote + "/" + src, root.remote + "/" + dst, "--ignore-times"], check=False)[0]

                if pairs:
                    if len(pairs) > 1:
                        with ThreadPoolExecutor(max_workers=4) as pool_ex:
                            codes = list(pool_ex.map(move, pairs))
                    else:
                        codes = [move(pairs[0])]
                    for (src, dst), rc_mv in zip(pairs, codes):
                        if rc_mv != 0:
                            continue        # did not work: sent and deleted the usual way
                        renamed.append((src, dst))
                        up.remove(dst)
                        del_cloud.remove(src)
                        done.update((src, dst))
                        if TIMING:
                            log(t("renamed", old=root.label(src), new=root.label(dst)))

            # 3. a big file whose new content is already in the cloud under another name
            # that stays (after a new save the slots shift: one slot gets what the
            # next one had, and that one gets the new save) is copied inside the
            # cloud - before the uploads below overwrite the source
            if up:
                moved_away = {src for src, _ in renamed}
                cloud_has = {}
                for rel in C:
                    h = known.get(rel)
                    if h and rel not in moved_away:
                        cloud_has.setdefault((h, C[rel][0]), rel)
                for src, dst in renamed:
                    cloud_has.setdefault((L[dst]["h"], L[dst]["s"]), dst)
                cpairs = []
                for rel in up:
                    if L[rel]["s"] < RENAME_MIN:
                        continue
                    src = cloud_has.get((L[rel]["h"], L[rel]["s"]))
                    if src and src != rel:
                        cpairs.append((src, rel))

                def copy_in_cloud(pair):
                    src, dst = pair
                    return rclone(["copyto", root.remote + "/" + src, root.remote + "/" + dst, "--ignore-times"], check=False)[0]

                if cpairs:
                    if len(cpairs) > 1:
                        with ThreadPoolExecutor(max_workers=4) as pool_ex:
                            codes = list(pool_ex.map(copy_in_cloud, cpairs))
                    else:
                        codes = [copy_in_cloud(cpairs[0])]
                    for (src, dst), rc_cp in zip(cpairs, codes):
                        if rc_cp != 0:
                            continue        # did not work: sent the usual way
                        copied.append((src, dst))
                        up.remove(dst)
                        done.add(dst)
                        if TIMING:
                            log(t("copied", old=root.label(src), new=root.label(dst)))

            # 4. uploads
            ups = up + won_local
            if ups:
                stage("send", len(ups))
                with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
                    f.write("\n".join(ups) + "\n")
                try:
                    rclone(["copy", root.local, root.remote, "--files-from-raw", f.name, "--ignore-times", "--no-check-dest"], stats=True)
                finally:
                    os.remove(f.name)
                done.update(ups)

            # 5. downloads (conflicts already fetched are moved into place)
            downs = [r for r in down + won_cloud if r not in fetched]
            for rel in down + won_cloud:
                if rel in fetched:
                    dst = os.path.join(root.local, *rel.split("/"))
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.move(fetched[rel], dst)
                    done.add(rel)
            if downs:
                stage("recv", len(downs))
                os.makedirs(root.local, exist_ok=True)
                # files that already existed here are compared by content: an old copy
                # must not be taken for a downloaded one
                failed_down = set(download_some(root.remote, root.local, downs, stats=True, want=known))
                for rel in downs:
                    if rel in failed_down:
                        continue
                    p = os.path.join(root.local, *rel.split("/"))
                    want = known.get(rel)
                    if want and os.path.isfile(p) and md5(p) != want:
                        failed_down.add(rel)
                for rel in sorted(failed_down):
                    if not quiet_in_log(rel):
                        log(t("dl_failed", rel=root.label(rel)))
                done.update(r for r in downs if r not in failed_down)

            # 6. deletions (the copies are already in _conflicts)
            if del_cloud:
                stage("delete", len(del_cloud))
                # one call for all files (each rclone call takes seconds on a slow cloud)
                with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
                    f.write("\n".join(del_cloud) + "\n")
                try:
                    rclone(["delete", root.remote, "--files-from-raw", f.name])
                finally:
                    os.remove(f.name)
            for rel in del_cloud + [src for src, _ in renamed]:
                if not quiet_in_log(rel):
                    log(t("deleted_cloud", rel=root.label(rel)))
                done.add(rel)
            for rel in del_local:
                try:
                    os.remove(os.path.join(root.local, *rel.split("/")))
                except FileNotFoundError:
                    pass
                if not quiet_in_log(rel):
                    log(t("deleted_here", rel=root.label(rel)))
                done.add(rel)

            # debug log (LOG_LEVEL="debug"): which files were sent and received
            if TIMING:
                for rel in up:
                    if not quiet_in_log(rel):
                        log(t("sent_file", rel=root.label(rel)))
                for rel in down:
                    if rel not in failed_down and not quiet_in_log(rel):
                        log(t("recv_file", rel=root.label(rel)))

            tail = t("copy_kept", days=keep, dir=CONFLICTS.split(":", 1)[-1]) if keep else ""
            for rel in won_local:
                if not quiet_in_log(rel):
                    log(t("conflict_local", rel=root.label(rel)) + tail)
            for rel in won_cloud:
                m = M.get(rel)
                src_dev = m.get("d") if m and m.get("h") == known.get(rel) else None
                if not quiet_in_log(rel):
                    log(t("conflict_cloud", rel=root.label(rel), dev=src_dev or t("other_device")) + tail)
        finally:
            if tmpdir:
                shutil.rmtree(tmpdir, ignore_errors=True)

        # counted like the log: pictures (state thumbnails, screenshots) are not counted
        def n(rels):
            return sum(1 for r in rels if not quiet_in_log(r))
        total["d"] += n([r for r in down + won_cloud if r not in failed_down])
        total["f"] += n(failed_down) + n(unfetched)
        total["u"] += n(up) + n(won_local) + n([d for _, d in renamed]) + n([d for _, d in copied])
        total["c"] += n(conflicts)
        total["x"] += n(del_cloud) + n(del_local) + n([s for s, _ in renamed])

        # ---- new state: everything that is now the same on both sides
        moved_to = {d for _, d in renamed} | {d for _, d in copied}
        moved_from = {s for s, _ in renamed}
        changed_cloud = bool(up or won_local or del_cloud or renamed or copied)
        C2 = refresh_listing(root, C, set(up) | set(won_local) | moved_to, set(del_cloud) | moved_from) if changed_cloud else C
        L2 = local_list(root, base)
        nb = {}
        for rel in set(same) | done:
            l, c = L2.get(rel), C2.get(rel)
            if l is None or c is None:
                continue
            nb[rel] = {"h": l["h"], "s": l["s"], "m": l["m"], "ns": l["ns"], "cs": c[0], "ct": c[1]}
        if fast:
            # what the quick sync did not look at stays as it was at the last sync
            for rel, b in base.items():
                if rel not in nb and (rel not in cand or rel in deferred):
                    nb[rel] = b
        # not downloaded / not fetched: as it was, so the next sync tries again
        for rel in failed_down | unfetched:
            if rel in base:
                nb[rel] = base[rel]
            else:
                nb.pop(rel, None)
        new_base_roots[root.name] = nb

        # ---- manifest in the cloud: who wrote which version, and when. It is read
        # again right before writing, so what another device wrote meanwhile stays.
        uploaded = set(up) | set(won_local) | moved_to

        def build_manifest(fresh):
            newM = dict(fresh)
            for rel in list(newM):
                if not root.accept(rel, (newM[rel] or {}).get("s") if isinstance(newM[rel], dict) else None):
                    continue            # not ours (excluded, no games here, too big): another device's entry stays
                if fast and rel not in cand:
                    continue            # the quick sync did not look at it in the cloud
                if rel not in C2 or rel in del_cloud or rel in moved_from:
                    newM.pop(rel, None)
            for rel, e in nb.items():
                if fast and rel not in cand:
                    continue
                if rel in failed_down or rel in unfetched:
                    continue
                c = C2.get(rel)
                if c is None:
                    continue
                old_e = newM.get(rel) or M.get(rel) or {}
                if rel in uploaded:
                    newM[rel] = {"h": e["h"], "s": c[0], "ct": c[1], "d": dev, "t": L2[rel]["m"]}
                elif old_e.get("h") != e["h"] or old_e.get("s") != c[0]:
                    if rel in fresh and fresh[rel].get("h") != M.get(rel, {}).get("h"):
                        continue        # changed by another device right now: its entry wins
                    newM[rel] = {"h": e["h"], "s": c[0], "ct": c[1], "d": old_e.get("d", ""),
                                 "t": old_e.get("t") or parse_time(c[1])}
            return newM

        # nothing to change in the manifest -> nothing to write, so no need to read it again
        fresh = M
        newM = build_manifest(fresh)
        if newM != fresh:
            rc, mout = rclone(["cat", root.remote + "/" + MANIFEST], check=False)
            try:
                fresh = json.loads(mout).get("files", {}) if rc == 0 and mout.strip() else {}
            except (ValueError, AttributeError):
                fresh = {}
            newM = build_manifest(fresh)
        if newM != fresh:
            data = json.dumps({"version": 1, "files": newM}, ensure_ascii=False, separators=(",", ":")).encode()
            t0 = time.monotonic()
            stage("finish")
            subprocess.run(rclone_cmd(["rcat", root.remote + "/" + MANIFEST]), input=data,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if TIMING:
                timed("rcat", t0)
            # a failed manifest write is harmless: it is only a hint for the other devices

    base_all["roots"] = new_base_roots
    base_all["device"] = dev
    save_json(BASE_FILE, base_all)

    # old conflict copies are removed by any device during its sync (at most once
    # a day, or right away after the setting changed). The age is taken from the
    # date in the copy's name, i.e. from the moment the conflict happened.
    keep = keep_days()
    if not fast and clock_ok and (now - base_all.get("cleaned", 0) > 86400 or base_all.get("cleaned_keep") != keep):
        if clean_conflicts(keep, now):
            base_all["cleaned"] = now
            base_all["cleaned_keep"] = keep
            save_json(BASE_FILE, base_all)

    summary = t("summary", d=total["d"], u=total["u"], c=total["c"], x=total["x"])
    # short note for the "Saves uploaded / downloaded" log line of the calling script
    parts = [t(k, n=total[v]) for k, v in (("n_sent", "u"), ("n_recv", "d"), ("n_del", "x"), ("n_conf", "c")) if total[v]]
    if total["f"]:
        parts.append(t("n_failed", n=total["f"]))
    if FLAGS["guard"]:
        parts.append(t("n_guard"))
    res = os.environ.get("SS_RESULT")
    if res:
        try:
            with open(res, "w") as f:
                f.write(", ".join(parts) or t("no_changes"))
        except OSError:
            pass
    if VERBOSE:
        print(summary)
    else:
        print(json.dumps(total))
    return 0


def run_mirror():
    """"Change cloud" -> "make the cloud a copy of this device": the cloud folder becomes
    exactly what is on this device - missing files are sent, different ones replaced,
    extra ones deleted; nothing is compared by date. Systems this device has no games
    for (and excluded ones) are not touched. Afterwards the memory says: cloud = device."""
    dev = device_name()
    new_base_roots = {}
    total = {"u": 0, "x": 0}
    for root in roots():
        L = local_list(root, {})
        listing = cloud_list(root.remote)
        C = {r: v for r, v in listing.items() if root.accept(r, v[0])}
        M = {}
        if MANIFEST in listing:
            rc, mout = rclone(["cat", root.remote + "/" + MANIFEST], check=False)
            try:
                M = json.loads(mout).get("files", {}) if rc == 0 and mout.strip() else {}
            except (ValueError, AttributeError):
                M = {}
        # a file the cloud already has with the same content (the manifest says so) is not sent again
        up = [r for r in sorted(L)
              if not (r in C and (M.get(r) or {}).get("h") == L[r]["h"] and (M.get(r) or {}).get("s") == C[r][0])]
        dels = [r for r in sorted(C) if r not in L]
        if up:
            with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
                f.write("\n".join(up) + "\n")
            try:
                rclone(["copy", root.local, root.remote, "--files-from-raw", f.name, "--ignore-times", "--no-check-dest"], stats=True)
            finally:
                os.remove(f.name)
            if TIMING:
                for rel in up:
                    if not quiet_in_log(rel):
                        log(t("sent_file", rel=root.label(rel)))
        if dels:
            with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
                f.write("\n".join(dels) + "\n")
            try:
                rclone(["delete", root.remote, "--files-from-raw", f.name])
            finally:
                os.remove(f.name)
            for rel in dels:
                if not quiet_in_log(rel):
                    log(t("deleted_cloud", rel=root.label(rel)))
        total["u"] += sum(1 for r in up if not quiet_in_log(r))
        total["x"] += sum(1 for r in dels if not quiet_in_log(r))
        C2 = refresh_listing(root, C, set(up), set(dels)) if (up or dels) else C
        nb = {}
        for rel, l in L.items():
            c = C2.get(rel)
            if c is not None:
                nb[rel] = {"h": l["h"], "s": l["s"], "m": l["m"], "ns": l["ns"], "cs": c[0], "ct": c[1]}
        new_base_roots[root.name] = nb
        # manifest: entries of systems this device does not sync stay as they are
        newM = {rel: e for rel, e in M.items() if not root.accept(rel, e.get("s") if isinstance(e, dict) else None)}
        for rel, e in nb.items():
            old = M.get(rel) or {}
            sent = rel in up
            newM[rel] = {"h": e["h"], "s": e["cs"], "ct": e["ct"],
                         "d": dev if sent or not old.get("d") else old["d"], "t": L[rel]["m"]}
        if newM != M:
            data = json.dumps({"version": 1, "files": newM}, ensure_ascii=False, separators=(",", ":")).encode()
            stage("finish")
            subprocess.run(rclone_cmd(["rcat", root.remote + "/" + MANIFEST]), input=data,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    save_json(BASE_FILE, {"roots": new_base_roots, "device": dev})
    parts = [t(k, n=total[v]) for k, v in (("n_sent", "u"), ("n_del", "x")) if total[v]]
    res = os.environ.get("SS_RESULT")
    if res:
        try:
            with open(res, "w") as f:
                f.write(", ".join(parts) or t("no_changes"))
        except OSError:
            pass
    print(", ".join(parts) or t("no_changes"))
    return 0


STAMP_RE = re.compile(r"\.(\d{4})-(\d\d)-(\d\d)_(\d\d)-(\d\d)-(\d\d)(?:\.deleted)?$")


def clean_conflicts(keep, now):
    """Removes conflict copies older than the setting of this device. A device that keeps
    no copies (0) does not touch them at all: copies made by other devices stay for as
    long as those devices keep them."""
    if keep <= 0:
        return True
    items = cloud_list(CONFLICTS)
    if not items:
        return True
    limit = now - keep * 86400
    old = []
    for rel, (_size, mt) in items.items():
        m = STAMP_RE.search(rel)
        if m:
            y, mo, d, h, mi, se = (int(x) for x in m.groups())
            try:
                made = time.mktime((y, mo, d, h, mi, se, 0, 0, -1))
            except (OverflowError, ValueError):
                made = parse_time(mt)
        else:
            made = parse_time(mt)
        if made < limit:
            old.append(rel)
    if old:
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
            f.write("\n".join(old) + "\n")
        try:
            rclone(["delete", CONFLICTS, "--files-from-raw", f.name], check=False)
        finally:
            os.remove(f.name)
        rclone(["rmdirs", CONFLICTS], check=False)
    return True


# ================================================================== conflict copies
# <folder>_conflicts/<path>.<device>.<YYYY-MM-DD_hh-mm-ss>: the version that lost a conflict
CONFLICT_RE = re.compile(r"^(.+)\.([A-Za-z0-9_-]+)\.(\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d|time-unknown-\d+)(\.deleted)?$")


def conflict_info(cid, mt=""):
    """What a conflict copy is: the save it belongs to, from which device and when.
    None for anything that is not a conflict copy or points outside the save folders."""
    m = CONFLICT_RE.match(cid or "")
    if not m:
        return None
    sub, dev, stamp, _deleted = m.groups()
    parts = sub.split("/")
    if any(p in ("", ".", "..") or p.startswith(".ss_tmp") for p in parts):
        return None
    if parts[0] == PORTS_CLOUD:
        if len(parts) < 3 or parts[1] in PORT_NOT_GAMES:
            return None
        rel = "/".join(parts[2:])
        local = os.path.join(ROMS_DIR, "ports", parts[1], *parts[2:])
        label = "ports/%s/%s" % (parts[1], rel)
        ex = excluded()
        synced = PORTS_KEY not in ex and port_accept(rel, None)
    else:
        local = os.path.join(SAVE_DIR, *parts)
        label = sub
        synced = saves_accept(excluded())(sub, None)
    made = None
    sm = STAMP_RE.search("." + stamp)
    if sm:
        y, mo, d, h, mi, se = (int(x) for x in sm.groups())
        try:
            made = time.mktime((y, mo, d, h, mi, se, 0, 0, -1))
        except (OverflowError, ValueError):
            made = None
    if made is None and mt:
        made = parse_time(mt)
    return {"id": cid, "sub": sub, "file": label, "dev": dev, "local": local, "synced": bool(synced),
            "ts": int(made or 0), "time": time.strftime("%d.%m %H:%M", time.localtime(made)) if made else t("time_unknown")}


def list_conflicts():
    """Conflict copies of saves. Pictures (save-state thumbnails like game.state.png) are
    not listed: they are restored and deleted together with their save."""
    keep = keep_days()
    now = time.time()
    out = []
    for cid, (size, mt) in cloud_list(CONFLICTS).items():
        info = conflict_info(cid, mt)
        if not info or quiet_in_log(info["sub"]):
            continue
        left = keep - int((now - info["ts"]) // 86400) if info["ts"] else keep
        # kept at least until the conflict time + the setting of this device; old copies
        # are removed by a full sync (at most once a day), so it can stay a little longer
        until = info["ts"] + keep * 86400 if info["ts"] and keep else 0
        info.update({"size": size, "left": max(0, left), "keep": keep,
                     "until": time.strftime("%d.%m %H:%M", time.localtime(until)) if until > now else "",
                     "here": os.path.exists(info.pop("local"))})
        out.append(info)
    out.sort(key=lambda x: (-x["ts"], x["file"]))
    return out


def version_device(info, target):
    """Which device made the save that is here now: the manifest in the cloud says who
    wrote each version; if this one is not there (changed here), it is this device."""
    parts = info["sub"].split("/")
    if parts[0] == PORTS_CLOUD:
        remote, rel = "%s/%s/%s" % (REMOTE, PORTS_CLOUD, parts[1]), "/".join(parts[2:])
    else:
        remote, rel = REMOTE, info["sub"]
    try:
        rc, out = rclone(["cat", remote + "/" + MANIFEST], check=False)
        e = (json.loads(out).get("files") or {}).get(rel) if rc == 0 and out else None
        if e and e.get("d") and e.get("h") == md5(target) and re.match(r"^[A-Za-z0-9_-]+$", e["d"]):
            return e["d"]
    except (ValueError, AttributeError, OSError):
        pass
    return device_name()


def conflict_sub(cid):
    m = CONFLICT_RE.match(cid)
    return m.group(1) if m else cid


def conflict_pictures(info, cid):
    """[(conflict id, local path)] of the pictures that lost the conflict together with
    this save (game.state -> game.state.png with the same device and time)."""
    tag = cid[len(info["sub"]) + 1:]
    folder, name = (info["sub"].rsplit("/", 1) + [""])[:2] if "/" in info["sub"] else ("", info["sub"])
    rc, out = rclone(["lsjson", "--files-only", "--no-mimetype", CONFLICTS + ("/" + folder if folder else "")], check=False)
    try:
        names = {i["Path"] for i in json.loads(out or "[]")} if rc == 0 else set()
    except (ValueError, KeyError, TypeError):
        names = set()
    found = []
    for ext in QUIET_EXT:
        pic = "%s%s.%s" % (name, ext, tag)
        if pic in names:
            found.append(((folder + "/" if folder else "") + pic, info["local"] + ext))
    return found


def restore_conflict(cid):
    """The conflict copy becomes the save on this device again; the save it replaces goes to
    the conflicts (it can be restored the same way). The next sync sends it everywhere."""
    info = conflict_info(cid)
    if not info:
        print("bad id")
        return 2
    lock = open(ENGINE_LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("busy")
        return 3
    now = int(time.time())
    stamp = (datetime.now().strftime("%Y-%m-%d_%H-%M-%S") if now > SANE_TIME
             else "time-unknown-%d" % random.randint(0, 99999))
    backup_tag = None
    if os.path.exists(info["local"]):
        backup_tag = "%s.%s" % (version_device(info, info["local"]), stamp)
    items = [(cid, info["local"])] + conflict_pictures(info, cid)
    for n, (item, target) in enumerate(items):
        folder = os.path.dirname(target)
        os.makedirs(folder, exist_ok=True)
        tmp = os.path.join(folder, ".ss_tmp_restore_" + os.path.basename(target))
        try:
            if rclone(["copyto", CONFLICTS + "/" + item, tmp], check=(n == 0))[0] != 0:
                continue                # a picture that could not be fetched: the save matters
            backup = None
            if backup_tag and os.path.exists(target):
                # the version here now goes to the conflicts with the same device and time
                # as its save, so it can be restored the same way
                backup = "%s.%s" % (conflict_sub(item), backup_tag)
                if backup != item:
                    rclone(["copyto", target, CONFLICTS + "/" + backup])
            os.replace(tmp, target)
            os.utime(target, None)      # newer than any other version: the next sync keeps it
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
        if backup != item:
            rclone(["deletefile", CONFLICTS + "/" + item], check=False)
    log(t("restored", file=info["file"], dev=info["dev"], time=info["time"]))
    print("ok")
    return 0


def drop_conflict(cid):
    info = conflict_info(cid)
    if not info:
        print("bad id")
        return 2
    pictures = conflict_pictures(info, cid)
    rclone(["deletefile", CONFLICTS + "/" + cid])
    for item, _local in pictures:
        rclone(["deletefile", CONFLICTS + "/" + item], check=False)
    log(t("conflict_dropped", file=info["file"], dev=info["dev"], time=info["time"]))
    print("ok")
    return 0


def timing_line(total):
    parts = ["%s %dx %.1f с" % (k, v[0], v[1]) for k, v in TIMES.items() if k != "scan"]
    scan = TIMES.get("scan", [0, 0.0])[1]
    return "Время: всего %.1f с; rclone: %s; скан устройства %.1f с" % (total, ", ".join(parts) or "-", scan)


def human_size(n):
    """Bytes in the same short form as rclone about: 9.996 GiB."""
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    v, i = float(n), 0
    while v >= 1024 and i < len(units) - 1:
        v /= 1024
        i += 1
    if i == 0:
        return "%d B" % n
    return "%s %s" % (("%.3f" % v).rstrip("0").rstrip("."), units[i])


def cloud_about():
    """Volume of the cloud: {total, used, free} in bytes (keys missing when unknown) or None."""
    vals = {}
    try:
        rc, out = rclone(["about", "--json", REMOTE.split(":", 1)[0] + ":"], check=False, timeout=60)
        if rc == 0:
            data = json.loads(out)
            vals = {k: int(data[k]) for k in ("total", "used", "free") if data.get(k) is not None}
    except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
        vals = {}
    return vals or None


def main(argv):
    global VERBOSE, WEB
    if argv and argv[0] == "about":
        vals = cloud_about() or {}
        if "--json" in argv:
            print(json.dumps(vals))
        else:
            for key, label in (("total", "Total"), ("used", "Used"), ("free", "Free")):
                if key in vals:
                    print("%s: %s" % (label, human_size(vals[key])))
        return 0 if vals else 1
    if argv and argv[0] in ("conflicts", "restore", "drop"):
        # conflict copies, for the web interface: list (JSON), restore one, delete one
        try:
            if argv[0] == "conflicts":
                print(json.dumps(list_conflicts(), ensure_ascii=False))
                return 0
            if len(argv) < 2:
                return 2
            return restore_conflict(argv[1]) if argv[0] == "restore" else drop_conflict(argv[1])
        except (SyncError, OSError, subprocess.SubprocessError) as e:
            sys.stderr.write("%s\n" % e)
            return 1
    if argv and argv[0] == "check":
        try:
            return 0 if unchanged_here() else 1
        except Exception:
            return 1
    if not argv or argv[0] != "sync":
        print(__doc__ or "usage: sync_engine.py sync")
        return 2
    VERBOSE = "--verbose" in argv
    WEB = "--web-progress" in argv
    if WEB:
        try:
            os.remove(STAGE_FILE)
        except OSError:
            pass
        stage("scan")
    try:
        lock = open(ENGINE_LOCK, "w")
        fcntl.flock(lock, fcntl.LOCK_EX)     # a boot download and a game-exit upload never overlap
        t_start = time.monotonic()
        rc_run = run_mirror() if "--mirror" in argv else run(fast="--fast" in argv)
        if TIMING:
            log(timing_line(time.monotonic() - t_start))
        return rc_run
    except SyncError as e:
        sys.stderr.write("%s\n" % e)
        if FLAGS["full"] and os.environ.get("SS_RESULT"):
            try:
                with open(os.environ["SS_RESULT"], "w") as rf:
                    rf.write("cloud_full")
            except OSError:
                pass
        return 1
    except (OSError, subprocess.SubprocessError) as e:
        if isinstance(e, OSError) and e.errno == errno.ENOSPC:
            sys.stderr.write("no space\n")
        else:
            sys.stderr.write("%s\n" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
ENGEOF
    sed -i \
        -e "s|__SS_LANG__|ru|g" \
        -e "s|__SS_SAVE_DIR__|$SAVE_DIR|g" \
        -e "s|__SS_ROMS_DIR__|$ROMS_DIR|g" \
        -e "s|__SS_REMOTE__|$REMOTE|g" \
        -e "s|__SS_BASE__|$BASE|g" \
        -e "s|__SS_LOG_FILE__|$LOG_FILE|g" \
        -e "s|__SS_RCLONE_CONF__|$RCLONE_CONF|g" \
        -e "s|__SS_STATE_FILE__|$STATE_FILE|g" \
        -e "s|__SS_SYSTEM__|$SYSTEM|g" \
        "$ENGINE_SCRIPT"
    chmod +x "$ENGINE_SCRIPT" 2>/dev/null
    command -v python3 >/dev/null 2>&1 || echo "⚠️  python3 не найден - синхронизация сохранений на этом устройстве работать не будет"
}

############################################
# create_download_script
############################################

create_download_script() {
    create_engine_script
    cat > "$DOWNLOAD_SCRIPT" << ENDOFSCRIPT
#!/bin/bash
RCLONE_BIN="$RCLONE_BIN"
RCLONE_CONF="$RCLONE_CONF"
SAVE_DIR="$SAVE_DIR"
REMOTE="$REMOTE"
REMOTE_NAME="$REMOTE_NAME"
REMOTE_FOLDER="$REMOTE_FOLDER"
FIRST_SYNC_MARKER="$FIRST_SYNC_MARKER"
READY_FILE="/tmp/save_sync_ready"
LOCK_FILE="/tmp/save_sync_download.lock"
STATE_FILE="$STATE_FILE"
ENGINE_SCRIPT="$ENGINE_SCRIPT"

# Само-восстановление, если раздел с rclone смонтирован noexec
# (например, /recalbox/share на Recalbox)
RCLONE_PATH="\$RCLONE_BIN"
# Результат проверки запоминается до перезагрузки, пока сам rclone не обновлён.
RC_CACHE=/tmp/save_sync_rclone_path
RC_STAMP="\$(stat -c %Y "\$RCLONE_BIN" 2>/dev/null)"
if [ -n "\$RC_STAMP" ] && [ -f "\$RC_CACHE" ] && [ "\$(sed -n 2p "\$RC_CACHE")" = "\$RC_STAMP" ] && [ "\$(sed -n 3p "\$RC_CACHE")" = "\$RCLONE_BIN" ] && [ -x "\$(sed -n 1p "\$RC_CACHE")" ]; then
    RCLONE_PATH="\$(sed -n 1p "\$RC_CACHE")"
else
    RC_OK=0
    if "\$RCLONE_PATH" version >/dev/null 2>&1; then
        RC_OK=1
    else
        mkdir -p /tmp/save_sync_bin 2>/dev/null
        cp -f "\$RCLONE_BIN" /tmp/save_sync_bin/rclone 2>/dev/null
        chmod +x /tmp/save_sync_bin/rclone 2>/dev/null
        if /tmp/save_sync_bin/rclone version >/dev/null 2>&1; then
            RCLONE_PATH="/tmp/save_sync_bin/rclone"
            RC_OK=1
        fi
    fi
    [ \$RC_OK -eq 1 ] && [ -n "\$RC_STAMP" ] && printf '%s\n%s\n%s\n' "\$RCLONE_PATH" "\$RC_STAMP" "\$RCLONE_BIN" > "\$RC_CACHE" 2>/dev/null
fi
CONFIG_FILE="$CONFIG_FILE"
LOG_FILE="$LOG_FILE"
STATUS_FILE="$STATUS_FILE"
LAST_SYNC_TIME="$LAST_SYNC_TIME"
PROGRESS_FILE="/tmp/save_sync_progress.json"
PROGRESS_LOG="/tmp/save_sync_progress.log"
WEB_PROGRESS=false

if [ -f "\$CONFIG_FILE" ]; then
    . "\$CONFIG_FILE"
fi

# лог не больше MAX_LOG_SIZE: при превышении старая часть уходит в .old
if [ -f "\$LOG_FILE" ] && [ "\$(wc -c < "\$LOG_FILE" 2>/dev/null || echo 0)" -gt "\${MAX_LOG_SIZE:-102400}" ] 2>/dev/null; then
    mv -f "\$LOG_FILE" "\$LOG_FILE.old" 2>/dev/null
fi

# LOG_LEVEL="debug" in the config: write how long each stage of the sync took
# uptime, not the clock: at boot the clock can jump by years when it is set over the network
T0=\$(cut -d. -f1 /proc/uptime 2>/dev/null || date +%s)
[ "\$LOG_LEVEL" = "debug" ] && export SS_TIMING=1

# on-screen message (EmulationStation on Batocera / KNULLI); silent if unavailable
notify_screen() {
    [ "\${NOTIFICATIONS:-true}" = "false" ] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    curl -s -m 3 -X POST -H "Content-Type: text/plain; charset=utf-8" --data-binary "\$1" http://127.0.0.1:1234/notify >/dev/null 2>&1 || true
}

# ======== ОБРАБОТКА АРГУМЕНТОВ ========
SHOW_PROGRESS=""
FORCE_SYNC=false

if [ "\$1" = "--detach" ]; then
    # Фоновый запуск. Интервал сохраняется для автоматических событий.
    nohup bash -c "sleep 2; bash $DOWNLOAD_SCRIPT --bg" > /dev/null 2>&1 &
    exit 0
fi

if [ "\$1" = "--bg" ]; then
    SHOW_PROGRESS=""
elif [ "\$1" = "--force" ]; then
    FORCE_SYNC=true
elif [ "\$1" = "--web-progress" ]; then
    SHOW_PROGRESS=""
    FORCE_SYNC=true
    WEB_PROGRESS=true
elif [ "\$1" = "--verbose" ]; then
    SHOW_PROGRESS="yes"
    FORCE_SYNC=true
fi

# ======== ПРОГРЕСС ДЛЯ WEB UI ========
progress_start() {
    local action="\$1"
    local phase="\$2"
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":true,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0}\n' \
            "\$action" "\$phase" > "\$PROGRESS_FILE"
        : > "\$PROGRESS_LOG"
    fi
}

progress_finish() {
    local ok="\$1"
    local action="\$2"
    local phase="\$3"
    if [ "\$WEB_PROGRESS" = "true" ]; then
        if [ "\$ok" = "true" ]; then
            printf '{"active":false,"action":"%s","phase":"%s","percent":100,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":true}\n' \
                "\$action" "\$phase" > "\$PROGRESS_FILE"
        else
            printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false}\n' \
                "\$action" "\$phase" > "\$PROGRESS_FILE"
        fi
    fi
}

# ======== ОСНОВНАЯ ЛОГИКА ========
save_status() {
    echo "\$1 \$(date +%s)" > "\$STATUS_FILE"
}

# ======== ПОСТОЯННОЕ СОСТОЯНИЕ СИНХРОНИЗАЦИИ ========
# Хранится на разделе share, поэтому переживает перезагрузку (в отличие от /tmp).
# Пишут его только скрипты синхронизации, веб-интерфейс его не трогает.
state_get() {
    [ -f "\$STATE_FILE" ] || return 0
    grep "^\$1=" "\$STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# state_set КЛЮЧ ЗНАЧЕНИЕ  (пустое ЗНАЧЕНИЕ удаляет ключ)
state_set() {
    (
        flock 9
        tmp="\$STATE_FILE.tmp.\$\$"
        {
            [ -f "\$STATE_FILE" ] && grep -v "^\$1=" "\$STATE_FILE"
            [ -n "\$2" ] && echo "\$1=\$2"
        } > "\$tmp" 2>/dev/null
        mv -f "\$tmp" "\$STATE_FILE" 2>/dev/null
    ) 9>/tmp/save_sync_state.lock
}

exec 200>"\$LOCK_FILE"
flock -n 200 || { echo "\$(date '+%d.%m %H:%M:%S') Пропущено: предыдущая загрузка ещё выполняется" >> "\$LOG_FILE" 2>/dev/null; exit 0; }

# ======== ОТМЕНА (кнопка «Отмена» в веб-интерфейсе, Ctrl+C, выключение) ========
# rclone получает тот же сигнал и останавливается; здесь только
# записывается результат, чтобы прогресс в веб-интерфейсе не висел.
on_cancel() {
    trap - TERM INT
    save_status "ERROR"
    echo "\$(date '+%d.%m %H:%M:%S') Отменена загрузка сохранений" >> "\$LOG_FILE" 2>/dev/null
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false,"cancelled":true}\n' \
            "download" "Отменена загрузка сохранений" > "\$PROGRESS_FILE"
    fi
    exit 130
}
trap on_cancel TERM INT

# Синхронизацию выполняет sync_engine.py (нужен python3). Если чего-то
# не хватает, ничего не делаем и пишем понятную ошибку в лог.
ENGINE_ERR=""
command -v python3 >/dev/null 2>&1 || ENGINE_ERR="не найден python3 - без него синхронизация сохранений невозможна"
[ -f "\$ENGINE_SCRIPT" ] || ENGINE_ERR="не найден sync_engine.py - переустановите Save Sync"
if [ -n "\$ENGINE_ERR" ]; then
    save_status "ERROR"
    echo "\$(date '+%d.%m %H:%M:%S') Ошибка загрузки сохранений: \$ENGINE_ERR" >> "\$LOG_FILE" 2>/dev/null
    [ -n "\$SHOW_PROGRESS" ] && echo "❌ \$ENGINE_ERR"
    progress_start "download" "Ошибка загрузки сохранений"
    progress_finish false "download" "Ошибка загрузки сохранений: \$ENGINE_ERR"
    exit 1
fi


# Проверка интервала (ТОЛЬКО если НЕ принудительная синхронизация)
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ \$SYNC_INTERVAL -gt 0 ] && [ -f "\$LAST_SYNC_TIME" ]; then
    LAST=\$(cat "\$LAST_SYNC_TIME" 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [ \$((NOW - LAST)) -lt \$SYNC_INTERVAL ]; then
        exit 0
    fi
fi

# Ждём, пока часы не станут разумными. На Raspberry Pi нет RTC,
# и до синхронизации по NTP дата может быть 01.01 - из-за этого
# HTTPS-соединение с облаком падает по проверке сертификата, даже
# если сеть уже работает.
CLOCK_WAIT=0
while [ "\$(date +%Y)" -lt 2024 ]; do
    CLOCK_WAIT=\$((CLOCK_WAIT+1))
    if [ \$CLOCK_WAIT -ge 20 ]; then
        break
    fi
    sleep 3
done

# Ждём облако. Сразу после включения сеть может ещё подниматься,
# поэтому пробуем около 2 минут. Проверяется само облако, а не ping
# до 1.1.1.1: в некоторых сетях ping закрыт, хотя облако работает.
# Срок считаем по uptime - обычные часы могут прыгнуть при синхронизации NTP.
uptime_sec() { cut -d. -f1 /proc/uptime; }
WAIT_UNTIL=\$(( \$(uptime_sec) + 120 ))
CLOUD_OK=0
while :; do
    if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsd "\$REMOTE_NAME:" \
        --contimeout 15s --timeout 30s --low-level-retries 1 --retries 1 >/dev/null 2>&1; then
        CLOUD_OK=1
        break
    fi
    [ "\$(uptime_sec)" -ge "\$WAIT_UNTIL" ] && break
    sleep 5
done
if [ \$CLOUD_OK -eq 0 ]; then
    echo "\$(date '+%d.%m %H:%M:%S') Облако недоступно (нет сети или облако не отвечает)" >> "\$LOG_FILE" 2>/dev/null
    save_status "ERROR"
    exit 1
fi

# ======== ДВУСТОРОННЯЯ СИНХРОНИЗАЦИЯ (sync_engine.py) ========
# Устройство и облако сравниваются с последней синхронизацией: скачивается
# только изменённое в облаке, отправляется только изменённое здесь. Если
# сохранение изменили на разных устройствах, остаётся более новое, а старое
# копируется в папку _conflicts (срок - настройка «Копии при конфликтах»). Ничего не спрашивается.
T_ENG=\$(cut -d. -f1 /proc/uptime 2>/dev/null || date +%s)
progress_start "download" "Загрузка сохранений"
ENGINE_ARGS=(sync)
[ "\$WEB_PROGRESS" = "true" ] && ENGINE_ARGS+=(--web-progress)
if [ -n "\$SHOW_PROGRESS" ]; then
    SS_RCLONE="\$RCLONE_PATH" SS_EXCLUDED="\$EXCLUDED_SYSTEMS" SS_RETRIES="\$MAX_RETRIES" SS_KEEP_DAYS="\${CONFLICT_KEEP_DAYS:-3}" SS_RESULT="/tmp/save_sync_result.\$\$" \
        python3 "\$ENGINE_SCRIPT" "\${ENGINE_ARGS[@]}" --verbose
else
    SS_RCLONE="\$RCLONE_PATH" SS_EXCLUDED="\$EXCLUDED_SYSTEMS" SS_RETRIES="\$MAX_RETRIES" SS_KEEP_DAYS="\${CONFLICT_KEEP_DAYS:-3}" SS_RESULT="/tmp/save_sync_result.\$\$" \
        python3 "\$ENGINE_SCRIPT" "\${ENGINE_ARGS[@]}" > /dev/null 2>&1
fi
ENGINE_EXIT=\$?
if [ \$ENGINE_EXIT -eq 0 ]; then
    # the marker is still needed by devices on older versions
    if [ "\$(state_get MARKER_DONE)" != "\$FIRST_SYNC_MARKER" ]; then
        if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$FIRST_SYNC_MARKER" 2>/dev/null | grep -q . || \
            echo "first_sync_\$(date +%s)" | "\$RCLONE_PATH" --config "\$RCLONE_CONF" rcat "\$FIRST_SYNC_MARKER" 2>/dev/null; then
            state_set MARKER_DONE "\$FIRST_SYNC_MARKER"
        fi
    fi
    date +%s > "\$READY_FILE"
    date +%s > "\$LAST_SYNC_TIME"
    save_status "OK"
    state_set PENDING_UPLOAD ""
    state_set LAST_GOOD_SYNC "\$(date +%s)"
    [ "\$LOG_LEVEL" = "debug" ] && echo "\$(date '+%d.%m %H:%M:%S') Время: до запуска синхронизации \$((T_ENG - T0)) с" >> "\$LOG_FILE" 2>/dev/null
    SYNC_NOTE=\$(cat "/tmp/save_sync_result.\$\$" 2>/dev/null); rm -f "/tmp/save_sync_result.\$\$"
    if [ "\$FORCE_SYNC" = "true" ]; then SYNC_WHAT="Синхронизация вручную"; else SYNC_WHAT="Синхронизация"; fi
    echo "\$(date '+%d.%m %H:%M:%S') \$SYNC_WHAT\${SYNC_NOTE:+ (\$SYNC_NOTE)}" >> "\$LOG_FILE" 2>/dev/null
    if [ -n "\$SYNC_NOTE" ] && [ "\$SYNC_NOTE" != "нет изменений" ]; then
        case "\$SYNC_NOTE" in
            *конфликт*) [ "\${CONFLICT_KEEP_DAYS:-3}" != "0" ] && notify_screen "Save Sync: конфликт сохранений - подробнее в веб-интерфейсе" || notify_screen "Save Sync: \$SYNC_NOTE" ;;
            *) notify_screen "Save Sync: \$SYNC_NOTE" ;;
        esac
    fi
    progress_finish true "download" "Загрузка сохранений завершена"
    exit 0
fi
save_status "ERROR"
echo "\$(date '+%d.%m %H:%M:%S') Ошибка загрузки сохранений (код: \$ENGINE_EXIT)" >> "\$LOG_FILE" 2>/dev/null
if grep -q "^cloud_full" "/tmp/save_sync_result.\$\$" 2>/dev/null; then
    notify_screen "Save Sync: ошибка - в облаке закончилось место"
else
    notify_screen "Save Sync: ошибка синхронизации"
fi
rm -f "/tmp/save_sync_result.\$\$"
progress_finish false "download" "Ошибка загрузки сохранений"
exit 1
ENDOFSCRIPT
    chmod +x "$DOWNLOAD_SCRIPT"
}

############################################
# create_upload_script
############################################

create_upload_script() {
    cat > "$UPLOAD_SCRIPT" << ENDOFSCRIPT
#!/bin/bash
RCLONE_BIN="$RCLONE_BIN"
RCLONE_CONF="$RCLONE_CONF"
SAVE_DIR="$SAVE_DIR"
REMOTE="$REMOTE"
REMOTE_NAME="$REMOTE_NAME"
REMOTE_FOLDER="$REMOTE_FOLDER"
FIRST_SYNC_MARKER="$FIRST_SYNC_MARKER"
READY_FILE="/tmp/save_sync_ready"
LOCK_FILE="/tmp/save_sync_upload.lock"
STATE_FILE="$STATE_FILE"
ENGINE_SCRIPT="$ENGINE_SCRIPT"

# Само-восстановление, если раздел с rclone смонтирован noexec
# (например, /recalbox/share на Recalbox)
RCLONE_PATH="\$RCLONE_BIN"
# Результат проверки запоминается до перезагрузки, пока сам rclone не обновлён.
RC_CACHE=/tmp/save_sync_rclone_path
RC_STAMP="\$(stat -c %Y "\$RCLONE_BIN" 2>/dev/null)"
if [ -n "\$RC_STAMP" ] && [ -f "\$RC_CACHE" ] && [ "\$(sed -n 2p "\$RC_CACHE")" = "\$RC_STAMP" ] && [ "\$(sed -n 3p "\$RC_CACHE")" = "\$RCLONE_BIN" ] && [ -x "\$(sed -n 1p "\$RC_CACHE")" ]; then
    RCLONE_PATH="\$(sed -n 1p "\$RC_CACHE")"
else
    RC_OK=0
    if "\$RCLONE_PATH" version >/dev/null 2>&1; then
        RC_OK=1
    else
        mkdir -p /tmp/save_sync_bin 2>/dev/null
        cp -f "\$RCLONE_BIN" /tmp/save_sync_bin/rclone 2>/dev/null
        chmod +x /tmp/save_sync_bin/rclone 2>/dev/null
        if /tmp/save_sync_bin/rclone version >/dev/null 2>&1; then
            RCLONE_PATH="/tmp/save_sync_bin/rclone"
            RC_OK=1
        fi
    fi
    [ \$RC_OK -eq 1 ] && [ -n "\$RC_STAMP" ] && printf '%s\n%s\n%s\n' "\$RCLONE_PATH" "\$RC_STAMP" "\$RCLONE_BIN" > "\$RC_CACHE" 2>/dev/null
fi
CONFIG_FILE="$CONFIG_FILE"
LOG_FILE="$LOG_FILE"
STATUS_FILE="$STATUS_FILE"
LAST_SYNC_TIME="$LAST_SYNC_TIME"
PROGRESS_FILE="/tmp/save_sync_progress.json"
PROGRESS_LOG="/tmp/save_sync_progress.log"
WEB_PROGRESS=false

if [ -f "\$CONFIG_FILE" ]; then
    . "\$CONFIG_FILE"
fi

# лог не больше MAX_LOG_SIZE: при превышении старая часть уходит в .old
if [ -f "\$LOG_FILE" ] && [ "\$(wc -c < "\$LOG_FILE" 2>/dev/null || echo 0)" -gt "\${MAX_LOG_SIZE:-102400}" ] 2>/dev/null; then
    mv -f "\$LOG_FILE" "\$LOG_FILE.old" 2>/dev/null
fi

# LOG_LEVEL="debug" in the config: write how long each stage of the sync took
# uptime, not the clock: at boot the clock can jump by years when it is set over the network
T0=\$(cut -d. -f1 /proc/uptime 2>/dev/null || date +%s)
[ "\$LOG_LEVEL" = "debug" ] && export SS_TIMING=1

# on-screen message (EmulationStation on Batocera / KNULLI); silent if unavailable
notify_screen() {
    [ "\${NOTIFICATIONS:-true}" = "false" ] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    curl -s -m 3 -X POST -H "Content-Type: text/plain; charset=utf-8" --data-binary "\$1" http://127.0.0.1:1234/notify >/dev/null 2>&1 || true
}

# ======== ОБРАБОТКА АРГУМЕНТОВ ========
SHOW_PROGRESS=""
FORCE_SYNC=false

if [ "\$1" = "--detach" ]; then
    # Фоновый запуск. Интервал сохраняется для автоматических событий.
    nohup bash -c "sleep 3; bash $UPLOAD_SCRIPT --bg" > /dev/null 2>&1 &
    exit 0
fi

if [ "\$1" = "--bg" ]; then
    SHOW_PROGRESS=""
elif [ "\$1" = "--force" ]; then
    FORCE_SYNC=true
elif [ "\$1" = "--web-progress" ]; then
    SHOW_PROGRESS=""
    FORCE_SYNC=true
    WEB_PROGRESS=true
elif [ "\$1" = "--verbose" ]; then
    SHOW_PROGRESS="yes"
    FORCE_SYNC=true
fi

# ======== ПРОГРЕСС ДЛЯ WEB UI ========
progress_start() {
    local action="\$1"
    local phase="\$2"
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":true,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0}\n' \
            "\$action" "\$phase" > "\$PROGRESS_FILE"
        : > "\$PROGRESS_LOG"
    fi
}

progress_finish() {
    local ok="\$1"
    local action="\$2"
    local phase="\$3"
    if [ "\$WEB_PROGRESS" = "true" ]; then
        if [ "\$ok" = "true" ]; then
            printf '{"active":false,"action":"%s","phase":"%s","percent":100,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":true}\n' \
                "\$action" "\$phase" > "\$PROGRESS_FILE"
        else
            printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false}\n' \
                "\$action" "\$phase" > "\$PROGRESS_FILE"
        fi
    fi
}

# ======== ОСНОВНАЯ ЛОГИКА ========
save_status() {
    echo "\$1 \$(date +%s)" > "\$STATUS_FILE"
}

# ======== ПОСТОЯННОЕ СОСТОЯНИЕ СИНХРОНИЗАЦИИ ========
# Хранится на разделе share, поэтому переживает перезагрузку (в отличие от /tmp).
# Пишут его только скрипты синхронизации, веб-интерфейс его не трогает.
state_get() {
    [ -f "\$STATE_FILE" ] || return 0
    grep "^\$1=" "\$STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# state_set КЛЮЧ ЗНАЧЕНИЕ  (пустое ЗНАЧЕНИЕ удаляет ключ)
state_set() {
    (
        flock 9
        tmp="\$STATE_FILE.tmp.\$\$"
        {
            [ -f "\$STATE_FILE" ] && grep -v "^\$1=" "\$STATE_FILE"
            [ -n "\$2" ] && echo "\$1=\$2"
        } > "\$tmp" 2>/dev/null
        mv -f "\$tmp" "\$STATE_FILE" 2>/dev/null
    ) 9>/tmp/save_sync_state.lock
}

exec 200>"\$LOCK_FILE"
flock -n 200 || { echo "\$(date '+%d.%m %H:%M:%S') Пропущено: предыдущая выгрузка ещё выполняется" >> "\$LOG_FILE" 2>/dev/null; exit 0; }

# ======== ОТМЕНА (кнопка «Отмена» в веб-интерфейсе, Ctrl+C, выключение) ========
# rclone получает тот же сигнал и останавливается; здесь только
# записывается результат, чтобы прогресс в веб-интерфейсе не висел.
on_cancel() {
    trap - TERM INT
    save_status "ERROR"
    state_set PENDING_UPLOAD 1
    echo "\$(date '+%d.%m %H:%M:%S') Отменена выгрузка сохранений - изменения будут выгружены в следующий раз" >> "\$LOG_FILE" 2>/dev/null
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false,"cancelled":true}\n' \
            "upload" "Отменена выгрузка сохранений - изменения будут выгружены в следующий раз" > "\$PROGRESS_FILE"
    fi
    exit 130
}
trap on_cancel TERM INT

# Синхронизацию выполняет sync_engine.py (нужен python3). Если чего-то
# не хватает, ничего не делаем и пишем понятную ошибку в лог.
ENGINE_ERR=""
command -v python3 >/dev/null 2>&1 || ENGINE_ERR="не найден python3 - без него синхронизация сохранений невозможна"
[ -f "\$ENGINE_SCRIPT" ] || ENGINE_ERR="не найден sync_engine.py - переустановите Save Sync"
if [ -n "\$ENGINE_ERR" ]; then
    save_status "ERROR"
    echo "\$(date '+%d.%m %H:%M:%S') Ошибка выгрузки сохранений: \$ENGINE_ERR" >> "\$LOG_FILE" 2>/dev/null
    [ -n "\$SHOW_PROGRESS" ] && echo "❌ \$ENGINE_ERR"
    state_set PENDING_UPLOAD 1
    progress_start "upload" "Ошибка выгрузки сохранений"
    progress_finish false "upload" "Ошибка выгрузки сохранений: \$ENGINE_ERR"
    exit 1
fi


# Синхронизация после игры (настройка «Синхронизация после игры», SYNC_MODE):
#   economy - только при изменениях: сохранения на устройстве не менялись - облако не трогается,
#             менялись - быстрая синхронизация
#   fast    - после каждой игры: чужие изменения и удаления берутся из манифестов, облако
#             спрашивается только про эти файлы и изменённые здесь
#   full    - полная: весь список файлов в облаке, как в прошлых версиях
# При включении, из меню, веб-интерфейса, с --force и после неудачной выгрузки
# (PENDING_UPLOAD) синхронизация всегда полная. Старая настройка SKIP_UNCHANGED:
# включена = только при изменениях (economy), выключена = полная.
case "\$SYNC_MODE" in
    full|fast|economy) ;;
    *) if [ "\$SKIP_UNCHANGED" = "false" ]; then SYNC_MODE=full; else SYNC_MODE=economy; fi ;;
esac
LOCAL_CHANGED=""
FAST_SYNC=""
if [ "\$SYNC_MODE" != "full" ] && [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ -z "\$(state_get PENDING_UPLOAD)" ]; then
    FAST_SYNC=1
fi
if [ -n "\$FAST_SYNC" ] && [ "\$SYNC_MODE" = "economy" ]; then
    if SS_EXCLUDED="\$EXCLUDED_SYSTEMS" python3 "\$ENGINE_SCRIPT" check >/dev/null 2>&1; then
        echo "\$(date '+%d.%m %H:%M:%S') Синхронизация (нет изменений) - облако не запрашивалось" >> "\$LOG_FILE" 2>/dev/null
        exit 0
    else
        LOCAL_CHANGED=1
    fi
fi

# Проверка интервала (ТОЛЬКО если НЕ принудительная синхронизация)
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ \$SYNC_INTERVAL -gt 0 ] && [ -f "\$LAST_SYNC_TIME" ]; then
    LAST=\$(cat "\$LAST_SYNC_TIME" 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [ \$((NOW - LAST)) -lt \$SYNC_INTERVAL ]; then
        echo "\$(date '+%d.%m %H:%M:%S') Выгрузка пропущена (интервал \$SYNC_INTERVAL сек)" >> "\$LOG_FILE" 2>/dev/null
        # Это не ошибка, но изменения пока есть только на устройстве
        state_set PENDING_UPLOAD 1
        exit 0
    fi
fi

# Автоматическая выгрузка после игры: показываем, что она началась, а если она затянулась -
# раз в минуту напоминаем, что процесс идёт. Не показывается, если менять нечего.
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ "\$WEB_PROGRESS" != "true" ]; then
    if [ -n "\$(state_get PENDING_UPLOAD)" ] || [ "\$LOCAL_CHANGED" = "1" ] || \
       { [ -z "\$LOCAL_CHANGED" ] && ! SS_EXCLUDED="\$EXCLUDED_SYSTEMS" python3 "\$ENGINE_SCRIPT" check >/dev/null 2>&1; }; then
        notify_screen "Save Sync: синхронизация началась"
        (
            P=\$\$; n=0
            while sleep 60; do
                kill -0 "\$P" 2>/dev/null || break
                n=\$((n+1))
                notify_screen "Save Sync: синхронизация ещё идёт (\$n мин)"
            done
        ) 200>&- >/dev/null 2>&1 &
    fi
fi

# Ждём, пока часы не станут разумными. На Raspberry Pi нет RTC,
# и до синхронизации по NTP дата может быть 01.01 - из-за этого
# HTTPS-соединение с облаком падает по проверке сертификата, даже
# если сеть уже работает.
CLOCK_WAIT=0
while [ "\$(date +%Y)" -lt 2024 ]; do
    CLOCK_WAIT=\$((CLOCK_WAIT+1))
    if [ \$CLOCK_WAIT -ge 20 ]; then
        break
    fi
    sleep 3
done

# Ждём облако около 30 секунд: после игры сеть обычно уже есть, а если её
# нет, сохранения уйдут позже (PENDING_UPLOAD). Проверяется само облако, а не ping
# до 1.1.1.1: в некоторых сетях ping закрыт, хотя облако работает.
# Срок считаем по uptime - обычные часы могут прыгнуть при синхронизации NTP.
uptime_sec() { cut -d. -f1 /proc/uptime; }
WAIT_UNTIL=\$(( \$(uptime_sec) + 30 ))
CLOUD_OK=0
while :; do
    if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsd "\$REMOTE_NAME:" \
        --contimeout 15s --timeout 30s --low-level-retries 1 --retries 1 >/dev/null 2>&1; then
        CLOUD_OK=1
        break
    fi
    [ "\$(uptime_sec)" -ge "\$WAIT_UNTIL" ] && break
    sleep 5
done
if [ \$CLOUD_OK -eq 0 ]; then
    echo "\$(date '+%d.%m %H:%M:%S') Облако недоступно (нет сети или облако не отвечает)" >> "\$LOG_FILE" 2>/dev/null
    notify_screen "Save Sync: нет связи с облаком, сохранения отправятся позже"
    save_status "ERROR"
    state_set PENDING_UPLOAD 1
    exit 1
fi

# ======== ДВУСТОРОННЯЯ СИНХРОНИЗАЦИЯ (sync_engine.py) ========
# Устройство и облако сравниваются с последней синхронизацией: скачивается
# только изменённое в облаке, отправляется только изменённое здесь. Если
# сохранение изменили на разных устройствах, остаётся более новое, а старое
# копируется в папку _conflicts (срок - настройка «Копии при конфликтах»). Ничего не спрашивается.
T_ENG=\$(cut -d. -f1 /proc/uptime 2>/dev/null || date +%s)
progress_start "upload" "Выгрузка сохранений"
ENGINE_ARGS=(sync)
[ "\$WEB_PROGRESS" = "true" ] && ENGINE_ARGS+=(--web-progress)
[ -n "\$FAST_SYNC" ] && ENGINE_ARGS+=(--fast)
if [ -n "\$SHOW_PROGRESS" ]; then
    SS_RCLONE="\$RCLONE_PATH" SS_EXCLUDED="\$EXCLUDED_SYSTEMS" SS_RETRIES="\$MAX_RETRIES" SS_KEEP_DAYS="\${CONFLICT_KEEP_DAYS:-3}" SS_RESULT="/tmp/save_sync_result.\$\$" \
        python3 "\$ENGINE_SCRIPT" "\${ENGINE_ARGS[@]}" --verbose
else
    SS_RCLONE="\$RCLONE_PATH" SS_EXCLUDED="\$EXCLUDED_SYSTEMS" SS_RETRIES="\$MAX_RETRIES" SS_KEEP_DAYS="\${CONFLICT_KEEP_DAYS:-3}" SS_RESULT="/tmp/save_sync_result.\$\$" \
        python3 "\$ENGINE_SCRIPT" "\${ENGINE_ARGS[@]}" > /dev/null 2>&1
fi
ENGINE_EXIT=\$?
if [ \$ENGINE_EXIT -eq 0 ]; then
    # the marker is still needed by devices on older versions
    if [ "\$(state_get MARKER_DONE)" != "\$FIRST_SYNC_MARKER" ]; then
        if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$FIRST_SYNC_MARKER" 2>/dev/null | grep -q . || \
            echo "first_sync_\$(date +%s)" | "\$RCLONE_PATH" --config "\$RCLONE_CONF" rcat "\$FIRST_SYNC_MARKER" 2>/dev/null; then
            state_set MARKER_DONE "\$FIRST_SYNC_MARKER"
        fi
    fi
    date +%s > "\$READY_FILE"
    date +%s > "\$LAST_SYNC_TIME"
    save_status "OK"
    state_set PENDING_UPLOAD ""
    state_set LAST_GOOD_SYNC "\$(date +%s)"
    [ "\$LOG_LEVEL" = "debug" ] && echo "\$(date '+%d.%m %H:%M:%S') Время: до запуска синхронизации \$((T_ENG - T0)) с" >> "\$LOG_FILE" 2>/dev/null
    SYNC_NOTE=\$(cat "/tmp/save_sync_result.\$\$" 2>/dev/null); rm -f "/tmp/save_sync_result.\$\$"
    if [ "\$FORCE_SYNC" = "true" ]; then SYNC_WHAT="Синхронизация вручную"; else SYNC_WHAT="Синхронизация"; fi
    echo "\$(date '+%d.%m %H:%M:%S') \$SYNC_WHAT\${SYNC_NOTE:+ (\$SYNC_NOTE)}" >> "\$LOG_FILE" 2>/dev/null
    if [ -n "\$SYNC_NOTE" ] && [ "\$SYNC_NOTE" != "нет изменений" ]; then
        case "\$SYNC_NOTE" in
            *конфликт*) [ "\${CONFLICT_KEEP_DAYS:-3}" != "0" ] && notify_screen "Save Sync: конфликт сохранений - подробнее в веб-интерфейсе" || notify_screen "Save Sync: \$SYNC_NOTE" ;;
            *) notify_screen "Save Sync: \$SYNC_NOTE" ;;
        esac
    fi
    progress_finish true "upload" "Выгрузка сохранений завершена"
    exit 0
fi
save_status "ERROR"
echo "\$(date '+%d.%m %H:%M:%S') Ошибка выгрузки сохранений (код: \$ENGINE_EXIT)" >> "\$LOG_FILE" 2>/dev/null
if grep -q "^cloud_full" "/tmp/save_sync_result.\$\$" 2>/dev/null; then
    notify_screen "Save Sync: ошибка - в облаке закончилось место"
else
    notify_screen "Save Sync: ошибка синхронизации"
fi
rm -f "/tmp/save_sync_result.\$\$"
state_set PENDING_UPLOAD 1
progress_finish false "upload" "Ошибка выгрузки сохранений"
exit 1
ENDOFSCRIPT
    chmod +x "$UPLOAD_SCRIPT"
}

############################################
# create_hook_script
############################################

create_hook_script() {
    if [ "$SYSTEM" = "Recalbox" ]; then
        # Recalbox использует совершенно другой механизм хуков, чем
        # Batocera: скрипты кладутся в /recalbox/share/userscripts,
        # событие выхода из игры называется EndGame (а не gameStop),
        # фильтр события задаётся квадратными скобками в ИМЕНИ ФАЙЛА,
        # а аргументы передаются как "-action ACTION -statefile FILE",
        # а не позиционным $1.
        # См. https://wiki.recalbox.com/en/advanced-usage/scripts-on-emulationstation-events
        local USERSCRIPTS_DIR="/recalbox/share/userscripts"
        mkdir -p "$USERSCRIPTS_DIR" 2>/dev/null
        # Удаляем хук старого (Batocera-style) формата, если остался от
        # предыдущей версии скрипта
        rm -f "$SCRIPT_DIR/save-sync.sh" 2>/dev/null

        cat > "$USERSCRIPTS_DIR/save-sync[endgame].sh" << ENDOFSCRIPT
#!/bin/sh

LOG_FILE="$LOG_FILE"

echo "\$(date '+%d.%m %H:%M:%S') Выход из игры" >> "\$LOG_FILE" 2>/dev/null
bash "$UPLOAD_SCRIPT" --detach &
ENDOFSCRIPT
        chmod +x "$USERSCRIPTS_DIR/save-sync[endgame].sh" 2>/dev/null
    else
        mkdir -p "$SCRIPT_DIR" 2>/dev/null
        cat > "$SCRIPT_DIR/save-sync.sh" << ENDOFSCRIPT
#!/bin/bash

# Хук для Batocera - вызывается при событиях эмулятора
LOG_FILE="$LOG_FILE"

log_hook() {
    echo "\$(date '+%d.%m %H:%M:%S') \$1" >> "\$LOG_FILE" 2>/dev/null
}

case "\$1" in
    gameStop)
        log_hook "Выход из игры"
        bash "$UPLOAD_SCRIPT" --detach &
        ;;
esac
exit 0
ENDOFSCRIPT
        chmod +x "$SCRIPT_DIR/save-sync.sh"
    fi
}

############################################
# Создание скриптов для ромов (с логированием)
############################################

create_roms_scripts() {
    load_config
    create_roms_filter
    
    cat > "$DOWNLOAD_ROMS" << ENDOFSCRIPT
#!/bin/bash

RCLONE_BIN="$RCLONE_BIN"

# Само-восстановление, если раздел с rclone смонтирован noexec
# (например, /recalbox/share на Recalbox)
RCLONE_PATH="\$RCLONE_BIN"
# Результат проверки запоминается до перезагрузки, пока сам rclone не обновлён.
RC_CACHE=/tmp/save_sync_rclone_path
RC_STAMP="\$(stat -c %Y "\$RCLONE_BIN" 2>/dev/null)"
if [ -n "\$RC_STAMP" ] && [ -f "\$RC_CACHE" ] && [ "\$(sed -n 2p "\$RC_CACHE")" = "\$RC_STAMP" ] && [ "\$(sed -n 3p "\$RC_CACHE")" = "\$RCLONE_BIN" ] && [ -x "\$(sed -n 1p "\$RC_CACHE")" ]; then
    RCLONE_PATH="\$(sed -n 1p "\$RC_CACHE")"
else
    RC_OK=0
    if "\$RCLONE_PATH" version >/dev/null 2>&1; then
        RC_OK=1
    else
        mkdir -p /tmp/save_sync_bin 2>/dev/null
        cp -f "\$RCLONE_BIN" /tmp/save_sync_bin/rclone 2>/dev/null
        chmod +x /tmp/save_sync_bin/rclone 2>/dev/null
        if /tmp/save_sync_bin/rclone version >/dev/null 2>&1; then
            RCLONE_PATH="/tmp/save_sync_bin/rclone"
            RC_OK=1
        fi
    fi
    [ \$RC_OK -eq 1 ] && [ -n "\$RC_STAMP" ] && printf '%s\n%s\n%s\n' "\$RCLONE_PATH" "\$RC_STAMP" "\$RCLONE_BIN" > "\$RC_CACHE" 2>/dev/null
fi
RCLONE_CONF="$RCLONE_CONF"
ROMS_DIR="$ROMS_DIR"
REMOTE_ROMS="$REMOTE_ROMS"
FILTER_FILE="$ROMS_FILTER_FILE"
LOG_FILE="$LOG_FILE"
PROGRESS_FILE="/tmp/save_sync_progress.json"
PROGRESS_LOG="/tmp/save_sync_progress.log"
WEB_PROGRESS=false
CONFIG_FILE="$CONFIG_FILE"

# on-screen message (EmulationStation on Batocera / KNULLI); silent if unavailable
notify_screen() {
    [ -f "\$CONFIG_FILE" ] && grep -q '^NOTIFICATIONS="false"' "\$CONFIG_FILE" && return 0
    command -v curl >/dev/null 2>&1 || return 0
    curl -s -m 3 -X POST -H "Content-Type: text/plain; charset=utf-8" --data-binary "\$1" http://127.0.0.1:1234/notify >/dev/null 2>&1 || true
}

if [ "\$1" = "--web-progress" ]; then
    WEB_PROGRESS=true
fi

progress_start() {
    local action="\$1"
    local phase="\$2"
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":true,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0}\n' \
            "\$action" "\$phase" > "\$PROGRESS_FILE"
        : > "\$PROGRESS_LOG"
    fi
}

progress_finish() {
    local ok="\$1"
    local action="\$2"
    local phase="\$3"
    if [ "\$WEB_PROGRESS" = "true" ]; then
        local percent=0
        if [ "\$ok" = "true" ]; then percent=100; fi
        printf '{"active":false,"action":"%s","phase":"%s","percent":%s,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":%s}\n' \
            "\$action" "\$phase" "\$percent" "\$ok" > "\$PROGRESS_FILE"
    fi
}

run_transfer() {
    if [ "\$WEB_PROGRESS" = "true" ]; then
        local args=()
        for arg in "\$@"; do
            [ "\$arg" = "--progress" ] && continue
            args+=("\$arg")
        done
        "\$RCLONE_PATH" --config "\$RCLONE_CONF" "\${args[@]}" \
            --stats 1s --stats-log-level NOTICE --use-json-log \
            > /dev/null 2>"\$PROGRESS_LOG"
    else
        "\$RCLONE_PATH" --config "\$RCLONE_CONF" "\$@" --progress
    fi
}

# Функция логирования
log_msg() {
    echo "\$(date '+%d.%m %H:%M:%S') \$1" >> "\$LOG_FILE"
}

# лог не больше MAX_LOG_SIZE: при превышении старая часть уходит в .old
if [ -f "\$LOG_FILE" ] && [ "\$(wc -c < "\$LOG_FILE" 2>/dev/null || echo 0)" -gt "\${MAX_LOG_SIZE:-102400}" ] 2>/dev/null; then
    mv -f "\$LOG_FILE" "\$LOG_FILE.old" 2>/dev/null
fi

log_msg "Начало загрузки ромов"

# ======== ОТМЕНА (кнопка «Отмена» в веб-интерфейсе, Ctrl+C, выключение) ========
# rclone получает тот же сигнал и останавливается; здесь только
# записывается результат, чтобы прогресс в веб-интерфейсе не висел.
on_cancel() {
    trap - TERM INT
    echo "\$(date '+%d.%m %H:%M:%S') Отменена загрузка ромов" >> "\$LOG_FILE" 2>/dev/null
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false,"cancelled":true}\n' \
            "roms_download" "Отменена загрузка ромов" > "\$PROGRESS_FILE"
    fi
    exit 130
}
trap on_cancel TERM INT


"\$RCLONE_PATH" --config "\$RCLONE_CONF" mkdir "\$REMOTE_ROMS" 2>/dev/null

echo "🔄 Загрузка ромов из облака..."

notify_screen "Save Sync: загрузка ромов началась"
(
    P=\$\$; n=0
    while sleep 60; do
        kill -0 "\$P" 2>/dev/null || break
        n=\$((n+1))
        notify_screen "Save Sync: загрузка ромов ещё идёт (\$n мин)"
    done
) 200>&- >/dev/null 2>&1 &

progress_start "roms_download" "Загрузка ромов"
run_transfer copy "\$REMOTE_ROMS" "\$ROMS_DIR" \
    --update \
    --filter-from "\$FILTER_FILE"

EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ] || [ \$EXIT_CODE -eq 3 ]; then
    echo "✅ Загрузка ромов завершена"
    log_msg "Загрузка ромов завершена"
    progress_finish true "roms_download" "Загрузка ромов завершена"
    notify_screen "Save Sync: ромы загружены"
    # новые игры сразу появляются в списке EmulationStation (Batocera, KNULLI),
    # если ES ничем не занят: не идёт игра, скрапер или обновление
    if curl -s -m 3 http://127.0.0.1:1234/isIdle 2>/dev/null | grep -q true; then
        curl -s -m 5 http://127.0.0.1:1234/reloadgames >/dev/null 2>&1 || true
    fi
else
    echo "❌ Ошибка загрузки ромов (код: \$EXIT_CODE)"
    log_msg "Ошибка загрузки ромов (код: \$EXIT_CODE)"
    progress_finish false "roms_download" "Ошибка загрузки ромов"
    notify_screen "Save Sync: ошибка загрузки ромов"
fi

log_msg "Конец загрузки ромов"

exit \$EXIT_CODE
ENDOFSCRIPT
    
    chmod +x "$DOWNLOAD_ROMS"
    
    cat > "$UPLOAD_ROMS" << ENDOFSCRIPT
#!/bin/bash

RCLONE_BIN="$RCLONE_BIN"

# Само-восстановление, если раздел с rclone смонтирован noexec
# (например, /recalbox/share на Recalbox)
RCLONE_PATH="\$RCLONE_BIN"
# Результат проверки запоминается до перезагрузки, пока сам rclone не обновлён.
RC_CACHE=/tmp/save_sync_rclone_path
RC_STAMP="\$(stat -c %Y "\$RCLONE_BIN" 2>/dev/null)"
if [ -n "\$RC_STAMP" ] && [ -f "\$RC_CACHE" ] && [ "\$(sed -n 2p "\$RC_CACHE")" = "\$RC_STAMP" ] && [ "\$(sed -n 3p "\$RC_CACHE")" = "\$RCLONE_BIN" ] && [ -x "\$(sed -n 1p "\$RC_CACHE")" ]; then
    RCLONE_PATH="\$(sed -n 1p "\$RC_CACHE")"
else
    RC_OK=0
    if "\$RCLONE_PATH" version >/dev/null 2>&1; then
        RC_OK=1
    else
        mkdir -p /tmp/save_sync_bin 2>/dev/null
        cp -f "\$RCLONE_BIN" /tmp/save_sync_bin/rclone 2>/dev/null
        chmod +x /tmp/save_sync_bin/rclone 2>/dev/null
        if /tmp/save_sync_bin/rclone version >/dev/null 2>&1; then
            RCLONE_PATH="/tmp/save_sync_bin/rclone"
            RC_OK=1
        fi
    fi
    [ \$RC_OK -eq 1 ] && [ -n "\$RC_STAMP" ] && printf '%s\n%s\n%s\n' "\$RCLONE_PATH" "\$RC_STAMP" "\$RCLONE_BIN" > "\$RC_CACHE" 2>/dev/null
fi
RCLONE_CONF="$RCLONE_CONF"
ROMS_DIR="$ROMS_DIR"
REMOTE_ROMS="$REMOTE_ROMS"
FILTER_FILE="$ROMS_FILTER_FILE"
LOG_FILE="$LOG_FILE"
PROGRESS_FILE="/tmp/save_sync_progress.json"
PROGRESS_LOG="/tmp/save_sync_progress.log"
WEB_PROGRESS=false
CONFIG_FILE="$CONFIG_FILE"

# on-screen message (EmulationStation on Batocera / KNULLI); silent if unavailable
notify_screen() {
    [ -f "\$CONFIG_FILE" ] && grep -q '^NOTIFICATIONS="false"' "\$CONFIG_FILE" && return 0
    command -v curl >/dev/null 2>&1 || return 0
    curl -s -m 3 -X POST -H "Content-Type: text/plain; charset=utf-8" --data-binary "\$1" http://127.0.0.1:1234/notify >/dev/null 2>&1 || true
}

if [ "\$1" = "--web-progress" ]; then
    WEB_PROGRESS=true
fi

progress_start() {
    local action="\$1"
    local phase="\$2"
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":true,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0}\n' \
            "\$action" "\$phase" > "\$PROGRESS_FILE"
        : > "\$PROGRESS_LOG"
    fi
}

progress_finish() {
    local ok="\$1"
    local action="\$2"
    local phase="\$3"
    if [ "\$WEB_PROGRESS" = "true" ]; then
        local percent=0
        if [ "\$ok" = "true" ]; then percent=100; fi
        printf '{"active":false,"action":"%s","phase":"%s","percent":%s,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":%s}\n' \
            "\$action" "\$phase" "\$percent" "\$ok" > "\$PROGRESS_FILE"
    fi
}

run_transfer() {
    if [ "\$WEB_PROGRESS" = "true" ]; then
        local args=()
        for arg in "\$@"; do
            [ "\$arg" = "--progress" ] && continue
            args+=("\$arg")
        done
        "\$RCLONE_PATH" --config "\$RCLONE_CONF" "\${args[@]}" \
            --stats 1s --stats-log-level NOTICE --use-json-log \
            > /dev/null 2>"\$PROGRESS_LOG"
    else
        "\$RCLONE_PATH" --config "\$RCLONE_CONF" "\$@" --progress
    fi
}

# Функция логирования
log_msg() {
    echo "\$(date '+%d.%m %H:%M:%S') \$1" >> "\$LOG_FILE"
}

# лог не больше MAX_LOG_SIZE: при превышении старая часть уходит в .old
if [ -f "\$LOG_FILE" ] && [ "\$(wc -c < "\$LOG_FILE" 2>/dev/null || echo 0)" -gt "\${MAX_LOG_SIZE:-102400}" ] 2>/dev/null; then
    mv -f "\$LOG_FILE" "\$LOG_FILE.old" 2>/dev/null
fi

log_msg "Начало выгрузки ромов"

# ======== ОТМЕНА (кнопка «Отмена» в веб-интерфейсе, Ctrl+C, выключение) ========
# rclone получает тот же сигнал и останавливается; здесь только
# записывается результат, чтобы прогресс в веб-интерфейсе не висел.
on_cancel() {
    trap - TERM INT
    echo "\$(date '+%d.%m %H:%M:%S') Отменена выгрузка ромов" >> "\$LOG_FILE" 2>/dev/null
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false,"cancelled":true}\n' \
            "roms_upload" "Отменена выгрузка ромов" > "\$PROGRESS_FILE"
    fi
    exit 130
}
trap on_cancel TERM INT


"\$RCLONE_PATH" --config "\$RCLONE_CONF" mkdir "\$REMOTE_ROMS" 2>/dev/null

echo "🔄 Копирование ромов в облако..."

notify_screen "Save Sync: выгрузка ромов началась"
(
    P=\$\$; n=0
    while sleep 60; do
        kill -0 "\$P" 2>/dev/null || break
        n=\$((n+1))
        notify_screen "Save Sync: выгрузка ромов ещё идёт (\$n мин)"
    done
) 200>&- >/dev/null 2>&1 &

progress_start "roms_upload" "Выгрузка ромов"
run_transfer sync "\$ROMS_DIR" "\$REMOTE_ROMS" \
    --delete-after \
    --filter-from "\$FILTER_FILE"

EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ] || [ \$EXIT_CODE -eq 3 ]; then
    echo "✅ Выгрузка ромов завершена"
    log_msg "Выгрузка ромов завершена"
    progress_finish true "roms_upload" "Выгрузка ромов завершена"
    notify_screen "Save Sync: ромы выгружены"
else
    echo "❌ Ошибка выгрузки ромов (код: \$EXIT_CODE)"
    log_msg "❌ Ошибка выгрузки ромов (код: \$EXIT_CODE)"
    progress_finish false "roms_upload" "Ошибка выгрузки ромов"
    notify_screen "Save Sync: ошибка выгрузки ромов"
fi

log_msg "Конец выгрузки ромов"

exit \$EXIT_CODE
ENDOFSCRIPT
    
    chmod +x "$UPLOAD_ROMS"
    
    echo "✅ Скрипты для ромов созданы (с логированием)"
    create_link_script
}

############################################
# create_link_script - загрузка по публичной ссылке (Python)
############################################

create_link_script() {
    cat > "$LINK_SCRIPT" << 'LINKEOF'
#!/usr/bin/env python3
# Save Sync - download files from a public link to the device or to your cloud.
# Supported: Yandex Disk, pCloud, Nextcloud / ownCloud, archive.org.
# Files are transferred one by one, the folder structure is kept; a .zip can be
# opened to take single files from it (they are unpacked on the fly),
# files already present with the same size are skipped.
#   device: files go to roms/<system>; an interrupted download resumes from .part
#   cloud:  files are streamed through the device into <cloud>:GameROMs/<system>
#           (nothing is stored on the card); download them to the device later
#           with ROMs -> Download ROMs, like any system that is only in the cloud
#
# Usage:
#   link_download.py [URL]                                   interactive
#   link_download.py --list-json URL [--password PW]         folder tree as JSON
#   link_download.py --zip-json URL PATH                     contents of the .zip at PATH as JSON
#   link_download.py --dests-json device|cloud               destination systems as JSON
#   link_download.py --download URL --dest SYSTEM [--target device|cloud]
#                    [--item PATH]... [--password PW] [--unpack] [--web-progress]
#     --unpack  unpack .zip/.7z/.rar: on the device next to themselves (the archive is
#               deleted); for the cloud .zip files are taken straight from the archive,
#               .7z/.rar are unpacked in a temporary folder on the card and uploaded
#               (.7z/.rar need 7z/7zr/unrar/bsdtar on the system)
#     --dest    a system folder name (roms/<system> or GameROMs/<system>)
#     --item    path inside the link to download (repeatable); a single
#               folder item is unpacked: its CONTENTS go into --dest.
#               Without --item the contents of the whole link are downloaded.
#     a .zip:   "a.zip" = the archive as is, "a.zip/" = its contents (unpacked),
#               "a.zip/x.gb" = one file from it. Only the chosen files are read
#               from the archive (HTTP Range requests) and unpacked on the fly.
#   The password can also be passed in the SS_LINK_PASSWORD environment variable.

import errno
import io
import fcntl
import json
import os
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from base64 import b64encode
from datetime import datetime

LANG = "__SS_LANG__"
ROMS_DIR = "__SS_ROMS_DIR__"
LOG_FILE = "__SS_LOG_FILE__"
RCLONE_BIN = "__SS_RCLONE_BIN__"
RCLONE_CONF = "__SS_RCLONE_CONF__"
REMOTE_ROMS = "__SS_REMOTE_ROMS__"
CONFIG_FILE = "__SS_CONFIG_FILE__"

PROGRESS_FILE = "/tmp/save_sync_progress.json"
LOCK_FILE = "/tmp/save_sync_link.lock"
PID_FILE = "/tmp/save_sync_link.pid"
YANDEX_API = "https://cloud-api.yandex.net/v1/disk/public/resources"
PCLOUD_APIS = ("https://api.pcloud.com", "https://eapi.pcloud.com")
PCLOUD_DL_SCHEME = "https"
ARCHIVE_META = "https://archive.org/metadata"
ARCHIVE_DL = "https://archive.org/download"
USER_AGENT = "SaveSync (+https://github.com/1DeX6/save-sync)"
MIN_FREE_BYTES = 50 * 1024 * 1024   # keep this much free on the card
RETRIES = 3
NO_SPACE = {"hit": False}      # set when a download stopped for lack of space
CHUNK = 256 * 1024
TIMEOUT = 60

# ============================================================== messages
MSG = {
    "en": {
        "title": "🔗 Download from a public link",
        "supported": "Supported: Yandex Disk, pCloud, Nextcloud / ownCloud, archive.org",
        "prompt_url": "Paste the link (empty - exit): ",
        "unsupported": "❌ This link is not supported.",
        "scanning": "🔍 Reading the file list... {n}",
        "scan_done": "✅ Found {files} files ({size})",
        "empty": "📭 There are no files at this link.",
        "password_prompt": "🔒 The link is password-protected (or does not exist). Password (empty - cancel): ",
        "password_wrong": "❌ Wrong password.",
        "password_needed": "🔒 The link is password-protected (or does not exist) - pass the password with --password",
        "not_found": "❌ The link was not found: it was deleted, expired or mistyped.",
        "api_error": "❌ The service returned an error: {err}",
        "net_error": "❌ Network error: {err}",
        "folder": "📂 {service}: /{path}",
        "dir_line": "{n:>3}  📁 {name}  ({files} files, {size})",
        "file_line": "{n:>3}  📄 {name}  ({size})",
        "help_title": "What to do:",
        "ask_unpack": "Unpack the archives after download ({kinds})? The archive is deleted after unpacking. (y/n): ",
        "unpack_cannot": "ℹ️  {kinds}: no program to unpack them on this system - they are downloaded as is.",
        "unpacking": "📦 Unpacking {name}...",
        "unpacked": "  📦 Unpacked {name}: files {n}",
        "unpack_failed": "  ❌ Could not unpack {name} (the archive is kept): {err}",
        "unpack_no_tool": "no program to unpack .{kind} on this system",
        "unpack_empty": "the archive is empty",
        "unpack_no_space": "not enough free space to unpack",
        "log_unpacked": "Link download: unpacked {name} ({n} files)",
        "unpack_cloud_note": "ℹ️  For the cloud: files from .zip are taken straight from the archive; .7z/.rar are first downloaded to the card for a moment, unpacked there and uploaded.",
        "cloud_uploading": "☁️  Uploading the unpacked files of {name} to the cloud...",
        "unpack_tmp_space": "not enough space on the card to unpack it temporarily (need {need}, free {free})",
        "zip_line": "{n:>3}  🗜  {name}  ({size}, archive - can be opened)",
        "help_open_zip": "  {ex:<8} - open archive \"{name}\" and pick files from it (unpacked on download)",
        "zip_reading": "🗜  Reading archive {name}...",
        "zip_bad": "❌ Cannot read archive {name}: it is damaged or not a zip. Tick the archive itself to download it whole.",
        "zip_no_range": "❌ This server does not allow reading an archive in parts. Tick the archive itself to download it whole.",
        "zip_encrypted": "❌ Archive {name} is password-protected: tick the archive itself to download it whole.",
        "zip_method": "the file is packed with a method Python cannot unpack - download the whole archive",
        "help_select": "  {ex:<8} - download the selected items (numbers separated by spaces)",
        "help_open": "  {ex:<8} - open folder \"{name}\" (o + folder number)",
        "help_all": "  {ex:<8} - download everything in this folder",
        "help_back": "  {ex:<8} - back to the previous folder",
        "help_quit": "  {ex:<8} - exit",
        "choice": "Choice: ",
        "bad_input": "❌ Invalid input",
        "not_folder": "❌ This is not a folder",
        "contents_note": "The CONTENTS of the folder \"{name}\" will be placed into {dest}",
        "items_note": "Selected items will be placed into {dest}",
        "choose_dest": "System number or name (q - exit)",
        "choose_target": "Where to download?\n  1 - to the device: roms/<system>\n  2 - to your cloud: GameROMs/<system> (then on the device: ROMs → Download ROMs)",
        "target_prompt": "Choice (1/2, q - exit): ",
        "grp_device_files": "Systems with games (ROM files):",
        "grp_device_other": "Systems without games:",
        "grp_cloud_files": "Systems in the cloud:",
        "grp_cloud_other": "Add a new system to the cloud:",
        "cloud_reading": "🔍 Reading the cloud folders...",
        "cloud_unavailable": "❌ The cloud is not available: Save Sync is not set up or rclone does not start.",
        "free_cloud": "Free in the cloud: {free}",
        "free_unknown": "Free space in the cloud: unknown",
        "cloud_label": "cloud: {path}",
        "cloud_done": "☁️  The files are in the cloud: {dest}. To put them on the device: ROMs → select the system → Download ROMs.",
        "dest_invalid": "❌ No such system",
        "no_roms_dir": "❌ ROMs folder not found: {path}",
        "plan": "Files to download: {files} ({size}), already on the device: {skip}",
        "free_space": "Free space: {free}",
        "no_space": "❌ Not enough free space: need {need}, free {free}",
        "nothing_to_do": "✅ All these files are already on the device.",
        "confirm": "Start the download? (y/n): ",
        "cancelled": "❌ Cancelled.",
        "progress": "\r  {pct:>3}%  {done} / {total}  {speed}/s  ETA {eta}   ",
        "file_start": "[{i}/{n}] {path}",
        "file_failed": "  ❌ Failed: {path} ({err})",
        "done": "✅ Done: downloaded {ok}, skipped {skip}, failed {fail}",
        "too_many_fail": "❌ Several files in a row failed - stopping. Check the network and run again.",
        "interrupted": "⏹  Interrupted. Run again with the same link to resume.",
        "locked": "❌ Another link download is already running.",
        "es_hint": "ℹ️  To see new games: EmulationStation menu → Update gamelists (or restart).",
        "es_reloaded": "ℹ️  New games were added to the EmulationStation list.",
        "units": ("B", "KB", "MB", "GB", "TB"),
        "log_start": "Link download: {service} {url} -> {dest}",
        "log_done": "Link download complete: {ok} downloaded, {skip} skipped, {fail} failed",
        "log_error": "Link download error: {err}",
        "phase": "Downloading from link",
        "svc_yandex": "Yandex Disk", "svc_pcloud": "pCloud", "svc_nextcloud": "Nextcloud",
        "svc_archive": "archive.org",
        "restricted": "❌ This archive.org item is restricted: it can only be downloaded after logging in on archive.org.",
        "cancelled_web": "Download cancelled",
        "running_other": "⏳ A link download is already running{pct} (PID {pid}).",
        "ask_stop": "Stop it? (y/n): ",
        "stopping": "Stopping...",
        "stopped": "✅ Stopped. Downloaded parts are kept - run the same link again to resume.",
        "stop_failed": "❌ Could not stop it (PID {pid}). Restart the device.",
        "keep_running": "The download continues. You can watch or cancel it in the Web UI too.",
        "cancelled_other": "⏹  The download was stopped from another session or the Web UI.",
        "detached_log": "SSH session closed - the link download continues in the background",
    },
    "ru": {
        "title": "🔗 Скачать по публичной ссылке",
        "supported": "Поддерживаются: Яндекс.Диск, pCloud, Nextcloud / ownCloud, archive.org",
        "prompt_url": "Вставьте ссылку (пусто - выход): ",
        "unsupported": "❌ Эта ссылка не поддерживается.",
        "scanning": "🔍 Получаю список файлов... {n}",
        "scan_done": "✅ Найдено файлов: {files} ({size})",
        "empty": "📭 По ссылке нет файлов.",
        "password_prompt": "🔒 Ссылка защищена паролем (или не существует). Пароль (пусто - отмена): ",
        "password_wrong": "❌ Неверный пароль.",
        "password_needed": "🔒 Ссылка защищена паролем (или не существует) - укажите пароль через --password",
        "not_found": "❌ Ссылка не найдена: удалена, истекла или введена с ошибкой.",
        "api_error": "❌ Сервис вернул ошибку: {err}",
        "net_error": "❌ Ошибка сети: {err}",
        "folder": "📂 {service}: /{path}",
        "dir_line": "{n:>3}  📁 {name}  (файлов: {files}, {size})",
        "file_line": "{n:>3}  📄 {name}  ({size})",
        "help_title": "Что сделать:",
        "ask_unpack": "Распаковать архивы после скачивания ({kinds})? После распаковки архив удаляется. (y/n): ",
        "unpack_cannot": "ℹ️  {kinds}: на этой системе нечем распаковать - скачаются как есть.",
        "unpacking": "📦 Распаковка {name}...",
        "unpacked": "  📦 Распакован {name}: файлов {n}",
        "unpack_failed": "  ❌ Не удалось распаковать {name} (архив оставлен): {err}",
        "unpack_no_tool": "на этой системе нечем распаковать .{kind}",
        "unpack_empty": "архив пустой",
        "unpack_no_space": "не хватает места для распаковки",
        "log_unpacked": "Загрузка по ссылке: распакован {name} (файлов: {n})",
        "unpack_cloud_note": "ℹ️  Для облака: файлы из .zip берутся прямо из архива; .7z/.rar сначала ненадолго скачиваются на карту, там распаковываются и выгружаются.",
        "cloud_uploading": "☁️  Выгружаю распакованные файлы {name} в облако...",
        "unpack_tmp_space": "на карте не хватает места для временной распаковки (нужно {need}, свободно {free})",
        "zip_line": "{n:>3}  🗜  {name}  ({size}, архив - можно открыть)",
        "help_open_zip": "  {ex:<8} - открыть архив «{name}» и выбрать файлы из него (при скачивании распакуются)",
        "zip_reading": "🗜  Читаю архив {name}...",
        "zip_bad": "❌ Не удалось прочитать архив {name}: он повреждён или это не zip. Отметьте сам архив, чтобы скачать его целиком.",
        "zip_no_range": "❌ Сервер не позволяет читать архив по частям. Отметьте сам архив, чтобы скачать его целиком.",
        "zip_encrypted": "❌ Архив {name} защищён паролем: отметьте сам архив, чтобы скачать его целиком.",
        "zip_method": "файл сжат способом, который Python не умеет распаковывать - скачайте архив целиком",
        "help_select": "  {ex:<8} - скачать выбранное (номера через пробел)",
        "help_open": "  {ex:<8} - открыть папку «{name}» (o + номер папки)",
        "help_all": "  {ex:<8} - скачать всё в этой папке",
        "help_back": "  {ex:<8} - назад, в предыдущую папку",
        "help_quit": "  {ex:<8} - выход",
        "choice": "Выбор: ",
        "bad_input": "❌ Неверный ввод",
        "not_folder": "❌ Это не папка",
        "contents_note": "СОДЕРЖИМОЕ папки «{name}» будет помещено в {dest}",
        "items_note": "Выбранное будет помещено в {dest}",
        "choose_dest": "Номер или имя системы (q - выход)",
        "choose_target": "Куда скачать?\n  1 - на устройство: roms/<система>\n  2 - в ваше облако: GameROMs/<система> (потом на устройстве: Ромы → Загрузить ромы)",
        "target_prompt": "Выбор (1/2, q - выход): ",
        "grp_device_files": "Системы с играми (ром-файлами):",
        "grp_device_other": "Системы без игр:",
        "grp_cloud_files": "Системы в облаке:",
        "grp_cloud_other": "Добавить новую систему в облако:",
        "cloud_reading": "🔍 Читаю папки в облаке...",
        "cloud_unavailable": "❌ Облако недоступно: Save Sync не настроен или rclone не запускается.",
        "free_cloud": "Свободно в облаке: {free}",
        "free_unknown": "Свободное место в облаке: неизвестно",
        "cloud_label": "облако: {path}",
        "cloud_done": "☁️  Файлы в облаке: {dest}. Чтобы перенести на устройство: Ромы → выбрать систему → Загрузить ромы.",
        "dest_invalid": "❌ Нет такой системы",
        "no_roms_dir": "❌ Папка ромов не найдена: {path}",
        "plan": "К загрузке файлов: {files} ({size}), уже есть на устройстве: {skip}",
        "free_space": "Свободно: {free}",
        "no_space": "❌ Недостаточно места: нужно {need}, свободно {free}",
        "nothing_to_do": "✅ Все эти файлы уже есть на устройстве.",
        "confirm": "Начать загрузку? (y/n): ",
        "cancelled": "❌ Отменено.",
        "progress": "\r  {pct:>3}%  {done} / {total}  {speed}/с  осталось {eta}   ",
        "file_start": "[{i}/{n}] {path}",
        "file_failed": "  ❌ Не удалось: {path} ({err})",
        "done": "✅ Готово: скачано {ok}, пропущено {skip}, с ошибкой {fail}",
        "too_many_fail": "❌ Несколько файлов подряд не скачались - остановка. Проверьте сеть и запустите снова.",
        "interrupted": "⏹  Прервано. Запустите снова с той же ссылкой - загрузка продолжится.",
        "locked": "❌ Уже идёт другая загрузка по ссылке.",
        "es_hint": "ℹ️  Чтобы увидеть новые игры: меню EmulationStation → Обновить списки игр (или перезапуск).",
        "es_reloaded": "ℹ️  Новые игры добавлены в список EmulationStation.",
        "units": ("Б", "КБ", "МБ", "ГБ", "ТБ"),
        "log_start": "Загрузка по ссылке: {service} {url} -> {dest}",
        "log_done": "Загрузка по ссылке завершена: скачано {ok}, пропущено {skip}, с ошибкой {fail}",
        "log_error": "Ошибка загрузки по ссылке: {err}",
        "phase": "Загрузка по ссылке",
        "svc_yandex": "Яндекс.Диск", "svc_pcloud": "pCloud", "svc_nextcloud": "Nextcloud",
        "svc_archive": "archive.org",
        "restricted": "❌ Этот архив на archive.org закрыт: скачать его можно только после входа на archive.org.",
        "cancelled_web": "Загрузка отменена",
        "running_other": "⏳ Уже идёт загрузка по ссылке{pct} (PID {pid}).",
        "ask_stop": "Остановить её? (y/n): ",
        "stopping": "Останавливаю...",
        "stopped": "✅ Остановлено. Скачанные части сохранены - запустите ту же ссылку снова, и загрузка продолжится.",
        "stop_failed": "❌ Не удалось остановить (PID {pid}). Перезагрузите устройство.",
        "keep_running": "Загрузка продолжается. Следить за ней и отменить можно и в веб-интерфейсе.",
        "cancelled_other": "⏹  Загрузку остановили из другого сеанса или из веб-интерфейса.",
        "detached_log": "SSH-сеанс закрыт - загрузка по ссылке продолжается в фоне",
    },
}


def t(key, **kw):
    text = MSG.get(LANG, MSG["en"])[key]
    return text.format(**kw) if kw else text


def human(n):
    if n is None:
        return "?"
    units = t("units")
    n = float(n)
    for u in units:
        if n < 1024 or u == units[-1]:
            return ("%d %s" % (n, u)) if u == units[0] else ("%.1f %s" % (n, u))
        n /= 1024.0


def es_reload_games():
    """New games show up in EmulationStation without "Update gamelists" (Batocera, KNULLI).
    Only when ES is not busy: no game, scraper or update running (it would ask about them)."""
    try:
        if b"true" not in urllib.request.urlopen("http://127.0.0.1:1234/isIdle", timeout=3).read():
            return False
        urllib.request.urlopen("http://127.0.0.1:1234/reloadgames", timeout=5).read()
        return True
    except Exception:
        return False


def notify_screen(text):
    """On-screen message (EmulationStation on Batocera / KNULLI); silent if unavailable."""
    try:
        with open(CONFIG_FILE) as f:
            if re.search(r'^NOTIFICATIONS="false"', f.read(), re.M):
                return
    except OSError:
        pass
    try:
        req = urllib.request.Request("http://127.0.0.1:1234/notify", data=text.encode("utf-8"),
                                     headers={"Content-Type": "text/plain; charset=utf-8"}, method="POST")
        urllib.request.urlopen(req, timeout=3).read()
    except Exception:
        pass


def start_ticker(first, tick):
    """Message that the work started, then 'still running' once a minute; .set() stops it."""
    notify_screen(first)
    stop = threading.Event()

    def loop():
        n = 0
        while not stop.wait(60):
            n += 1
            notify_screen(tick.format(n=n))
    threading.Thread(target=loop, daemon=True).start()
    return stop


def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write("%s %s\n" % (datetime.now().strftime("%d.%m %H:%M:%S"), msg))
    except OSError:
        pass


# ---- console output during a download
# The terminal may stall (dead SSH connection) or vanish: output then goes through
# a background writer so the download itself never waits for the terminal.
_CON = {"q": None, "on": True}
DOWNLOADING = {"on": False, "interactive": False}


def _con_writer(q):
    while True:
        data = q.get()
        try:
            if _CON["on"]:
                os.write(1, data)
        except OSError:
            _CON["on"] = False
        q.task_done()


def con_start():
    if _CON["q"] is None and sys.stdout.isatty():
        import queue
        sys.stdout.flush()
        _CON["q"] = queue.Queue(maxsize=400)
        threading.Thread(target=_con_writer, args=(_CON["q"],), daemon=True).start()


def con(text, droppable=False):
    """Console write that never blocks the download."""
    if not _CON["on"]:
        return
    q = _CON["q"]
    if q is None:
        try:
            sys.stdout.write(text)
            sys.stdout.flush()
        except OSError:
            _CON["on"] = False
        return
    if droppable and q.qsize() > 50:
        return          # terminal is not keeping up: skip progress redraws
    try:
        q.put_nowait(text.encode("utf-8", "replace"))
    except Exception:
        pass


def con_drain(timeout=3.0):
    q = _CON["q"]
    end = time.time() + timeout
    while q is not None and _CON["on"] and q.unfinished_tasks and time.time() < end:
        time.sleep(0.05)


def con_detach():
    """The terminal is gone: stop writing to it (the download keeps going)."""
    _CON["on"] = False
    try:
        fd = os.open(os.devnull, os.O_RDWR)
        for n in (0, 1, 2):
            os.dup2(fd, n)
        os.close(fd)
    except OSError:
        pass


class LinkError(Exception):
    """An error with a message ready to show to the user."""


class NeedPassword(Exception):
    pass


# ============================================================== HTTP
def _ssl_context():
    ctx = ssl.create_default_context()
    try:
        if ctx.cert_store_stats().get("x509_ca", 0) == 0:
            for cafile in ("/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem",
                           "/etc/pki/tls/certs/ca-bundle.crt"):
                if os.path.exists(cafile):
                    ctx.load_verify_locations(cafile)
                    break
    except Exception:
        pass
    return ctx


SSL_CTX = _ssl_context()


def open_url(url, headers=None, method="GET", data=None, timeout=TIMEOUT):
    """urlopen with retries for temporary errors. Returns the response object.
    HTTPError with a non-retryable status is raised immediately."""
    hdrs = {"User-Agent": USER_AGENT}
    hdrs.update(headers or {})
    last = None
    for attempt in range(RETRIES + 1):
        req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
        try:
            return urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < RETRIES:
                last = e
                time.sleep(2 + attempt * 4)
                continue
            raise
        except (urllib.error.URLError, socket.timeout, ConnectionError) as e:
            last = e
            if attempt < RETRIES:
                time.sleep(2 + attempt * 4)
                continue
            raise LinkError(t("net_error", err=getattr(e, "reason", e)))
    raise LinkError(t("net_error", err=last))


def get_json(url, headers=None):
    try:
        with open_url(url, headers) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")
        except Exception:
            pass
        e.body = body
        raise


# ============================================================== tree
class Entry:
    def __init__(self, name, is_dir, size=None, ref=None):
        self.name = name
        self.is_dir = is_dir
        self.size = size          # bytes (files)
        self.ref = ref            # service-specific id/path used to download
        self.children = []
        self.rel = ""             # path inside the link, "/"-separated
        self.files = 0            # totals (filled by finish_tree)
        self.total = 0
        self.zip_file = None      # the .zip Entry this is a file/folder/view of
        self.zip_view = None      # for a .zip file: its opened contents (a folder Entry)

    def to_dict(self):
        d = {"name": self.name, "path": self.rel, "dir": self.is_dir,
             "size": self.total if self.is_dir else self.size}
        if is_zip(self):
            d["zip"] = True
        if arc_kind(self):
            d["arc"] = arc_kind(self)
        if self.is_dir and self.zip_file is not None and self.rel == self.zip_file.rel:
            d["path"] = self.rel + "/"      # "a.zip/" = the contents of a.zip
        if self.is_dir:
            d["files"] = self.files
            d["children"] = [c.to_dict() for c in sorted_children(self)]
        return d


def safe_name(name):
    name = (name or "").replace("/", "_").replace("\\", "_").replace("\0", "_").strip()
    return "_" if name in ("", ".", "..") else name


def finish_tree(root):
    def walk(e, rel):
        e.name = safe_name(e.name)
        e.rel = rel
        if e.is_dir:
            e.files, e.total = 0, 0
            for c in e.children:
                walk(c, (rel + "/" + safe_name(c.name)).lstrip("/"))
                e.files += c.files if c.is_dir else 1
                e.total += (c.total if c.is_dir else (c.size or 0))
    walk(root, "")
    return root


def sorted_children(e):
    return sorted(e.children, key=lambda c: (not c.is_dir, c.name.lower()))


def find_entry(root, rel, src=None):
    """'a/b.zip' is the archive itself, 'a/b.zip/' its contents, 'a/b.zip/x.gb' a file in it."""
    want_view = rel.endswith("/")
    parts = [p for p in rel.strip("/").split("/") if p]
    cur = root
    for part in parts:
        if not cur.is_dir and is_zip(cur) and src is not None:
            cur = zip_view(src, cur)
        if not cur.is_dir:
            return None
        nxt = [c for c in cur.children if c.name == part]
        if not nxt:
            return None
        cur = nxt[0]
    if want_view and parts and is_zip(cur) and src is not None:
        cur = zip_view(src, cur)
    return cur


# ============================================================== zip archives
# A .zip on the link can be opened without downloading it: the list of files
# and each chosen file are read with HTTP Range requests (all four services
# support them), so only the chosen games are transferred - already unpacked.
_ZIPS = {}


def is_zip(e):
    return (not e.is_dir and e.zip_file is None and e.size is not None and e.size >= 22
            and e.name.lower().endswith(".zip"))


class RangeFile(io.RawIOBase):
    """Read-only seekable file over HTTP Range requests. Sequential reads fetch
    growing blocks (64 KB .. 4 MB), so unpacking streams without tiny requests."""

    def __init__(self, src, entry):
        super().__init__()
        self.src, self.entry, self.size = src, entry, entry.size
        self.pos, self.buf, self.buf_start, self.block = 0, b"", 0, 64 * 1024
        self.url, self.headers = src.download_request(entry)

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        if whence == 1:
            off += self.pos
        elif whence == 2:
            off += self.size
        self.pos = max(0, off)
        return self.pos

    def _fetch(self, start, length):
        end = min(self.size, start + length) - 1
        last = None
        for attempt in range(RETRIES + 1):
            try:
                hdrs = dict(self.headers)
                hdrs["Range"] = "bytes=%d-%d" % (start, end)
                with open_url(self.url, hdrs) as resp:
                    if getattr(resp, "status", 200) != 206:
                        raise LinkError(t("zip_no_range"))
                    data = resp.read(end - start + 1)
                    self.url = resp.geturl() or self.url    # skip the redirect next time
                if len(data) != end - start + 1:
                    raise LinkError("short read")
                return data
            except KeyboardInterrupt:
                raise
            except LinkError as e:
                if str(e) == t("zip_no_range"):
                    raise
                last = e
            except (urllib.error.URLError, socket.timeout, ConnectionError, OSError) as e:
                last = e
            if attempt < RETRIES:
                time.sleep(3 + attempt * 5)
                try:
                    self.url, self.headers = self.src.download_request(self.entry)   # links expire
                except (LinkError, urllib.error.URLError, socket.timeout, OSError):
                    pass
        raise LinkError(str(getattr(last, "reason", last)))

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        n = min(n, self.size - self.pos)
        out = bytearray()
        while n > 0:
            off = self.pos - self.buf_start
            if 0 <= off < len(self.buf):
                piece = self.buf[off:off + n]
                out += piece
                self.pos += len(piece)
                n -= len(piece)
                continue
            if self.buf and self.pos == self.buf_start + len(self.buf):
                self.block = min(self.block * 2, 4 * 1024 * 1024)     # sequential: bigger blocks
            else:
                self.block = 64 * 1024
            self.buf = self._fetch(self.pos, max(self.block, n))
            self.buf_start = self.pos
        return bytes(out)

    def readinto(self, b):
        data = self.read(len(b))
        b[:len(data)] = data
        return len(data)


def zip_name(info):
    """Names without the UTF-8 flag: UTF-8 anyway (many tools) or DOS cp866 (Windows, Russian)."""
    if info.flag_bits & 0x800:
        return info.filename
    try:
        raw = info.filename.encode("cp437")
    except UnicodeEncodeError:
        return info.filename
    for enc in ("utf-8", "cp866"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            pass
    return info.filename


def open_zip(src, entry):
    zf = _ZIPS.get(id(entry))
    if zf is None:
        try:
            zf = zipfile.ZipFile(RangeFile(src, entry))
        except (zipfile.BadZipFile, zipfile.LargeZipFile, EOFError, ValueError):
            raise LinkError(t("zip_bad", name=entry.name))
        _ZIPS[id(entry)] = zf
    return zf


def zip_view(src, entry):
    """The contents of a .zip Entry as a folder Entry (read once, then cached)."""
    if entry.zip_view is not None:
        return entry.zip_view
    zf = open_zip(src, entry)
    view = Entry(entry.name, True)
    view.zip_file = entry
    encrypted = 0
    for info in zf.infolist():
        if info.is_dir():
            continue
        if info.flag_bits & 1:
            encrypted += 1
            continue
        parts = [safe_name(p) for p in zip_name(info).replace("\\", "/").split("/") if p not in ("", ".")]
        if not parts:
            continue
        node = view
        for d in parts[:-1]:
            sub = [c for c in node.children if c.is_dir and c.name == d]
            if sub:
                node = sub[0]
            else:
                nd = Entry(d, True)
                nd.zip_file = entry
                node.children.append(nd)
                node = nd
        m = Entry(parts[-1], False, size=info.file_size, ref=info)
        m.zip_file = entry
        node.children.append(m)
    if encrypted and not view.children:
        raise LinkError(t("zip_encrypted", name=entry.name))

    def walk(e, rel):
        e.rel = rel
        if e.is_dir:
            e.files, e.total = 0, 0
            for c in e.children:
                walk(c, rel + "/" + c.name)
                e.files += c.files if c.is_dir else 1
                e.total += (c.total if c.is_dir else (c.size or 0))
    walk(view, entry.rel)
    entry.zip_view = view
    return view


def open_stream(src, entry):
    """A readable stream of one file of the link (a file inside a zip is unpacked on the fly)."""
    if entry.zip_file is not None:
        zf = open_zip(src, entry.zip_file)
        try:
            return zf.open(entry.ref)
        except NotImplementedError:
            raise LinkError(t("zip_method"))
        except (zipfile.BadZipFile, RuntimeError) as e:
            raise LinkError(str(e))
    url, headers = src.download_request(entry)
    return open_url(url, headers)


class Scanner:
    """Prints how many objects were found while the tree is loading."""
    def __init__(self, quiet):
        self.n = 0
        self.quiet = quiet
        self.last = 0

    def add(self, k=1):
        self.n += k
        if not self.quiet and time.time() - self.last > 0.3:
            self.last = time.time()
            sys.stdout.write("\r" + t("scanning", n=self.n))
            sys.stdout.flush()

    def end(self):
        if not self.quiet:
            sys.stdout.write("\r" + t("scanning", n=self.n) + "\n")


# ============================================================== Yandex Disk
class YandexSource:
    title = t("svc_yandex")
    HOST_RE = re.compile(r"^(disk(\.360)?\.yandex\.[a-z.]+|yadi\.sk)$", re.I)

    @classmethod
    def match(cls, u):
        return bool(cls.HOST_RE.match(u.hostname or "")) and bool(re.match(r"^/(d|i)/", u.path))

    def __init__(self, url, password=None):
        u = urllib.parse.urlsplit(url)
        m = re.match(r"^/(d|i)/([^/]+)(/.*)?$", u.path)
        self.public_key = "%s://%s/%s/%s" % (u.scheme, u.netloc, m.group(1), m.group(2))
        self.sub = urllib.parse.unquote(m.group(3) or "").rstrip("/")
        self.single_file = False

    def _call(self, path, offset):
        q = {"public_key": self.public_key, "limit": 200, "offset": offset}
        if path:
            q["path"] = path
        try:
            return get_json(YANDEX_API + "?" + urllib.parse.urlencode(q))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise LinkError(t("not_found"))
            raise LinkError(t("api_error", err=_yandex_err(e)))

    def load(self, scan):
        meta = self._call(self.sub or None, 0)
        if meta.get("type") == "file":
            self.single_file = True
            scan.add()
            return Entry(meta.get("name"), False, meta.get("size"), meta.get("path") or None)
        root = Entry(meta.get("name") or "", True, ref=meta.get("path") or "/")
        self._fill(root, meta, scan)
        return root

    def _fill(self, entry, first_page, scan):
        page, offset = first_page, 0
        while True:
            emb = page.get("_embedded") or {}
            items = emb.get("items") or []
            for it in items:
                scan.add()
                if it.get("type") == "dir":
                    child = Entry(it.get("name"), True, ref=it.get("path"))
                    self._fill(child, self._call(it.get("path"), 0), scan)
                else:
                    child = Entry(it.get("name"), False, it.get("size"), it.get("path"))
                entry.children.append(child)
            offset += len(items)
            if not items or offset >= int(emb.get("total") or 0):
                break
            page = self._call(entry.ref, offset)

    def download_request(self, entry):
        q = {"public_key": self.public_key}
        if not self.single_file and entry.ref:
            q["path"] = entry.ref
        try:
            r = get_json(YANDEX_API + "/download?" + urllib.parse.urlencode(q))
        except urllib.error.HTTPError as e:
            raise LinkError(_yandex_err(e))
        return r["href"], {}


def _yandex_err(e):
    try:
        j = json.loads(getattr(e, "body", "") or "{}")
        return j.get("description") or j.get("error") or "HTTP %d" % e.code
    except ValueError:
        return "HTTP %d" % e.code


# ============================================================== pCloud
class PCloudSource:
    title = t("svc_pcloud")
    ERRORS = {7001: "invalid link", 7002: "deleted by owner", 7004: "expired",
              7005: "traffic limit reached", 7006: "download limit reached",
              1000: "login required", 2000: "login failed"}

    @classmethod
    def match(cls, u):
        host = (u.hostname or "").lower()
        q = urllib.parse.parse_qs(u.query)
        return (host.endswith("pcloud.link") or host.endswith("pcloud.com")) and "code" in q

    def __init__(self, url, password=None):
        u = urllib.parse.urlsplit(url)
        self.code = urllib.parse.parse_qs(u.query)["code"][0]
        host = (u.hostname or "").lower()
        # EU links (e.pcloud.link, e1.pcloud.link...) live on the EU API host
        eu = re.match(r"^e\d*\.", host) is not None
        self.apis = PCLOUD_APIS[::-1] if eu else PCLOUD_APIS
        self.api = self.apis[0]
        self.single_file = False

    def _call(self, api, method, **params):
        params["code"] = self.code
        try:
            return get_json("%s/%s?%s" % (api, method, urllib.parse.urlencode(params)))
        except urllib.error.HTTPError as e:
            raise LinkError(t("api_error", err="HTTP %d" % e.code))

    def load(self, scan):
        res = None
        for api in self.apis:
            res = self._call(api, "showpublink")
            if res.get("result") == 0:
                self.api = api
                break
            if res.get("result") != 7001:   # 7001 = not on this host, try the other
                break
        code = res.get("result")
        if code != 0:
            if code in (7001, 7002, 7004):
                raise LinkError(t("not_found"))
            raise LinkError(t("api_error", err="%s (%s)" % (self.ERRORS.get(code, res.get("error", "")), code)))
        meta = res["metadata"]
        if not meta.get("isfolder"):
            self.single_file = True
        return self._entry(meta, scan)

    def _entry(self, m, scan):
        scan.add()
        if m.get("isfolder"):
            e = Entry(m.get("name"), True)
            for c in m.get("contents") or []:
                e.children.append(self._entry(c, scan))
            return e
        return Entry(m.get("name"), False, m.get("size"), m.get("fileid"))

    def download_request(self, entry):
        params = {} if self.single_file else {"fileid": entry.ref}
        res = self._call(self.api, "getpublinkdownload", **params)
        if res.get("result") != 0:
            code = res.get("result")
            raise LinkError("%s (%s)" % (self.ERRORS.get(code, res.get("error", "")), code))
        return "%s://%s%s" % (PCLOUD_DL_SCHEME, res["hosts"][0], res["path"]), {}


# ============================================================== Nextcloud / ownCloud
class NextcloudSource:
    title = t("svc_nextcloud")
    PATH_RE = re.compile(r"^(.*?)/(?:index\.php/)?s/([A-Za-z0-9]+)(?:/download)?/?$")
    PROPS = (b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
             b'<d:displayname/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>')

    @classmethod
    def match(cls, u):
        return bool(cls.PATH_RE.match(u.path))

    def __init__(self, url, password=None):
        u = urllib.parse.urlsplit(url)
        m = self.PATH_RE.match(u.path)
        base = "%s://%s%s" % (u.scheme, u.netloc, m.group(1))
        self.token = m.group(2)
        self.sub = urllib.parse.parse_qs(u.query).get("path", [""])[0].strip("/")
        self.password = password
        # Nextcloud 29+ first, then the older endpoint (older Nextcloud, ownCloud 10)
        self.endpoints = [(base + "/public.php/dav/files/" + self.token, "new"),
                          (base + "/public.php/webdav", "legacy")]
        self.endpoint = None
        self.new_user = "anonymous"
        self.single_file = False

    def _auth(self, kind):
        if kind == "new":
            if not self.password:
                return {}
            # docs name "anonymous" (developer manual) or the token (user manual)
            pair = self.new_user + ":" + self.password
        else:
            pair = self.token + ":" + (self.password or "")
        return {"Authorization": "Basic " + b64encode(pair.encode("utf-8")).decode("ascii")}

    def _headers(self, kind):
        h = {"X-Requested-With": "XMLHttpRequest"}
        h.update(self._auth(kind))
        return h

    def _propfind(self, url, kind):
        h = self._headers(kind)
        h.update({"Depth": "1", "Content-Type": "application/xml; charset=utf-8"})
        with open_url(url, h, method="PROPFIND", data=self.PROPS) as r:
            return r.read()

    def load(self, scan):
        last_err = None
        body = None
        for url, kind in self.endpoints:
            start = url + ("/" + urllib.parse.quote(self.sub) if self.sub else "")
            users = ["anonymous", self.token] if (kind == "new" and self.password) else [None]
            got401 = False
            for user in users:
                if user:
                    self.new_user = user
                try:
                    self.endpoint = (url, kind)
                    body = self._propfind(start, kind)
                    break
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        got401 = True
                        continue
                    last_err = e
                    break
            if body is not None:
                break
            if got401:
                raise NeedPassword()
        if body is None:
            if last_err is not None and last_err.code in (404, 405):
                raise LinkError(t("not_found"))
            raise LinkError(t("api_error", err="HTTP %s" % getattr(last_err, "code", "?")))
        me, others = self._split(self._parse(body), self.sub)
        if me is None:
            raise LinkError(t("not_found"))
        if not me[1]:
            self.single_file = True
            scan.add()
            return Entry(me[3] or me[0].rsplit("/", 1)[-1] or "download", False, me[2], me[0])
        root = Entry(me[0].rsplit("/", 1)[-1], True, ref=me[0])
        self._fill(root, others, scan)
        return root

    @staticmethod
    def _split(items, rel):
        """Separates the requested item itself from its children."""
        rel = rel.strip("/")
        me = [it for it in items if it[0] == rel]
        others = [it for it in items if it[0] != rel]
        return (me[0] if me else None), others

    def _fill(self, entry, items, scan):
        for rel, is_dir, size, _name in items:
            scan.add()
            name = rel.rsplit("/", 1)[-1]
            if is_dir:
                child = Entry(name, True, ref=rel)
                url = self.endpoint[0] + "/" + urllib.parse.quote(rel)
                _me, sub = self._split(self._parse(self._propfind(url, self.endpoint[1])), rel)
                self._fill(child, sub, scan)
            else:
                child = Entry(name, False, size, rel)
            entry.children.append(child)

    def _parse(self, body):
        """-> [(rel_path, is_dir, size, displayname)], the requested item first."""
        base_path = urllib.parse.urlsplit(self.endpoint[0]).path.rstrip("/")
        out = []
        root = ET.fromstring(body)
        for resp in root.findall("{DAV:}response"):
            href = resp.findtext("{DAV:}href") or ""
            path = urllib.parse.unquote(urllib.parse.urlsplit(href).path)
            if path.startswith(base_path):
                path = path[len(base_path):]
            rel = path.strip("/")
            is_dir, size, name = False, None, None
            for ps in resp.findall("{DAV:}propstat"):
                if "200" not in (ps.findtext("{DAV:}status") or ""):
                    continue
                prop = ps.find("{DAV:}prop")
                if prop is None:
                    continue
                rt = prop.find("{DAV:}resourcetype")
                if rt is not None and rt.find("{DAV:}collection") is not None:
                    is_dir = True
                cl = prop.findtext("{DAV:}getcontentlength")
                if cl and cl.isdigit():
                    size = int(cl)
                name = prop.findtext("{DAV:}displayname") or name
            out.append((rel, is_dir, size, name))
        return out

    def download_request(self, entry):
        url = self.endpoint[0]
        if entry.ref:
            url += "/" + urllib.parse.quote(entry.ref)
        return url, self._auth(self.endpoint[1])


# ============================================================== archive.org
class ArchiveSource:
    title = t("svc_archive")
    HOST_RE = re.compile(r"^(www\.)?archive\.org$", re.I)
    PATH_RE = re.compile(r"^/(?:details|download)/([^/]+)(/.*)?$")

    @classmethod
    def match(cls, u):
        return bool(cls.HOST_RE.match(u.hostname or "")) and bool(cls.PATH_RE.match(u.path))

    def __init__(self, url, password=None):
        u = urllib.parse.urlsplit(url)
        m = self.PATH_RE.match(u.path)
        self.ident = urllib.parse.unquote(m.group(1))
        self.sub = urllib.parse.unquote(m.group(2) or "").strip("/")
        self.single_file = False

    def _service_file(self, name):
        # archive.org adds its own files to every item - they are not the content
        if name in ("__ia_thumb.jpg",):
            return True
        return re.match(r"^%s_(files\.xml|meta\.xml|meta\.sqlite|reviews\.xml|archive\.torrent)$"
                        % re.escape(self.ident), name) is not None

    def load(self, scan):
        try:
            meta = get_json("%s/%s" % (ARCHIVE_META, urllib.parse.quote(self.ident)))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise LinkError(t("not_found"))
            raise LinkError(t("api_error", err="HTTP %d" % e.code))
        if not meta or meta.get("is_dark") or "files" not in meta:
            raise LinkError(t("not_found"))
        md = meta.get("metadata") or {}
        if str(md.get("access-restricted-item", "")).lower() == "true":
            raise LinkError(t("restricted"))
        root = Entry(self.ident, True)
        dirs = {"": root}
        for f in meta.get("files") or []:
            name = f.get("name") or ""
            if f.get("source") != "original" or not name or self._service_file(name):
                continue
            if self.sub:
                if name == self.sub:           # link to a single file
                    self.single_file = True
                    scan.add()
                    return Entry(name.rsplit("/", 1)[-1], False, _int(f.get("size")), name)
                if not name.startswith(self.sub + "/"):
                    continue
                rel = name[len(self.sub) + 1:]
            else:
                rel = name
            parts = rel.split("/")
            parent = ""
            for d in parts[:-1]:
                path = (parent + "/" + d).lstrip("/")
                if path not in dirs:
                    e = Entry(d, True)
                    dirs[parent].children.append(e)
                    dirs[path] = e
                    scan.add()
                parent = path
            scan.add()
            dirs[parent].children.append(Entry(parts[-1], False, _int(f.get("size")), name))
        if self.sub and len(dirs) == 1 and not root.children:
            raise LinkError(t("not_found"))
        return root

    def download_request(self, entry):
        return "%s/%s/%s" % (ARCHIVE_DL, urllib.parse.quote(self.ident),
                             urllib.parse.quote(entry.ref, safe="/")), {}


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


SOURCES = (YandexSource, PCloudSource, NextcloudSource, ArchiveSource)


def make_source(url, password=None):
    u = urllib.parse.urlsplit(url.strip())
    if u.scheme not in ("http", "https"):
        return None
    for cls in SOURCES:
        if cls.match(u):
            return cls(url.strip(), password)
    return None


def load_tree(url, password=None, quiet=False, ask_password=False):
    """-> (source, root). Asks for a password when needed (interactive)."""
    while True:
        src = make_source(url, password)
        if src is None:
            raise LinkError(t("unsupported") + "\n" + t("supported"))
        scan = Scanner(quiet)
        try:
            root = src.load(scan)
        except NeedPassword:
            scan.end() if scan.n else None
            if not ask_password:
                raise LinkError(t("password_wrong") if password else t("password_needed"))
            if password:
                print(t("password_wrong"))
            password = input(t("password_prompt")).strip()
            if not password:
                raise LinkError(t("cancelled"))
            continue
        scan.end()
        return src, finish_tree(root)


# ============================================================== plan & download
def collect(entry, prefix, out):
    rel = (prefix + "/" + entry.name).lstrip("/")
    if entry.is_dir:
        for c in entry.children:
            collect(c, rel, out)
    else:
        out.append((entry, rel))


def build_plan(root, items, unpack_single_folder=True):
    """items: list of Entry. A single selected folder is unpacked (its contents
    go straight into the destination); otherwise items keep their names."""
    plan = []
    if not items or items == [root]:
        if root.is_dir:
            for c in root.children:
                collect(c, "", plan)
        else:
            collect(root, "", plan)
    elif len(items) == 1 and items[0].is_dir and unpack_single_folder:
        for c in items[0].children:
            collect(c, "", plan)
    else:
        for e in items:
            collect(e, "", plan)
    return plan


def safe_join(base, rel):
    target = os.path.realpath(os.path.join(base, *rel.split("/")))
    base_real = os.path.realpath(base)
    if target != base_real and not target.startswith(base_real + os.sep):
        raise LinkError("unsafe path: " + rel)
    return target


def free_bytes(path):
    p = path
    while not os.path.isdir(p):
        p = os.path.dirname(p) or "/"
    return shutil.disk_usage(p).free


class Progress:
    def __init__(self, total_bytes, total_files, web, quiet):
        self.total = max(total_bytes, 1)
        self.files = total_files
        self.done = 0
        self.file_i = 0
        self.web = web
        self.quiet = quiet
        self.start = time.time()
        self.last = 0

    def _stats(self):
        el = max(time.time() - self.start, 0.001)
        speed = self.done / el
        eta = int((self.total - self.done) / speed) if speed > 0 else 0
        pct = min(100, int(self.done * 100 / self.total))
        return pct, speed, eta

    def update(self, n=0, force=False):
        self.done += n
        now = time.time()
        if not force and now - self.last < 0.5:
            return
        self.last = now
        pct, speed, eta = self._stats()
        if not self.quiet:
            con(t("progress", pct=pct, done=human(self.done), total=human(self.total),
                  speed=human(speed), eta="%02d:%02d" % (eta // 60, eta % 60)), droppable=True)
        if self.web:
            write_progress(True, pct, self.done, self.total, speed, eta, self.file_i, self.files)

    def finish(self, ok, phase=None):
        pct, speed, eta = self._stats()
        if not self.quiet:
            con("\n")
        if self.web:
            write_progress(False, 100 if ok else pct, self.done, self.total, speed, 0,
                           self.file_i, self.files, success=ok, phase=phase)


def write_progress(active, pct, done, total, speed, eta, i, n, success=None, phase=None):
    d = {"active": active, "action": "link_download", "phase": phase or t("phase"), "percent": pct,
         "bytes": done, "totalBytes": total, "speed": int(speed), "eta": eta,
         "transfers": i, "totalTransfers": n}
    if success is not None:
        d["success"] = success
    try:
        tmp = PROGRESS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f)
        os.replace(tmp, PROGRESS_FILE)
    except OSError:
        pass


def download_file(src, entry, path, progress):
    """Downloads into path + '.part' (resuming it), then renames."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    part = path + ".part"
    last = None
    for attempt in range(RETRIES + 1):
        try:
            url, headers = src.download_request(entry)   # fresh link: they expire
            offset = os.path.getsize(part) if os.path.isfile(part) else 0
            if entry.size is not None and offset > entry.size:
                os.remove(part)
                offset = 0
            if entry.size is not None and offset == entry.size and offset > 0:
                os.replace(part, path)
                return
            hdrs = dict(headers)
            if offset:
                hdrs["Range"] = "bytes=%d-" % offset
            try:
                resp = open_url(url, hdrs)
            except urllib.error.HTTPError as e:
                if e.code == 416 and entry.size is not None and offset == entry.size:
                    os.replace(part, path)
                    return
                raise
            with resp:
                mode = "ab"
                if offset and getattr(resp, "status", 200) != 206:
                    mode, offset = "wb", 0    # server ignored Range - start over
                with open(part, mode) as f:
                    while True:
                        chunk = resp.read(CHUNK)
                        if not chunk:
                            break
                        f.write(chunk)
                        progress.update(len(chunk))
            got = os.path.getsize(part)
            if entry.size is not None and got != entry.size:
                raise LinkError("size %d != %d" % (got, entry.size))
            os.replace(part, path)
            return
        except KeyboardInterrupt:
            raise
        except (LinkError, urllib.error.URLError, socket.timeout, ConnectionError, OSError) as e:
            if isinstance(e, OSError) and e.errno == errno.ENOSPC:
                NO_SPACE["hit"] = True
                raise LinkError(str(e))
            last = e
            # the part file stays: the next attempt resumes it
            if attempt < RETRIES:
                time.sleep(3 + attempt * 5)
    raise LinkError(str(getattr(last, "reason", last)))


def download_member(src, entry, path, progress):
    """A file inside a zip: read only its bytes from the archive and unpack them."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".unzip"
    last = None
    for attempt in range(RETRIES + 1):
        got = 0
        try:
            with open_stream(src, entry) as zs, open(tmp, "wb") as f:
                while True:
                    chunk = zs.read(CHUNK)
                    if not chunk:
                        break
                    f.write(chunk)
                    got += len(chunk)
                    progress.update(len(chunk))
            if entry.size is not None and got != entry.size:
                raise LinkError("size %d != %d" % (got, entry.size))
            os.replace(tmp, path)
            return
        except KeyboardInterrupt:
            _rm(tmp)
            raise
        except LinkError as e:
            if str(e) in (t("zip_method"), t("zip_no_range")):
                _rm(tmp)
                raise
            last = e
        except (zipfile.BadZipFile, urllib.error.URLError, socket.timeout, ConnectionError, OSError) as e:
            if isinstance(e, OSError) and e.errno == errno.ENOSPC:
                NO_SPACE["hit"] = True
                _rm(tmp)
                raise LinkError(str(e))
            last = e
        progress.done -= got
        _rm(tmp)
        if attempt < RETRIES:
            time.sleep(3 + attempt * 5)
    raise LinkError(str(getattr(last, "reason", last)))


def _rm(path):
    try:
        os.remove(path)
    except OSError:
        pass


# ============================================================== unpacking archives on the device
# Optional (--unpack): a downloaded .zip/.7z/.rar is unpacked next to itself and
# then deleted. .zip is unpacked by Python; .7z/.rar need a program on the system
# (Batocera/KNULLI: 7z, unrar, bsdtar; Recalbox: 7zr - .7z only).
ARCHIVE_KINDS = (("zip", ".zip"), ("7z", ".7z"), ("rar", ".rar"))


def arc_kind(e):
    if e.is_dir:
        return None
    n = e.name.lower()
    for kind, ext in ARCHIVE_KINDS:
        if n.endswith(ext):
            return kind
    return None


def _tools(kind):
    """Commands able to unpack this kind, best first: [(name, argv-builder)]."""
    seven = [(p, lambda a, o, p=p: [p, "x", "-y", "-bd", "-o" + o, a]) for p in ("7z", "7za", "7zr")]
    unrar = [("unrar", lambda a, o: ["unrar", "x", "-o+", "-y", "-idq", "-p-", a, o + "/"])]
    bsdtar = [("bsdtar", lambda a, o: ["bsdtar", "-xf", a, "-C", o])]
    unzip = [("unzip", lambda a, o: ["unzip", "-o", "-qq", a, "-d", o])]
    order = {"7z": seven + bsdtar, "rar": unrar + bsdtar + seven[:1], "zip": seven + bsdtar + unzip}[kind]
    return [(n, f) for n, f in order if shutil.which(n)]


def unpack_kinds():
    """Archive kinds that can be unpacked on this system."""
    return [k for k, _e in ARCHIVE_KINDS if k == "zip" or _tools(k)]


def _unzip_py(path, out):
    with zipfile.ZipFile(path) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if info.flag_bits & 1:
                raise LinkError(t("zip_encrypted", name=os.path.basename(path)))
            parts = [safe_name(p) for p in zip_name(info).replace("\\", "/").split("/") if p not in ("", ".")]
            if not parts:
                continue
            dst = os.path.join(out, *parts)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with zf.open(info) as s, open(dst, "wb") as d:
                shutil.copyfileobj(s, d, CHUNK)


def _merge_move(src_dir, dst_dir):
    """Moves the unpacked files into place (existing files are replaced); symlinks are skipped."""
    n = 0
    for root, _dirs, files in os.walk(src_dir):
        rel = os.path.relpath(root, src_dir)
        tdir = dst_dir if rel == "." else os.path.join(dst_dir, rel)
        os.makedirs(tdir, exist_ok=True)
        for f in files:
            sp = os.path.join(root, f)
            if os.path.islink(sp) or not os.path.isfile(sp):
                continue
            dp = os.path.join(tdir, f)
            if os.path.isdir(dp):
                continue
            os.replace(sp, dp)
            n += 1
    return n


def work_dir():
    """Temporary space on the card (next to roms/, not /tmp: that is RAM on some systems)."""
    return os.path.join(os.path.dirname(ROMS_DIR.rstrip("/")) or "/", ".ss_link_tmp", str(os.getpid()))


def expand_zips(src, plan):
    """Cloud + unpack: a .zip is replaced by its files, taken straight from the archive
    (nothing is stored on the card). Archives that cannot be read in parts stay as they are."""
    out = []
    for entry, rel in plan:
        if is_zip(entry):
            try:
                view = zip_view(src, entry)
            except LinkError:
                out.append((entry, rel))
                continue
            base = rel.rsplit("/", 1)[0] + "/" if "/" in rel else ""
            members = []
            for c in view.children:
                collect(c, "", members)
            out += [(e, base + r) for e, r in members]
        else:
            out.append((entry, rel))
    return out


def cloud_unpack(src, entry, remote_path, kind, progress, note):
    """Cloud + unpack for .7z/.rar: download to the card, unpack, upload the files, clean up."""
    wd = work_dir()
    shutil.rmtree(wd, ignore_errors=True)
    os.makedirs(wd, exist_ok=True)
    try:
        need = (entry.size or 0) * 3 + MIN_FREE_BYTES      # archive + unpacked files, roughly
        free = free_bytes(wd)
        if free < need:
            raise LinkError(t("unpack_tmp_space", need=human(need), free=human(free)))
        local = os.path.join(wd, entry.name)
        download_file(src, entry, local, progress)
        note(t("unpacking", name=entry.name))
        n = unpack_archive(local, kind)
        note(t("cloud_uploading", name=entry.name))
        remote_dir = remote_path.rsplit("/", 1)[0]
        rc, _out, err = rclone(["copy", wd, remote_dir], timeout=24 * 3600)
        if rc != 0:
            raise LinkError("rclone: " + _last_line(err))
        return n
    finally:
        shutil.rmtree(wd, ignore_errors=True)
        try:
            os.rmdir(os.path.dirname(wd))
        except OSError:
            pass


def unpack_archive(path, kind):
    """Unpacks path into its own folder and deletes it. -> number of files; LinkError on failure
    (the archive is then kept)."""
    folder = os.path.dirname(path)
    tmp = os.path.join(folder, ".ss_unpack_%d" % os.getpid())
    shutil.rmtree(tmp, ignore_errors=True)
    errors = []
    attempts = ([("python", None)] if kind == "zip" else []) + _tools(kind)
    if not attempts:
        raise LinkError(t("unpack_no_tool", kind=kind))
    try:
        for name, build in attempts:
            os.makedirs(tmp, exist_ok=True)
            try:
                if build is None:
                    _unzip_py(path, tmp)
                else:
                    proc = subprocess.Popen(build(path, tmp), stdin=subprocess.DEVNULL,
                                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    try:
                        _out, err = proc.communicate(timeout=6 * 3600)
                    except BaseException:
                        _kill(proc)
                        raise
                    if proc.returncode != 0:
                        raise LinkError("%s: %s" % (name, _last_line(err.decode("utf-8", "replace")) or proc.returncode))
                n = _merge_move(tmp, folder)
                if n == 0:
                    raise LinkError(t("unpack_empty"))
                os.remove(path)
                return n
            except KeyboardInterrupt:
                raise
            except (LinkError, zipfile.BadZipFile, NotImplementedError, OSError) as e:
                if isinstance(e, OSError) and e.errno == errno.ENOSPC:
                    NO_SPACE["hit"] = True
                    raise LinkError(t("unpack_no_space"))
                errors.append(str(e) or e.__class__.__name__)
                shutil.rmtree(tmp, ignore_errors=True)
        raise LinkError(errors[-1] if errors else "?")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ============================================================== rclone (cloud target)
_RCLONE = []


def _runs(path):
    try:
        return subprocess.run([path, "version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=30).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def rclone_bin():
    """rclone path, or None. Same self-heal as the sync scripts: if the share
    partition is mounted noexec (Recalbox), rclone is run from /tmp."""
    if _RCLONE:
        return _RCLONE[0]
    found = None
    if os.path.isfile(RCLONE_CONF):
        tmp_bin = "/tmp/save_sync_bin/rclone"
        for cand in (RCLONE_BIN, tmp_bin):
            if os.path.isfile(cand) and _runs(cand):
                found = cand
                break
        if found is None and os.path.isfile(RCLONE_BIN):
            try:
                os.makedirs(os.path.dirname(tmp_bin), exist_ok=True)
                shutil.copyfile(RCLONE_BIN, tmp_bin)
                os.chmod(tmp_bin, 0o755)
                if _runs(tmp_bin):
                    found = tmp_bin
            except OSError:
                pass
    _RCLONE.append(found)
    return found


def rclone(args, timeout=300):
    """-> (returncode, stdout, stderr)"""
    rb = rclone_bin()
    if rb is None:
        raise LinkError(t("cloud_unavailable"))
    try:
        r = subprocess.run([rb, "--config", RCLONE_CONF] + args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def _last_line(text):
    lines = [l.strip() for l in (text or "").splitlines() if l.strip()]
    return lines[-1][-200:] if lines else "rclone error"


def cloud_systems():
    """System folders that already exist in <cloud>:GameROMs."""
    rc, out, _err = rclone(["lsjson", "--dirs-only", REMOTE_ROMS], timeout=120)
    if rc != 0:
        return []       # the GameROMs folder does not exist yet
    try:
        return sorted(e["Name"] for e in json.loads(out or "[]") if e.get("IsDir"))
    except (ValueError, KeyError, TypeError):
        return []


def upload_stream(src, entry, remote_path, progress):
    """Streams one file from the link into the cloud with 'rclone rcat':
    nothing is written to the card. If anything fails, rclone is killed
    before its input is closed, so no truncated file reaches the cloud."""
    rb = rclone_bin()
    last = None
    for attempt in range(RETRIES + 1):
        sent = 0
        proc = None
        errf = tempfile.TemporaryFile()
        try:
            resp = open_stream(src, entry)
            cmd = [rb, "--config", RCLONE_CONF, "rcat", remote_path]
            if entry.size is not None:
                cmd += ["--size", str(entry.size)]
            proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errf)
            with resp:
                while True:
                    chunk = resp.read(CHUNK)
                    if not chunk:
                        break
                    proc.stdin.write(chunk)
                    sent += len(chunk)
                    progress.update(len(chunk))
            if entry.size is not None and sent != entry.size:
                raise LinkError("size %d != %d" % (sent, entry.size))
            proc.stdin.close()
            rc = proc.wait(timeout=3600)
            if rc != 0:
                errf.seek(0)
                raise LinkError("rclone: " + _last_line(errf.read().decode("utf-8", "replace")))
            return
        except KeyboardInterrupt:
            _kill(proc)
            raise
        except (LinkError, zipfile.BadZipFile, urllib.error.URLError, socket.timeout, ConnectionError, OSError,
                subprocess.SubprocessError) as e:
            _kill(proc)
            if isinstance(e, LinkError) and str(e) in (t("zip_method"), t("zip_no_range")):
                raise
            last = e
            progress.done -= sent      # this attempt's bytes are sent again
            if attempt < RETRIES:
                time.sleep(3 + attempt * 5)
        finally:
            errf.close()
    raise LinkError(str(getattr(last, "reason", last)))


def _kill(proc):
    if proc is not None and proc.poll() is None:
        try:
            proc.kill()
            proc.wait(timeout=30)
        except Exception:
            pass
    if proc is not None:
        try:
            proc.stdin.close()
        except Exception:
            pass


# ============================================================== destinations
MEDIA_DIRS = ("images", "videos", "media", "manuals", "downloaded_images", "downloaded_videos",
              "screenshots", "thumbnails", "bezels", "covers", "backcovers", "3dboxes", "fanart", "marquees",
              "miximages", "miximages_v2", "physicalmedia", "titlescreens", "wheel", "boxart", "snaps",
              "downloaded_media", "__macosx", "@eadir", "#recycle", "$recycle.bin", "system volume information")
NOT_GAMES = ("gamelist.xml", "_info.txt", "Thumbs.db", "desktop.ini")


def list_systems():
    try:
        return sorted(d for d in os.listdir(ROMS_DIR)
                      if not d.startswith(".") and os.path.isdir(os.path.join(ROMS_DIR, d)))
    except OSError:
        return []


def has_games(path):
    """A system folder with games in it (not just gamelist.xml or media)."""
    try:
        for e in os.scandir(path):
            if e.name.startswith("."):
                continue
            if e.is_dir(follow_symlinks=False):
                if e.name.lower() not in MEDIA_DIRS:
                    return True
            elif e.name not in NOT_GAMES:
                return True
    except OSError:
        pass
    return False


def dest_groups(target):
    """-> (with_files, others, free, available) for the destination lists."""
    device = list_systems()
    if target == "cloud":
        if rclone_bin() is None:
            return [], [], None, False
        in_cloud = cloud_systems()
        return in_cloud, [s for s in device if s not in in_cloud], cloud_free(), True
    with_files = [s for s in device if has_games(os.path.join(ROMS_DIR, s))]
    others = [s for s in device if s not in with_files]
    try:
        free = free_bytes(ROMS_DIR)
    except OSError:
        free = None
    return with_files, others, free, True


def cloud_free():
    root = REMOTE_ROMS.split(":", 1)[0] + ":"
    rc, out, _err = rclone(["about", "--json", root], timeout=120)
    if rc != 0:
        return None
    try:
        free = json.loads(out).get("free")
        return int(free) if free is not None else None
    except (ValueError, TypeError, AttributeError):
        return None


class DeviceDest:
    kind = "device"

    def __init__(self, system):
        self.system = system
        self.path = os.path.join(ROMS_DIR, system)
        self.label = "roms/" + system
        self.unpack = []          # archive kinds to unpack after download
        self.present = {}         # archives already on the card that only need unpacking

    def classify(self, plan):
        """-> (todo, skipped): files already present with the same size are skipped."""
        todo, skipped = [], 0
        for entry, rel in plan:
            path = safe_join(self.path, rel)
            if entry.size is not None and os.path.isfile(path) and os.path.getsize(path) == entry.size:
                if arc_kind(entry) in self.unpack:
                    self.present[path] = entry.size
                    todo.append((entry, rel, path))
                    continue
                skipped += 1
                continue
            todo.append((entry, rel, path))
        return todo, skipped

    def already(self, target):
        if target in self.present:
            return self.present[target]
        part = target + ".part"
        return os.path.getsize(part) if os.path.isfile(part) else 0

    def free(self):
        return free_bytes(self.path)

    def reserve(self):
        return MIN_FREE_BYTES

    def transfer(self, src, entry, target, progress):
        if target in self.present:
            return
        if entry.zip_file is not None:
            download_member(src, entry, target, progress)
        else:
            download_file(src, entry, target, progress)


class CloudDest:
    kind = "cloud"

    def __init__(self, system):
        self.system = system
        self.remote = REMOTE_ROMS.rstrip("/") + "/" + system
        self.unpack = []
        self.label = t("cloud_label", path=REMOTE_ROMS.split(":", 1)[-1] + "/" + system)

    def classify(self, plan):
        rc, out, _err = rclone(["lsjson", "-R", "--files-only", self.remote], timeout=600)
        existing = {}
        if rc == 0:
            try:
                existing = {e["Path"]: e.get("Size") for e in json.loads(out or "[]")}
            except (ValueError, KeyError, TypeError):
                existing = {}
        todo, skipped = [], 0
        for entry, rel in plan:
            if ".." in rel.split("/"):
                raise LinkError("unsafe path: " + rel)
            if entry.size is not None and existing.get(rel) == entry.size:
                skipped += 1
                continue
            todo.append((entry, rel, self.remote + "/" + rel))
        return todo, skipped

    def already(self, target):
        return 0

    def free(self):
        return cloud_free()

    def reserve(self):
        return 0

    def transfer(self, src, entry, target, progress):
        upload_stream(src, entry, target, progress)


def resolve_dest(target, name):
    """-> DeviceDest / CloudDest, or None if there is no such system."""
    name = (name or "").strip()
    if not name or "/" in name or name in (".", ".."):
        return None
    device = list_systems()
    if target == "cloud":
        if rclone_bin() is None:
            raise LinkError(t("cloud_unavailable"))
        in_cloud = cloud_systems()
        known = in_cloud + [s for s in device if s not in in_cloud]
    else:
        known = device
    exact = [s for s in known if s == name] or [s for s in known if s.lower() == name.lower()]
    if not exact:
        return None
    return CloudDest(exact[0]) if target == "cloud" else DeviceDest(exact[0])


def run_download(src, plan, dest, url, web=False, quiet=False, confirm=None, start=None):
    """Returns process exit code."""
    # before start() the lock is not ours: do not touch another download's progress
    pre_web = web and start is None
    if dest.kind == "cloud" and "zip" in dest.unpack:
        plan = expand_zips(src, plan)
    todo, skipped = dest.classify(plan)
    if not todo:
        print(t("nothing_to_do"))
        if pre_web:
            write_progress(False, 100, 0, 0, 0, 0, 0, 0, success=True,
                           phase=t("nothing_to_do").lstrip("✅ "))
        return 0
    need = 0
    for entry, _rel, target in todo:
        need += max(0, (entry.size or 0) - dest.already(target))
    free = dest.free()
    print(t("plan", files=len(todo), size=human(need), skip=skipped))
    if free is None:
        print(t("free_unknown"))
    else:
        print(t("free_cloud", free=human(free)) if dest.kind == "cloud" else t("free_space", free=human(free)))
    if free is not None and need + dest.reserve() > free:
        msg = t("no_space", need=human(need), free=human(free))
        NO_SPACE["hit"] = True
        print(msg)
        log(t("log_error", err=msg.lstrip("❌ ")))
        if pre_web:
            write_progress(False, 0, 0, need, 0, 0, 0, len(todo), success=False, phase=msg.lstrip("❌ "))
        return 1
    if confirm is not None and not confirm():
        print(t("cancelled"))
        return 1
    if start is not None and not start():
        return 1
    if web:
        write_progress(True, 0, 0, need, 0, 0, 0, len(todo))

    log(t("log_start", service=src.title, url=url, dest=dest.label))
    progress = Progress(need, len(todo), web, quiet)
    ok = fail = streak = 0
    try:
        for i, (entry, rel, target) in enumerate(todo, 1):
            progress.file_i = i
            if not quiet:
                con("\r" + " " * 70 + "\r" + t("file_start", i=i, n=len(todo), path=rel) + "\n")
            had = dest.already(target)
            before = progress.done
            try:
                kind = arc_kind(entry)
                if dest.kind == "cloud" and kind and kind in dest.unpack and entry.zip_file is None:
                    def note(text, i=i):
                        progress.update(0, force=True)
                        con("\r" + " " * 70 + "\r" + text + "\n")
                        if web:
                            pct, _speed, _eta = progress._stats()
                            write_progress(True, pct, progress.done, progress.total, 0, 0, i, len(todo),
                                           phase=text.split(" ", 1)[-1].strip())
                    n = cloud_unpack(src, entry, target, kind, progress, note)
                    if entry.size is not None:
                        progress.done = before + entry.size
                    ok += 1
                    streak = 0
                    con(t("unpacked", name=entry.name, n=n) + "\n")
                    log(t("log_unpacked", name=entry.name, n=n))
                    progress.update(0, force=True)
                    continue
                dest.transfer(src, entry, target, progress)
                # a restarted transfer re-reads bytes: count this file exactly once
                if entry.size is not None:
                    progress.done = before + max(0, entry.size - had)
                ok += 1
                streak = 0
                kind = arc_kind(entry)
                if dest.kind == "device" and kind and kind in getattr(dest, "unpack", ()):
                    name = os.path.basename(target)
                    progress.update(0, force=True)
                    con("\r" + " " * 70 + "\r" + t("unpacking", name=name) + "\n")
                    if web:
                        pct, speed, eta = progress._stats()
                        write_progress(True, pct, progress.done, progress.total, 0, 0, i, len(todo),
                                       phase=t("unpacking", name=name).lstrip("📦 "))
                    try:
                        n = unpack_archive(target, kind)
                        con(t("unpacked", name=name, n=n) + "\n")
                        log(t("log_unpacked", name=name, n=n))
                    except LinkError as e:
                        ok -= 1
                        fail += 1
                        con(t("unpack_failed", name=name, err=e) + "\n")
                        log(t("log_error", err=t("unpack_failed", name=name, err=e).strip().lstrip("❌ ")))
            except LinkError as e:
                fail += 1
                streak += 1
                con("\n" + t("file_failed", path=rel, err=e) + "\n")
                log(t("log_error", err="%s: %s" % (rel, e)))
                if "No space" in str(e) or streak >= 3:
                    if streak >= 3:
                        con(t("too_many_fail") + "\n")
                    break
            progress.update(0, force=True)
    except KeyboardInterrupt:
        progress.finish(False, phase=t("cancelled_web"))
        con("\n" + t("interrupted") + "\n")
        log(t("log_error", err="interrupted"))
        con_drain()
        return 130
    progress.finish(fail == 0, phase=None if fail == 0 else
                    t("done", ok=ok, skip=skipped, fail=fail).lstrip("✅ "))
    con(t("done", ok=ok, skip=skipped, fail=fail) + "\n")
    log(t("log_done", ok=ok, skip=skipped, fail=fail))
    reloaded = ok and dest.kind != "cloud" and es_reload_games()
    if ok and not quiet:
        if dest.kind == "cloud":
            con(t("cloud_done", dest=dest.label) + "\n")
        else:
            con(t("es_reloaded" if reloaded else "es_hint") + "\n")
    con_drain()
    return 0 if fail == 0 else 1


def print_columns(names, start):
    if not names:
        return
    width = max(len(s) for s in names) + 7
    cols = max(1, 78 // width)
    for i, s in enumerate(names):
        end = "\n" if (i + 1) % cols == 0 or i == len(names) - 1 else ""
        sys.stdout.write(("%4d  %s" % (start + i, s)).ljust(width) + end)


def ask_target():
    """-> 'device' / 'cloud' / None. Without a working cloud: device."""
    if rclone_bin() is None:
        return "device"
    print("")
    print(t("choose_target"))
    while True:
        ans = input(t("target_prompt")).strip().lower()
        if ans in ("q", ""):
            return None
        if ans == "1":
            return "device"
        if ans == "2":
            return "cloud"
        print(t("bad_input"))


def ask_dest(target):
    if target == "cloud":
        print(t("cloud_reading"))
    with_files, others, _free, available = dest_groups(target)
    if not available:
        print(t("cloud_unavailable"))
        return None
    if not with_files and not others:
        print(t("no_roms_dir", path=ROMS_DIR))
        return None
    names = with_files + others
    print("")
    if with_files:
        print(t("grp_cloud_files" if target == "cloud" else "grp_device_files"))
        print_columns(with_files, 1)
    if others:
        print(t("grp_cloud_other" if target == "cloud" else "grp_device_other"))
        print_columns(others, len(with_files) + 1)
    while True:
        ans = input(t("choose_dest") + ": ").strip()
        if ans.lower() == "q" or ans == "":
            return None
        if ans.isdigit() and 1 <= int(ans) <= len(names):
            name = names[int(ans) - 1]
            return CloudDest(name) if target == "cloud" else DeviceDest(name)
        dest = resolve_dest(target, ans)
        if dest:
            return dest
        print(t("dest_invalid"))


# ============================================================== interactive browser
def browse(src, root):
    """-> list of selected Entry (current folder level), or None to exit."""
    if not root.is_dir:
        return [root]
    stack = [root]
    while True:
        cur = stack[-1]
        items = sorted_children(cur)
        print("")
        print(t("folder", service=src.title, path=cur.rel))
        for i, e in enumerate(items, 1):
            if e.is_dir:
                print(t("dir_line", n=i, name=e.name, files=e.files, size=human(e.total)))
            elif is_zip(e):
                print(t("zip_line", n=i, name=e.name, size=human(e.size)))
            else:
                print(t("file_line", n=i, name=e.name, size=human(e.size)))
        # only the commands that make sense here, each on its own line,
        # with examples built from the real numbers on the screen
        print("")
        print(t("help_title"))
        n = len(items)
        print(t("help_select", ex="1" if n == 1 else ("1 %d" % n if n == 2 else "1 %d %d" % (min(2, n), n))))
        dirs = [i for i, e in enumerate(items, 1) if e.is_dir]
        if dirs:
            print(t("help_open", ex="o %d" % dirs[0], name=items[dirs[0] - 1].name))
        zips = [i for i, e in enumerate(items, 1) if is_zip(e)]
        if zips:
            print(t("help_open_zip", ex="o %d" % zips[0], name=items[zips[0] - 1].name))
        if n > 1:
            print(t("help_all", ex="a"))
        if len(stack) > 1:
            print(t("help_back", ex="b"))
        print(t("help_quit", ex="q"))
        ans = input(t("choice")).strip().lower()
        if ans == "q" or ans == "":
            return None
        if ans == "b":
            if len(stack) > 1:
                stack.pop()
            continue
        if ans == "a":
            return [cur]
        parts = ans.split()
        if re.match(r"^o\d+$", parts[0]) and len(parts) == 1:
            parts = ["o", parts[0][1:]]
        if parts[0] == "o" and len(parts) == 2 and parts[1].isdigit():
            k = int(parts[1])
            if 1 <= k <= len(items) and items[k - 1].is_dir:
                stack.append(items[k - 1])
            elif 1 <= k <= len(items) and is_zip(items[k - 1]):
                print(t("zip_reading", name=items[k - 1].name))
                try:
                    stack.append(zip_view(src, items[k - 1]))
                except LinkError as e:
                    print(e)
            else:
                print(t("not_folder"))
            continue
        if all(p.isdigit() and 1 <= int(p) <= len(items) for p in parts):
            chosen = []
            for p in parts:
                e = items[int(p) - 1]
                if e not in chosen:
                    chosen.append(e)
            return chosen
        print(t("bad_input"))


def _lock_holder():
    """PID of a running link download, or None if the lock is free."""
    try:
        f = open(LOCK_FILE, "a")
    except OSError:
        return None
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(f, fcntl.LOCK_UN)
        return None
    except OSError:
        pid = 0
        try:
            with open(PID_FILE) as pf:
                pid = int(pf.read().strip())
        except (OSError, ValueError):
            pass
        return pid
    finally:
        f.close()


def _running_percent():
    try:
        with open(PROGRESS_FILE) as f:
            d = json.load(f)
        if d.get("action") == "link_download" and d.get("active") and d.get("percent") is not None:
            return int(d["percent"])
    except (OSError, ValueError, TypeError):
        pass
    return None


def offer_stop(pid):
    """Another link download holds the lock: offer to stop it. True if it was stopped."""
    pct = _running_percent()
    print(t("running_other", pct=(" (%d%%)" % pct) if pct is not None else "", pid=pid or "?"))
    if input(t("ask_stop")).strip().lower() not in ("y", "yes", "д", "да"):
        print(t("keep_running"))
        return False
    print(t("stopping"))
    for sig, wait in ((signal.SIGTERM, 15), (signal.SIGKILL, 5)):
        if pid:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
            except OSError:
                break
        end = time.time() + wait
        while time.time() < end:
            if _lock_holder() is None:
                if sig == signal.SIGKILL:
                    # killed hard: it could not report that itself
                    write_progress(False, 0, 0, 0, 0, 0, 0, 0, success=False, phase=t("cancelled_web"))
                    log(t("log_error", err="interrupted"))
                print(t("stopped"))
                return True
            time.sleep(0.3)
    print(t("stop_failed", pid=pid or "?"))
    return False


def interactive(url=None):
    print("")
    print(t("title"))
    print(t("supported"))
    print("")
    pid = _lock_holder()
    if pid is not None and not offer_stop(pid):
        return 1
    if not url:
        url = input(t("prompt_url")).strip()
        if not url:
            return 0
    try:
        src, root = load_tree(url, ask_password=True)
    except LinkError as e:
        print(e)
        log(t("log_error", err=str(e).splitlines()[0].lstrip("❌ ")))
        return 1
    if root.is_dir and root.files == 0:
        print(t("empty"))
        return 1
    if root.is_dir:
        print(t("scan_done", files=root.files, size=human(root.total)))
    items = browse(src, root)
    if not items:
        return 0
    try:
        target = ask_target()
        if not target:
            return 0
        dest = ask_dest(target)
        if not dest:
            return 0
    except LinkError as e:
        print(e)
        return 1
    if len(items) == 1 and items[0].is_dir:
        print(t("contents_note", name=items[0].name or "/", dest=dest.label))
    else:
        print(t("items_note", dest=dest.label))
    plan = build_plan(root, items)
    kinds = [k for k, _e in ARCHIVE_KINDS if any(arc_kind(e) == k for e, _r in plan)]
    if kinds:
        able = unpack_kinds()
        can = [k for k in kinds if k in able]
        cannot = [k for k in kinds if k not in able]
        if cannot:
            print(t("unpack_cannot", kinds=", ".join("." + k for k in cannot)))
        if can:
            if dest.kind == "cloud":
                print(t("unpack_cloud_note"))
            if input(t("ask_unpack", kinds=", ".join("." + k for k in can))).strip().lower() in ("y", "yes", "д", "да"):
                dest.unpack = can

    def confirm():
        return input(t("confirm")).strip().lower() in ("y", "yes", "д", "да")

    held = []

    def start():
        # the lock is taken only now: browsing does not block other downloads
        lock = take_lock(False)
        if lock is None:
            return False
        held.append(lock)
        con_start()
        DOWNLOADING["on"] = True
        return True
    try:
        return run_download(src, plan, dest, url, web=True, confirm=confirm, start=start)
    except LinkError as e:
        con(str(e) + "\n")
        log(t("log_error", err=str(e)))
        if held:
            write_progress(False, 0, 0, 0, 0, 0, 0, 0, success=False, phase=str(e).lstrip("❌ "))
        con_drain()
        return 1
    finally:
        DOWNLOADING["on"] = False
        for lock in held:
            release_lock(lock)


# ============================================================== entry point
def _on_sigterm(signum, frame):
    # "Cancel" in the Web UI (or "stop" in another session) sends SIGTERM:
    # stop like Ctrl+C (keeps .part files)
    if DOWNLOADING["on"] and DOWNLOADING["interactive"]:
        con("\n" + t("cancelled_other") + "\n")
    raise KeyboardInterrupt


def _on_sighup(signum, frame):
    # SSH connection closed. While downloading: keep going in the background
    # (progress stays visible in the Web UI); otherwise just quit.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)   # the hang-up may be delivered more than once
    if DOWNLOADING["on"]:
        con_detach()
        log(t("detached_log"))
        return
    con_detach()
    raise KeyboardInterrupt


def take_lock(web):
    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(t("locked"))
        if web:
            write_progress(False, 0, 0, 0, 0, 0, 0, 0, success=False, phase=t("locked").lstrip("❌ "))
        return None
    try:
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    return lock


def release_lock(lock):
    try:
        with open(PID_FILE) as f:
            mine = f.read().strip() == str(os.getpid())
        if mine:
            os.remove(PID_FILE)
    except OSError:
        pass
    try:
        lock.close()
    except OSError:
        pass


def main(argv):
    signal.signal(signal.SIGTERM, _on_sigterm)

    if len(argv) >= 2 and argv[0] == "--list-json":
        password = argv[argv.index("--password") + 1] if "--password" in argv[:-1] else None
        password = password or os.environ.get("SS_LINK_PASSWORD") or None
        try:
            src, root = load_tree(argv[1], password=password, quiet=True)
            print(json.dumps({"service": src.title, "root": root.to_dict()}, ensure_ascii=False))
            return 0
        except LinkError as e:
            need = str(e) in (t("password_needed"), t("password_wrong"))
            print(json.dumps({"error": str(e), "need_password": need}, ensure_ascii=False))
            return 1

    if len(argv) >= 3 and argv[0] == "--zip-json":
        password = os.environ.get("SS_LINK_PASSWORD") or None
        try:
            src, root = load_tree(argv[1], password=password, quiet=True)
            e = find_entry(root, argv[2].rstrip("/"))
            if e is None or not is_zip(e):
                raise LinkError("not found: " + argv[2])
            print(json.dumps({"entry": zip_view(src, e).to_dict()}, ensure_ascii=False))
            return 0
        except LinkError as e:
            print(json.dumps({"error": str(e)}, ensure_ascii=False))
            return 1

    if len(argv) >= 2 and argv[0] == "--dests-json":
        target = "cloud" if argv[1] == "cloud" else "device"
        try:
            with_files, others, free, available = dest_groups(target)
        except LinkError:
            with_files, others, free, available = [], [], None, False
        print(json.dumps({"target": target, "available": available, "with_files": with_files,
                          "others": others, "free": free, "unpack": unpack_kinds()}, ensure_ascii=False))
        return 0

    if len(argv) >= 2 and argv[0] == "--download":
        url, dest_name, items, password, web, target, unpack = argv[1], None, [], None, False, "device", False
        i = 2
        while i < len(argv):
            a = argv[i]
            if a in ("--dest", "--item", "--password", "--target") and i + 1 < len(argv):
                val = argv[i + 1]
                if a == "--dest":
                    dest_name = val
                elif a == "--item":
                    items.append(val)
                elif a == "--target":
                    target = "cloud" if val == "cloud" else "device"
                else:
                    password = val
                i += 2
                continue
            if a == "--web-progress":
                web = True
            if a == "--unpack":
                unpack = True
            i += 1
        password = password or os.environ.get("SS_LINK_PASSWORD") or None
        try:
            dest = resolve_dest(target, dest_name)
        except LinkError as e:
            print(e)
            if web:
                write_progress(False, 0, 0, 0, 0, 0, 0, 0, success=False, phase=str(e).lstrip("❌ "))
            return 1
        if not dest:
            print(t("dest_invalid"))
            if web:
                write_progress(False, 0, 0, 0, 0, 0, 0, 0, success=False, phase=t("dest_invalid").lstrip("❌ "))
            return 1
        if unpack:
            dest.unpack = unpack_kinds()
        lock = take_lock(web)
        if lock is None:
            return 1
        if web:
            write_progress(True, 0, 0, 0, 0, 0, 0, 0)
        ticker = start_ticker('Save Sync: загрузка по ссылке началась', 'Save Sync: загрузка по ссылке ещё идёт ({n} мин)')
        try:
            src, root = load_tree(url, password=password, quiet=True)
            entries = []
            for rel in items:
                e = find_entry(root, rel, src)
                if e is None:
                    raise LinkError("not found: " + rel)
                entries.append(e)
            plan = build_plan(root, entries)
            rc = run_download(src, plan, dest, url, web=web, quiet=True)
            if rc != 130:
                notify_screen('Save Sync: загрузка по ссылке завершена' if rc == 0 else ('Save Sync: в облаке не хватает места для загрузки по ссылке' if dest.kind == "cloud" else 'Save Sync: на устройстве не хватает места для загрузки по ссылке') if NO_SPACE["hit"] else 'Save Sync: ошибка загрузки по ссылке')
            return rc
        except LinkError as e:
            print(e)
            log(t("log_error", err=str(e).splitlines()[0].lstrip("❌ ")))
            notify_screen(('Save Sync: в облаке не хватает места для загрузки по ссылке' if dest.kind == "cloud" else 'Save Sync: на устройстве не хватает места для загрузки по ссылке') if NO_SPACE["hit"] else 'Save Sync: ошибка загрузки по ссылке')
            if web:
                write_progress(False, 0, 0, 0, 0, 0, 0, 0, success=False,
                               phase=str(e).splitlines()[0].lstrip("❌ "))
            return 1
        except KeyboardInterrupt:
            if web:
                write_progress(False, 0, 0, 0, 0, 0, 0, 0, success=False, phase=t("cancelled_web"))
            return 130
        finally:
            ticker.set()

    DOWNLOADING["interactive"] = True
    signal.signal(signal.SIGHUP, _on_sighup)
    try:
        try:
            return interactive(argv[0] if argv else None)
        except (KeyboardInterrupt, EOFError):
            try:
                print("")
            except OSError:
                pass
            return 130
    except KeyboardInterrupt:   # a hang-up signal right after the terminal closed
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
LINKEOF
    sed -i \
        -e "s|__SS_LANG__|ru|g" \
        -e "s|__SS_ROMS_DIR__|$ROMS_DIR|g" \
        -e "s|__SS_LOG_FILE__|$LOG_FILE|g" \
        -e "s|__SS_RCLONE_BIN__|$RCLONE_BIN|g" \
        -e "s|__SS_RCLONE_CONF__|$RCLONE_CONF|g" \
        -e "s|__SS_REMOTE_ROMS__|$REMOTE_ROMS|g" \
        -e "s|__SS_CONFIG_FILE__|$CONFIG_FILE|g" \
        "$LINK_SCRIPT"
    chmod +x "$LINK_SCRIPT" 2>/dev/null
}

############################################
# Создание фильтра для ромов
############################################

create_roms_filter() {
    # Фильтр rclone: решает первое подходящее правило. Мусор других систем не
    # синхронизируется никогда, медиа - по настройке, дальше только выбранные системы.
    local pico=false d
    IFS='|' read -ra DIRS <<< "$ROMS_SYNC_DIRS"
    for d in "${DIRS[@]}"; do
        [ "$(echo "$d" | xargs)" = "pico8" ] && pico=true
    done
    {
        echo "# Фильтр для синхронизации ромов"
        echo "# Создан автоматически, не редактируйте вручную"
        echo ""
        echo "# Служебные файлы и мусор других систем (Mac, Windows, NAS)"
        cat << 'EOF'
- **/_info.txt
- .DS_Store
- Thumbs.db
- desktop.ini
- ._*
- *:Zone.Identifier
- *.crdownload
- __MACOSX/**
- @eaDir/**
- #recycle/**
- $RECYCLE.BIN/**
- System Volume Information/**
- .Trash-*/**
- .Trashes/**
- .Spotlight-V100/**
- .fseventsd/**
EOF
        if [ "$ROMS_SYNC_MEDIA" != "true" ]; then
            echo ""
            echo "# Медиа-папки"
            echo "- **/{images,media,videos,manuals,screenshots,thumbnails,bezels,covers,backcovers,3dboxes,fanart,marquees,miximages,miximages_v2,physicalmedia,titlescreens,wheel,boxart,snaps,downloaded_images,downloaded_videos,downloaded_media}/**"
            if [ "$pico" = true ]; then
                echo ""
                echo "# Игры PICO-8 - это картинки (.p8.png): их не исключаем"
                echo "+ /pico8/**.png"
            fi
            echo ""
            echo "# Картинки"
            cat << 'EOF'
- **.png
- **.jpg
- **.jpeg
- **.gif
- **.bmp
EOF
        fi
        echo ""
        echo "# Видео (всегда: большие файлы)"
        cat << 'EOF'
- **.mp4
- **.avi
- **.webm
- **.wmv
- **.mkv
- **.mov
- **.m4v
- **.mpg
- **.mpeg
EOF
        if [ -n "$ROMS_SYNC_DIRS" ]; then
            echo ""
            echo "# Выбранные системы"
            for d in "${DIRS[@]}"; do
                d=$(echo "$d" | xargs)
                [ -n "$d" ] && echo "+ /$d/**"
            done
        fi
        echo ""
        echo "# Всё остальное"
        echo "- **"
    } > "$ROMS_FILTER_FILE"
}

############################################
# Управление исключениями (сохранения)
############################################

manage_exclusions() {
    # Загружаем конфиг
    load_config

    # Systems whose ROMs are only in the cloud (uploaded from another device) are
    # listed too, so they can be excluded before their saves are downloaded here.
    local CLOUD_ROM_SYS=()
    local CLOUD_PORTS=false
    local CLOUD_SAVE_SYS=()
    if [ -n "$RCLONE_PATH" ] && [ -f "$RCLONE_PATH" ]; then
        echo "🔍 Проверяю облако: системы, ромы которых есть только там..."
        while IFS= read -r cloud_sys; do
            [ -n "$cloud_sys" ] && CLOUD_ROM_SYS+=("$cloud_sys")
        done < <("$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_ROMS" --contimeout 15s --timeout 20s 2>/dev/null | awk '{print $NF}')
        "$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE/_ports" --contimeout 15s --timeout 20s 2>/dev/null | grep -q . && CLOUD_PORTS=true
        # systems that have saves in the cloud (ROMs are not required)
        while IFS= read -r cloud_sys; do
            case "$cloud_sys" in ""|_*|.*) continue ;; esac
            CLOUD_SAVE_SYS+=("$cloud_sys")
        done < <("$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE" --contimeout 15s --timeout 20s 2>/dev/null | awk '{print $NF}')
    fi
    
    while true; do
        SYSTEMS=()
        CLOUD_ONLY_SYS=()
        
        # Рекурсивный поиск систем с ромами
        for dir in "$ROMS_DIR"/*/; do
            [ -d "$dir" ] || continue
            BASENAME=$(basename "$dir")
            
            if find "$dir" -type f ! -name "gamelist.xml" ! -name "_info.txt" ! -name "*.dat" ! -name "*.txt" ! -name "*.log" ! -name "*.cache" ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "desktop.ini" ! -name "._*" ! -name "*.pdf" ! -name "*.jpg" ! -name "*.mp4" ! -path "*/images/*" ! -path "*/media/*" ! -path "*/videos/*" ! -path "*/manuals/*" ! -path "*/bezels/*" ! -path "*/downloaded_*" ! -path "*/__MACOSX/*" 2>/dev/null | head -1 | grep -q .; then
                SYSTEMS+=("$BASENAME")
            fi
        done
        for cloud_sys in "${CLOUD_ROM_SYS[@]}"; do
            local known=false
            for sys in "${SYSTEMS[@]}"; do
                [ "$sys" = "$cloud_sys" ] && { known=true; break; }
            done
            if [ "$known" = false ]; then
                SYSTEMS+=("$cloud_sys")
                CLOUD_ONLY_SYS+=("$cloud_sys")
            fi
        done
        for cloud_sys in "${CLOUD_SAVE_SYS[@]}"; do
            local known=false
            for sys in "${SYSTEMS[@]}"; do
                [ "$sys" = "$cloud_sys" ] && { known=true; break; }
            done
            if [ "$known" = false ]; then
                SYSTEMS+=("$cloud_sys")
                CLOUD_ONLY_SYS+=("$cloud_sys")
            fi
        done
        # PortMaster ports: one entry for the saves of all ports
        HAS_PORTS=false
        for pdir in "$ROMS_DIR"/ports/*/; do
            [ -d "$pdir" ] || continue
            case "$(basename "$pdir")" in PortMaster|autoinstall|images|videos|manuals) continue ;; esac
            if [ -d "$pdir/saves" ] || [ -d "$pdir/conf" ] || [ -d "$pdir/gamedata" ]; then
                HAS_PORTS=true
                break
            fi
        done
        if [ "$HAS_PORTS" = true ]; then
            SYSTEMS+=("PortMaster")
        elif [ "$CLOUD_PORTS" = true ]; then
            # no ports here, but their saves are in the cloud (uploaded from another device)
            SYSTEMS+=("PortMaster")
            CLOUD_ONLY_SYS+=("PortMaster")
        fi
        
        # Разбираем исключения из переменной
        EXCLUDED_SYSTEMS_LIST=()
        if [ -n "$EXCLUDED_SYSTEMS" ]; then
            IFS='|' read -ra EXCLUDED_SYSTEMS_LIST <<< "$EXCLUDED_SYSTEMS"
        fi
        
        clear
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " Исключить системы (сохранения)"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        
        if [ ${#EXCLUDED_SYSTEMS_LIST[@]} -gt 0 ]; then
            echo "Исключены:"
            for sys in "${EXCLUDED_SYSTEMS_LIST[@]}"; do
                [ -n "$sys" ] && echo "  • $sys"
            done
        else
            echo "  Все системы синхронизируются"
        fi
        
        echo ""
        echo "Всего систем с ромами: ${#SYSTEMS[@]}"
        echo "Исключено: ${#EXCLUDED_SYSTEMS_LIST[@]}"
        echo "Синхронизируется: $((${#SYSTEMS[@]} - ${#EXCLUDED_SYSTEMS_LIST[@]}))"
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo ""
        echo " 1 - Добавить систему в исключения"
        echo " 2 - Удалить систему из исключений"
        echo " 3 - Очистить все исключения"
        echo " 4 - Показать все системы"
        echo " 0 - Назад"
        echo ""
        read -p "Выберите (0-4): " excl_choice
        
        case "$excl_choice" in
            1)
                echo ""
                echo "Доступные системы для исключения (0 - отмена):"
                echo ""
                local idx=0
                for sys in "${SYSTEMS[@]}"; do
                    idx=$((idx+1))
                    local excluded=false
                    for ex in "${EXCLUDED_SYSTEMS_LIST[@]}"; do
                        if [ "$ex" = "$sys" ]; then
                            excluded=true
                            break
                        fi
                    done
                    local ctag=""
                    for co in "${CLOUD_ONLY_SYS[@]}"; do [ "$co" = "$sys" ] && ctag=" (только в облаке)"; done
                    if [ "$excluded" = true ]; then
                        echo "  $idx - $sys$ctag ⚠️ УЖЕ ИСКЛЮЧЕНА"
                    else
                        echo "  $idx - $sys$ctag"
                    fi
                done
                echo ""
                read -p "Введите номера систем через пробел (0 - отмена): " -a ADD_NUMS
                
                local cancel=false
                for num in "${ADD_NUMS[@]}"; do
                    if [ "$num" = "0" ]; then
                        cancel=true
                        break
                    fi
                done
                if [ "$cancel" = true ]; then
                    echo "Отменено"
                    pause
                    continue
                fi
                
                for num in "${ADD_NUMS[@]}"; do
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -le "${#SYSTEMS[@]}" ]; then
                        local sys_name="${SYSTEMS[$((num-1))]}"
                        local already=false
                        for ex in "${EXCLUDED_SYSTEMS_LIST[@]}"; do
                            if [ "$ex" = "$sys_name" ]; then
                                already=true
                                break
                            fi
                        done
                        if [ "$already" = false ]; then
                            if [ -z "$EXCLUDED_SYSTEMS" ]; then
                                EXCLUDED_SYSTEMS="$sys_name"
                            else
                                EXCLUDED_SYSTEMS="$EXCLUDED_SYSTEMS|$sys_name"
                            fi
                            echo "  ✅ $sys_name добавлена в исключения"
                        else
                            echo "  ⚠️ $sys_name уже исключена"
                        fi
                    fi
                done
                save_config
                echo ""
                pause
                ;;
            2)
                if [ ${#EXCLUDED_SYSTEMS_LIST[@]} -eq 0 ]; then
                    echo ""
                    echo "Нет исключений для удаления."
                    pause
                    continue
                fi
                
                echo ""
                echo "Текущие исключения (0 - отмена):"
                echo ""
                local idx=0
                for sys in "${EXCLUDED_SYSTEMS_LIST[@]}"; do
                    [ -n "$sys" ] && idx=$((idx+1)) && echo "  $idx - $sys"
                done
                echo ""
                read -p "Введите номера систем для удаления (0 - отмена): " -a REMOVE_NUMS
                
                local cancel=false
                for num in "${REMOVE_NUMS[@]}"; do
                    if [ "$num" = "0" ]; then
                        cancel=true
                        break
                    fi
                done
                if [ "$cancel" = true ]; then
                    echo "Отменено"
                    pause
                    continue
                fi
                
                local new_list=""
                local idx=0
                for sys in "${EXCLUDED_SYSTEMS_LIST[@]}"; do
                    [ -z "$sys" ] && continue
                    idx=$((idx+1))
                    local remove=false
                    for num in "${REMOVE_NUMS[@]}"; do
                        if [ "$num" = "$idx" ]; then
                            remove=true
                            break
                        fi
                    done
                    if [ "$remove" = false ]; then
                        if [ -z "$new_list" ]; then
                            new_list="$sys"
                        else
                            new_list="$new_list|$sys"
                        fi
                    else
                        echo "  ✅ $sys удалена из исключений"
                    fi
                done
                EXCLUDED_SYSTEMS="$new_list"
                save_config
                echo ""
                pause
                ;;
            3)
                echo ""
                read -p "Удалить все исключения? (y/n): " clean_excl
                if [ "$clean_excl" = "y" ] || [ "$clean_excl" = "Y" ]; then
                    EXCLUDED_SYSTEMS=""
                    save_config
                    echo "✅ Все исключения удалены"
                else
                    echo "Отменено"
                fi
                echo ""
                pause
                ;;
            4)
                echo ""
                echo "Все системы с ромами:"
                echo ""
                local idx=0
                for sys in "${SYSTEMS[@]}"; do
                    idx=$((idx+1))
                    local excluded=false
                    for ex in "${EXCLUDED_SYSTEMS_LIST[@]}"; do
                        if [ "$ex" = "$sys" ]; then
                            excluded=true
                            break
                        fi
                    done
                    local ctag=""
                    for co in "${CLOUD_ONLY_SYS[@]}"; do [ "$co" = "$sys" ] && ctag=" (только в облаке)"; done
                    if [ "$excluded" = true ]; then
                        echo "  $idx - $sys$ctag ❌ (исключена)"
                    else
                        echo "  $idx - $sys$ctag ✅ (синхронизируется)"
                    fi
                done
                echo ""
                pause
                ;;
            0)
                return
                ;;
            *)
                echo "❌ Неверный выбор"
                sleep 1
                ;;
        esac
    done
}

############################################
# Управление синхронизацией ромов
############################################

manage_roms_sync() {
    # Загружаем конфиг
    load_config
    
    while true; do
        clear
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📁 Копирование и загрузка ромов"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        
        if [ -n "$ROMS_SYNC_DIRS" ]; then
            echo "Выбранные системы: ${ROMS_SYNC_DIRS//|/, }"
            echo "Всего систем: $(echo "$ROMS_SYNC_DIRS" | tr '|' '\n' | grep -c .)"
        else
            echo "Системы: не выбраны"
        fi
        
        if [ "$ROMS_SYNC_MEDIA" = "true" ]; then
            echo "Копирование медиа: ✅ ВКЛЮЧЕНО"
        else
            echo "Копирование медиа: ❌ ВЫКЛЮЧЕНО"
        fi
        
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo ""
        echo " 1 - 📂 Выбор систем для копирования и загрузки"
        echo " 2 - 🖼️ Включить/выключить копирование изображений"
        echo " 3 - 📥 Загрузить ромы из облака"
        echo " 4 - 📤 Выгрузить ромы в облако"
        echo " 5 - 🔗 Скачать по публичной ссылке (Яндекс.Диск, pCloud, Nextcloud, archive.org)"
        echo " 0 - Назад"
        echo ""
        read -p "Выберите (0-5): " roms_choice
        
        case "$roms_choice" in
            0)
                return
                ;;
            1)
                select_roms_systems
                ;;
            2)
                toggle_roms_media
                ;;
            3)
                manual_roms_download
                ;;
            4)
                manual_roms_upload
                ;;
            5)
                link_download_menu
                ;;
            *)
                echo "❌ Неверный выбор"
                sleep 1
                ;;
        esac
    done
}

link_download_menu() {
    clear
    if ! command -v python3 >/dev/null 2>&1; then
        echo "❌ python3 не найден - загрузка по ссылке недоступна на этой системе."
        echo ""
        pause
        return
    fi
    [ -f "$LINK_SCRIPT" ] || create_link_script
    python3 "$LINK_SCRIPT"
    echo ""
    pause
}

select_roms_systems() {
    local SYSTEMS_LIST=()
    local CLOUD_ONLY=()
    
    if [ ! -d "$ROMS_DIR" ]; then
        echo "❌ Папка $ROMS_DIR не найдена"
        sleep 2
        return
    fi
    
    echo "🔍 Поиск систем с ромами (локально и в облаке)..."
    
    for dir in "$ROMS_DIR"/*/; do
        [ -d "$dir" ] || continue
        BASENAME=$(basename "$dir")
        
        if find "$dir" -type f ! -name "gamelist.xml" ! -name "_info.txt" ! -name "*.dat" ! -name "*.txt" ! -name "*.log" ! -name "*.cache" ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "desktop.ini" ! -name "._*" ! -name "*.pdf" ! -name "*.jpg" ! -name "*.mp4" ! -path "*/images/*" ! -path "*/media/*" ! -path "*/videos/*" ! -path "*/manuals/*" ! -path "*/bezels/*" ! -path "*/downloaded_*" ! -path "*/__MACOSX/*" 2>/dev/null | head -1 | grep -q .; then
            SYSTEMS_LIST+=("$BASENAME")
        fi
    done
    
    # Дополнительно спрашиваем облако - там могут быть системы,
    # которых ещё нет на устройстве (например, ромы закинули прямо
    # в облако с компьютера, не трогая устройство). Без этого их
    # нельзя было бы выбрать и, соответственно, скачать.
    if [ -n "$RCLONE_PATH" ] && [ -f "$RCLONE_PATH" ]; then
        while IFS= read -r cloud_sys; do
            [ -z "$cloud_sys" ] && continue
            local exists=false
            for sys in "${SYSTEMS_LIST[@]}"; do
                if [ "$sys" = "$cloud_sys" ]; then
                    exists=true
                    break
                fi
            done
            if [ "$exists" = false ]; then
                SYSTEMS_LIST+=("$cloud_sys")
                CLOUD_ONLY+=("$cloud_sys")
            fi
        done < <("$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_ROMS" 2>/dev/null | awk '{print $NF}')
    fi
    
    if [ ${#SYSTEMS_LIST[@]} -eq 0 ]; then
        echo "❌ Нет систем с ромами ни локально, ни в облаке"
        sleep 2
        return
    fi
    
    echo "✅ Найдено систем: ${#SYSTEMS_LIST[@]}"
    if [ ${#CLOUD_ONLY[@]} -gt 0 ]; then
        echo "   из них только в облаке: ${#CLOUD_ONLY[@]} (можно выбрать и скачать)"
    fi
    sleep 1
    
    local SELECTED=()
    if [ -n "$ROMS_SYNC_DIRS" ]; then
        IFS='|' read -ra SELECTED <<< "$ROMS_SYNC_DIRS"
    fi
    
    while true; do
        clear
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📁 Выбор систем для копирования и загрузки"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo "Выберите системы, которые будут копироваться"
        echo ""
        echo "Текущий выбор:"
        if [ ${#SELECTED[@]} -gt 0 ]; then
            echo "  ${SELECTED[*]}"
        else
            echo "  ❌ Не выбрано ни одной системы"
        fi
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo "Доступные системы (${#SYSTEMS_LIST[@]}):"
        echo ""
        
        local idx=0
        for sys in "${SYSTEMS_LIST[@]}"; do
            idx=$((idx+1))
            local selected=false
            for sel in "${SELECTED[@]}"; do
                if [ "$sel" = "$sys" ]; then
                    selected=true
                    break
                fi
            done
            local cloud_tag=""
            for co in "${CLOUD_ONLY[@]}"; do
                if [ "$co" = "$sys" ]; then
                    cloud_tag=" (только в облаке)"
                    break
                fi
            done
            if [ "$selected" = true ]; then
                echo "  $idx - $sys ✅$cloud_tag"
            else
                echo "  $idx - $sys$cloud_tag"
            fi
        done
        
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo ""
        echo " 1 - Добавить системы"
        echo " 2 - Выбрать все системы"
        echo " 3 - Очистить все"
        echo " 4 - Удалить системы"
        echo " 0 - Применить и выйти"
        echo ""
        read -p "Выберите (0-4): " sys_choice
        
        case "$sys_choice" in
            0)
                if [ ${#SELECTED[@]} -gt 0 ]; then
                    ROMS_SYNC_DIRS=$(IFS='|'; echo "${SELECTED[*]}")
                    echo "✅ Выбраны системы: ${ROMS_SYNC_DIRS//|/, }"
                    save_config
                    create_roms_filter
                    sleep 1
                else
                    ROMS_SYNC_DIRS=""
                    save_config
                    create_roms_filter
                    echo "ℹ️ Системы не выбраны. Копирование ромов отключено."
                    sleep 1
                fi
                return
                ;;
            1)
                echo ""
                read -p "Введите номера систем через пробел (0 - отмена): " -a ADD_NUMS
                local cancel=false
                for num in "${ADD_NUMS[@]}"; do
                    if [ "$num" = "0" ]; then
                        cancel=true
                        break
                    fi
                done
                if [ "$cancel" = true ]; then
                    echo "Отменено"
                    sleep 1
                    continue
                fi
                
                for num in "${ADD_NUMS[@]}"; do
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#SYSTEMS_LIST[@]}" ]; then
                        local sys_name="${SYSTEMS_LIST[$((num-1))]}"
                        local already=false
                        for sel in "${SELECTED[@]}"; do
                            if [ "$sel" = "$sys_name" ]; then
                                already=true
                                break
                            fi
                        done
                        if [ "$already" = false ]; then
                            SELECTED+=("$sys_name")
                            echo "  ✅ $sys_name добавлена"
                        else
                            echo "  ⚠️ $sys_name уже выбрана"
                        fi
                    else
                        echo "  ⚠️ Неверный номер: $num (пропущено)"
                    fi
                done
                
                if [ ${#SELECTED[@]} -gt 0 ]; then
                    echo ""
                    echo "✅ Теперь выбрано систем: ${#SELECTED[@]}"
                    sleep 1
                fi
                ;;
            2)
                SELECTED=("${SYSTEMS_LIST[@]}")
                echo "✅ Выбраны все системы (${#SELECTED[@]})"
                sleep 1
                ;;
            3)
                SELECTED=()
                echo "✅ Все системы очищены"
                sleep 1
                ;;
            4)
                if [ ${#SELECTED[@]} -eq 0 ]; then
                    echo ""
                    echo "⚠️ Нет выбранных систем для удаления"
                    sleep 1
                    continue
                fi
                
                echo ""
                echo "Текущий выбор:"
                local idx=0
                for sys in "${SELECTED[@]}"; do
                    idx=$((idx+1))
                    echo "  $idx - $sys"
                done
                echo ""
                echo "Введите номера систем для УДАЛЕНИЯ:"
                echo ""
                read -p "Введите номера систем через пробел (0 - отмена): " -a REMOVE_NUMS
                local cancel=false
                for num in "${REMOVE_NUMS[@]}"; do
                    if [ "$num" = "0" ]; then
                        cancel=true
                        break
                    fi
                done
                if [ "$cancel" = true ]; then
                    echo "Отменено"
                    sleep 1
                    continue
                fi
                
                local NEW_SELECTED=()
                local idx=0
                for sys in "${SELECTED[@]}"; do
                    idx=$((idx+1))
                    local remove=false
                    for num in "${REMOVE_NUMS[@]}"; do
                        if [ "$num" = "$idx" ]; then
                            remove=true
                            break
                        fi
                    done
                    if [ "$remove" = false ]; then
                        NEW_SELECTED+=("$sys")
                    else
                        echo "  ✅ $sys удалена"
                    fi
                done
                SELECTED=("${NEW_SELECTED[@]}")
                
                if [ ${#SELECTED[@]} -gt 0 ]; then
                    echo ""
                    echo "✅ Осталось систем: ${#SELECTED[@]}"
                else
                    echo ""
                    echo "⚠️ Не осталось выбранных систем"
                fi
                sleep 1
                ;;
            *)
                echo "❌ Неверный выбор"
                sleep 1
                ;;
        esac
    done
}

toggle_roms_media() {
    if [ "$ROMS_SYNC_MEDIA" = "true" ]; then
        ROMS_SYNC_MEDIA="false"
        echo "✅ Копирование медиа ВЫКЛЮЧЕНО"
    else
        ROMS_SYNC_MEDIA="true"
        echo "✅ Копирование медиа ВКЛЮЧЕНО"
    fi
    save_config
    create_roms_filter
    sleep 1
}

manual_roms_download() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " 📥 Загрузка ромов из облака"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo "Это действие ЗАГРУЗИТ ромы из облака на устройство."
    echo "Файлы на устройстве НЕ УДАЛЯЮТСЯ."
    echo ""
    echo "Будут загружены только новые или измененные файлы."
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo ""
    read -p "Продолжить загрузку? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "❌ Отменено."
        echo ""
        pause
        return
    fi
    
    echo ""
    echo "🔄 Загрузка ромов из облака..."
    if [ -f "$DOWNLOAD_ROMS" ]; then
        bash "$DOWNLOAD_ROMS"
    else
        echo "❌ Скрипт download_roms.sh не найден"
    fi
    echo ""
    pause
}

manual_roms_upload() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " ⚠️  ВНИМАНИЕ! Выгрузка ромов в облако"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo "Это действие УДАЛИТ из облака ромы,"
    echo "которых нет на устройстве."
    echo ""
    echo "Если на устройстве не хватает каких-то ромов,"
    echo "они исчезнут из облака без возможности восстановления!"
    echo ""
    echo "Рекомендуется сначала ЗАГРУЗИТЬ ромы из облака (пункт 3)"
    echo "или сделать бэкап облака."
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo ""
    read -p "Продолжить выгрузку? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "❌ Отменено."
        echo ""
        pause
        return
    fi
    
    echo ""
    echo "🔄 Выгрузка ромов в облако..."
    if [ -f "$UPLOAD_ROMS" ]; then
        bash "$UPLOAD_ROMS"
    else
        echo "❌ Скрипт upload_roms.sh не найден"
    fi
    echo ""
    pause
}

############################################
# Функция статистики и логов
############################################

show_statistics() {
    while true; do
        clear
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📊 СТАТИСТИКА И ЛОГИ"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        
        if [ -f "$LOG_FILE" ]; then
            sync_stats_counts
            TOTAL=$((SYNC_OK + SYNC_ERR))
            OK=$SYNC_OK
            ERR=$SYNC_ERR
            
            echo "📈 Статистика сохранений:"
            echo "  Всего синхронизаций: $TOTAL"
            echo "  Успешных: $OK"
            echo "  Ошибок: $ERR"
            echo ""
            
            ROMS_TOTAL=$(grep -c "Выгрузка ромов завершена\|Загрузка ромов завершена" "$LOG_FILE" 2>/dev/null)
            ROMS_ERR=$(grep -c "Ошибка загрузки ромов\|Ошибка выгрузки ромов" "$LOG_FILE" 2>/dev/null)
            [ -z "$ROMS_TOTAL" ] && ROMS_TOTAL=0
            [ -z "$ROMS_ERR" ] && ROMS_ERR=0
            ROMS_OK=$((ROMS_TOTAL - ROMS_ERR))
            [ $ROMS_OK -lt 0 ] && ROMS_OK=0
            
            echo "📈 Статистика ромов:"
            echo "  Всего синхронизаций: $ROMS_TOTAL"
            echo "  Успешных: $ROMS_OK"
            echo "  Ошибок: $ROMS_ERR"
            echo ""
            
            LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null)
            [ -z "$LOG_LINES" ] && LOG_LINES=0
            
            if [ "$LOG_LINES" -eq 0 ]; then
                echo "📭 Лог пуст"
                echo ""
                echo "  0 - Назад"
                echo ""
                read -p "Выберите (0): " log_action
                if [ "$log_action" = "0" ]; then
                    return
                fi
                continue
            fi
            
            if [ "$LOG_LINES" -le 15 ]; then
                SHOW_LINES=$LOG_LINES
            else
                SHOW_LINES=15
            fi
            
            echo "📋 Последние $SHOW_LINES записей (всего: $LOG_LINES):"
            echo "──────────────────────────────────────────────────────────"
            tail -$SHOW_LINES "$LOG_FILE" 2>/dev/null
            echo "──────────────────────────────────────────────────────────"
            
            echo ""
            echo "Действия:"
            echo "  1 - Показать больше записей"
            echo "  2 - Показать весь лог"
            echo "  3 - Очистить лог"
            echo "  0 - Назад"
            echo ""
            read -p "Выберите (0-3): " log_action
            
            case "$log_action" in
                0)
                    return
                    ;;
                1)
                    echo ""
                    if [ "$LOG_LINES" -gt 3 ]; then
                        echo "Введите количество записей (3-$LOG_LINES):"
                        read -p "→ " custom_lines
                        if [[ "$custom_lines" =~ ^[0-9]+$ ]] && [ "$custom_lines" -ge 3 ] && [ "$custom_lines" -le "$LOG_LINES" ]; then
                            echo ""
                            echo "📋 Последние $custom_lines записей:"
                            echo "──────────────────────────────────────────────────────────"
                            tail -$custom_lines "$LOG_FILE"
                            echo "──────────────────────────────────────────────────────────"
                        else
                            echo "❌ Неверное количество (от 3 до $LOG_LINES)"
                        fi
                    else
                        echo "❌ В логе всего $LOG_LINES записей"
                    fi
                    echo ""
                    pause
                    ;;
                2)
                    echo ""
                    echo "📋 ПОЛНЫЙ ЛОГ"
                    echo "══════════════════════════════════════════════════════════"
                    cat "$LOG_FILE"
                    echo "══════════════════════════════════════════════════════════"
                    echo ""
                    pause
                    ;;
                3)
                    echo ""
                    read -p "Очистить лог-файл? (y/n): " clean_confirm
                    if [ "$clean_confirm" = "y" ] || [ "$clean_confirm" = "Y" ]; then
                        > "$LOG_FILE"
                        echo "✅ Лог очищен"
                    else
                        echo "Отменено"
                    fi
                    echo ""
                    pause
                    ;;
                *)
                    echo "❌ Неверный выбор"
                    echo ""
                    pause
                    ;;
            esac
        else
            echo "❌ Лог-файл не найден: $LOG_FILE"
            echo ""
            echo "Лог будет создан автоматически после первой синхронизации."
            echo ""
            echo "  0 - Назад"
            echo ""
            read -p "Выберите (0): " log_action
            if [ "$log_action" = "0" ]; then
                return
            fi
        fi
    done
}

############################################
# Функция статуса для меню
############################################

get_status_info() {
    SYSTEM_VERSION="неизвестно"
    
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        SYSTEM_VERSION=$(get_system_version)
    fi
    
    # Загружаем конфиг
    load_config
    
    REAL_INTERVAL=$SYNC_INTERVAL
    REAL_RETRIES=$MAX_RETRIES
    
    if [ -f "$RCLONE_PATH" ] && [ -f "$RCLONE_CONF" ]; then
        # how long the cloud takes to answer is shown too: a slow cloud is not "not connected"
        T0=$SECONDS
        if "$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_NAME:" --contimeout 10s --timeout 15s \
            --low-level-retries 1 --retries 1 >/dev/null 2>&1; then
            T1=$((SECONDS - T0))
            if [ "$T1" -gt 3 ]; then CLOUD_STATUS="⚠ медленно (${T1} с)"; else CLOUD_STATUS="✓ подключено"; fi
            CLOUD_FREE=$(cloud_about | grep -i "^free" | awk '{print $2, $3}')
            [ -z "$CLOUD_FREE" ] && CLOUD_FREE=$(cloud_free_unknown)
        else
            if timeout 3 bash -c ': > /dev/tcp/1.1.1.1/443' 2>/dev/null || timeout 3 bash -c ': > /dev/tcp/8.8.8.8/443' 2>/dev/null; then
                CLOUD_STATUS="✗ не отвечает"
            else
                CLOUD_STATUS="✗ нет интернета"
            fi
            CLOUD_FREE="неизвестно"
        fi
    else
        CLOUD_STATUS="✗ не настроено"
        CLOUD_FREE="неизвестно"
    fi
    
   if [ -d "$SAVE_DIR" ]; then
    # Считаем только файлы сохранений
    FILE_COUNT=$(find "$SAVE_DIR" -type f ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "*.log" ! -name "*.cache" ! -name ".keep" ! -name "*.keep" 2>/dev/null | wc -l)
    
    # Считаем размер в байтах (как в Python)
    if [ "$FILE_COUNT" -gt 0 ]; then
        FILE_SIZE_BYTES=$(find "$SAVE_DIR" -type f ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "*.log" ! -name "*.cache" ! -name ".keep" ! -name "*.keep" -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
        # find without -printf (busybox on Recalbox) prints nothing: count with python3
        if [ -z "$FILE_SIZE_BYTES" ] || [ "$FILE_SIZE_BYTES" = "0" ]; then
            FILE_SIZE_BYTES=$(python3 -c 'import os,sys,fnmatch
skip=(".DS_Store","Thumbs.db","*.log","*.cache",".keep","*.keep")
n=0
for r,d,fs in os.walk(sys.argv[1]):
    for f in fs:
        if not any(fnmatch.fnmatch(f,p) for p in skip):
            try: n+=os.path.getsize(os.path.join(r,f))
            except OSError: pass
print(n)' "$SAVE_DIR" 2>/dev/null)
        fi
        # awk instead of bc: bc is not on every system
        if [ -n "$FILE_SIZE_BYTES" ] && [ "$FILE_SIZE_BYTES" -gt 0 ] 2>/dev/null; then
            FILE_SIZE=$(awk -v n="$FILE_SIZE_BYTES" 'BEGIN { if (n > 1048576) printf "%.1f МБ", n/1048576; else if (n > 1024) printf "%.1f КБ", n/1024; else printf "%d Б", n }')
        else
            FILE_SIZE="0"
        fi
    else
        FILE_SIZE="0"
    fi
    
    SAVES_STATUS="$FILE_COUNT файлов, $FILE_SIZE"
else
    SAVES_STATUS="папка не найдена"
fi
    
    if [ -f "$STATUS_FILE" ]; then
        read -r STATUS STATUS_TIME < "$STATUS_FILE" 2>/dev/null
        TIME_STR=$(date -d @$STATUS_TIME "+%d.%m.%Y %H:%M" 2>/dev/null || echo "неизвестно")
        if [ "$STATUS" = "OK" ]; then
            LAST_SYNC_STATUS="✓ успешно ($TIME_STR)"
        elif [ "$STATUS" = "ERROR" ]; then
            LAST_SYNC_STATUS="✗ ошибка ($TIME_STR)"
        else
            LAST_SYNC_STATUS="неизвестно"
        fi
    else
        LAST_SYNC_STATUS="ещё не выполнялась"
    fi
    
    FREE=$(df -h "$SAVE_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    [ -z "$FREE" ] && FREE="неизвестно"
    
    if [ "$REAL_INTERVAL" -eq 0 ]; then
        INTERVAL_DISPLAY="При каждом выходе из игры"
    elif [ "$REAL_INTERVAL" -lt 60 ]; then
        INTERVAL_DISPLAY="Каждые ${REAL_INTERVAL} сек после выхода из игры"
    elif [ "$REAL_INTERVAL" -lt 3600 ]; then
        INTERVAL_DISPLAY="Каждые $((REAL_INTERVAL / 60)) мин после выхода из игры"
    else
        INTERVAL_DISPLAY="Каждый $((REAL_INTERVAL / 3600)) ч после выхода из игры"
    fi
    
    if [ -n "$EXCLUDED_SYSTEMS" ]; then
        EXCLUDE_DISPLAY="${EXCLUDED_SYSTEMS//|/, }"
    else
        EXCLUDE_DISPLAY="Все системы синхронизируются"
    fi
    
    # ============================================
    # СТАТИСТИКА СИНХРОНИЗАЦИЙ
    # ============================================
    sync_stats_counts
    SYNC_STATS="$SYNC_NOCHG синхр. ($SYNC_CHG OK, $SYNC_ERR ERR)"
    
}

############################################
# Центр управления (плоское меню с группировкой)
############################################

show_control_panel() {
    while true; do
        get_status_info
        
        clear
        echo ""
        echo "══════════════════════════════════════════════════════════" 
        echo ""
        echo "           Save Sync - Центр управления v1.4.7"
        echo "" 
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo " 🖥️ Система:        $SYSTEM (${CFW_VERSION:-неизвестно})"
        echo " 💾 Сохранений:     $SAVES_STATUS"
        echo " ☁️ $(cloud_header_label)$CLOUD_STATUS"
        echo " 📦 Свободно:       $FREE (локально) / $CLOUD_FREE (облако)"
        echo " 🔄 Обновлено:      $LAST_SYNC_STATUS"
        echo " 📊 Статистика:     $SYNC_STATS"
        echo " 📁 Исключения:     $EXCLUDE_DISPLAY"
        echo " ⏱️ Интервал:       $INTERVAL_DISPLAY"
        echo " 🌐 Веб-интерфейс:  http://$IP_ADDR:8080"
        echo "" 
        echo "──────────────────────────────────────────────────────────"
        echo ""
        echo " ── СОХРАНЕНИЯ ──"
        echo "  1 - 📥 Загрузить сохранения из облака"
        echo "  2 - 📤 Выгрузить сохранения в облако"
        echo "  3 - 🔄 Полная синхронизация"
        
        # Показываем количество исключённых систем
        if [ -n "$EXCLUDED_SYSTEMS" ]; then
            EXCL_COUNT=$(echo "$EXCLUDED_SYSTEMS" | tr '|' '\n' | grep -c .)
            echo "  4 - 📁 Исключить системы (${EXCL_COUNT} исключено)"
        else
            echo "  4 - 📁 Исключить системы (все системы синхр.)"
        fi
        echo ""
        
        echo " ── РОМЫ ──"
        echo "  5 - 📁 Копирование и загрузка ромов"
        echo ""
        
        echo " ── НАСТРОЙКИ СОХРАНЕНИЙ ──"
        echo "  6 - ⏱️ Интервал синхронизации (сейчас: $REAL_INTERVAL сек)"
        echo "  7 - 🔄 Количество попыток (сейчас: $REAL_RETRIES)"
        echo "  8 - 🗂️ Копии при конфликтах (сейчас: $(keep_days_label))"
        echo "  9 - 🎮 Синхронизация (сейчас: $(sync_mode_label))"
        echo ""
        
        echo " ── ИНФОРМАЦИЯ ──"
        echo " 10 - 📊 Статистика и логи"
        echo " 11 - 🔍 Полная диагностика"
        echo ""
        
        echo " ── СИСТЕМА ──"
        echo " 12 - 🔔 Уведомления на экране (сейчас: $(notify_label))"
        echo " 13 - 🗑️ Очистить временные файлы"
        echo " 14 - 🔄 Перезагрузить устройство"
        echo " 15 - 🌐 Перезапустить веб-интерфейс"
        echo " 16 - ☁️ Сменить облако"
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo "  0 - 🚪 Выход"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        read -p "Выберите действие (0-16): " choice
        
        case $choice in
            1) 
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo " 📥 Загрузка сохранений из облака"
                echo "══════════════════════════════════════════════════════════"
                echo ""
                echo "Это действие ЗАГРУЗИТ сохранения из облака на устройство."
                echo ""
                echo " ⚠️ ВАЖНО:"
                echo "  • Скачиваются только сохранения, изменённые на других устройствах"
                echo "  • Если сохранение удалили на другом устройстве — оно удаляется и здесь"
                echo "  • Изменённые на этом устройстве сохранения не заменяются,"
                echo "    а отправляются в облако"
                echo "  • Если сохранение изменили и здесь, и на другом устройстве —"
                echo "    остаётся более новое"
                if ! "$RCLONE_PATH" --config "$RCLONE_CONF" lsf "$REMOTE" 2>/dev/null | grep -v -e ".first_sync_done" -e ".sync_manifest.json" | grep -q .; then
                    echo ""
                    echo " ℹ️  В облаке пока нет сохранений - сохранения с устройства"
                    echo "    будут скопированы в облако."
                fi
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo ""
                read -p "Продолжить загрузку? (y/n): " confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    echo "❌ Отменено."
                    echo ""
                    pause
                    continue
                fi
                echo ""
                echo "🔄 Загрузка сохранений из облака..."
                bash "$DOWNLOAD_SCRIPT" --verbose
                echo ""
                pause
                ;;
            2)
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo " 📤 Выгрузка сохранений в облако"
                echo "══════════════════════════════════════════════════════════"
                echo ""
                echo "Это действие ВЫГРУЗИТ сохранения из устройства в облако."
                echo ""
                echo " ⚠️ ВАЖНО:"
                echo "  • Выгружаются только новые или измененные файлы"
                echo "  • Если файл удалили на устройстве — он УДАЛЯЕТСЯ из облака"
                echo "  • Удаление синхронизируется между устройствами"
                echo "  • Изменённые на других устройствах сохранения не перезаписываются,"
                echo "    а скачиваются сюда"
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo ""
                read -p "Продолжить выгрузку? (y/n): " confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    echo "❌ Отменено."
                    echo ""
                    pause
                    continue
                fi
                echo ""
                echo "🔄 Выгрузка сохранений в облако..."
                bash "$UPLOAD_SCRIPT" --verbose
                echo ""
                pause
                ;;
            3)
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo " 🔄 Полная синхронизация сохранений"
                echo "══════════════════════════════════════════════════════════"
                echo ""
                echo "Это действие выполнит ПОЛНУЮ синхронизацию:"
                echo ""
                echo "  1. Сначала ЗАГРУЗИТ сохранения из облака"
                echo "  2. Затем ВЫГРУЗИТ сохранения в облако"
                echo ""
                echo " ⚠️ Если загрузка не удалась, выгрузка не выполняется."
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo ""
                read -p "Продолжить полную синхронизацию? (y/n): " confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    echo "❌ Отменено."
                    echo ""
                    pause
                    continue
                fi
                echo ""
                echo "🔄 Полная синхронизация сохранений..."
                echo ""
                echo "--- Шаг 1: Загрузка из облака ---"
                if bash "$DOWNLOAD_SCRIPT" --verbose; then
                    echo ""
                    echo "--- Шаг 2: Выгрузка в облако ---"
                    if bash "$UPLOAD_SCRIPT" --verbose; then
                        echo ""
                        echo "✅ Полная синхронизация завершена!"
                    else
                        echo ""
                        echo "❌ Выгрузка не удалась. Подробности: пункт 10 (Статистика и логи)."
                    fi
                else
                    echo ""
                    echo "❌ Загрузка не удалась - выгрузка не выполнялась."
                    echo "   Подробности: пункт 10 (Статистика и логи)."
                fi
                echo ""
                pause
                ;;
            4)
                manage_exclusions
                ;;
            5)
                manage_roms_sync
                ;;
            6)
                echo ""
                echo "Текущий интервал: $REAL_INTERVAL сек"
                echo ""
                echo "Как часто синхронизировать?"
                echo " 1 - При каждом выходе из игры (0 сек)"
                echo " 2 - Раз в 5 минут (300 сек)"
                echo " 3 - Раз в 15 минут (900 сек)"
                echo " 4 - Раз в 30 минут (1800 сек)"
                echo " 5 - Раз в час (3600 сек)"
                echo " 6 - Свой интервал"
                echo ""
                read -p "Выберите (1-6): " int_choice
                case "$int_choice" in
                    1) NEW_INTERVAL=0 ;;
                    2) NEW_INTERVAL=300 ;;
                    3) NEW_INTERVAL=900 ;;
                    4) NEW_INTERVAL=1800 ;;
                    5) NEW_INTERVAL=3600 ;;
                    6) read -p "Введите интервал в секундах: " NEW_INTERVAL ;;
                    *) echo "❌ Неверный выбор"; pause; continue ;;
                esac
                
                SYNC_INTERVAL=$NEW_INTERVAL
                save_config
                
                echo ""
                echo "✅ Интервал изменён на $NEW_INTERVAL сек"
                echo ""
                echo "💡 Изменения применены. Перезагрузка не требуется."
                echo ""
                pause
                ;;
            7)
                echo ""
                echo "Текущее значение: $REAL_RETRIES попыток"
                echo ""
                echo "Сколько раз пробовать при ошибке?"
                echo " 1 - 1 раз"
                echo " 2 - 2 раза"
                echo " 3 - 3 раза (по умолчанию)"
                echo " 4 - 5 раз"
                echo " 5 - 10 раз"
                echo ""
                read -p "Выберите (1-5): " retry_choice
                case "$retry_choice" in
                    1) NEW_RETRIES=1 ;;
                    2) NEW_RETRIES=2 ;;
                    3) NEW_RETRIES=3 ;;
                    4) NEW_RETRIES=5 ;;
                    5) NEW_RETRIES=10 ;;
                    *) echo "❌ Неверный выбор"; pause; continue ;;
                esac
                
                MAX_RETRIES=$NEW_RETRIES
                save_config
                
                echo ""
                echo "✅ Количество попыток изменено на $NEW_RETRIES"
                echo ""
                echo "Изменения применены. Перезагрузка не требуется."
                echo ""
                pause
                ;;
            8)
                echo ""
                echo "Сейчас: $(keep_days_label)"
                echo ""
                echo "Если одно и то же сохранение изменили на разных устройствах,"
                echo "остаётся самая новая версия. Более старую можно хранить в облаке"
                echo "(папка GameSaves_conflicts) и вернуть в веб-интерфейсе (Сохранения)."
                echo "При «Не хранить» устройство не делает копий и не удаляет чужие."
                echo "Сколько дней хранить такие копии?"
                echo " 1 - Не хранить"
                echo " 2 - 1 день"
                echo " 3 - 3 дня (по умолчанию)"
                echo " 4 - 7 дней"
                echo " 5 - 30 дней"
                echo ""
                read -p "Выберите (1-5): " keep_choice
                case "$keep_choice" in
                    1) CONFLICT_KEEP_DAYS=0 ;;
                    2) CONFLICT_KEEP_DAYS=1 ;;
                    3) CONFLICT_KEEP_DAYS=3 ;;
                    4) CONFLICT_KEEP_DAYS=7 ;;
                    5) CONFLICT_KEEP_DAYS=30 ;;
                    *) echo "❌ Неверный выбор"; pause; continue ;;
                esac
                save_config
                echo ""
                echo "✅ Копии при конфликтах: $(keep_days_label)"
                echo ""
                pause
                ;;
            12)
                echo ""
                echo "Сейчас: $(notify_label)"
                echo ""
                echo "Короткие уведомления о синхронизации"
                echo "и загрузках. Работает на Batocera и KNULLI."
                echo ""
                echo " 1 - Включить"
                echo " 2 - Выключить"
                echo ""
                read -p "Выберите (1-2): " notify_choice
                case "$notify_choice" in
                    1) NOTIFICATIONS="true" ;;
                    2) NOTIFICATIONS="false" ;;
                    *) echo "❌ Неверный выбор"; pause; continue ;;
                esac
                save_config
                echo ""
                echo "✅ Уведомления: $(notify_label)"
                echo ""
                pause
                ;;
            9)
                echo ""
                echo "Сейчас: $(sync_mode_label)"
                echo ""
                echo "Как синхронизироваться после выхода из игры:"
                echo ""
                echo " 1 - Только при изменениях"
                echo "     Сохранения менялись - синхронизация"
                echo "     как в режиме «После каждой игры». Не"
                echo "     менялись - облако не запрашивается, а"
                echo "     изменения с других устройств придут при"
                echo "     включении устройства или после игры,"
                echo "     в которой сохранения изменятся."
                echo " 2 - После каждой игры"
                echo "     Отправляются и загружаются изменения"
                echo "     и удаления, без полного списка файлов"
                echo "     в облаке. Подходит для игры на"
                echo "     нескольких устройствах."
                echo " 3 - Полная"
                echo "     После каждой игры сверяется весь список"
                echo "     файлов в облаке, включая добавленные"
                echo "     в облако вручную. Самая медленная."
                echo ""
                echo "При включении устройства и ручном запуске"
                echo "синхронизация всегда полная."
                echo ""
                read -p "Выберите (1-3): " mode_choice
                case "$mode_choice" in
                    1) SYNC_MODE="economy" ;;
                    2) SYNC_MODE="fast" ;;
                    3) SYNC_MODE="full" ;;
                    *) echo "❌ Неверный выбор"; pause; continue ;;
                esac
                save_config
                echo ""
                echo "✅ Синхронизация: $(sync_mode_label)"
                echo ""
                pause
                ;;
            10)
                show_statistics
                ;;
            11)
                echo ""
                bash "$0" --info
                echo ""
                pause
                ;;
            13)
                echo ""
                echo " 🗑️  Очистка временных файлов"
                echo ""
                echo "Будут удалены:"
                echo "  • /tmp/save_sync_*"
                echo "  • /tmp/rclone_*"
                echo "  • /tmp/*.lock"
                echo ""
                read -p "Продолжить? (y/n): " clean_confirm
                if [ "$clean_confirm" = "y" ] || [ "$clean_confirm" = "Y" ]; then
                    rm -rf /tmp/save_sync_* /tmp/rclone_* /tmp/*.lock 2>/dev/null
                    echo "✅ Временные файлы удалены"
                else
                    echo "Отменено"
                fi
                echo ""
                pause
                ;;
            14)
                echo ""
                echo "⚠️ ВНИМАНИЕ!"
                echo "Устройство будет перезагружено."
                echo ""
                read -p "Перезагрузить сейчас? (y/n): " reboot_confirm
                if [ "$reboot_confirm" = "y" ] || [ "$reboot_confirm" = "Y" ]; then
                    echo "🔄 Перезагрузка..."
                    sleep 1
                    reboot
                    exit 0
                else
                    echo "Отменено"
                fi
                echo ""
                pause
                ;;
            15)
                echo ""
                echo "🔄 Перезапуск веб-интерфейса..."
                STOPPED=false
                if [ -f "/tmp/save_sync_web.pid" ]; then
                    PID=$(cat /tmp/save_sync_web.pid 2>/dev/null)
                    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
                        kill -9 "$PID" 2>/dev/null
                        STOPPED=true
                    fi
                    rm -f /tmp/save_sync_web.pid
                fi
                if [ "$STOPPED" = false ]; then
                    pkill -f "python3.*server.py" 2>/dev/null
                fi
                sleep 2
                # Запускаем новый
                bash "$0" --web &
                echo "✅ Веб-интерфейс перезапущен"
                echo "🌐 Откройте: http://$IP_ADDR:8080"
                echo ""
                pause
                ;;
            16)
                echo ""
                echo "Сейчас: $(cloud_label "$RCLONE_CONF")"
                echo ""
                echo "Смена облака для сохранений и ромов."
                echo "Старое облако не изменяется: всё в нём остаётся."
                echo ""
                if sync_busy; then
                    echo "⚠️  Сейчас идёт синхронизация."
                    echo "   Если старое облако не отвечает, она может идти долго."
                    read -p "Остановить её и сменить облако? (y/n): " stop_now
                    if [ "$stop_now" != "y" ] && [ "$stop_now" != "Y" ]; then
                        echo "❌ Отменено. Облако не изменено."
                        echo ""
                        pause
                        continue
                    fi
                    echo "⏹️  Остановка синхронизации..."
                    if ! stop_sync; then
                        echo "❌ Не удалось остановить синхронизацию. Попробуйте позже."
                        echo ""
                        pause
                        continue
                    fi
                    echo "✅ Синхронизация остановлена."
                    echo ""
                fi
                NEW_CONF="$RCLONE_CONF.new"
                rm -f "$NEW_CONF"
                if ! ask_cloud_config "$NEW_CONF" cancel; then
                    rm -f "$NEW_CONF"
                    pause
                    continue
                fi
                echo "Проверка подключения..."
                if ! cloud_check "$NEW_CONF"; then
                    rm -f "$NEW_CONF"
                    echo "❌ Не удалось подключиться. Облако не изменено."
                    [ -n "$CLOUD_ERR" ] && echo "   Причина: $CLOUD_ERR"
                    echo ""
                    pause
                    continue
                fi
                echo "✅ Подключение успешно."
                echo ""
                echo "Что сделать с сохранениями:"
                echo ""
                echo " 1 - Сделать облако копией этого устройства"
                echo "     Сохранения в облаке станут такими же,"
                echo "     как здесь: недостающие загрузятся,"
                echo "     отличающиеся заменятся, лишние удалятся."
                echo "     Для первого устройства."
                echo " 2 - Объединить сохранения с облаком"
                echo "     Чужие скачаются, свои загрузятся,"
                echo "     ничего не удалится. Для остальных"
                echo "     устройств, когда облако уже заполнено."
                echo " 0 - Отмена"
                echo ""
                read -p "Выберите (0-2): " cloud_mode
                if [ "$cloud_mode" != "1" ] && [ "$cloud_mode" != "2" ]; then
                    rm -f "$NEW_CONF"
                    echo "❌ Отменено. Облако не изменено."
                    echo ""
                    pause
                    continue
                fi
                if [ "$cloud_mode" = "1" ]; then
                    echo ""
                    echo "⚠️  Папка GameSaves в новом облаке станет копией"
                    echo "    сохранений этого устройства. Сохранения систем,"
                    echo "    для которых здесь нет игр, не затрагиваются."
                    read -p "Продолжить? (y/n): " confirm
                    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                        rm -f "$NEW_CONF"
                        echo "❌ Отменено. Облако не изменено."
                        echo ""
                        pause
                        continue
                    fi
                fi
                # прежние настройки остаются в rclone.conf.bak
                cp -f "$RCLONE_CONF" "$RCLONE_CONF.bak" 2>/dev/null
                mv -f "$NEW_CONF" "$RCLONE_CONF"
                chmod 600 "$RCLONE_CONF"
                # память о прошлой синхронизации относится к старому облаку
                rm -f "$BASE/.sync_base.json"
                if [ -f "$STATE_FILE" ]; then
                    sed -i -e '/^PENDING_UPLOAD=/d' -e '/^MARKER_DONE=/d' "$STATE_FILE"
                fi
                "$RCLONE_PATH" --config "$RCLONE_CONF" mkdir "$REMOTE" >/dev/null 2>&1
                load_config
                echo ""
                if [ "$cloud_mode" = "1" ]; then
                    echo "🔄 Облако заполняется сохранениями этого устройства..."
                    SS_RCLONE="$RCLONE_PATH" SS_EXCLUDED="$EXCLUDED_SYSTEMS" SS_RETRIES="$MAX_RETRIES" \
                        python3 "$ENGINE_SCRIPT" sync --mirror --verbose
                    RC=$?
                    MODE_TXT="копия устройства"
                else
                    echo "🔄 Синхронизация с облаком..."
                    bash "$DOWNLOAD_SCRIPT" --verbose
                    RC=$?
                    MODE_TXT="объединение"
                fi
                echo ""
                if [ $RC -eq 0 ]; then
                    log_msg "Облако изменено: $(cloud_label "$RCLONE_CONF") ($MODE_TXT)"
                    echo "✅ Облако изменено: $(cloud_label "$RCLONE_CONF")"
                    echo "   Остальные устройства переключите так же,"
                    echo "   выбрав «Объединить сохранения с облаком»."
                else
                    log_msg "Облако изменено: $(cloud_label "$RCLONE_CONF") ($MODE_TXT) - синхронизация не завершилась"
                    echo "⚠️  Облако изменено, но синхронизация не завершилась."
                    echo "   Она повторится при следующем выходе из игры"
                    echo "   или включении устройства, ничего не потеряется."
                fi
                echo ""
                pause
                ;;
            0)
                echo "🚪 Выход..."
                exit 0
                ;;
            *)
                echo "❌ Неверный выбор"
                sleep 1
                ;;
        esac
    done
}

############################################
# ВЕБ-ИНТЕРФЕЙС (УЛУЧШЕННЫЙ, БЕЗ ЭКСПОРТА/ИМПОРТА И БЕЗ АВТОСОХРАНЕНИЯ)
############################################

restart_web_after_update() {
    echo "🔄 Перезапускаю веб-интерфейс с новой версией..."
    STOPPED=false
    if [ -f "/tmp/save_sync_web.pid" ]; then
        PID=$(cat /tmp/save_sync_web.pid 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID" 2>/dev/null
            STOPPED=true
        fi
        rm -f /tmp/save_sync_web.pid
    fi
    if [ "$STOPPED" = false ]; then
        pkill -f "python3.*server.py" 2>/dev/null
    fi
    sleep 2
    bash "$0" --web > /dev/null 2>&1 &
    echo "✅ Веб-интерфейс запущен"
}

start_web() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " 🌐 Save Sync - Веб-интерфейс v1.4.7"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    
    # Получаем IP-адрес (как в диагностике)
    IP_ADDR=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR="localhost"
    fi
    
    # Проверка Python
    if ! command -v python3 &> /dev/null; then
        if ! command -v python3 &> /dev/null; then
            echo "❌ Python3 не найден и не может быть установлен автоматически."
            echo "Установите python3 вручную для вашей системы и запустите --web ещё раз."
            return 1
        fi
        echo "✅ Python3 установлен"
    fi
    
    # Проверка, не запущен ли уже сервер
    if [ -f "/tmp/save_sync_web.pid" ]; then
        PID=$(cat /tmp/save_sync_web.pid 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && grep -q "server.py" "/proc/$PID/cmdline" 2>/dev/null; then
            echo "⚠️ Веб-интерфейс уже запущен (PID: $PID)"
            echo "🌐 Откройте: http://${IP_ADDR}:8080"
            echo ""
            echo "Для остановки: kill $PID"
            return 1
        else
            # PID-файл устарел: процесс уже не существует, либо его номер
            # был переиспользован другим процессом после перезагрузки
            rm -f "/tmp/save_sync_web.pid"
        fi
    fi
    
    # Создаем директорию для веб-интерфейса
    WEB_DIR="/tmp/save_sync_web"
    mkdir -p "$WEB_DIR"
    
    # Создаем Python сервер
    cat > "$WEB_DIR/server.py" << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import signal
import threading
import subprocess
import os
import urllib.parse
import socket
import time
from datetime import datetime
import re
import shutil
import sys

PORT = 8080
BASE = "__SS_BASE__"
CONFIG_FILE = "__SS_CONFIG_FILE__"
LOG_FILE = "__SS_LOG_FILE__"
SAVE_DIR = "__SS_SAVE_DIR__"
ROMS_DIR = "__SS_ROMS_DIR__"
STATUS_FILE = "__SS_STATUS_FILE__"
DOWNLOAD_SCRIPT = "__SS_DOWNLOAD_SCRIPT__"
UPLOAD_SCRIPT = "__SS_UPLOAD_SCRIPT__"
DOWNLOAD_ROMS = "__SS_DOWNLOAD_ROMS__"
UPLOAD_ROMS = "__SS_UPLOAD_ROMS__"
ROMS_FILTER_FILE = "__SS_ROMS_FILTER_FILE__"
LAST_SYNC_TIME = "__SS_LAST_SYNC_TIME__"
RCLONE_PATH = "__SS_RCLONE_PATH__"
RCLONE_CONF = "__SS_RCLONE_CONF__"
REMOTE_ROMS = "__SS_REMOTE_ROMS__"
REMOTE_SAVES = "__SS_REMOTE_SAVES__"
LINK_SCRIPT = "__SS_LINK_SCRIPT__"
LINK_PID_FILE = "/tmp/save_sync_link.pid"
OP_FILE = "/tmp/save_sync_op.json"

CLOUD_CHECK = {}                    # last connection check: result and when it was made
CLOUD_CHECK_LOCK = threading.Lock()
CLOUD_ABOUT_CACHE = {}              # last known cloud volume (free / used / total)
CLOUD_ABOUT_LOCK = threading.Lock()



def cloud_check():
    """-> (connected, seconds). The time is shown when the cloud answers slowly; a slow
    cloud is given up to 15 s and is not reported as "not connected". Parallel status
    requests share one check made less than 8 s ago."""
    with CLOUD_CHECK_LOCK:
        if CLOUD_CHECK and time.time() - CLOUD_CHECK["t"] < 8:
            return CLOUD_CHECK["res"]
        t0 = time.time()
        try:
            r = subprocess.run([RCLONE_PATH, "--config", RCLONE_CONF, "lsd", "cloud:",
                                "--contimeout", "10s", "--timeout", "15s",
                                "--low-level-retries", "1", "--retries", "1"],
                               capture_output=True, timeout=17)
            ok = r.returncode == 0
        except (OSError, subprocess.SubprocessError):
            ok = False
        res = (ok, time.time() - t0)
        CLOUD_CHECK.update(res=res, t=time.time())
        return res


def cloud_service():
    """Name of the cloud service in rclone.conf (no login), for the status card."""
    try:
        with open(RCLONE_CONF) as f:
            conf = f.read()
    except OSError:
        return ""
    if re.search(r"^type = mega", conf, re.M):
        return "Mega"
    m = re.search(r"^url = (.*)$", conf, re.M)
    url = m.group(1) if m else ""
    for key, name in (("yandex", "Яндекс.Диск"), ("mail.ru", "Облако Mail.ru"), ("pcloud", "pCloud"),
                      ("koofr", "Koofr"), ("fastmail", "Fastmail")):
        if key in url:
            return name
    return "WebDAV" if url else ""


def host_allowed(host):
    """The web interface answers only when it is opened by an IP address, localhost or a
    local name of the device (batocera, knulli.local...). A request for a domain name
    pointed at the device for a while (DNS rebinding) is refused."""
    if not host:
        return True                        # HTTP/1.0 without Host: not a browser
    name = host.strip().lower()
    if name.startswith("["):               # [IPv6]:port
        name = name[1:name.find("]")] if "]" in name else name[1:]
    elif name.count(":") == 1:
        name = name.split(":", 1)[0]
    name = name.rstrip(".")
    try:
        socket.inet_pton(socket.AF_INET6 if ":" in name else socket.AF_INET, name)
        return True
    except (OSError, ValueError):
        pass
    return name == "localhost" or "." not in name or name.endswith(".local") \
        or name == socket.gethostname().lower()


# What in a ROM folder is not a game (the same lists as in the sync engine). PICO-8
# games are .p8.png pictures, so pictures count as games there.
MEDIA_DIRS_ALL = {"images", "media", "videos", "manuals", "bezels", "covers", "backcovers", "3dboxes", "fanart",
                  "marquees", "miximages", "miximages_v2", "physicalmedia", "screenshots", "thumbnails",
                  "titlescreens", "wheel", "boxart", "snaps", "downloaded_images", "downloaded_videos",
                  "downloaded_media", "__macosx", "@eadir", "#recycle", "$recycle.bin", "system volume information"}
NOT_GAME_EXT = (".xml", ".txt", ".dat", ".log", ".cache", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".mp4",
                ".avi", ".mkv", ".webm", ".pdf", ".nfo", ".md", ".db", ".tmp", ".bak", ".crdownload", ".partial")
NOT_GAME_NAMES = {".ds_store", "thumbs.db", "desktop.ini", ".keep", ".gitkeep", ".localized"}


def system_has_games(path, system):
    for root, dirs, files in os.walk(path):
        dirs[:] = [x for x in dirs if not x.startswith(".") and x.lower() not in MEDIA_DIRS_ALL]
        for f in files:
            low = f.lower()
            if low.endswith(NOT_GAME_EXT) or low in NOT_GAME_NAMES or low.startswith("._"):
                continue
            if low.endswith(".png") and system != "pico8":
                continue
            return True
    return False


class Handler(http.server.BaseHTTPRequestHandler):
    def request_allowed(self, change):
        """Commands (POST) are taken only from the page of the web interface itself:
        a browser adds Origin to requests sent by other sites, and a page cannot fake it.
        Requests without Origin (curl, scripts) are not from a browser and are allowed."""
        host = self.headers.get("Host", "")
        if not host_allowed(host):
            return False
        if change:
            origin = self.headers.get("Origin")
            if origin is not None:
                if origin.strip().lower() == "null":
                    return False
                if urllib.parse.urlparse(origin).netloc.lower() != host.strip().lower():
                    return False
        return True

    def log_message(self, format, *args):
        pass
    
    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode())
    
    def send_html(self, content):
        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(content.encode())
    
    def read_config(self):
        config = {}
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, "r") as f:
                for line in f:
                    if "=" in line and not line.startswith("#"):
                        key, val = line.split("=", 1)
                        config[key.strip()] = val.strip().strip('"')
        return config
    
    def save_config(self, config):
        try:
            current = self.read_config()
            for key, value in config.items():
                current[key] = value

            # конфиг подключается скриптами синхронизации как shell-код:
            # числа только цифрами, переключатели только true/false, в тексте
            # нет символов, которые выходят за пределы кавычек
            int_def = {"SYNC_INTERVAL": 0, "MAX_RETRIES": 3, "CONFLICT_KEEP_DAYS": 3,
                       "MIN_FREE_KB": 51200, "MAX_LOG_SIZE": 102400, "LOG_KEEP_COUNT": 3}
            bool_def = {"NOTIFICATIONS": "true", "SKIP_UNCHANGED": "true",
                        "ROMS_SYNC_MEDIA": "false", "LOG_ENABLED": "true"}
            for key in list(current):
                val = str(current[key]).strip()
                if key in int_def:
                    try:
                        num = int(float(val))
                        current[key] = str(num) if num >= 0 else str(int_def[key])
                    except Exception:
                        current[key] = str(int_def[key])
                elif key in bool_def:
                    val = val.lower()
                    current[key] = val if val in ("true", "false") else bool_def[key]
                elif key == "LOG_LEVEL":
                    current[key] = val if val in ("info", "debug") else "info"
                else:
                    current[key] = re.sub(r'["$`\\\r\n]', "", val)
            if current.get("SYNC_MODE") not in ("full", "fast", "economy"):
                current["SYNC_MODE"] = "full" if current.get("SKIP_UNCHANGED") == "false" else "economy"
            with open(CONFIG_FILE, "w") as f:
                f.write("# ========================================\n")
                f.write("# Save Sync v1.4.7 - Главный конфиг\n")
                f.write("# ========================================\n\n")
                f.write("# ---- НАСТРОЙКИ СИНХРОНИЗАЦИИ ----\n")
                f.write(f'SYNC_INTERVAL="{current.get("SYNC_INTERVAL", 0)}"\n')
                f.write(f'MAX_RETRIES="{current.get("MAX_RETRIES", 3)}"\n')
                f.write(f'CONFLICT_KEEP_DAYS="{current.get("CONFLICT_KEEP_DAYS", 3)}"\n')
                f.write(f'NOTIFICATIONS="{current.get("NOTIFICATIONS", "true")}"\n')
                f.write(f'SYNC_MODE="{current.get("SYNC_MODE", "economy")}"\n')
                f.write(f'MIN_FREE_KB="{current.get("MIN_FREE_KB", 51200)}"\n\n')
                f.write("# ---- НАСТРОЙКИ РОМОВ ----\n")
                f.write(f'ROMS_SYNC_DIRS="{current.get("ROMS_SYNC_DIRS", "")}"\n')
                f.write(f'ROMS_SYNC_MEDIA="{current.get("ROMS_SYNC_MEDIA", "false")}"\n')
                f.write(f'EXCLUDED_SYSTEMS="{current.get("EXCLUDED_SYSTEMS", "")}"\n\n')
                f.write("# ---- НАСТРОЙКИ ЛОГИРОВАНИЯ ----\n")
                f.write(f'LOG_ENABLED="{current.get("LOG_ENABLED", "true")}"\n')
                f.write(f'MAX_LOG_SIZE="{current.get("MAX_LOG_SIZE", 102400)}"\n')
                f.write(f'LOG_LEVEL="{current.get("LOG_LEVEL", "info")}"\n')
                f.write(f'LOG_KEEP_COUNT="{current.get("LOG_KEEP_COUNT", 3)}"\n')
            return True
        except:
            return False
    
    def get_ip(self):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except:
            return "127.0.0.1"
    
    # ========================================
    # УЛУЧШЕННАЯ ФУНКЦИЯ ОПРЕДЕЛЕНИЯ СИСТЕМЫ
    # ========================================
    def get_system(self):
        # 1. Пробуем через /etc/os-release
        if os.path.exists("/etc/os-release"):
            with open("/etc/os-release", "r") as f:
                for line in f:
                    if line.startswith("ID="):
                        id_ = line.split("=")[1].strip().strip('"')
                        if id_ == "batocera": return "Batocera"
                        if id_ == "knulli": return "KNULLI"
                        if id_ == "recalbox": return "Recalbox"
        
        # 2. Проверка на Batocera (расширена)
        if os.path.exists("/boot/batocera") or os.path.exists("/etc/batocera-release") or os.path.exists("/usr/bin/batocera-es-swissknife"):
            return "Batocera"
        
        # 3. Проверка на KNULLI
        if os.path.exists("/usr/share/knulli/knulli.version") or os.path.exists("/etc/knulli-release") or os.path.exists("/boot/knulli"):
            return "KNULLI"
        
        # 4. Проверка на Recalbox
        if os.path.exists("/etc/recalbox-release") or os.path.exists("/recalbox/recalbox"):
            return "Recalbox"
        
        # 5. Проверка по наличию папок (как запасной вариант)
        if os.path.exists("/userdata/saves"):
            if os.path.exists("/recalbox"):
                return "Recalbox"
            elif os.path.exists("/usr/share/knulli/knulli.version"):
                return "KNULLI"
            elif os.path.exists("/boot/batocera") or os.path.exists("/usr/bin/batocera-es-swissknife"):
                return "Batocera"
            else:
                return "Batocera/KNULLI"
        
        if os.path.exists("/recalbox/share/saves"):
            return "Recalbox"
        
        return "Unknown"
    
    def get_device(self):
        if os.path.exists("/proc/device-tree/model"):
            try:
                with open("/proc/device-tree/model", "r") as f:
                    return f.read().strip().replace("\x00", "")
            except:
                pass
        if os.path.exists("/sys/firmware/devicetree/base/model"):
            try:
                with open("/sys/firmware/devicetree/base/model", "r") as f:
                    return f.read().strip().replace("\x00", "")
            except:
                pass
        return "Неизвестно"
    
    def get_version(self):
        # Приоритет: файлы конкретных систем
        version_files = [
            "/etc/batocera-release",
            "/usr/share/batocera/batocera.version",
            "/usr/share/knulli/knulli.version",
            "/etc/knulli-release",
            "/recalbox/recalbox.version",
            "/etc/recalbox-release"
        ]
        for f in version_files:
            if os.path.exists(f):
                try:
                    with open(f, "r") as fh:
                        ver = fh.read().strip()
                        if ver:
                            return ver
                except:
                    pass
        
        # Пробуем /etc/os-release
        if os.path.exists("/etc/os-release"):
            try:
                with open("/etc/os-release", "r") as f:
                    for line in f:
                        if line.startswith("PRETTY_NAME="):
                            return line.split("=")[1].strip().strip('"')
                        if line.startswith("VERSION="):
                            return line.split("=")[1].strip().strip('"')
                        if line.startswith("VERSION_ID="):
                            return line.split("=")[1].strip().strip('"')
            except:
                pass
        
        return "Неизвестно"
    
    def update_roms_filter(self):
        """The same filter as create_roms_filter() in the control panel."""
        config = self.read_config()
        dirs = [d.strip() for d in config.get("ROMS_SYNC_DIRS", "").split("|") if d.strip()]
        media = config.get("ROMS_SYNC_MEDIA", "false") == "true"
        lines = ["# Фильтр для синхронизации ромов", "# Создан автоматически, не редактируйте вручную", "", "# Служебные файлы и мусор других систем (Mac, Windows, NAS)"]
        lines += ['- **/_info.txt', '- .DS_Store', '- Thumbs.db', '- desktop.ini', '- ._*', '- *:Zone.Identifier', '- *.crdownload', '- __MACOSX/**', '- @eaDir/**', '- #recycle/**', '- $RECYCLE.BIN/**', '- System Volume Information/**', '- .Trash-*/**', '- .Trashes/**', '- .Spotlight-V100/**', '- .fseventsd/**']
        if not media:
            lines += ["", "# Медиа-папки", "- **/{images,media,videos,manuals,screenshots,thumbnails,bezels,covers,backcovers,3dboxes,fanart,marquees,miximages,miximages_v2,physicalmedia,titlescreens,wheel,boxart,snaps,downloaded_images,downloaded_videos,downloaded_media}/**"]
            if "pico8" in dirs:
                lines += ["", "# Игры PICO-8 - это картинки (.p8.png): их не исключаем", "+ /pico8/**.png"]
            lines += ["", "# Картинки"] + ['- **.png', '- **.jpg', '- **.jpeg', '- **.gif', '- **.bmp']
        lines += ["", "# Видео (всегда: большие файлы)"] + ['- **.mp4', '- **.avi', '- **.webm', '- **.wmv', '- **.mkv', '- **.mov', '- **.m4v', '- **.mpg', '- **.mpeg']
        if dirs:
            lines += ["", "# Выбранные системы"] + ["+ /%s/**" % d for d in dirs]
        lines += ["", "# Всё остальное", "- **"]
        try:
            with open(ROMS_FILTER_FILE, "w") as f:
                f.write("\n".join(lines) + "\n")
            return True
        except OSError:
            return False

    def get_stats(self):
        stats = {"sync": {"total": 0, "ok": 0, "changed": 0, "unchanged": 0, "error": 0}, "roms": {"total": 0, "ok": 0, "error": 0}}
        if os.path.exists(LOG_FILE):
            try:
                with open(LOG_FILE, "r") as f:
                    content = f.read()
                    stats["sync"]["ok"] = len(re.findall(r"Сохранения загружены|Выгрузка сохранений|Синхронизация(?: вручную)? \(", content))
                    # "(изменений нет)" / "(no changes)": the sync ran fine, but everything already matched
                    # with changes = the log line says what was moved ("(sent: 1, ...)"); a plain line or "(нет изменений)" means nothing was transferred
                    noted = len(re.findall(r"(?:Сохранения загружены|Выгрузка сохранений|Синхронизация(?: вручную)?) \(", content))
                    empty = len(re.findall(r"(?:Сохранения загружены|Выгрузка сохранений|Синхронизация(?: вручную)?) \((?:изменений нет|нет изменений)\)", content))
                    stats["sync"]["changed"] = noted - empty
                    stats["sync"]["unchanged"] = stats["sync"]["ok"] - stats["sync"]["changed"]
                    stats["sync"]["total"] = stats["sync"]["ok"]
                    # only save errors: ROM and link download errors have their own lines in the log
                    stats["sync"]["error"] = len(re.findall(r"Ошибка (?:загрузки|выгрузки) сохранений|Ошибка первой (?:загрузки|выгрузки)|Ошибка отправки невыгруженных сохранений|Облако недоступно \(нет сети", content))
                    stats["roms"]["total"] = len(re.findall(r"Выгрузка ромов завершена|Загрузка ромов завершена", content))
                    stats["roms"]["ok"] = len(re.findall(r"Выгрузка ромов завершена|Загрузка ромов завершена", content))
                    stats["roms"]["error"] = len(re.findall(r"Ошибка загрузки ромов|Ошибка выгрузки ромов", content))
            except:
                pass
        return stats

    def do_GET(self):
        if not self.request_allowed(False):
            self.send_error(403)
            return
        if self.path == "/" or self.path == "/index.html":
            self.send_html(HTML)
            return
        
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        
        if path == "/api/status":
            self.api_status()
        elif path == "/api/logs":
            self.api_logs(parsed.query)
        elif path == "/api/config":
            self.api_config()
        elif path == "/api/systems":
            self.api_systems()
        elif path == "/api/device":
            self.api_device()
        elif path == "/api/stats":
            self.api_stats()
        elif path == "/api/progress":
            self.api_progress()
        elif path == "/api/theme":
            self.api_theme()
        elif path == "/api/link/dests":
            self.api_link_dests(parsed.query)
        elif path == "/api/conflicts":
            self.api_conflicts()
        else:
            self.send_error(404)

    def do_POST(self):
        if not self.request_allowed(True):
            self.send_error(403)
            return
        parsed = urllib.parse.urlparse(self.path)
        
        if parsed.path == "/api/sync":
            self.api_sync(parsed.query)
        elif parsed.path == "/api/config":
            self.api_config_save()
        elif parsed.path == "/api/exclude":
            self.api_exclude()
        elif parsed.path == "/api/roms":
            self.api_roms()
        elif parsed.path == "/api/theme":
            self.api_theme_save()
        elif parsed.path == "/api/link/zip":
            self.api_link_zip()
        elif parsed.path == "/api/link/list":
            self.api_link_list()
        elif parsed.path == "/api/link/download":
            self.api_link_download()
        elif parsed.path == "/api/link/cancel":
            self.api_link_cancel()
        elif parsed.path == "/api/cancel":
            self.api_cancel()
        elif parsed.path == "/api/conflicts/restore":
            self.api_conflict_action("restore")
        elif parsed.path == "/api/conflicts/delete":
            self.api_conflict_action("delete")
        else:
            self.send_error(404)

    def api_status(self):
        config = self.read_config()
        stats = self.get_stats()
        
        system_name = self.get_system()
        system_version = self.get_version()
        device_name = self.get_device()

    # Формируем отображение системы как в центре управления
        if system_name == "KNULLI":
        # Пробуем получить версию scarab
            scarab_version = ""
            if os.path.exists("/boot/knulli"):
                try:
                    with open("/boot/knulli", "r") as f:
                        scarab_version = f.read().strip()
                except:
                    pass
            if scarab_version:
                system_display = f"{system_name} ({scarab_version})"
            else:
                system_display = f"{system_name} ({system_version})" if system_version != "Неизвестно" else system_name
        else:
            system_display = system_name if system_version == "Неизвестно" else f"{system_name} ({system_version})"
        
        status = {
            "system": system_name,
            "device": device_name,
            "version": system_version,
            "config": config,
            "saves": {"count": 0, "size": "0"},
            "cloud": {"status": "disconnected", "free": "0", "used": "0", "total": "0", "service": cloud_service()},
            "last_sync": {"status": "UNKNOWN", "time": "—"},
            "internet": False,
            "scripts": {
                "download": os.path.exists(DOWNLOAD_SCRIPT),
                "upload": os.path.exists(UPLOAD_SCRIPT),
                "download_roms": os.path.exists(DOWNLOAD_ROMS),
                "upload_roms": os.path.exists(UPLOAD_ROMS)
            },
            "excluded": [],
            "roms_selected": [],
            "stats": stats,
            "is_syncing": False
        }
        
        # Сохранения
        if os.path.exists(SAVE_DIR):
            try:
                count = 0
                size = 0
                skip_names = (".DS_Store", "Thumbs.db", ".keep")
                skip_suffixes = (".log", ".cache", ".keep")
                for root, dirs, files in os.walk(SAVE_DIR):
                    for f in files:
                        if f in skip_names or f.endswith(skip_suffixes):
                            continue
                        count += 1
                        size += os.path.getsize(os.path.join(root, f))
                size_str = f"{size/(1024*1024):.1f} МБ" if size > 1024*1024 else f"{size/1024:.1f} КБ" if size > 1024 else f"{size} Б"
                status["saves"] = {"count": count, "size": size_str}
            except:
                pass
        
        # Облако
        if os.path.exists(RCLONE_PATH) and os.path.exists(RCLONE_CONF):
            try:
                connected, took = cloud_check()
                if connected:
                    status["cloud"]["status"] = "connected"
                    if took > 3:
                        status["cloud"]["slow"] = int(round(took))
                    # The volume is asked at most once a minute and given more time: on a slow
                    # network "about" can take longer than a few seconds. If it fails, the last
                    # known values are shown instead of 0.
                    with CLOUD_ABOUT_LOCK:
                        cached = CLOUD_ABOUT_CACHE.get("vals")
                        fresh = cached and time.time() - CLOUD_ABOUT_CACHE.get("t", 0) < 60
                    if fresh:
                        status["cloud"].update(cached)
                    else:
                        try:
                            about = subprocess.run(
                                [sys.executable or "python3", os.path.join(BASE, "sync_engine.py"), "about"],
                                env=dict(os.environ, SS_RCLONE=RCLONE_PATH),
                                capture_output=True,
                                text=True,
                                timeout=20
                            )
                            vals = {}
                            if about.returncode == 0:
                                for line in about.stdout.split("\n"):
                                    if "Total:" in line:
                                        vals["total"] = line.split(":", 1)[1].strip()
                                    elif "Used:" in line:
                                        vals["used"] = line.split(":", 1)[1].strip()
                                    elif "Free:" in line:
                                        vals["free"] = line.split(":", 1)[1].strip()
                            if vals:
                                with CLOUD_ABOUT_LOCK:
                                    CLOUD_ABOUT_CACHE["vals"] = vals
                                    CLOUD_ABOUT_CACHE["t"] = time.time()
                                status["cloud"].update(vals)
                            elif cached:
                                status["cloud"].update(cached)
                        except Exception:
                            if cached:
                                status["cloud"].update(cached)
            except:
                pass
        
        # Последняя синхронизация
        if os.path.exists(STATUS_FILE):
            try:
                with open(STATUS_FILE, "r") as f:
                    parts = f.read().strip().split()
                    if len(parts) >= 2:
                        status["last_sync"]["status"] = parts[0]
                        status["last_sync"]["time"] = datetime.fromtimestamp(
                            int(parts[1])
                        ).strftime("%d.%m %H:%M")
            except:
                pass
        
        # Интернет: если облако ответило, интернет точно есть.
        # Иначе проверка TCP-соединения - не ping: в некоторых сетях
        # ping закрыт, хотя всё остальное работает.
        if status["cloud"]["status"] == "connected":
            status["internet"] = True
        else:
            for host in ("1.1.1.1", "8.8.8.8"):
                try:
                    with socket.create_connection((host, 443), timeout=2):
                        status["internet"] = True
                        break
                except OSError:
                    pass
        
        # Исключения
        if config.get("EXCLUDED_SYSTEMS"):
            status["excluded"] = [x.strip() for x in config["EXCLUDED_SYSTEMS"].split("|") if x.strip()]
        
        # Ромы
        if config.get("ROMS_SYNC_DIRS"):
            status["roms_selected"] = [x.strip() for x in config["ROMS_SYNC_DIRS"].split("|") if x.strip()]
        
        # Проверка, идет ли синхронизация
        if os.path.exists("/tmp/save_sync_download.lock") or os.path.exists("/tmp/save_sync_upload.lock"):
            status["is_syncing"] = True
        
        self.send_json(status)

    def api_logs(self, query):
        params = urllib.parse.parse_qs(query)
        lines = int(params.get("lines", [20])[0])
        action = params.get("action", [""])[0]
        
        result = {"lines": []}
        
        if action == "clear":
            if os.path.exists(LOG_FILE):
                with open(LOG_FILE, "w") as f:
                    f.write("")
                result["lines"] = ["Лог очищен"]
                self.send_json(result)
                return
        
        if os.path.exists(LOG_FILE):
            try:
                with open(LOG_FILE, "r") as f:
                    all_lines = f.readlines()
                    last = all_lines[-lines:] if len(all_lines) > lines else all_lines
                    result["lines"] = [l.strip() for l in last if l.strip()]
            except:
                result["lines"] = ["Ошибка чтения лога"]
        else:
            result["lines"] = ["Лог ещё не создан"]
        
        self.send_json(result)

    def api_config(self):
        self.send_json(self.read_config())

    def api_config_save(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_json({"success": False, "error": "Нет данных"})
            return
        
        try:
            data = json.loads(self.rfile.read(length))
            if self.save_config(data):
                self.update_roms_filter()
                self.send_json({"success": True, "message": "Настройки сохранены"})
            else:
                self.send_json({"success": False, "error": "Ошибка сохранения"})
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})

    def _port_saves(self):
        # PortMaster ports keep saves inside their own folder (saves/, conf/,
        # gamedata/); all of them are excluded at once with the "PortMaster" entry
        out = []
        pdir = os.path.join(ROMS_DIR, "ports")
        try:
            for n in sorted(os.listdir(pdir)):
                d = os.path.join(pdir, n)
                if os.path.isdir(d) and not n.startswith(".") and n not in ("PortMaster", "autoinstall", "images", "videos", "manuals") and any(
                        os.path.isdir(os.path.join(d, s)) for s in ("saves", "conf", "gamedata")):
                    out.append(n)
        except OSError:
            pass
        return out

    def api_systems(self):
        # (system_has_games: a system folder with games, not only media or leftovers)
        systems = []
        if os.path.exists(ROMS_DIR):
            for d in os.listdir(ROMS_DIR):
                path = os.path.join(ROMS_DIR, d)
                if os.path.isdir(path):
                    if system_has_games(path, d):
                        systems.append(d)
        
        # Дополнительно проверяем облако - там могут быть системы,
        # которых ещё нет на устройстве (например, ромы закинули прямо
        # в облако с компьютера, не трогая устройство). Без этого их
        # нельзя было бы выбрать и, соответственно, скачать.
        cloud_only = []
        cloud_error = True
        try:
            # a slow network needs more than a few seconds (the list is shown only after this)
            result = subprocess.run(
                [RCLONE_PATH, "--config", RCLONE_CONF, "lsd", REMOTE_ROMS,
                 "--contimeout", "15s", "--timeout", "20s", "--low-level-retries", "2"],
                capture_output=True, text=True, timeout=40
            )
            if result.returncode == 0:
                cloud_error = False
                for line in result.stdout.splitlines():
                    parts = line.split()
                    if not parts:
                        continue
                    cloud_sys = parts[-1]
                    if cloud_sys and cloud_sys not in systems:
                        systems.append(cloud_sys)
                        cloud_only.append(cloud_sys)
        except:
            pass
        
        # Systems that have saves in the cloud (uploaded from another device), even
        # without ROMs anywhere, and PortMaster saves (_ports): all can be excluded.
        port_saves_cloud = False
        saves_cloud = []
        if not cloud_error:
            try:
                r = subprocess.run(
                    [RCLONE_PATH, "--config", RCLONE_CONF, "lsd", REMOTE_SAVES.rstrip("/"),
                     "--contimeout", "15s", "--timeout", "20s", "--low-level-retries", "2"],
                    capture_output=True, text=True, timeout=40)
                if r.returncode == 0:
                    for line in r.stdout.splitlines():
                        parts = line.split()
                        if not parts:
                            continue
                        name = parts[-1]
                        if name == "_ports":
                            port_saves_cloud = True
                        elif not name.startswith(("_", ".")) and name not in systems:
                            saves_cloud.append(name)
            except Exception:
                pass

        config = self.read_config()
        excluded = config.get("EXCLUDED_SYSTEMS", "").split("|") if config.get("EXCLUDED_SYSTEMS") else []
        selected = config.get("ROMS_SYNC_DIRS", "").split("|") if config.get("ROMS_SYNC_DIRS") else []
        
        self.send_json({
            "port_saves_cloud": port_saves_cloud,
            "saves_cloud": saves_cloud,
            "all": systems,
            "cloud_only": cloud_only,
            "port_saves": self._port_saves(),
            "cloud_error": cloud_error,
            "excluded": [s for s in excluded if s],
            "selected": [s for s in selected if s]
        })

    def api_device(self):
        info = {
            "system": self.get_system(),
            "device": self.get_device(),
            "version": self.get_version(),
            "kernel": os.uname().release if hasattr(os, "uname") else "Unknown",
            "arch": os.uname().machine if hasattr(os, "uname") else "Unknown"
        }
        
        if os.path.exists("/proc/meminfo"):
            try:
                with open("/proc/meminfo", "r") as f:
                    for line in f:
                        if "MemTotal" in line:
                            info["ram_total"] = line.split(":", 1)[1].strip()
                        elif "MemAvailable" in line:
                            info["ram_available"] = line.split(":", 1)[1].strip()
            except:
                pass
        
        if os.path.exists("/sys/class/thermal/thermal_zone0/temp"):
            try:
                with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
                    temp = int(f.read().strip()) / 1000
                    info["temperature"] = f"{temp:.1f}°C"
            except:
                pass
        
        self.send_json(info)

    def _read_rclone_stats(self):
        log_file = "/tmp/save_sync_progress.log"
        try:
            with open(log_file, "r") as f:
                lines = f.readlines()
        except Exception:
            return None
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue
            stats = entry.get("stats")
            if isinstance(stats, dict):
                return stats
        return None

    def api_progress(self):
        progress_file = "/tmp/save_sync_progress.json"
        result = {
            "active": False,
            "action": "",
            "phase": "",
            "percent": None,
            "success": None
        }

        try:
            if os.path.exists(progress_file):
                with open(progress_file, "r") as f:
                    base = json.loads(f.read().strip() or "{}")
                if isinstance(base, dict):
                    result.update(base)
        except Exception as e:
            result["error"] = str(e)

        # what the save sync is doing now (written by the sync engine); rclone transfer
        # figures are used only when they belong to the current stage, not an earlier one
        stage_file = "/tmp/save_sync_stage.json"
        stage = None
        try:
            if os.path.exists(stage_file) and os.path.exists(progress_file) and \
                    os.path.getmtime(stage_file) >= os.path.getmtime(progress_file) - 1:
                with open(stage_file, "r") as f:
                    stage = json.load(f)
        except Exception:
            stage = None
        stats = self._read_rclone_stats()
        if stage and isinstance(stage, dict):
            result["stage"] = stage.get("text", "")
            log_file = "/tmp/save_sync_progress.log"
            fresh = (stage.get("kind") in ("send", "recv") and os.path.exists(log_file)
                     and os.path.getmtime(log_file) >= os.path.getmtime(stage_file))
            if not fresh:
                stats = None
        if stats:
            total = stats.get("totalBytes", 0) or 0
            done = stats.get("bytes", 0) or 0
            result["percent"] = int(done * 100 / total) if total > 0 else 0
            result["bytes"] = done
            result["totalBytes"] = total
            result["speed"] = stats.get("speed", 0) or 0
            result["eta"] = stats.get("eta", 0) or 0
            result["transfers"] = stats.get("transfers", 0) or 0
            result["totalTransfers"] = stats.get("totalTransfers", 0) or 0

        self.send_json(result)

    def api_stats(self):
        self.send_json(self.get_stats())

    def api_theme(self):
        theme_file = "/tmp/save_sync_theme"
        theme = "dark"
        if os.path.exists(theme_file):
            try:
                with open(theme_file, "r") as f:
                    theme = f.read().strip()
            except:
                pass
        self.send_json({"theme": theme})

    def api_theme_save(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_json({"success": False, "error": "Нет данных"})
            return
        try:
            data = json.loads(self.rfile.read(length))
            theme = data.get("theme", "dark")
            with open("/tmp/save_sync_theme", "w") as f:
                f.write(theme)
            self.send_json({"success": True, "theme": theme})
        except:
            self.send_json({"success": False, "error": "Ошибка сохранения темы"})

    def api_sync(self, query):
        params = urllib.parse.parse_qs(query)
        action = params.get("action", ["full"])[0]
        
        messages = {
            "download": "Загрузка сохранений запущена",
            "upload": "Выгрузка сохранений запущена",
            "full": "Полная синхронизация запущена",
            "roms_download": "Загрузка ромов запущена",
            "roms_upload": "Выгрузка ромов запущена"
        }
        
        # Сбрасываем файл состояния СРАЗУ, до запуска дочернего процесса.
        # Иначе первый опрос с браузера может увидеть старый success/error
        # от прошлого запуска — ещё до того, как сам скрипт дойдёт до
        # своего progress_start и перезапишет файл актуальным состоянием.
        try:
            with open("/tmp/save_sync_progress.json", "w") as f:
                json.dump({"active": False, "action": action, "phase": "", "percent": None, "success": None}, f)
            with open("/tmp/save_sync_progress.log", "w") as f:
                pass
        except Exception:
            pass
        
        try:
            if action == "download":
                if os.path.exists(DOWNLOAD_SCRIPT):
                    self._spawn_op(action, ["bash", DOWNLOAD_SCRIPT, "--web-progress"], 
                                   stdout=subprocess.DEVNULL, 
                                   stderr=subprocess.DEVNULL)
                    self.send_json({"success": True, "message": messages[action]})
                else:
                    self.send_json({"success": False, "error": f"Скрипт не найден: {DOWNLOAD_SCRIPT}"})
            
            elif action == "upload":
                if os.path.exists(UPLOAD_SCRIPT):
                    self._spawn_op(action, ["bash", UPLOAD_SCRIPT, "--web-progress"], 
                                   stdout=subprocess.DEVNULL, 
                                   stderr=subprocess.DEVNULL)
                    self.send_json({"success": True, "message": messages[action]})
                else:
                    self.send_json({"success": False, "error": f"Скрипт не найден: {UPLOAD_SCRIPT}"})
            
            elif action == "full":
                if not os.path.exists(DOWNLOAD_SCRIPT) or not os.path.exists(UPLOAD_SCRIPT):
                    self.send_json({"success": False, "error": "Не найден скрипт синхронизации"})
                    return
                # Один процесс выполняет download -> upload последовательно,
                # поэтому Web UI видит реальный текущий этап полной синхронизации.
                self._spawn_op(action, 
                    ["/bin/sh", "-c", f"bash '{DOWNLOAD_SCRIPT}' --web-progress; rc=$?; if [ $rc -eq 0 ]; then bash '{UPLOAD_SCRIPT}' --web-progress; else exit $rc; fi"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                self.send_json({"success": True, "message": messages[action]})
            
            elif action == "roms_download":
                if os.path.exists(DOWNLOAD_ROMS):
                    self._spawn_op(action, ["bash", DOWNLOAD_ROMS, "--web-progress"], 
                                   stdout=subprocess.DEVNULL, 
                                   stderr=subprocess.DEVNULL)
                    self.send_json({"success": True, "message": messages[action]})
                else:
                    self.send_json({"success": False, "error": f"Скрипт не найден: {DOWNLOAD_ROMS}"})
            
            elif action == "roms_upload":
                if os.path.exists(UPLOAD_ROMS):
                    self._spawn_op(action, ["bash", UPLOAD_ROMS, "--web-progress"], 
                                   stdout=subprocess.DEVNULL, 
                                   stderr=subprocess.DEVNULL)
                    self.send_json({"success": True, "message": messages[action]})
                else:
                    self.send_json({"success": False, "error": f"Скрипт не найден: {UPLOAD_ROMS}"})
            
            else:
                self.send_json({"success": False, "error": "Неизвестное действие"})
        
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})

    def api_exclude(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_json({"success": False, "error": "Нет данных"})
            return
        
        try:
            data = json.loads(self.rfile.read(length))
            action = data.get("action")
            system = data.get("system", "").strip()
            
            config = self.read_config()
            excluded = config.get("EXCLUDED_SYSTEMS", "")
            excluded_list = [x.strip() for x in excluded.split("|") if x.strip()]
            
            if action == "add":
                if system and system not in excluded_list:
                    excluded_list.append(system)
                    config["EXCLUDED_SYSTEMS"] = "|".join(excluded_list)
                    if self.save_config(config):
                        self.send_json({"success": True, "message": f"{system} исключена"})
                    else:
                        self.send_json({"success": False, "error": "Ошибка сохранения"})
                else:
                    self.send_json({"success": False, "error": "Система уже исключена"})
            
            elif action == "remove":
                if system in excluded_list:
                    excluded_list.remove(system)
                    config["EXCLUDED_SYSTEMS"] = "|".join(excluded_list)
                    if self.save_config(config):
                        self.send_json({"success": True, "message": f"{system} восстановлена"})
                    else:
                        self.send_json({"success": False, "error": "Ошибка сохранения"})
                else:
                    self.send_json({"success": False, "error": "Система не в исключениях"})
            
            elif action == "clear":
                config["EXCLUDED_SYSTEMS"] = ""
                if self.save_config(config):
                    self.send_json({"success": True, "message": "Все исключения удалены"})
                else:
                    self.send_json({"success": False, "error": "Ошибка сохранения"})
            
            else:
                self.send_json({"success": False, "error": "Неизвестное действие"})
        
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})

    def api_roms(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_json({"success": False, "error": "Нет данных"})
            return
        
        try:
            data = json.loads(self.rfile.read(length))
            action = data.get("action")
            
            config = self.read_config()
            
            if action == "select":
                systems = data.get("systems", [])
                config["ROMS_SYNC_DIRS"] = "|".join(systems) if systems else ""
                if self.save_config(config):
                    self.update_roms_filter()
                    self.send_json({"success": True, "message": f"Выбрано систем: {len(systems)}"})
                else:
                    self.send_json({"success": False, "error": "Ошибка сохранения"})
            
            elif action == "toggle_media":
                current = config.get("ROMS_SYNC_MEDIA", "false")
                config["ROMS_SYNC_MEDIA"] = "true" if current == "false" else "false"
                if self.save_config(config):
                    self.update_roms_filter()
                    status = "включено" if config["ROMS_SYNC_MEDIA"] == "true" else "выключено"
                    self.send_json({"success": True, "message": f"Медиа {status}"})
                else:
                    self.send_json({"success": False, "error": "Ошибка сохранения"})
            
            else:
                self.send_json({"success": False, "error": "Неизвестное действие"})
        
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})

    # ========================================
    # DOWNLOAD FROM A PUBLIC LINK (link_download.py)
    # ========================================
    def _json_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length <= 0:
            return {}
        try:
            data = json.loads(self.rfile.read(length))
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    def _link_env(self, password):
        env = dict(os.environ)
        env.pop("SS_LINK_PASSWORD", None)
        if password:
            # via the environment, not the command line: not visible in the process list
            env["SS_LINK_PASSWORD"] = password
        return env

    def _link_pid(self):
        try:
            with open(LINK_PID_FILE, "r") as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                if b"link_download" in f.read():
                    return pid
        except Exception:
            pass
        return None

    def api_link_dests(self, query=""):
        target = "cloud" if urllib.parse.parse_qs(query).get("target", ["device"])[0] == "cloud" else "device"
        result = {"target": target, "available": False, "with_files": [], "others": [], "free": None}
        if os.path.exists(LINK_SCRIPT):
            try:
                r = subprocess.run([sys.executable, LINK_SCRIPT, "--dests-json", target],
                                   capture_output=True, text=True, timeout=180)
                lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
                if lines:
                    result.update(json.loads(lines[-1]))
            except Exception as e:
                result["error"] = str(e)
        result["running"] = self._link_pid() is not None
        result["link_available"] = os.path.exists(LINK_SCRIPT)
        self.send_json(result)

    def api_link_list(self):
        data = self._json_body()
        url = (data.get("url") or "").strip()
        if not url:
            self.send_json({"error": "Нет ссылки"})
            return
        if not os.path.exists(LINK_SCRIPT):
            self.send_json({"error": "link_download.py не найден - переустановите Save Sync"})
            return
        try:
            r = subprocess.run([sys.executable, LINK_SCRIPT, "--list-json", url],
                               capture_output=True, text=True, timeout=600,
                               env=self._link_env(data.get("password") or ""))
            lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
            result = json.loads(lines[-1]) if lines else {"error": (r.stderr or "no output")[-300:]}
        except subprocess.TimeoutExpired:
            result = {"error": "Сервис слишком долго отдавал список файлов"}
        except Exception as e:
            result = {"error": str(e)}
        self.send_json(result)

    def api_link_zip(self):
        data = self._json_body()
        url, path = (data.get("url") or "").strip(), (data.get("path") or "").strip()
        if not url or not path or not os.path.exists(LINK_SCRIPT):
            self.send_json({"error": "bad request"})
            return
        try:
            r = subprocess.run([sys.executable, LINK_SCRIPT, "--zip-json", url, path],
                               capture_output=True, text=True, timeout=600,
                               env=self._link_env(data.get("password") or ""))
            lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
            result = json.loads(lines[-1]) if lines else {"error": (r.stderr or "no output")[-300:]}
        except subprocess.TimeoutExpired:
            result = {"error": "Архив слишком долго читался"}
        except Exception as e:
            result = {"error": str(e)}
        self.send_json(result)

    def api_link_download(self):
        data = self._json_body()
        url = (data.get("url") or "").strip()
        dest = (data.get("dest") or "").strip()
        items = [i for i in (data.get("items") or []) if isinstance(i, str)]
        if not url:
            self.send_json({"success": False, "error": "Нет ссылки"})
            return
        if not dest:
            self.send_json({"success": False, "error": "Выберите, куда положить файлы"})
            return
        if not os.path.exists(LINK_SCRIPT):
            self.send_json({"success": False, "error": "link_download.py не найден - переустановите Save Sync"})
            return
        if self._link_pid() is not None:
            self.send_json({"success": False, "error": "Загрузка по ссылке уже идёт"})
            return
        # Same as api_sync: reset the progress state before starting, and clear the
        # rclone stats log so it does not override this download's progress
        try:
            with open("/tmp/save_sync_progress.json", "w") as f:
                json.dump({"active": False, "action": "link_download", "phase": "", "percent": None, "success": None}, f)
            with open("/tmp/save_sync_progress.log", "w") as f:
                pass
        except Exception:
            pass
        target = "cloud" if data.get("target") == "cloud" else "device"
        cmd = [sys.executable, LINK_SCRIPT, "--download", url, "--dest", dest, "--target", target, "--web-progress"]
        for item in items:
            cmd += ["--item", item]
        if data.get("unpack"):
            cmd.append("--unpack")
        try:
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             env=self._link_env(data.get("password") or ""), start_new_session=True)
            self.send_json({"success": True})
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})


    # ========================================
    # CANCEL A RUNNING OPERATION
    # ========================================
    def _spawn_op(self, action, cmd, **kw):
        # Every operation gets its own process group: "Cancel" stops the
        # script together with its rclone in one go.
        proc = subprocess.Popen(cmd, start_new_session=True, **kw)
        try:
            with open(OP_FILE, "w") as f:
                json.dump({"pgid": proc.pid, "action": action}, f)
        except OSError:
            pass
        return proc

    def _group_alive(self, pgid):
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                with open("/proc/%s/stat" % d, "r") as f:
                    st = f.read()
                rest = st[st.rindex(")") + 2:].split()
                if int(rest[2]) == pgid and rest[0] != "Z":
                    return True
            except Exception:
                pass
        return False

    def _cancel_watchdog(self, pgid, action):
        for _ in range(20):
            time.sleep(0.5)
            if not self._group_alive(pgid):
                break
        else:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except Exception:
                pass
        # the script records the cancel itself; this is only a safety net
        try:
            with open("/tmp/save_sync_progress.json", "r") as f:
                cur = json.load(f)
        except Exception:
            cur = {}
        if cur.get("active") or cur.get("success") is None:
            try:
                with open("/tmp/save_sync_progress.json", "w") as f:
                    json.dump({"active": False, "action": action, "phase": "Операция отменена", "percent": 0,
                               "success": False, "cancelled": True}, f)
            except OSError:
                pass

    def _engine(self, args, timeout):
        """Runs sync_engine.py with the settings of this device."""
        config = self.read_config()
        env = dict(os.environ, SS_RCLONE=RCLONE_PATH, SS_EXCLUDED=config.get("EXCLUDED_SYSTEMS", "") or "",
                   SS_KEEP_DAYS=str(config.get("CONFLICT_KEEP_DAYS", "3") or "3"))
        return subprocess.run([sys.executable or "python3", os.path.join(BASE, "sync_engine.py")] + args,
                              env=env, capture_output=True, text=True, timeout=timeout)

    def api_conflicts(self):
        try:
            r = self._engine(["conflicts"], 60)
            if r.returncode == 0:
                self.send_json({"success": True, "items": json.loads(r.stdout or "[]")})
                return
        except Exception:
            pass
        self.send_json({"success": False, "error": 'Не удалось получить список конфликтов'})

    def api_conflict_action(self, action):
        try:
            length = int(self.headers.get("Content-Length", 0))
            cid = str(json.loads(self.rfile.read(length) or b"{}").get("id", "")) if length else ""
        except (ValueError, AttributeError):
            cid = ""
        if not cid:
            self.send_json({"success": False, "error": 'Нет данных'})
            return
        try:
            if action == "delete":
                r = self._engine(["drop", cid], 60)
                if r.returncode == 0:
                    self.send_json({"success": True})
                else:
                    self.send_json({"success": False, "error": 'Не удалось удалить копию'})
                return
            r = self._engine(["restore", cid], 300)
            if r.returncode == 3:
                self.send_json({"success": False, "error": 'Сейчас идёт синхронизация - попробуйте через минуту'})
                return
            if r.returncode != 0:
                self.send_json({"success": False, "error": 'Не удалось вернуть версию'})
                return
            # the restored save is a change on this device: the sync sends it everywhere
            try:
                with open("/tmp/save_sync_progress.json", "w") as f:
                    json.dump({"active": False, "action": "upload", "phase": "", "percent": None, "success": None}, f)
                with open("/tmp/save_sync_progress.log", "w") as f:
                    pass
            except OSError:
                pass
            self._spawn_op("upload", ["bash", UPLOAD_SCRIPT, "--web-progress"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.send_json({"success": True, "message": 'Версия возвращена, идёт синхронизация'})
        except Exception:
            self.send_json({"success": False, "error": 'Не удалось вернуть версию'})

    def api_cancel(self):
        pid = self._link_pid()
        if pid is not None:
            try:
                os.kill(pid, signal.SIGTERM)
                self.send_json({"success": True})
            except Exception as e:
                self.send_json({"success": False, "error": str(e)})
            return
        try:
            with open(OP_FILE, "r") as f:
                op = json.load(f)
            pgid = int(op.get("pgid"))
        except Exception:
            self.send_json({"success": False, "error": "Нет запущенной операции"})
            return
        if not self._group_alive(pgid):
            self.send_json({"success": False, "error": "Нет запущенной операции"})
            return
        try:
            os.killpg(pgid, signal.SIGTERM)
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})
            return
        threading.Thread(target=self._cancel_watchdog, args=(pgid, op.get("action", "")), daemon=True).start()
        self.send_json({"success": True})

    def api_link_cancel(self):
        pid = self._link_pid()
        if pid is None:
            self.send_json({"success": False, "error": "Загрузка по ссылке не запущена"})
            return
        try:
            os.kill(pid, signal.SIGTERM)
            self.send_json({"success": True})
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})


HTML = '''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Save Sync Web</title>
<style>

/* Анимация прогресс-бара */
@keyframes syncProgressMove {
    0% { transform: translateX(-140%); }
    50% { transform: translateX(120%); }
    100% { transform: translateX(280%); }
}

/* ========================================
   MATERIAL DESIGN - ТЁМНАЯ ТЕМА (Лунная ночь)
   ======================================== */
:root {
    --bg-primary: #0A0E17;
    --bg-secondary: #141B2B;
    --bg-card: #1A2333;
    --bg-hover: #26344A;
    --border-color: #2A3A52;
    --text-primary: #E8EDF5;
    --text-secondary: #9BB0CC;
    --text-muted: #5A7390;
    --accent: #5C6BC0;
    --accent-hover: #7986CB;
    --accent-dark: #303F9F;
    --success: #66BB6A;
    --success-hover: #43A047;
    --error: #EF5350;
    --error-hover: #D32F2F;
    --warning: #FFCA28;
    --warning-hover: #FFB300;
    --disabled: #424242;
    --radius: 8px;
    --elevation-0: none;
    --elevation-1: 0 2px 4px rgba(0,0,0,0.3);
    --elevation-2: 0 4px 12px rgba(0,0,0,0.4);
    --elevation-3: 0 8px 24px rgba(0,0,0,0.5);
    --elevation-4: 0 12px 40px rgba(0,0,0,0.6);
}

/* ========================================
   MATERIAL DESIGN - СВЕТЛАЯ ТЕМА (Sky Blue)
   ======================================== */
/* ========================================
   MATERIAL DESIGN - СВЕТЛАЯ ТЕМА (Облачное утро)
   ======================================== */
[data-theme="light"] {
    --bg-primary: #F0F4FA;
    --bg-secondary: #FFFFFF;
    --bg-card: #F8FAFE;
    --bg-hover: #EBF0F8;
    --border-color: #DCE4ED;
    --text-primary: #1A2634;
    --text-secondary: #4A607A;
    --text-muted: #8A9FB5;
    --accent: #1565C0;
    --accent-hover: #0D47A1;
    --accent-dark: #0D47A1;
    --success: #4CAF50;
    --success-hover: #388E3C;
    --error: #F44336;
    --error-hover: #D32F2F;
    --warning: #FFC107;
    --warning-hover: #F9A825;
    --disabled: #BDBDBD;
    --radius: 8px;
    --elevation-0: none;
    --elevation-1: 0 2px 4px rgba(0,0,0,0.08);
    --elevation-2: 0 4px 12px rgba(0,0,0,0.12);
    --elevation-3: 0 8px 24px rgba(0,0,0,0.16);
    --elevation-4: 0 12px 40px rgba(0,0,0,0.2);
}

*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Roboto','Segoe UI',system-ui,sans-serif;background:var(--bg-primary);color:var(--text-primary);padding:20px;min-height:100vh;display:flex;justify-content:center;align-items:center;transition:background 0.3s, color 0.3s}
.container{max-width:1100px;width:100%;background:var(--bg-secondary);border-radius:var(--radius);padding:24px;border:1px solid var(--border-color);box-shadow:var(--elevation-2);transition:background 0.3s, border 0.3s, box-shadow 0.3s}

/* ========== СКРЫВАЕМ ЛОГИ НА ВКЛАДКЕ НАСТРОЙКИ ========== */

/* По умолчанию логи видны */
.log-wrapper {
    display: block;
}

/* Скрываем весь блок логов, когда активна вкладка Настройки */
#tab-settings.active ~ .log-wrapper {
    display: none !important;
}

/* Стили внутри обёртки (без изменений) */
.log-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 8px;
    flex-wrap: wrap;
    gap: 8px;
}

.log-header span {
    color: var(--text-secondary);
    font-size: 13px;
    font-weight: 500;
}

.log-header .log-actions {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
}

.log-header button {
    background: none;
    border: none;
    color: var(--accent);
    cursor: pointer;
    font-size: 13px;
    padding: 4px 12px;
    border-radius: var(--radius);
    transition: all 0.3s;
    font-weight: 500;
}

.log-header button:hover {
    background: var(--bg-card);
    color: var(--accent-hover);
}

.log-container {
    background: var(--bg-card);
    border-radius: var(--radius);
    padding: 12px;
    max-height: 130px;
    overflow-y: auto;
    font-family: 'Roboto Mono', monospace;
    font-size: 12px;
    line-height: 1.6;
    border: 1px solid var(--border-color);
    box-shadow: inset 0 2px 4px rgba(0,0,0,0.05);
}

.log-container::-webkit-scrollbar {
    width: 6px;
}

.log-container::-webkit-scrollbar-track {
    background: var(--bg-primary);
    border-radius: 10px;
}

.log-container::-webkit-scrollbar-thumb {
    background: var(--accent);
    border-radius: 10px;
}

.log-container .log-line { color: var(--text-secondary); }

/* ========== ШАПКА ========== */
.header{text-align:center;margin-bottom:24px;position:relative}
.header h1{font-size:28px;font-weight:500;letter-spacing:-0.5px;color:var(--text-primary)}
.header .sub{color:var(--text-secondary);font-size:14px;font-weight:400;margin-top:4px}
.header .device{color:var(--text-muted);font-size:12px;margin-top:4px}

/* ========== КНОПКА ТЕМЫ ========== */
.header .theme-toggle {
    position: fixed;
    top: 16px;
    right: 16px;
    background: transparent;           /* ← ПРОЗРАЧНЫЙ */
    border: none;                      /* ← БЕЗ КОНТУРА */
    color: var(--text-primary);
    padding: 0;
    border-radius: 0;
    cursor: pointer;
    font-size: 32px;
    box-shadow: none;                  /* ← ТЕНЬ УБРАЛИ, БУДЕТ ЧЕРЕЗ FILTER */
    transition: transform 0.2s cubic-bezier(0.4, 0, 0.2, 1), filter 0.2s cubic-bezier(0.4, 0, 0.2, 1);
    z-index: 999;
    width: auto;
    height: auto;
    display: flex;
    align-items: center;
    justify-content: center;
    -webkit-tap-highlight-color: transparent;
    user-select: none;
    line-height: 1;
    /* ← ТЕНЬ ЧЕРЕЗ FILTER ДЛЯ ЛУНЫ */
    filter: drop-shadow(0 4px 6px rgba(0, 0, 0, 0.4));
}

/* ТЕНЬ ПРИ НАВЕДЕНИИ */
@media (hover: hover) {
    .header .theme-toggle:hover {
        transform: scale(1.15);
        filter: drop-shadow(0 6px 12px rgba(0, 0, 0, 0.6));
    }
}

/* ПРИ НАЖАТИИ */
.header .theme-toggle:active {
    transform: scale(0.9);
    transition-duration: 0.05s;
}

.header .theme-toggle:active {
    transform: scale(0.92);
    transition-duration: 0.05s;
}

.header .theme-toggle:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
}

/* ========== СТАТУСНАЯ ПАНЕЛЬ ========== */
.status-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px;margin-bottom:20px}
.status-item{background:var(--bg-card);padding:12px 16px;border-radius:var(--radius);border:1px solid var(--border-color);transition:all 0.3s;box-shadow:var(--elevation-1)}
.status-item .label{font-size:11px;color:var(--text-secondary);text-transform:uppercase;letter-spacing:0.5px;font-weight:500;display:flex;align-items:center}
.status-item .value{font-size:15px;margin-top:4px;color:var(--text-primary);font-weight:500}
.status-item .value.error{color:var(--error)}
.status-item .value.warning{color:var(--warning)}
.status-item .syncing{animation:pulse 1s infinite}

@media (hover: hover) {
    .status-item:hover {
        box-shadow: var(--elevation-3);
        transform: translateY(-4px);
    }
}

@keyframes pulse{0%,100%{opacity:1}50%{opacity:0.5}}

/* ========== ВКЛАДКИ ========== */
.tabs{display:flex;gap:4px;margin-bottom:20px;background:var(--bg-card);border-radius:var(--radius);padding:4px;border:1px solid var(--border-color)}
.tab{flex:1;background:transparent;border:none;color:var(--text-secondary);padding:10px 16px;border-radius:var(--radius);cursor:pointer;font-size:13px;font-weight:500;transition:all 0.3s;text-align:center}
.tab.active{background:var(--accent);color:#fff}

@media (hover: hover) {
    .tab:hover:not(.active) {
        background:var(--bg-hover);
        color:var(--text-primary);
    }
}

.tab-content{display:none}
.tab-content.active{display:block;margin:0}

/* ========== ЗАГОЛОВКИ СЕКЦИЙ ========== */
.section-title{font-size:14px;font-weight:500;color:var(--text-secondary);margin-bottom:12px;padding-bottom:4px;border-bottom:2px solid var(--accent);display:inline-block;letter-spacing:0.3px}

/* ========== КНОПКИ ========== */
.btn{background:var(--bg-card);border:1px solid var(--border-color);color:var(--text-secondary);padding:10px 20px;border-radius:var(--radius);cursor:pointer;font-size:13px;font-weight:500;transition:all 0.3s cubic-bezier(0.4, 0, 0.2, 1);text-transform:uppercase;letter-spacing:0.5px;position:relative;overflow:hidden}
.btn:active{transform:translateY(0);box-shadow:var(--elevation-1)}

@media (hover: hover) {
    .btn:hover {
        background:var(--bg-hover);
        transform:translateY(0px);
    }
}

.btn::after{content:'';position:absolute;inset:0;background:rgba(255,255,255,0.1);opacity:0;transition:opacity 0.3s}
.btn:active::after{opacity:1;transition:0s}

/* ========== PRIMARY КНОПКА (ТЁМНЫЙ ТЕКСТ) ========== */
.btn-primary {
    padding: 14px 20px;
    background: var(--accent);
    border-color: var(--accent);
    color: #fff;
}

@media (hover: hover) {
    .btn-primary:hover {
        background: var(--accent-hover);
        border-color: var(--accent-hover);
        color: #fff;
        transform: translateY(0px);
    }
}

.btn-primary:active {
    transform: translateY(0);
    box-shadow: var(--elevation-2);
}

.btn:disabled{opacity:0.5;cursor:not-allowed;transform:none!important;box-shadow:none!important}

/* ========== DANGER КНОПКА ========== */
.btn-danger{background:var(--error);border-color:var(--error);color:#fff;box-shadow:var(--elevation-2)}
@media (hover: hover) {
    .btn-danger:hover {
        background:var(--error-hover);
        border-color:var(--error-hover);
        color:#fff;
        transform:translateY(0px);
    }
}
.btn-danger:active{transform:translateY(0);box-shadow:var(--elevation-2)}

/* ========== ГРУППЫ КНОПОК ========== */
.actions{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px;margin-bottom:16px}

/* ========== НАСТРОЙКИ ========== */
.settings-row{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin:6px 0;padding:8px 12px;background:var(--bg-card);border-radius:var(--radius);border:1px solid var(--border-color);transition:all 0.3s}
.settings-row:focus-within{border-color:var(--accent);box-shadow:0 0 0 3px rgba(38,166,154,0.15)}
.settings-row label{color:var(--text-secondary);font-size:13px;min-width:110px;font-weight:500}
.settings-row input,.settings-row select{background:var(--bg-primary);border:1px solid var(--border-color);color:var(--text-primary);padding:8px 12px;border-radius:var(--radius);font-size:13px;flex:1;min-width:100px;transition:border 0.3s;font-family:inherit}
.settings-row input:focus,.settings-row select:focus{outline:none;border-color:var(--accent)}

.quick-intervals{display:flex;gap:6px;flex-wrap:wrap}
.quick-intervals button{background:var(--bg-primary);border:1px solid var(--border-color);color:var(--text-secondary);padding:4px 12px;border-radius:var(--radius);cursor:pointer;font-size:12px;font-weight:500;transition:all 0.3s}

@media (hover: hover) {
    .quick-intervals button:hover {
        background:var(--accent);
        color:#1A1A1A;
        box-shadow:var(--elevation-1);
    }
}

/* ========== СТАТИСТИКА ========== */
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:8px;margin:10px 0}
.stats-group-label{font-size:13px;font-weight:500;color:var(--text-secondary);margin:16px 0 8px}
.stats-group-label:first-child{margin-top:0}
.stats-item{text-align:center;padding:12px 8px;background:var(--bg-card);border-radius:var(--radius);border:1px solid var(--border-color);transition:all 0.3s;box-shadow:var(--elevation-1)}
@media (hover: hover) {
    .stats-item:hover {
        box-shadow:var(--elevation-3);
        transform:translateY(-4px);
    }
}
.stats-item .num{font-size:24px;font-weight:500;color:var(--text-primary)}
.stats-item .num.ok{color:var(--success)}
.stats-item .num.error{color:var(--error)}
.roms-stats{display:flex;flex-wrap:wrap;gap:8px;margin:6px 0 18px}
.roms-stats .chip{display:inline-flex;align-items:center;white-space:nowrap;gap:6px;padding:5px 12px;border-radius:999px;background:var(--bg-card);border:1px solid var(--border-color);font-size:13px;color:var(--text-secondary)}
.roms-stats .chip b{font-weight:600;color:var(--text-primary)}
.roms-stats .chip.ok b{color:var(--success)}
.roms-stats .chip.err b{color:var(--error)}
.roms-stats .chip.err{border-color:var(--error)}
@media (max-width:600px){
  /* on a phone: three small tiles in one row, the number above its label */
  .roms-stats{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}
  .roms-stats .chip{flex-direction:column-reverse;justify-content:center;gap:1px;padding:6px 4px;border-radius:12px;font-size:11px;min-width:0;white-space:normal;text-align:center;line-height:1.2}
  .roms-stats .chip b{font-size:17px}
}
.stats-item .label{font-size:11px;color:var(--text-secondary);margin-top:4px}

/* ========== СИСТЕМЫ ========== */
.system-list{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:6px;margin:10px 0}
.system-item{display:flex;align-items:center;gap:8px;padding:8px 12px;background:var(--bg-card);border-radius:var(--radius);border:1px solid var(--border-color);cursor:pointer;transition:all 0.3s;box-shadow:var(--elevation-0)}
@media (hover: hover) {
    .system-item:hover {
        background:var(--bg-hover);
        border-color:var(--accent);
        transform:translateX(4px);
        box-shadow:var(--elevation-1);
    }
}
.system-item.selected{border-color:var(--success);background:rgba(102,187,106,0.08);box-shadow:var(--elevation-1)}
.system-item.excluded{border-color:var(--error);background:rgba(239,83,80,0.08)}
.system-item input[type=checkbox]{display:none;accent-color:var(--accent);width:16px;height:16px;cursor:pointer}
.system-item .name{font-size:13px;flex:1;font-weight:400}
.system-item .name-wrap{display:flex;flex-direction:column;flex:1;gap:2px;min-width:0}
.system-item .name-wrap .name{flex:none}
.system-item .cloud-badge{font-size:10px;color:var(--text-secondary);white-space:nowrap;opacity:0.8}
.system-item .badge{font-size:10px;padding:2px 12px;border-radius:var(--radius);background:var(--bg-card);color:var(--text-secondary);font-weight:500;border:1px solid var(--border-color)}
.system-item .badge.excluded{background:rgba(239,83,80,0.12);color:var(--error);border-color:var(--error)}
.system-item .badge.selected{background:rgba(102,187,106,0.12);color:var(--success);border-color:var(--success)}

/* ========== ПОДПИСЬ ПОД КНОПКАМИ ========== */
.sync-note{margin-top:6px;padding:10px 16px;background:var(--bg-card);border-radius:var(--radius);border-left:4px solid var(--warning);font-size:11px;color:var(--text-secondary);line-height:1.6;box-shadow:var(--elevation-0)}
.sync-note p{margin:3px 0}
.sync-note strong{color:var(--text-primary)}
.conflicts-box{margin:10px 0 14px;padding:12px 14px;background:var(--bg-card);border-radius:var(--radius);border:1px solid var(--border-color);border-left:4px solid var(--warning)}
.conflicts-head{font-size:13px;font-weight:600;color:var(--text-primary);margin-bottom:4px}
.conflicts-hint{font-size:12px;color:var(--text-secondary);line-height:1.5;margin-bottom:6px}
.conflict-row{display:flex;flex-wrap:wrap;align-items:center;gap:8px 12px;padding:9px 0 3px;border-top:1px solid var(--border-color);margin-top:6px}
.conflict-info{flex:1 1 220px;min-width:0}
.conflict-file{font-size:13px;font-weight:500;color:var(--text-primary);word-break:break-all}
.conflict-meta{font-size:12px;color:var(--text-secondary);margin-top:2px}
.conflict-actions{display:flex;gap:8px;flex-shrink:0}
.conflict-actions .btn{padding:6px 14px;font-size:12px;width:auto}
.tab-badge{display:inline-block;min-width:18px;padding:0 5px;margin-left:5px;border-radius:9px;background:var(--warning);color:#1A2634;font-size:11px;font-weight:700;line-height:18px;text-align:center;vertical-align:1px}

/* ========== УСТРОЙСТВО ========== */
.device{font-size:11px;color:var(--text-muted);margin-top:2px;text-align:center;line-height:1.4}
.device br{display:none}

/* ========== TOAST ========== */
.toast{position:fixed;bottom:24px;right:24px;background:var(--bg-secondary);padding:12px 24px;border-radius:var(--radius);border:1px solid var(--border-color);box-shadow:var(--elevation-4);opacity:0;transform:translateY(20px) scale(0.95);transition:all 0.3s cubic-bezier(0.4, 0, 0.2, 1);z-index:1000;font-size:14px;max-width:90%;font-weight:500}
.toast.show{opacity:1;transform:translateY(0) scale(1)}
.toast.success{border-color:var(--success)}
.toast.error{border-color:var(--error)}
.toast.warning{border-color:var(--warning)}
.toast .icon{margin-right:8px}

.loading{color:var(--text-secondary);text-align:center;padding:20px 0;font-size:13px}

/* ========== ФОН С ОБЛАКАМИ ========== */
body::before {
    content: '☁ ☁ ☁   ☁ ☁ ☁ ☁   ☁ ☁ ☁ ☁ ☁   ☁ ☁ ☁   ☁ ☁ ☁ ☁    ☁ ☁ ☁ ☁ ☁   ☁ ☁   ☁ ☁   ☁ ☁   ☁ ☁  ☁ ☁ ☁  ☁ ☁ ☁   ☁ ☁ ☁ ☁ ☁';
    position: fixed;
    top: -10%;
    left: -5%;
    width: 110%;
    height: 120%;
    font-size: 40px;
    color: rgba(255, 255, 255, 0.04);
    letter-spacing: 60px;
    line-height: 110px;
    pointer-events: none;
    z-index: 0;
    transform: rotate(-4deg);
    white-space: pre-wrap;
    word-break: break-all;
    padding: 20px;
    text-align: left;
}

body::after {
    content: '☁  ☁ ☁   ☁   ☁ ☁ ☁  ☁  ☁   ☁ ☁ ☁   ☁   ☁   ☁ ☁   ☁  ☁  ☁  ☁     ☁     ☁  ☁     ☁  ☁  ☁     ☁  ☁    ☁  ☁  ☁   ☁  ☁  ☁  ☁';
    position: fixed;
    top: -5%;
    left: -10%;
    width: 120%;
    height: 120%;
    font-size: 30px;
    color: rgba(255, 255, 255, 0.03);
    letter-spacing: 80px;
    line-height: 140px;
    pointer-events: none;
    z-index: 0;
    transform: rotate(3deg);
    white-space: pre-wrap;
    word-break: break-all;
    padding: 30px;
    text-align: right;
}

[data-theme="light"] body::before {
    color: rgba(0, 0, 0, 0.04);
}

[data-theme="light"] body::after {
    color: rgba(0, 0, 0, 0.03);
}

.container {
    position: relative;
    z-index: 1;
}

/* ========== АДАПТИВ ========== */
@media (max-width: 600px) {
    .container{padding:16px}
    .status-grid{grid-template-columns:1fr 1fr;gap:6px}
    .actions{grid-template-columns:1fr}
    .btn-full{grid-column:1}
    .settings-row{flex-direction:column;align-items:stretch}
    .settings-row label{min-width:auto}
    .system-list{grid-template-columns:1fr}
    .stats-grid{grid-template-columns:1fr 1fr 1fr;gap:6px}
    .tabs{flex-wrap:wrap}
    .tab{flex:1 1 auto;padding:8px 12px;font-size:11px}
    .device br{display:block}
    .header h1{font-size:22px}
    .header .theme-toggle{top:12px;right:12px;width:10px;height:10px;font-size:24px}
    .btn{padding:8px 14px;font-size:12px}
    .btn-primary{padding: 14px 14px;}
    .status-item .value{font-size:12px;}
    body{padding:30px 16px}
}


/* ========== DOWNLOAD FROM A PUBLIC LINK ========== */
.link-box{background:var(--bg-card);border:1px solid var(--border-color);border-radius:var(--radius);padding:12px;margin:10px 0}
.link-input-row{display:flex;gap:8px;flex-wrap:wrap}
.link-input,.link-controls select{flex:1;min-width:0;background:var(--bg-primary);border:1px solid var(--border-color);color:var(--text-primary);padding:9px 12px;border-radius:var(--radius);font-size:13px;font-family:inherit}
.link-input{min-width:0}
.link-input-row .btn{flex:none}
.link-input:focus,.link-controls select:focus{outline:none;border-color:var(--accent)}
.link-hint{color:var(--text-muted);font-size:12px;margin-top:8px;line-height:1.4}
.link-status{font-size:13px;margin-top:8px;color:var(--text-secondary)}
.link-status:empty{display:none}
.link-status.error{color:var(--error)}
.link-crumbs{font-size:13px;margin:12px 0 6px;color:var(--text-secondary);word-break:break-all}
.link-crumbs a{color:var(--accent);cursor:pointer}
.link-list{max-height:380px;overflow-y:auto;border:1px solid var(--border-color);border-radius:var(--radius);background:var(--bg-primary)}
.link-row{display:flex;align-items:center;gap:10px;padding:8px 10px;border-bottom:1px solid var(--border-color);font-size:13px}
.link-row:last-child{border-bottom:none}
.link-row:hover{background:var(--bg-hover)}
.link-row input{width:16px;height:16px;accent-color:var(--accent);flex:none;cursor:pointer}
.link-row svg{flex:none;color:var(--text-muted)}
.link-name{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.link-name.dir{color:var(--accent);cursor:pointer}
.link-meta{color:var(--text-muted);font-size:12px;white-space:nowrap}
@media (max-width:600px){.link-row{flex-wrap:wrap;row-gap:2px}.link-name{flex:1 1 0}.link-meta{flex-basis:100%;padding-left:52px;white-space:normal}.link-row:not(:has(input)) .link-meta{padding-left:26px}}
.link-controls{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:10px}
.link-controls select{min-width:180px}
.link-summary{font-size:13px;color:var(--text-secondary);margin-top:10px;line-height:1.5}
.link-summary .warn{color:var(--error);font-weight:500}
.op-cancel-row{display:flex;justify-content:flex-end;margin-top:8px}
.op-cancel{padding:6px 14px;font-size:12px}
.link-target{display:flex;gap:18px;flex-wrap:wrap;align-items:center;margin-top:12px;font-size:13px;color:var(--text-secondary)}
.link-target label{display:flex;align-items:center;gap:6px;cursor:pointer;color:var(--text-primary)}
.link-target input{accent-color:var(--accent);width:16px;height:16px;cursor:pointer}
.link-unpack{display:flex;align-items:center;gap:6px;margin-top:10px;font-size:13px;color:var(--text-primary);cursor:pointer}
.link-unpack input{accent-color:var(--accent);width:16px;height:16px;cursor:pointer}
@media (max-width:600px){.link-controls select{flex-basis:100%}.link-controls .btn{flex:1}}
</style>
</head>
<body>

<div class="container">
  <div class="header" style="position:relative">
    <button class="theme-toggle" onclick="toggleTheme()">
    <span id="themeIcon">🌕</span>
    </button>
    <h1 style="display:flex;align-items:center;justify-content:center;gap:10px">
      <svg width="37" height="33" viewBox="0 0 380 341" xmlns="http://www.w3.org/2000/svg" style="color:var(--accent);flex-shrink:0">
        <g transform="translate(0,341) scale(0.1,-0.1)" fill="currentColor"><path d="M1725 3260 c-344 -73 -625 -291 -764 -593 -21 -45 -41 -89 -44 -98 -4 -11 -23 -18 -65 -22 -70 -8 -207 -49 -277 -85 -231 -116 -415 -341 -484 -592 -74 -271 -23 -594 129 -815 91 -132 242 -259 373 -313 121 -50 110 -55 204 93 45 72 82 137 82 146 1 11 -18 23 -57 38 -84 30 -168 88 -237 162 -237 254 -225 645 26 889 118 115 267 177 454 188 l110 7 7 60 c11 89 35 160 84 256 133 258 411 413 709 396 121 -7 195 -26 300 -77 139 -67 258 -186 330 -330 42 -84 54 -124 69 -218 l12 -77 104 -12 c173 -19 301 -77 408 -185 199 -201 246 -495 121 -747 -70 -142 -217 -271 -356 -312 -24 -7 -43 -18 -43 -26 0 -7 37 -74 81 -148 91 -151 75 -142 182 -100 328 130 555 485 557 871 1 369 -199 704 -515 860 -49 24 -121 51 -160 60 -38 9 -76 19 -83 23 -8 3 -25 38 -38 76 -106 305 -411 558 -757 629 -109 23 -344 20 -462 -4z"/><path d="M1766 2469 c-136 -47 -218 -142 -246 -286 -30 -151 50 -315 195 -399 18 -10 19 -31 19 -371 1 -275 4 -364 14 -375 33 -41 183 -49 250 -14 l32 17 0 367 0 367 37 20 c108 58 192 201 193 325 0 60 -29 152 -65 207 -90 135 -273 196 -429 142z"/><path d="M974 1903 c-164 -202 -174 -215 -174 -234 0 -21 20 -28 98 -31 l54 -3 -2 -189 c-1 -233 -5 -226 117 -226 131 0 123 -14 123 220 l0 200 63 0 c63 0 104 16 96 38 -9 26 -261 332 -274 332 -8 0 -53 -48 -101 -107z"/><path d="M2576 1994 c-14 -13 -16 -47 -16 -215 l0 -199 -63 0 c-62 0 -87 -11 -87 -37 0 -13 221 -285 253 -311 23 -19 33 -11 133 108 170 202 167 197 154 219 -9 18 -20 21 -75 21 l-65 0 0 198 c0 243 6 232 -128 232 -69 0 -94 -4 -106 -16z"/><path d="M1393 1225 c-23 -10 -44 -35 -78 -94 -40 -69 -51 -81 -73 -81 -48 0 -105 -21 -131 -48 -15 -15 -93 -138 -175 -274 -160 -268 -178 -315 -162 -419 17 -113 109 -203 222 -218 33 -5 455 -6 939 -4 976 5 930 1 1007 71 22 20 49 54 60 76 29 56 35 157 15 227 -18 61 -284 512 -322 546 -28 25 -84 43 -132 43 -23 0 -37 7 -46 23 -8 12 -29 48 -47 79 -47 79 -69 88 -219 88 l-121 0 0 -34 c0 -23 8 -44 25 -62 107 -115 -17 -250 -240 -262 -95 -5 -173 7 -230 35 -49 24 -104 84 -111 119 -7 37 19 99 47 115 14 7 19 21 19 49 l0 40 -107 0 c-69 -1 -119 -6 -140 -15z m851 -419 c42 -17 76 -61 76 -97 0 -60 -102 -117 -182 -103 -74 14 -128 62 -128 113 0 26 38 71 74 87 40 17 118 18 160 0z m420 0 c39 -16 76 -60 76 -91 0 -12 -10 -35 -22 -50 -58 -74 -208 -74 -266 0 -38 48 -23 97 42 136 37 23 121 25 170 5z"/></g>
      </svg>
      Save Sync
    </h1>
    <div class="sub">Управление облачной синхронизацией</div>
    <div class="device" id="deviceInfo">Загрузка...</div>
  </div>

  <!-- СТАТУСНАЯ ПАНЕЛЬ -->
  <div class="status-grid" id="statusGrid">
    <div class="status-item">
    <div class="label"><svg width="12" height="11" viewBox="-312 -312 3120 3120" style="vertical-align:0px;margin-right:3px"><g transform="translate(0,2496) scale(0.1,-0.1)" fill="currentColor"><path d="M9350 12533 c0 -6836 3 -12452 6 -12480 l7 -53 3153 0 3154 0 0 4408 c0 2425 -3 8041 -7 12480 l-6 8072 -3154 0 -3153 0 0 -12427z"/><path d="M521 15176 c-9 -10 -10 -1883 -5 -7595 l7 -7581 3154 0 3153 0 0 7583 c0 5885 -3 7586 -12 7595 -9 9 -722 12 -3149 12 -2662 0 -3138 -2 -3148 -14z"/><path d="M19945 7610 l-1750 -5 -3 -3803 -2 -3802 3162 0 3161 0 -6 3802 c-6 3005 -10 3804 -20 3810 -12 8 -1345 7 -4542 -2z"/></g></svg>Статистика</div>
    <div class="value" id="syncStats" title="Без изменений / С изменениями / Ошибок">0 • <svg width="13" height="13" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M16 17.01V10h-2v7.01h-3L15 21l4-3.99h-3zM9 3L5 6.99h3V14h2V6.99h3L9 3z" fill="currentColor"/></svg> 0 • <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> 0</div>
   </div>
    <div class="status-item">
      <div class="label"><svg width="13" height="13" viewBox="-6 -6 36 36" fill="none" style="vertical-align:0px;margin-right:3px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Сохранений</div>
      <div class="value" id="sysSaves">-</div>
    </div>
    <div class="status-item">
      <div class="label"><svg width="17" height="12" viewBox="-192 -123 1664 1068" style="vertical-align:0px;margin-right:3px"><g transform="translate(0,822) scale(0.1,-0.1)" fill="currentColor"><path d="M7121 8205 c-484 -56 -926 -221 -1315 -494 -238 -166 -476 -397 -637 -618 -23 -32 -44 -60 -45 -62 -2 -2 -40 8 -84 23 -117 38 -260 73 -385 92 -150 23 -442 23 -590 0 -611 -94 -1127 -423 -1468 -934 -235 -353 -362 -809 -344 -1229 l6 -132 -32 -5 c-18 -3 -72 -10 -122 -16 -413 -50 -861 -242 -1201 -515 -434 -349 -738 -846 -852 -1395 -38 -183 -47 -272 -46 -495 0 -243 14 -368 63 -571 221 -899 936 -1599 1835 -1794 268 -58 -2 -55 4336 -55 3806 0 4011 1 4125 18 649 97 1197 373 1635 824 142 145 217 237 324 396 233 346 381 728 448 1162 18 116 22 183 22 395 0 282 -16 420 -74 657 -180 738 -643 1363 -1298 1752 -333 198 -715 326 -1104 371 -117 14 -118 14 -118 89 0 95 -59 403 -107 556 -75 243 -205 524 -331 715 -452 687 -1140 1129 -1947 1250 -185 28 -520 35 -694 15z"/></g></svg><span id="sysCloudLabel">Облако</span></div>
      <div class="value" id="sysCloud">-</div>
    </div>
    <div class="status-item">
      <div class="label"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" style="vertical-align:0px;margin-right:3px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg>Обновлено</div>
      <div class="value" id="sysLastSync">-</div>
    </div>
    <div class="status-item">
      <div class="label"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" style="vertical-align:0px;margin-right:3px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm6.93 6h-2.95c-.32-1.25-.78-2.45-1.38-3.56 1.84.63 3.37 1.9 4.33 3.56zM12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96zM4.26 14C4.1 13.36 4 12.69 4 12s.1-1.36.26-2h3.38c-.08.66-.14 1.32-.14 2 0 .68.06 1.34.14 2H4.26zm.82 2h2.95c.32 1.25.78 2.45 1.38 3.56-1.84-.63-3.37-1.9-4.33-3.56zm2.95-8H5.08c.96-1.66 2.49-2.93 4.33-3.56C8.81 5.55 8.35 6.75 8.03 8zM12 19.96c-.83-1.2-1.48-2.53-1.91-3.96h3.82c-.43 1.43-1.08 2.76-1.91 3.96zM14.34 14H9.66c-.09-.66-.16-1.32-.16-2 0-.68.07-1.35.16-2h4.68c.09.65.16 1.32.16 2 0 .68-.07 1.34-.16 2zm.25 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95c-.96 1.65-2.49 2.93-4.33 3.56zM16.36 14c.08-.66.14-1.32.14-2 0-.68-.06-1.34-.14-2h3.38c.16.64.26 1.31.26 2s-.1 1.36-.26 2h-3.38z" fill="currentColor"/></svg>Интернет</div>
      <div class="value" id="sysInternet">-</div>
    </div>
    <div class="status-item">
      <div class="label"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" style="vertical-align:0px;margin-right:3px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg>Исключено</div>
      <div class="value" id="sysExcluded">-</div>
    </div>
  </div>

  <!-- ВКЛАДКИ -->
  <div class="tabs">
    <button class="tab active" data-tab="saves"><svg width="16" height="16" viewBox="-6 -6 36 36" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Сохранения<span id="conflictsBadge" class="tab-badge" style="display:none" title="Есть конфликты сохранений"></span></button>
    <button class="tab" data-tab="roms"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>Ромы</button>
    <button class="tab" data-tab="settings"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z" fill="currentColor"/></svg>Настройки</button>
</div>

<!-- Вкладка Сохранения -->
<div id="tab-saves" class="tab-content active">
    <div class="section-title"><svg width="16" height="16" viewBox="-6 -6 36 36" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Сохранения</div>
    
    <div class="actions">
        <button class="btn btn-primary" onclick="runSyncWithProgress('download')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z" fill="currentColor"/></svg>Загрузить сохранения из облака</button>
        <button class="btn btn-primary" onclick="runSyncWithProgress('upload')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M9 16h6v-6h4l-7-7-7 7h4v6zm-4 2h14v2H5v-2z" fill="currentColor"/></svg>Выгрузить сохранения в облако</button>
        <button class="btn btn-primary btn-full" onclick="runSyncWithProgress('full')"><svg width="16" height="16" viewBox="0 0 512 512" style="vertical-align:-3px;margin-right:4px"><g transform="translate(0,512) scale(0.1,-0.1)" fill="currentColor"><path d="M2360 4782 l0 -279 -57 -7 c-581 -68 -1130 -424 -1450 -939 -194 -313 -293 -668 -293 -1047 0 -314 65 -597 200 -875 53 -110 165 -289 222 -358 l23 -27 245 195 c135 108 249 200 253 204 5 5 -17 44 -48 87 -103 143 -184 335 -222 522 -24 120 -24 384 0 504 56 281 186 518 392 716 191 185 399 296 652 352 l83 18 2 -226 3 -225 485 408 c267 224 489 411 493 415 5 4 -42 51 -105 103 -373 314 -781 658 -826 695 l-52 44 0 -280z"/><path d="M3900 3558 c-124 -99 -236 -188 -248 -199 l-24 -18 56 -84 c153 -230 220 -458 220 -747 0 -230 -32 -382 -125 -579 -110 -235 -329 -470 -556 -598 -127 -71 -305 -133 -455 -158 l-38 -6 -2 276 -3 276 -485 -408 c-267 -224 -488 -412 -490 -417 -3 -4 216 -194 485 -420 l490 -413 3 227 2 227 68 6 c164 14 424 86 594 165 505 234 893 666 1067 1190 71 212 101 402 101 632 0 314 -65 597 -200 875 -72 149 -206 356 -228 354 -4 0 -108 -81 -232 -181z"/></g></svg>Полная синхронизация</button>
    </div> 

     
<!-- ПРОГРЕСС-БАР СОХРАНЕНИЙ -->
<div id="syncProgressSaves" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--border-color)">
    <div style="display:flex;justify-content:space-between;margin-bottom:5px">
        <span id="syncProgressTextSaves" style="color:var(--text-secondary);font-size:13px">Синхронизация...</span>
        <span id="syncProgressPercentSaves" style="color:var(--accent);font-size:13px;font-weight:bold">Идёт передача</span>
    </div>
    <div style="width:100%;height:8px;background:var(--bg-primary);border-radius:4px;overflow:hidden">
        <div id="syncProgressBarSaves" style="width:35%;height:100%;background:linear-gradient(90deg,var(--accent),var(--accent-hover));border-radius:4px;animation:syncProgressMove 1.4s ease-in-out infinite;"></div>
    </div>
    <div class="op-cancel-row"><button class="btn btn-danger op-cancel" id="opCancelSaves" onclick="cancelOperation()" style="display:none">Отмена</button></div>
</div>

    <!-- ОБЩАЯ ПОДПИСЬ -->
<!-- КОНФЛИКТЫ СОХРАНЕНИЙ / SAVE CONFLICTS (shown only when there are copies) -->
<div id="conflictsBox" class="conflicts-box" style="display:none">
    <div class="conflicts-head"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px;color:var(--warning)"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><span id="conflictsHead"></span></div>
    <div class="conflicts-hint" id="conflictsHint"></div>
    <div id="conflictsList"></div>
</div>

    <div class="sync-note">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>ВАЖНО:</strong></p>
        <p>• <strong>Загрузка:</strong> Это действие ЗАГРУЗИТ сохранения из облака на устройство. Скачиваются только сохранения, изменённые на других устройствах. Если сохранение удалили на другом устройстве — оно удаляется и здесь. Изменённые на этом устройстве сохранения не заменяются, а отправляются в облако. Если сохранение изменили и здесь, и на другом устройстве — остаётся более новое. Если облако пустое, сохранения с устройства копируются в облако.</p>
        <p>• <strong>Выгрузка:</strong> Это действие ВЫГРУЗИТ сохранения из устройства в облако. Выгружаются только новые или измененные файлы. Если файл удалили на устройстве — он УДАЛЯЕТСЯ из облака. Удаление синхронизируется между устройствами. Изменённые на других устройствах сохранения не перезаписываются, а скачиваются сюда.</p>
        <p>• <strong>Полная синхронизация:</strong> Это действие выполнит ПОЛНУЮ синхронизацию. Сначала ЗАГРУЗИТ сохранения из облака, затем ВЫГРУЗИТ сохранения в облако. Если загрузка не удалась, выгрузка не выполняется.</p>
    </div>
     
    <div class="section-title" style="margin-top:20px"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg>Исключения</div>
    <div style="margin-bottom:10px;display:flex;gap:10px;flex-wrap:wrap;align-items:center">
        <button class="btn btn-danger" onclick="excludeAction('clear')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>Очистить все исключения</button>
        <span style="color:var(--text-secondary);font-size:12px">Кликните по системе, чтобы исключить/восстановить</span>
    </div>
    <div class="system-list" id="excludeList"><div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Загрузка систем...</div></div>
</div>

  <!-- Вкладка Ромы -->
<div id="tab-roms" class="tab-content">
    <div class="section-title"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>Ромы</div>
    <div class="actions">
        <button class="btn btn-primary" onclick="runSyncWithProgress('roms_download')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z" fill="currentColor"/></svg>Загрузить ромы</button>
        <button class="btn btn-primary" onclick="runSyncWithProgress('roms_upload')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M9 16h6v-6h4l-7-7-7 7h4v6zm-4 2h14v2H5v-2z" fill="currentColor"/></svg>Выгрузить ромы</button>
    </div>
    <div id="romsStats" class="roms-stats" title="Статистика загрузки и выгрузки ромов"></div>
    
<!-- ПРОГРЕСС-БАР РОМОВ -->
<div id="syncProgressRoms" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--border-color)">
    <div style="display:flex;justify-content:space-between;margin-bottom:5px">
        <span id="syncProgressTextRoms" style="color:var(--text-secondary);font-size:13px">Синхронизация...</span>
        <span id="syncProgressPercentRoms" style="color:var(--accent);font-size:13px;font-weight:bold">Идёт передача</span>
    </div>
    <div style="width:100%;height:8px;background:var(--bg-primary);border-radius:4px;overflow:hidden">
        <div id="syncProgressBarRoms" style="width:35%;height:100%;background:linear-gradient(90deg,var(--accent),var(--accent-hover));border-radius:4px;animation:syncProgressMove 1.4s ease-in-out infinite;"></div>
    </div>
    <div class="op-cancel-row"><button class="btn btn-danger op-cancel" id="opCancelRoms" onclick="cancelOperation()" style="display:none">Отмена</button></div>
</div>

    <!-- ОБЩАЯ ПОДПИСЬ -->
    <div class="sync-note">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>ВАЖНО:</strong></p>
        <p>• <strong>Загрузка ромов:</strong> Это действие ЗАГРУЗИТ ромы из облака на устройство. Файлы на устройстве НЕ УДАЛЯЮТСЯ. Будут загружены только новые или измененные файлы.</p>
        <p>• <strong>Выгрузка ромов:</strong> Это действие УДАЛИТ из облака ромы, которых нет на устройстве. Если на устройстве не хватает каких-то ромов, они исчезнут из облака без возможности восстановления! Рекомендуется сначала ЗАГРУЗИТЬ ромы из облака или сделать бэкап облака.</p>
    </div>
    
    <div class="section-title" style="margin-top:20px"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M20 6h-8l-2-2H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z" fill="currentColor"/></svg>Выбор систем для копирования и загрузки</div>
    <div style="margin-bottom:10px;display:flex;gap:10px;flex-wrap:wrap;align-items:center">
        <button class="btn" onclick="selectAllRoms()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg>Выбрать все</button>
        <button class="btn btn-danger" onclick="deselectAllRoms()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>Очистить все</button>
        <button class="btn" onclick="toggleMedia()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z" fill="currentColor"/></svg>Медиа: <span id="mediaStatus">-</span></button>
        <span style="color:var(--text-secondary);font-size:12px">Кликните по системе, чтобы выбрать/отменить</span>
    </div>
    <div class="system-list" id="romsList"><div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Загрузка систем...</div></div>

    <!-- Download from a public link -->
    <div class="section-title" style="margin-top:20px"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z" fill="currentColor"/></svg>Скачать по публичной ссылке</div>
    <div class="link-box" id="linkBox">
      <div class="link-input-row">
        <input id="linkUrl" class="link-input" type="url" autocomplete="off" placeholder="Вставьте ссылку: Яндекс.Диск, pCloud, Nextcloud, archive.org" onkeydown="if(event.key==='Enter')linkOpen()">
        <button class="btn btn-primary" id="linkOpenBtn" onclick="linkOpen()">Открыть</button>
      </div>
      <div class="link-input-row" id="linkPwRow" style="display:none;margin-top:8px">
        <input id="linkPw" class="link-input" type="password" autocomplete="off" placeholder="Пароль ссылки" onkeydown="if(event.key==='Enter')linkOpen()">
      </div>
      <div class="link-hint">Яндекс.Диск, pCloud, Nextcloud / ownCloud, archive.org. Можно выбрать отдельные файлы и папки. Zip-архив открывается как папка: из него можно взять только нужные файлы. Уже скачанные файлы пропускаются, прерванная загрузка продолжается.</div>
      <div class="link-status" id="linkStatus"></div>
      <div id="linkBrowser" style="display:none">
        <div class="link-crumbs" id="linkCrumbs"></div>
        <div class="link-list" id="linkList"></div>
        <div class="link-target">
          <span>Куда:</span>
          <label><input type="radio" name="linkTarget" value="device" checked onchange="linkTargetChanged()">На устройство</label>
          <label><input type="radio" name="linkTarget" value="cloud" onchange="linkTargetChanged()">В облако</label>
        </div>
        <label class="link-unpack" id="linkUnpackRow" style="display:none"><input type="checkbox" id="linkUnpack" onchange="linkUpdateSummary()"><span id="linkUnpackText">Распаковать архивы после скачивания</span></label>
        <div class="link-controls">
          <select id="linkDest" onchange="linkUpdateSummary()"></select>
          <button class="btn btn-primary" id="linkStartBtn" onclick="linkDownload()">Скачать</button>
        </div>
        <div class="link-summary" id="linkSummary"></div>
      </div>
    </div>
    <div id="syncProgressLink" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--border-color)">
        <div style="display:flex;justify-content:space-between;margin-bottom:5px">
            <span id="syncProgressTextLink" style="color:var(--text-secondary);font-size:13px">Синхронизация...</span>
            <span id="syncProgressPercentLink" style="color:var(--accent);font-size:13px;font-weight:bold">Идёт передача</span>
        </div>
        <div style="width:100%;height:8px;background:var(--bg-primary);border-radius:4px;overflow:hidden">
            <div id="syncProgressBarLink" style="width:35%;height:100%;background:linear-gradient(90deg,var(--accent),var(--accent-hover));border-radius:4px;animation:syncProgressMove 1.4s ease-in-out infinite;"></div>
        </div>
        <div class="op-cancel-row"><button class="btn btn-danger op-cancel" id="opCancelLink" onclick="cancelOperation()" style="display:none">Отмена</button></div>
    </div>
</div>

  <!-- ВКЛАДКА: НАСТРОЙКИ -->
  <div id="tab-settings" class="tab-content">
    <div class="settings-row">
      <label>Интервал (сек):</label>
      <input type="number" id="settingInterval" value="0" min="0" step="60">
      <span style="color:var(--text-secondary);font-size:12px">0 = всегда</span>
    </div>
    <div class="settings-row">
      <label>Быстрый выбор:</label>
      <div class="quick-intervals">
        <button onclick="setIntervalQuick(0)">Всегда</button>
        <button onclick="setIntervalQuick(300)">5 мин</button>
        <button onclick="setIntervalQuick(900)">15 мин</button>
        <button onclick="setIntervalQuick(3600)">1 час</button>
      </div>
    </div>
    <div class="settings-row">
      <label>Попытки:</label>
      <input type="number" id="settingRetries" value="3" min="1" max="10">
    </div>
    <div class="settings-row">
      <label>Копии при конфликтах:</label>
      <select id="settingKeepDays">
        <option value="0">Не хранить</option>
        <option value="1">1 день</option>
        <option value="3">3 дня</option>
        <option value="7">7 дней</option>
        <option value="30">30 дней</option>
      </select>
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px">Если одно и то же сохранение изменили на разных устройствах, остаётся самая новая версия, а более старая хранится в облаке в папке GameSaves_conflicts выбранное время - вернуть её можно во вкладке «Сохранения». При «Не хранить» это устройство не делает копий и не удаляет копии других устройств.</div>
    <div class="settings-row">
      <label>Уведомления на экране:</label>
      <select id="settingNotifications">
        <option value="true">Включены</option>
        <option value="false">Выключены</option>
      </select>
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px">Короткие уведомления о синхронизации и загрузках. Работает на Batocera и KNULLI.</div>
    <div class="settings-row">
      <label>Синхронизация после игры:</label>
      <select id="settingSyncMode">
        <option value="economy">Только при изменениях</option>
        <option value="fast">После каждой игры</option>
        <option value="full">Полная</option>
      </select>
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px"><b>Только при изменениях:</b> если сохранения на устройстве менялись - синхронизация как в режиме «После каждой игры»; если не менялись, облако не запрашивается, а изменения с других устройств придут при включении устройства или после игры, в которой сохранения изменятся.<br><b>После каждой игры:</b> отправляются и загружаются изменения и удаления, без полного списка файлов в облаке. Подходит для игры на нескольких устройствах.<br><b>Полная:</b> после каждой игры сверяется весь список файлов в облаке, включая добавленные в облако вручную. Самая медленная.<br>При включении устройства и ручном запуске синхронизация всегда полная.</div>
    <div class="settings-row">
      <label>Режим лога:</label>
      <select id="settingLogLevel">
        <option value="info">Обычный</option>
        <option value="debug">Подробный (debug)</option>
      </select>
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px"><b>Обычный:</b> записываются результаты синхронизаций (по ним строится статистика).<br><b>Подробный (debug):</b> дополнительно отправленные, полученные и переименованные файлы, время каждого этапа и запросов к облаку. Включайте, когда ищете причину медленной синхронизации.</div>
    <button class="btn btn-primary" onclick="saveSettings()">Сохранить настройки</button>
  </div>

  <!-- ЛОГИ -->
  <div class="log-wrapper">
    <div class="log-header">
      <span><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3h-4.18C14.4 1.84 13.3 1 12 1c-1.3 0-2.4.84-2.82 2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 0c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1zm7 16H5V5h2v3h10V5h2v14z" fill="currentColor"/></svg>Последние логи</span>
      <div class="log-actions">
        <button onclick="refreshLogs()"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z" fill="currentColor"/></svg>Обновить</button>
        <button onclick="clearLogs()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>Очистить</button>
      </div>
    </div>
    <div class="log-container" id="logContainer"><div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Загрузка логов...</div></div>
  </div>
</div>

<div class="toast" id="toast"><span class="icon" id="toastIcon"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg></span><span id="toastMsg">Готово!</span></div>

<script>
const API = '/api';

// a browser reports a device that is off or out of reach as "Failed to fetch" (Chrome),
// "NetworkError..." (Firefox) or "Load failed" (Safari) - shown in plain words instead
const NET_ERR = 'Нет связи с устройством';
function netErr(e) {
  const m = (e && e.message) || String(e || '');
  if ((e && e.name === 'TypeError') || /Failed to fetch|NetworkError|Load failed|network/i.test(m)) return NET_ERR;
  return 'Ошибка: ' + m;
}

async function apiFetch(endpoint, options = {}) {
  let res;
  try {
    res = await fetch(API + endpoint, options);
  } catch (e) {
    return { success: false, error: NET_ERR };
  }
  try {
    return await res.json();
  } catch (e) {
    return { success: false, error: 'Устройство ответило ошибкой (код {c})'.replace('{c}', res.status) };
  }
}

function showToast(msg, type = 'success') {
  const t = document.getElementById('toast');
  document.getElementById('toastIcon').innerHTML = type === 'success' ? '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg>' : type === 'error' ? '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg>' : '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg>';
  document.getElementById('toastMsg').textContent = msg;
  t.className = 'toast ' + type + ' show';
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.remove('show'), 3000);
}

function setButtonsDisabled(disabled) {
  document.querySelectorAll('.btn').forEach(b => b.disabled = disabled);
}

// ========== УНИВЕРСАЛЬНЫЙ ПРОГРЕСС-БАР ==========

function showProgress(show, text, target) {
    let container, textEl, percentEl, barEl;
    
    if (show) {
        // Показываем конкретный бар
        if (target === 'saves' || target === undefined) {
            container = document.getElementById('syncProgressSaves');
            textEl = document.getElementById('syncProgressTextSaves');
            percentEl = document.getElementById('syncProgressPercentSaves');
            barEl = document.getElementById('syncProgressBarSaves');
        } else if (target === 'link') {
            container = document.getElementById('syncProgressLink');
            textEl = document.getElementById('syncProgressTextLink');
            percentEl = document.getElementById('syncProgressPercentLink');
            barEl = document.getElementById('syncProgressBarLink');
        } else if (target === 'roms') {
            container = document.getElementById('syncProgressRoms');
            textEl = document.getElementById('syncProgressTextRoms');
            percentEl = document.getElementById('syncProgressPercentRoms');
            barEl = document.getElementById('syncProgressBarRoms');
        } else {
            return;
        }

        if (!container) return;
        container.style.display = 'block';
        if (text) textEl.innerHTML = text;
        if (barEl) {
            barEl.style.width = '35%';
            barEl.style.animation = 'syncProgressMove 1.4s ease-in-out infinite';
        }
        if (percentEl) percentEl.textContent = 'Идёт передача';
    } else {
        // Скрываем ОБА бара
        const saves = document.getElementById('syncProgressSaves');
        const roms = document.getElementById('syncProgressRoms');
        
        if (saves) {
            saves.style.display = 'none';
            const bar = document.getElementById('syncProgressBarSaves');
            if (bar) {
                bar.style.width = '0%';
                bar.style.animation = 'none';
            }
        }
        if (roms) {
            roms.style.display = 'none';
            const bar = document.getElementById('syncProgressBarRoms');
            if (bar) {
                bar.style.width = '0%';
                bar.style.animation = 'none';
            }
        }
        
        const percentSaves = document.getElementById('syncProgressPercentSaves');
        const percentRoms = document.getElementById('syncProgressPercentRoms');
        if (percentSaves) percentSaves.textContent = 'Идёт передача';
        if (percentRoms) percentRoms.textContent = 'Идёт передача';
        const link = document.getElementById('syncProgressLink');
        if (link) {
            link.style.display = 'none';
            const bar = document.getElementById('syncProgressBarLink');
            if (bar) { bar.style.width = '0%'; bar.style.animation = 'none'; }
            const pl = document.getElementById('syncProgressPercentLink');
            if (pl) pl.textContent = 'Идёт передача';
        }
    }
}

function formatBytes(n) {
  if (!n || n <= 0) return '0 Б';
  const units = ['Б','КБ','МБ','ГБ'];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return n.toFixed(1) + ' ' + units[i];
}

function updateProgressBar(data, target) {
    const sfx = target === 'roms' ? 'Roms' : target === 'link' ? 'Link' : 'Saves';
    const barEl = document.getElementById('syncProgressBar' + sfx);
    const percentEl = document.getElementById('syncProgressPercent' + sfx);
    if (!barEl || !percentEl) return;

    if (typeof data.percent === 'number' && data.totalBytes > 0) {
        const pct = Math.min(100, Math.max(0, data.percent));
        barEl.style.animation = 'none';
        barEl.style.width = pct + '%';
        let label = (data.stage ? data.stage + ' · ' : '') + pct + '%';
        if (data.speed > 0) label += ' · ' + formatBytes(data.speed) + '/с';
        if (data.eta > 0) label += ' · осталось ' + Math.round(data.eta) + ' сек';
        if (data.totalTransfers > 0 && !data.stage) label += ' · ' + (data.transfers || 0) + '/' + data.totalTransfers + ' файлов';
        percentEl.textContent = label;
    } else {
        barEl.style.animation = 'syncProgressMove 1.4s ease-in-out infinite';
        barEl.style.width = '35%';
        percentEl.textContent = data.stage || 'Идёт передача';
    }
}

// ========== ЗАПУСК СИНХРОНИЗАЦИИ ==========

// ========== ЗАПУСК СИНХРОНИЗАЦИИ ==========

async function runSyncWithProgress(action, starter) {
    setButtonsDisabled(true);
    opCancelShow(true);

    const names = {
        'link_download': LINK_T.phase,
        'download': 'Загрузка сохранений',
        'upload': 'Выгрузка сохранений',
        'full': 'Полная синхронизация',
        'roms_download': 'Загрузка ромов',
        'roms_upload': 'Выгрузка ромов',
        'conflict_restore': 'Возврат версии'
    };

    // Определяем target один раз
    // a link download has its own progress bar in its own section
    const target = action === 'link_download' ? 'link' : (action === 'roms_download' || action === 'roms_upload') ? 'roms' : 'saves';
    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> ' + names[action] + ' запускается...', target);

    let polling = null;
    let seenActive = false;
    // A fast operation can already be finished on the very first poll:
    // then the interval must not start, or the result is handled twice.
    let finished = false;

    const stopPolling = () => {
        if (polling) {
            clearInterval(polling);
            polling = null;
        }
        window._syncPolling = null;
    };

    const poll = async () => {
        if (finished) return;
        try {
            const data = await apiFetch('/progress');
            if (data.error) throw new Error(data.error);

            // Если прогресс активен - показываем
            if (data.active) {
                seenActive = true;
                showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> ' + (data.phase || names[action] || 'Синхронизация') + ' — идёт передача данных...', target);
                updateProgressBar(data, target);
                return;
            }

            // Если операция завершилась очень быстро (например, все файлы уже идентичны),
            // мы могли не успеть увидеть active=true между стартом и первым опросом.
            // Поэтому сначала проверяем наличие финального результата.
            if (data.success !== null && data.success !== undefined) {
                // Для полной синхронизации - промежуточный этап
                if (action === 'full' && data.action === 'download' && data.success) {
                    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Загрузка сохранений завершена, начинается выгрузка...', 'saves');
                    return;
                }

                stopPolling();
                finished = true;
                opCancelShow(false);
                if (action === 'link_download') { linkFinished(data); return; }
                if (data.cancelled) { opCancelled(target); return; }
                if (data.success) {
                    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> ' + (data.phase || names[action]) + ' завершена!', target);
                    updateProgressBar({ ...data, percent: 100 }, target);
                    showToast('Операция завершена', 'success');
                } else {
                    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + (data.phase || 'Ошибка синхронизации'), target);
                    showToast('Операция завершилась с ошибкой', 'error');
                }
                setTimeout(() => {
                    showProgress(false);
                    refreshStatus();
                    refreshLogs();
                    refreshStats();
                    if (target === 'saves') loadConflicts();
                    setButtonsDisabled(false);
                }, 2000);
                return;
            }

            // Если ещё не видели активного состояния и финального результата пока нет,
            // показываем состояние запуска. Это нормальная ситуация в первые мгновения.
            if (!seenActive) {
                showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> ' + names[action] + ' запускается...', target);
                return;
            }

            // Если прошло больше 60 секунд и ничего не изменилось - скрываем
            if (seenActive && !data.active && data.success === null) {
                // Ждём ещё немного
            }

        } catch (e) {
            console.error('Progress error:', e);
        }
    };

    try {
        const res = starter ? await starter() : await apiFetch('/sync?action=' + action, { method: 'POST' });
        if (!res.success) {
            stopPolling();
            opCancelShow(false);
            showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Ошибка: ' + (res.error || 'Неизвестная ошибка'), target);
            showToast((res.error || 'Ошибка'), 'error');
            setTimeout(() => { showProgress(false); setButtonsDisabled(false); }, 2500);
            return;
        }

        // Ждём немного, чтобы скрипт успел запуститься
        await new Promise(r => setTimeout(r, 500));
        
        await poll();
        if (!finished) polling = setInterval(poll, 1000);
        window._syncPolling = polling;
    } catch (e) {
        stopPolling();
        showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Ошибка: ' + e.message, target);
        showToast(netErr(e), 'error');
        setTimeout(() => { showProgress(false); setButtonsDisabled(false); }, 3000);
    }
}

// ========== ТЕМА ==========

async function toggleTheme() {
    const current = document.documentElement.getAttribute('data-theme');
    const newTheme = current === 'light' ? 'dark' : 'light';
    
    const icon = document.getElementById('themeIcon');
    icon.textContent = newTheme === 'light' ? '🌑' : '🌕';
    
    document.documentElement.setAttribute('data-theme', newTheme);
    
    await apiFetch('/theme', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({theme: newTheme})
    });
}

async function loadTheme() {
  try {
    const res = await apiFetch('/theme');
    if (res.theme) {
      document.documentElement.setAttribute('data-theme', res.theme);
      // Синхронизируем иконку
      const icon = document.getElementById('themeIcon');
      if (icon) {
        icon.textContent = res.theme === 'light' ? '🌑' : '🌕';
      }
    }
  } catch (e) {}
}

// ========== ТАБЫ ==========

document.querySelectorAll('.tab').forEach(tab => {
  tab.addEventListener('click', function() {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
    this.classList.add('active');
    document.getElementById('tab-' + this.dataset.tab).classList.add('active');
    if (this.dataset.tab === 'roms' || this.dataset.tab === 'saves') loadSystems();
    if (this.dataset.tab === 'roms') refreshStats();
  });
});

// ========== СТАТУС (НЕ ОБНОВЛЯЕТ НАСТРОЙКИ) ==========

async function refreshStatus() {
  try {
    const data = await apiFetch('/status');
    
    // Статистика
    const unch = data.stats?.sync?.unchanged || 0;
    const chg = data.stats?.sync?.changed || 0;
    const err = data.stats?.sync?.error || 0;
    document.getElementById('syncStats').innerHTML = unch + ' • <svg width="13" height="13" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M16 17.01V10h-2v7.01h-3L15 21l4-3.99h-3zM9 3L5 6.99h3V14h2V6.99h3L9 3z" fill="currentColor"/></svg> ' + chg + ' • <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + err;
    const savesCount = data.saves?.count ?? 0;
    const savesSize = data.saves?.size ?? '0 Б';
    document.getElementById('sysSaves').textContent = savesCount + ' файл., ' + savesSize;
    
    const cloudEl = document.getElementById('sysCloud');
    // the card is titled with the cloud service in use (Yandex Disk, pCloud...)
    document.getElementById('sysCloudLabel').textContent = data.cloud?.service || 'Облако';
    if (data.cloud?.status === 'connected' && data.cloud.slow) {
      // the cloud answers, but slowly - that explains a long sync
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg> медленно (' + data.cloud.slow + ' с)';
      cloudEl.className = 'value warning';
    } else if (data.cloud?.status === 'connected') {
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> ' + ((data.cloud.free && data.cloud.free !== '0') ? data.cloud.free : 'подключено');
      cloudEl.className = 'value ok';
    } else {
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + (data.internet ? 'не отвечает' : 'нет интернета');
      cloudEl.className = 'value error';
    }
    
    const syncEl = document.getElementById('sysLastSync');
    if (data.last_sync?.status === 'OK') {
      syncEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> ' + data.last_sync.time;
      syncEl.className = 'value ok';
    } else if (data.last_sync?.status === 'ERROR') {
      syncEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + data.last_sync.time;
      syncEl.className = 'value error';
    } else {
      syncEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> ' + (data.last_sync?.time || '—');
      syncEl.className = 'value';
    }
    
    const netEl = document.getElementById('sysInternet');
    if (data.internet) {
      netEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Доступен';
      netEl.className = 'value ok';
    } else {
      netEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Нет';
      netEl.className = 'value error';
    }
    
    const excl = data.excluded || [];
    document.getElementById('sysExcluded').textContent = excl.length > 0 ? excl.length + ' систем' : 'Нет';
    
    // Показываем систему как в центре управления
    const devicePart = data.device || 'Устройство';
    const systemPart = (data.system || 'неизвестно') + ' (' + (data.version || '?') + ')';
    document.getElementById('deviceInfo').innerHTML = '<svg width="11" height="11" viewBox="0 0 512 512" style="vertical-align:-2px"><path d="M84.54,0v512h259.252c46.209,0,83.669-37.459,83.669-83.669V0H84.54z M138.121,53.582H373.88v189.321H138.121V53.582z M215.931,382.887h-25.6v25.6H156.94v-25.6h-25.6v-33.391h25.6v-25.6h33.391v25.6h25.6V382.887z M284.507,445.972c-17.976,0-32.6-14.624-32.6-32.6s14.624-32.6,32.6-32.6s32.6,14.624,32.6,32.6S302.482,445.972,284.507,445.972z M342.138,377.21c-17.976,0-32.6-14.624-32.6-32.6s14.624-32.6,32.6-32.6s32.6,14.624,32.6,32.6S360.114,377.21,342.138,377.21z" fill="currentColor"/></svg> <span style="white-space:nowrap">' + devicePart + '</span> • <span style="white-space:nowrap">' + systemPart + '</span>';
    
    // ================================================================
    // ⚠️ НАСТРОЙКИ НЕ ОБНОВЛЯЮТСЯ АВТОМАТИЧЕСКИ!
    // ================================================================
    
    if (data.is_syncing) {
      document.querySelectorAll('.btn').forEach(b => b.classList.add('syncing'));
    } else {
      document.querySelectorAll('.btn').forEach(b => b.classList.remove('syncing'));
    }
  } catch (e) {
    console.error('Status error:', e);
  }
}

// ========== ЗАГРУЗКА НАСТРОЕК ПРИ СТАРТЕ ==========

async function loadSettings() {
  try {
    const data = await apiFetch('/status');
    if (data.config) {
      document.getElementById('settingInterval').value = data.config.SYNC_INTERVAL || 0;
      document.getElementById('settingRetries').value = data.config.MAX_RETRIES || 3;
      const kd = data.config.CONFLICT_KEEP_DAYS;
      document.getElementById('settingKeepDays').value = (kd === undefined || kd === '') ? '3' : String(kd);
      document.getElementById('settingNotifications').value = data.config.NOTIFICATIONS || 'true';
      document.getElementById('settingSyncMode').value = ['full', 'fast', 'economy'].includes(data.config.SYNC_MODE)
        ? data.config.SYNC_MODE : (data.config.SKIP_UNCHANGED === 'false' ? 'full' : 'economy');
      document.getElementById('settingLogLevel').value = data.config.LOG_LEVEL === 'debug' ? 'debug' : 'info';
    }
  } catch (e) {
    console.error('Load settings error:', e);
  }
}

// ========== ЛОГИ ==========

let lastLogText = null;

async function refreshLogs() {
  try {
    const data = await apiFetch('/logs?lines=20');
    const container = document.getElementById('logContainer');
    if (data.lines && data.lines.length > 0) {
      // The log is redrawn only when it really changed, so it can be scrolled up and read.
      // A new entry scrolls to the bottom only if the log was already at the bottom.
      const text = data.lines.join('|');
      if (text === lastLogText) return;
      const atBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 30;
      const prevTop = container.scrollTop;
      container.innerHTML = data.lines.map(line => {
        return `<div class="log-line">${escapeHtml(line)}</div>`;
      }).join('');
      container.scrollTop = (lastLogText === null || atBottom) ? container.scrollHeight : prevTop;
      lastLogText = text;
    } else {
      lastLogText = null;
      container.innerHTML = '<div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3H4.99c-1.11 0-1.98.9-1.98 2L3 19c0 1.1.88 2 1.99 2H19c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 12h-4c0 1.66-1.35 3-3 3s-3-1.34-3-3H4.99V5H19v10z" fill="currentColor"/></svg>Лог пуст</div>';
    }
  } catch (e) {
    console.error('Logs error:', e);
  }
}

// Автоматически обновляем лог, пока открыт веб-интерфейс.
setInterval(refreshLogs, 2000);

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

async function clearLogs() {
  if (!confirm('Очистить лог-файл?')) return;
  try {
    await apiFetch('/logs?action=clear');
    showToast('Лог очищен');
    refreshLogs();
  } catch (e) {
    showToast(netErr(e), 'error');
  }
}

// ========== РОМЫ (АВТОСОХРАНЕНИЕ) ==========

let saveTimeout = null;

async function toggleRomsSystem(sys) {
    const container = document.getElementById('romsList');
    const items = container.querySelectorAll('.system-item');
    
    for (const item of items) {
        if (item.textContent.includes(sys)) {
            const checkbox = item.querySelector('input[type="checkbox"]');
            checkbox.checked = !checkbox.checked;
            item.classList.toggle('selected');
            const badge = item.querySelector('.badge');
            if (checkbox.checked) {
                badge.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Выбрана';
                badge.className = 'badge selected';
            } else {
                badge.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg>';
                badge.className = 'badge';
            }
            break;
        }
    }
    
    clearTimeout(saveTimeout);
    saveTimeout = setTimeout(saveRomsSelectionSilent, 300);
}

async function saveRomsSelectionSilent() {
    const selected = [];
    document.querySelectorAll('#romsList input[type="checkbox"]:checked').forEach(cb => {
        const item = cb.closest('.system-item');
        if (item) {
            const name = item.querySelector('.name')?.textContent;
            if (name) selected.push(name);
        }
    });
    
    try {
        const res = await apiFetch('/roms', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({action: 'select', systems: selected})
        });
        if (res.success && res.message) {
            showToast(res.message, 'success');
        }
        refreshStatus();
    } catch (e) {
        console.error('Save error:', e);
    }
}

function selectAllRoms() {
    document.querySelectorAll('#romsList input[type="checkbox"]').forEach(cb => cb.checked = true);
    document.querySelectorAll('#romsList .system-item').forEach(el => {
        el.classList.add('selected');
        const badge = el.querySelector('.badge');
        if (badge) { badge.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Выбрана'; badge.className = 'badge selected'; }
    });
    clearTimeout(saveTimeout);
    saveTimeout = setTimeout(saveRomsSelectionSilent, 300);
}

function deselectAllRoms() {
    document.querySelectorAll('#romsList input[type="checkbox"]').forEach(cb => cb.checked = false);
    document.querySelectorAll('#romsList .system-item').forEach(el => {
        el.classList.remove('selected');
        const badge = el.querySelector('.badge');
        if (badge) { badge.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg>'; badge.className = 'badge'; }
    });
    clearTimeout(saveTimeout);
    saveTimeout = setTimeout(saveRomsSelectionSilent, 300);
}

async function toggleMedia() {
  try {
    const res = await apiFetch('/roms', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({action: 'toggle_media'})
    });

    if (res.success) {
      const config = await apiFetch('/config');
      document.getElementById('mediaStatus').textContent =
        config.ROMS_SYNC_MEDIA === 'true' ? 'ВКЛ' : 'ВЫКЛ';
      showToast(res.message, 'success');
      refreshStatus();
    } else {
      showToast((res.error || 'Ошибка'), 'error');
    }
  } catch (e) {
    showToast(netErr(e), 'error');
  }
}

// ========== СИСТЕМЫ ==========

async function loadSystems() {
  try {
    const data = await apiFetch('/systems');
    
    const romsContainer = document.getElementById('romsList');
    if (data.all && data.all.length > 0) {
      romsContainer.innerHTML = data.all.map(sys => {
        const isSelected = data.selected.includes(sys);
        const isCloudOnly = data.cloud_only && data.cloud_only.includes(sys);
        return `<div class="system-item ${isSelected ? 'selected' : ''}" onclick="toggleRomsSystem('${sys}')">
          <input type="checkbox" ${isSelected ? 'checked' : ''} onclick="event.stopPropagation(); toggleRomsSystem('${sys}')">
          <div class="name-wrap">
            <span class="name">${sys}</span>
            ${isCloudOnly ? '<span class="cloud-badge"><svg width="12" height="8" viewBox="0 0 1280 822" style="vertical-align:-1px;margin-right:2px"><g transform="translate(0,822) scale(0.1,-0.1)" fill="currentColor"><path d="M7121 8205 c-484 -56 -926 -221 -1315 -494 -238 -166 -476 -397 -637 -618 -23 -32 -44 -60 -45 -62 -2 -2 -40 8 -84 23 -117 38 -260 73 -385 92 -150 23 -442 23 -590 0 -611 -94 -1127 -423 -1468 -934 -235 -353 -362 -809 -344 -1229 l6 -132 -32 -5 c-18 -3 -72 -10 -122 -16 -413 -50 -861 -242 -1201 -515 -434 -349 -738 -846 -852 -1395 -38 -183 -47 -272 -46 -495 0 -243 14 -368 63 -571 221 -899 936 -1599 1835 -1794 268 -58 -2 -55 4336 -55 3806 0 4011 1 4125 18 649 97 1197 373 1635 824 142 145 217 237 324 396 233 346 381 728 448 1162 18 116 22 183 22 395 0 282 -16 420 -74 657 -180 738 -643 1363 -1298 1752 -333 198 -715 326 -1104 371 -117 14 -118 14 -118 89 0 95 -59 403 -107 556 -75 243 -205 524 -331 715 -452 687 -1140 1129 -1947 1250 -185 28 -520 35 -694 15z"/></g></svg>только в облаке</span>' : ''}
          </div>
          <span class="badge ${isSelected ? 'selected' : ''}">${isSelected ? '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Выбрана' : '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg>'}</span>
        </div>`;
      }).join('');
      if (data.cloud_error) {
        romsContainer.insertAdjacentHTML('afterbegin', '<div class="cloud-note" style="grid-column:1/-1;font-size:12px;color:var(--text-secondary);padding:4px 2px 8px">⚠️ Облако не ответило: системы, которые есть только в облаке, сейчас не показаны. Откройте вкладку позже.</div>');
      }
    } else {
      romsContainer.innerHTML = '<div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3H4.99c-1.11 0-1.98.9-1.98 2L3 19c0 1.1.88 2 1.99 2H19c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 12h-4c0 1.66-1.35 3-3 3s-3-1.34-3-3H4.99V5H19v10z" fill="currentColor"/></svg>Нет систем с ромами</div>';
    }
    
    const excludeContainer = document.getElementById('excludeList');
    // PortMaster ports: one entry for the saves of all ports, like a system
    const hasPorts = (data.port_saves || []).length > 0;
    const exList = (data.all || []).concat(data.saves_cloud || []).concat((hasPorts || data.port_saves_cloud) ? ['PortMaster'] : []);
    if (exList.length > 0) {
      excludeContainer.innerHTML = exList.map(sys => {
        const isExcluded = data.excluded.includes(sys);
        const isCloudOnly = (data.cloud_only && data.cloud_only.includes(sys)) || (data.saves_cloud && data.saves_cloud.includes(sys)) || (sys === 'PortMaster' && !hasPorts);
        return `<div class="system-item ${isExcluded ? 'excluded' : ''}" onclick="excludeAction('${isExcluded ? 'remove' : 'add'}', '${sys}')">
          <div class="name-wrap">
            <span class="name">${sys}</span>
            ${isCloudOnly ? '<span class="cloud-badge"><svg width="12" height="8" viewBox="0 0 1280 822" style="vertical-align:-1px;margin-right:2px"><g transform="translate(0,822) scale(0.1,-0.1)" fill="currentColor"><path d="M7121 8205 c-484 -56 -926 -221 -1315 -494 -238 -166 -476 -397 -637 -618 -23 -32 -44 -60 -45 -62 -2 -2 -40 8 -84 23 -117 38 -260 73 -385 92 -150 23 -442 23 -590 0 -611 -94 -1127 -423 -1468 -934 -235 -353 -362 -809 -344 -1229 l6 -132 -32 -5 c-18 -3 -72 -10 -122 -16 -413 -50 -861 -242 -1201 -515 -434 -349 -738 -846 -852 -1395 -38 -183 -47 -272 -46 -495 0 -243 14 -368 63 -571 221 -899 936 -1599 1835 -1794 268 -58 -2 -55 4336 -55 3806 0 4011 1 4125 18 649 97 1197 373 1635 824 142 145 217 237 324 396 233 346 381 728 448 1162 18 116 22 183 22 395 0 282 -16 420 -74 657 -180 738 -643 1363 -1298 1752 -333 198 -715 326 -1104 371 -117 14 -118 14 -118 89 0 95 -59 403 -107 556 -75 243 -205 524 -331 715 -452 687 -1140 1129 -1947 1250 -185 28 -520 35 -694 15z"/></g></svg>только в облаке</span>' : ''}
          </div>
          <span class="badge ${isExcluded ? 'excluded' : ''}">${isExcluded ? '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg> Искл.' : '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Синх.'}</span>
        </div>`;
      }).join('');
    } else {
      excludeContainer.innerHTML = '<div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3H4.99c-1.11 0-1.98.9-1.98 2L3 19c0 1.1.88 2 1.99 2H19c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 12h-4c0 1.66-1.35 3-3 3s-3-1.34-3-3H4.99V5H19v10z" fill="currentColor"/></svg>Нет систем с ромами</div>';
    }
    
    const config = await apiFetch('/config');
    document.getElementById('mediaStatus').textContent = config.ROMS_SYNC_MEDIA === 'true' ? 'ВКЛ' : 'ВЫКЛ';
  } catch (e) {
    console.error('Systems error:', e);
  }
}

// ========== ИСКЛЮЧЕНИЯ ==========

async function excludeAction(action, system) {
  if (action === 'clear') {
    if (!confirm('Удалить все исключения?')) return;
  }
  
  try {
    const res = await apiFetch('/exclude', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({action, system})
    });
    if (res.success) {
      showToast(res.message, 'success');
      loadSystems();
      refreshStatus();
    } else {
      showToast((res.error || 'Ошибка'), 'error');
    }
  } catch (e) {
    showToast(netErr(e), 'error');
  }
}

// ========== НАСТРОЙКИ (ТОЛЬКО РУЧНОЕ СОХРАНЕНИЕ) ==========

function setIntervalQuick(seconds) {
  document.getElementById('settingInterval').value = seconds;
}

async function saveSettings() {
  const config = {
    SYNC_INTERVAL: parseInt(document.getElementById('settingInterval').value) || 0,
    MAX_RETRIES: parseInt(document.getElementById('settingRetries').value) || 3,
    CONFLICT_KEEP_DAYS: parseInt(document.getElementById('settingKeepDays').value) || 0,
    NOTIFICATIONS: document.getElementById('settingNotifications').value,
    SYNC_MODE: document.getElementById('settingSyncMode').value,
    LOG_ENABLED: 'true',
    LOG_LEVEL: document.getElementById('settingLogLevel').value
  };
  
  try {
    const res = await apiFetch('/config', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(config)
    });
    if (res.success) {
      showToast('Настройки сохранены', 'success');
      await loadSettings();
    } else {
      showToast((res.error || 'Ошибка'), 'error');
    }
  } catch (e) {
    showToast(netErr(e), 'error');
  }
}

// ========== СТАТИСТИКА ==========

async function refreshStats() {
  // the save statistics are in the status bar at the top; the ROM ones are one line in the ROMs tab
  try {
    const data = await apiFetch('/stats');
    const el = document.getElementById('romsStats');
    if (data && el) {
      const total = data.roms?.total || 0, ok = data.roms?.ok || 0, err = data.roms?.error || 0;
      el.innerHTML =
        '<span class="chip">Операций <b>' + total + '</b></span>' +
        '<span class="chip ok">Успешно <b>' + ok + '</b></span>' +
        '<span class="chip' + (err > 0 ? ' err' : '') + '">Ошибок <b>' + err + '</b></span>';
    }
  } catch (e) {
    console.error('Stats error:', e);
  }
}

// ========== ЗАПУСК ==========

// ========== SAVE CONFLICTS ==========
const CONF_T = {"head": "Конфликты сохранений", "hint": "Эти сохранения изменились на двух устройствах. Синхронизация оставила более новую версию, а другую сохранила здесь. «Вернуть» сделает выбранную версию текущей на всех устройствах; текущая версия при этом тоже сохранится здесь.", "from": "версия с {dev}", "left": "хранится до {until}", "last": "удалится при следующей синхронизации", "notHere": "на этом устройстве этого файла нет", "notSynced": "эта система не синхронизируется на этом устройстве", "restore": "Вернуть", "del": "Удалить", "confirmRestore": "Вернуть версию {file} с {dev} ({time})?\\n\\nОна станет текущей на всех устройствах, а текущая версия сохранится в конфликтах.\\nЕсли эта игра сейчас запущена, сначала выйдите из неё.", "confirmDel": "Удалить копию {file} ({dev}, {time})?\\nВернуть её будет нельзя.", "phase": "Возврат версии", "deleted": "Копия удалена", "badge": "Есть конфликты сохранений"};

async function loadConflicts() {
  const box = document.getElementById('conflictsBox');
  const badge = document.getElementById('conflictsBadge');
  const res = await apiFetch('/conflicts');
  if (!res.success) return;               // the cloud is not reachable: keep what is shown
  const items = res.items || [];
  badge.style.display = items.length ? '' : 'none';
  badge.textContent = items.length;
  if (!items.length) { box.style.display = 'none'; return; }
  document.getElementById('conflictsHead').textContent = CONF_T.head + ' (' + items.length + ')';
  document.getElementById('conflictsHint').textContent = CONF_T.hint;
  window._conflicts = items;
  document.getElementById('conflictsList').innerHTML = items.map((c, i) => {
    const meta = [CONF_T.from.replace('{dev}', c.dev), c.time,
                  c.until ? CONF_T.left.replace('{until}', c.until) : CONF_T.last];
    if (!c.keep) meta.pop();           // this device does not remove copies: other devices decide
    if (!c.synced) meta.push(CONF_T.notSynced);
    else if (!c.here) meta.push(CONF_T.notHere);
    return '<div class="conflict-row"><div class="conflict-info">' +
      '<div class="conflict-file">' + escapeHtml(c.file) + '</div>' +
      '<div class="conflict-meta">' + escapeHtml(meta.join(' · ')) + '</div></div>' +
      '<div class="conflict-actions">' +
      '<button class="btn btn-primary" onclick="conflictRestore(' + i + ')"' + (c.synced ? '' : ' disabled') + '>' + CONF_T.restore + '</button>' +
      '<button class="btn btn-danger" onclick="conflictDelete(' + i + ')">' + CONF_T.del + '</button>' +
      '</div></div>';
  }).join('');
  box.style.display = '';
}

function conflictText(tpl, c) {
  return tpl.replace('{file}', c.file).replace('{dev}', c.dev).replace('{time}', c.time);
}

function conflictRestore(i) {
  const c = (window._conflicts || [])[i];
  if (!c || !confirm(conflictText(CONF_T.confirmRestore, c))) return;
  runSyncWithProgress('conflict_restore', () => apiFetch('/conflicts/restore', {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({id: c.id})
  }));
}

async function conflictDelete(i) {
  const c = (window._conflicts || [])[i];
  if (!c || !confirm(conflictText(CONF_T.confirmDel, c))) return;
  const res = await apiFetch('/conflicts/delete', {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({id: c.id})
  });
  showToast(res.success ? CONF_T.deleted : (res.error || 'Error'), res.success ? 'success' : 'error');
  loadConflicts();
}

loadTheme();
loadSettings();        // загружаем настройки один раз при старте
refreshStatus();
refreshLogs();
refreshStats();
loadSystems();         // ЗАГРУЖАЕМ СИСТЕМЫ ПРИ СТАРТЕ
loadConflicts();

// Автообновление (настройки НЕ обновляются)
// ========== DOWNLOAD FROM A PUBLIC LINK ==========
const LINK_T = {"enterUrl": "Сначала вставьте ссылку", "loading": "Получаю список файлов… для больших папок это может занять минуту.", "needPw": "Ссылка защищена паролем: введите пароль и нажмите «Открыть».", "empty": "По ссылке нет файлов.", "files": "файлов", "nothingSel": "Отметьте файлы или папки, которые нужно скачать", "selected": "Выбрано: {n}", "free": "свободно на карте: {free}", "noSpace": "не хватает места", "contents": "Содержимое «{name}» будет помещено в {dest}", "items": "Выбранное будет помещено в {dest}", "chooseDest": "— выберите систему —", "needDest": "Выберите, куда положить файлы", "phase": "Загрузка по ссылке", "done": "Загрузка по ссылке завершена", "failed": "Загрузка по ссылке не удалась", "unavailable": "Загрузка по ссылке недоступна на этом устройстве (нет python3 или link_download.py).", "selectAll": "Выбрать все", "root": "корень", "nfiles": "файлов: {n}", "grpDeviceFiles": "Системы с играми (ром-файлами)", "grpDeviceOther": "Системы без игр", "grpCloudFiles": "Системы в облаке", "grpCloudOther": "Добавить новую систему в облако", "freeCloud": "свободно в облаке: {free}", "cloudLabel": "облако: GameROMs/{sys}", "cloudNote": "Потом перенесите на устройство: Ромы → выбрать систему → Загрузить ромы.", "cloudUnavailable": "Облако недоступно: Save Sync не настроен или rclone не запускается.", "loadingDests": "загрузка…", "zipMeta": "архив · нажмите, чтобы открыть", "zipReading": "Читаю архив «{name}»…", "zipContents": "Архив «{name}» будет распакован в {dest}", "zipItems": "Выбранное из архива будет распаковано в {dest}", "zipAsIs": "Архивы скачаются как есть, без распаковки. Картриджные приставки обычно запускают .zip/.7z сами. Нужны отдельные игры — откройте zip или включите «Распаковать архивы».", "unpackLabel": "Распаковать архивы после скачивания ({kinds})", "arcMeta": "архив {kind}", "unpackYes": "{kinds}: будут распакованы в папку системы, сами архивы удалятся", "unpackCannot": "{kinds}: на этом устройстве нечем распаковать — скачаются как есть", "unpackCloud": "Для облака: файлы из .zip берутся прямо из архива, а .7z/.rar сначала ненадолго скачиваются на карту, распаковываются и выгружаются — нужно свободное место примерно в 3 раза больше архива."};
const LINK_ICON_DIR = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>';
const LINK_ICON_ZIP = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d="M20 6h-8l-2-2H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-2 6h-2v2h2v2h-2v2h-2v-2h2v-2h-2v-2h2v-2h-2V8h2v2h2v2z" fill="currentColor"/></svg>';
const LINK_ICON_FILE = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d="M14 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6zm-1 7V3.5L18.5 9H13z" fill="currentColor"/></svg>';
let linkState = { url: '', service: '', root: null, stack: [], password: '', target: 'device', dests: {} };

function linkFmt(s, vars) {
    Object.keys(vars).forEach(k => { s = s.split('{' + k + '}').join(vars[k]); });
    return s;
}

function linkSetStatus(text, isError) {
    const el = document.getElementById('linkStatus');
    el.textContent = text || '';
    el.className = 'link-status' + (isError ? ' error' : '');
}

async function linkLoadDests(target) {
    const d = await apiFetch('/link/dests?target=' + target);
    if (d && d.success !== false) linkState.dests[target] = d;
    return d || {};
}

async function linkInit() {
    const d = await linkLoadDests('device');
    if (!d || d.success === false) return;
    if (!d.link_available) {
        linkSetStatus(LINK_T.unavailable, true);
        document.getElementById('linkOpenBtn').disabled = true;
    }
    linkFillDests();
    // A download started earlier (e.g. before the page was reloaded) - show its progress
    if (d.running) runSyncWithProgress('link_download', async () => ({ success: true }));
}

function linkFillDests() {
    const d = linkState.dests[linkState.target] || {};
    const cloud = linkState.target === 'cloud';
    const sel = document.getElementById('linkDest');
    const keep = sel.value;
    sel.innerHTML = '';
    const opt = (parent, value, label) => { const o = document.createElement('option'); o.value = value; o.textContent = label; parent.appendChild(o); };
    const group = (label, list) => {
        if (!list || !list.length) return;
        const g = document.createElement('optgroup');
        g.label = label;
        list.forEach(s => opt(g, s, s));
        sel.appendChild(g);
    };
    opt(sel, '', LINK_T.chooseDest);
    group(cloud ? LINK_T.grpCloudFiles : LINK_T.grpDeviceFiles, d.with_files);
    group(cloud ? LINK_T.grpCloudOther : LINK_T.grpDeviceOther, d.others);
    if (keep && Array.from(sel.options).some(o => o.value === keep)) sel.value = keep;
}

async function linkTargetChanged() {
    const radio = document.querySelector('input[name="linkTarget"]:checked');
    const target = radio ? radio.value : 'device';
    linkState.target = target;
    if (target === 'cloud' && !linkState.dests.cloud) {
        const sel = document.getElementById('linkDest');
        sel.innerHTML = '<option value="">' + escapeHtml(LINK_T.loadingDests) + '</option>';
        sel.disabled = true;
        const d = await linkLoadDests('cloud');
        sel.disabled = false;
        if (!d.available) {
            delete linkState.dests.cloud;
            showToast(LINK_T.cloudUnavailable, 'error');
            document.querySelector('input[name="linkTarget"][value="device"]').checked = true;
            linkState.target = 'device';
        }
    }
    linkFillDests();
    if (linkState.root) linkUpdateSummary();
}

async function linkOpen() {
    const url = document.getElementById('linkUrl').value.trim();
    if (!url) { showToast(LINK_T.enterUrl, 'error'); return; }
    const pw = document.getElementById('linkPw').value;
    const btn = document.getElementById('linkOpenBtn');
    btn.disabled = true;
    linkSetStatus(LINK_T.loading, false);
    document.getElementById('linkBrowser').style.display = 'none';
    const res = await apiFetch('/link/list', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url, password: pw })
    });
    btn.disabled = false;
    if (res.need_password) {
        document.getElementById('linkPwRow').style.display = 'flex';
        linkSetStatus(pw ? res.error : LINK_T.needPw, true);
        document.getElementById('linkPw').focus();
        return;
    }
    if (res.error || !res.root) { linkSetStatus(res.error || 'Error', true); return; }
    if (res.root.dir && !res.root.files) { linkSetStatus(LINK_T.empty, true); return; }
    linkState = { url: url, service: res.service, root: res.root, stack: [res.root], password: pw,
                  target: linkState.target, dests: linkState.dests };
    linkSetStatus('', false);
    if (!pw) document.getElementById('linkPwRow').style.display = 'none';
    document.getElementById('linkBrowser').style.display = 'block';
    linkRender();
    linkLoadDests(linkState.target).then(() => { linkFillDests(); linkUpdateSummary(); });
}

function linkCurrent() { return linkState.stack[linkState.stack.length - 1]; }

function linkRender() {
    const cur = linkCurrent();
    // breadcrumbs
    const crumbs = document.getElementById('linkCrumbs');
    crumbs.innerHTML = '';
    linkState.stack.forEach((e, i) => {
        if (i > 0) crumbs.appendChild(document.createTextNode(' / '));
        const label = (i === 0 ? linkState.service + ': ' : '') + (e.name || LINK_T.root);
        if (i < linkState.stack.length - 1) {
            const a = document.createElement('a');
            a.textContent = label;
            a.onclick = () => { linkState.stack = linkState.stack.slice(0, i + 1); linkRender(); };
            crumbs.appendChild(a);
        } else {
            crumbs.appendChild(document.createTextNode(label));
        }
    });
    // list
    const list = document.getElementById('linkList');
    list.innerHTML = '';
    const items = cur.dir ? (cur.children || []) : [cur];
    if (cur.dir && items.length > 1) {
        const row = document.createElement('label');
        row.className = 'link-row';
        row.innerHTML = '<input type="checkbox" id="linkAll"><span class="link-name" style="color:var(--text-secondary)">' + escapeHtml(LINK_T.selectAll) + '</span>';
        row.querySelector('input').onchange = (ev) => {
            list.querySelectorAll('input[data-idx]').forEach(cb => cb.checked = ev.target.checked);
            linkUpdateSummary();
        };
        list.appendChild(row);
    }
    items.forEach((e, idx) => {
        const row = document.createElement('div');
        row.className = 'link-row';
        const meta = e.dir ? (linkFmt(LINK_T.nfiles, { n: e.files }) + ' · ' + formatBytes(e.size))
                   : e.zip ? (formatBytes(e.size) + ' · ' + LINK_T.zipMeta)
                   : e.arc ? (formatBytes(e.size) + ' · ' + linkFmt(LINK_T.arcMeta, { kind: e.arc })) : formatBytes(e.size);
        row.innerHTML = (cur.dir ? '<input type="checkbox" data-idx="' + idx + '">' : '') +
            (e.dir ? LINK_ICON_DIR : (e.zip || e.arc) ? LINK_ICON_ZIP : LINK_ICON_FILE) +
            '<span class="link-name' + (e.dir || e.zip ? ' dir' : '') + '" title="' + escapeHtml(e.name) + '">' + escapeHtml(e.name) + '</span>' +
            '<span class="link-meta">' + escapeHtml(meta) + '</span>';
        const cb = row.querySelector('input');
        if (cb) cb.onchange = linkUpdateSummary;
        if (e.dir) row.querySelector('.link-name').onclick = () => { linkState.stack.push(e); linkRender(); };
        else if (e.zip) row.querySelector('.link-name').onclick = () => linkOpenZip(e);
        list.appendChild(row);
    });
    linkUpdateSummary();
}

// A .zip is opened like a folder: only its list is read, the chosen files are
// taken from the archive and unpacked during the download.
async function linkOpenZip(e) {
    if (!e.view) {
        linkSetStatus(linkFmt(LINK_T.zipReading, { name: e.name }), false);
        const res = await apiFetch('/link/zip', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: linkState.url, password: linkState.password, path: e.path })
        });
        if (res.error || !res.entry) { linkSetStatus(res.error || 'Error', true); return; }
        linkSetStatus('', false);
        e.view = res.entry;
    }
    linkState.stack.push(e.view);
    linkRender();
}

function linkInZip() { return linkState.stack.some(x => (x.path || '').endsWith('/')); }

function linkSelected() {
    const cur = linkCurrent();
    if (!cur.dir) return [cur];
    const out = [];
    document.querySelectorAll('#linkList input[data-idx]:checked').forEach(cb => out.push(cur.children[parseInt(cb.dataset.idx)]));
    return out;
}

function linkUpdateSummary() {
    const cur = linkCurrent();
    const sel = linkSelected();
    const all = document.getElementById('linkAll');
    if (all) all.checked = cur.dir && sel.length > 0 && sel.length === (cur.children || []).length;
    if (cur.dir && !sel.length) {
        document.getElementById('linkUnpackRow').style.display = 'none';
        document.getElementById('linkSummary').innerHTML = '<div>' + escapeHtml(LINK_T.nothingSel) + '</div>';
        return;
    }
    const picked = sel;
    let files = 0, size = 0;
    picked.forEach(e => { files += e.dir ? e.files : 1; size += e.size || 0; });
    const cloud = linkState.target === 'cloud';
    const dest = document.getElementById('linkDest').value;
    const destLabel = dest ? (cloud ? linkFmt(LINK_T.cloudLabel, { sys: dest }) : 'roms/' + dest) : '…';
    const totals = ' · ' + linkFmt(LINK_T.nfiles, { n: files }) + ' · ' + formatBytes(size);
    const lines = [];
    lines.push({ text: (cur.dir ? linkFmt(LINK_T.selected, { n: sel.length }) : cur.name) + totals });
    const allSel = cur.dir && sel.length > 1 && sel.length === (cur.children || []).length;
    const inZip = linkInZip();
    if (!allSel && (!cur.dir || sel.length > 1 || !sel[0].dir)) {
        lines.push({ text: linkFmt(inZip ? LINK_T.zipItems : LINK_T.items, { dest: destLabel }) });
    } else {
        const folder = allSel ? cur : sel[0];
        const whole = (folder.path || '').endsWith('/');
        lines.push({ text: linkFmt(whole ? LINK_T.zipContents : inZip ? LINK_T.zipItems : LINK_T.contents,
                                   { name: folder.name || LINK_T.root, dest: destLabel }) });
    }
    // archives among what is downloaded (also inside ticked folders)
    const kinds = [];
    const scan = e => { if (e.arc && !kinds.includes(e.arc)) kinds.push(e.arc); (e.children || []).forEach(scan); };
    (cur.dir ? sel : [cur]).forEach(scan);
    const order = ['zip', '7z', 'rar'];
    kinds.sort((a, b) => order.indexOf(a) - order.indexOf(b));
    const row = document.getElementById('linkUnpackRow');
    const showUnpack = kinds.length > 0;
    row.style.display = showUnpack ? 'flex' : 'none';
    if (showUnpack) {
        const dot = k => '.' + k;
        document.getElementById('linkUnpackText').textContent = linkFmt(LINK_T.unpackLabel, { kinds: kinds.map(dot).join(', ') });
        if (document.getElementById('linkUnpack').checked) {
            const able = ((linkState.dests.device || {}).unpack) || ['zip'];
            const can = kinds.filter(k => able.includes(k)), cannot = kinds.filter(k => !able.includes(k));
            if (can.length) lines.push({ text: linkFmt(LINK_T.unpackYes, { kinds: can.map(dot).join(', ') }) });
            if (cannot.length) lines.push({ text: linkFmt(LINK_T.unpackCannot, { kinds: cannot.map(dot).join(', ') }) });
            if (cloud && can.length) lines.push({ text: LINK_T.unpackCloud });
        } else {
            lines.push({ text: LINK_T.zipAsIs });
        }
    }
    const d = linkState.dests[linkState.target] || {};
    if (d.free !== null && d.free !== undefined) {
        const warn = size > d.free;
        lines.push({ text: (warn ? LINK_T.noSpace + ' — ' : '') + linkFmt(cloud ? LINK_T.freeCloud : LINK_T.free, { free: formatBytes(d.free) }), warn: warn });
    }
    if (cloud) {
        lines.push({ text: LINK_T.cloudNote });
    }
    document.getElementById('linkSummary').innerHTML =
        lines.map(l => '<div' + (l.warn ? ' class="warn"' : '') + '>' + escapeHtml(l.text) + '</div>').join('');
}

async function linkDownload() {
    const dest = document.getElementById('linkDest').value;
    if (!dest) { showToast(LINK_T.needDest, 'error'); return; }
    const cur = linkCurrent();
    const sel = linkSelected();
    if (cur.dir && !sel.length) { showToast(LINK_T.nothingSel, 'error'); return; }
    // everything in the open folder ticked = that folder's contents (same result, shorter command)
    const allSel = cur.dir && sel.length > 1 && sel.length === (cur.children || []).length;
    const items = !cur.dir ? [] : allSel ? (cur === linkState.root ? [] : [cur.path]) : sel.map(e => e.path);
    const bar = document.getElementById('syncProgressLink');
    runSyncWithProgress('link_download', async () => {
        const res = await apiFetch('/link/download', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: linkState.url, dest: dest, items: items, password: linkState.password,
                                   target: linkState.target,
                                   unpack: document.getElementById('linkUnpackRow').style.display !== 'none'
                                           && document.getElementById('linkUnpack').checked })
        });
        return res;
    });
    setTimeout(() => { if (bar) bar.scrollIntoView({ behavior: 'smooth', block: 'center' }); }, 100);
}

function linkFinished(data) {
    const ok = !!data.success;
    const text = ok ? ((data.phase && data.phase !== LINK_T.phase) ? data.phase : LINK_T.done)
                    : (data.phase && data.phase !== LINK_T.phase ? data.phase : LINK_T.failed);
    const icon = ok ? '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> '
                    : '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ';
    showProgress(true, icon + escapeHtml(text), 'link');
    if (ok) updateProgressBar({ ...data, percent: 100, totalBytes: data.totalBytes || 1 }, 'link');
    showToast(text, ok ? 'success' : 'error');
    setTimeout(() => {
        showProgress(false);
        refreshLogs();
        setButtonsDisabled(false);
        linkLoadDests(linkState.target).then(() => { linkFillDests(); if (linkState.root) linkUpdateSummary(); });
    }, ok ? 2500 : 5000);
}

// ========== CANCEL A RUNNING OPERATION ==========
const OP_T = {"cancelling": "Отменяю…", "cancelled": "Операция отменена"};

function opCancelShow(on) {
    document.querySelectorAll('.op-cancel').forEach(b => {
        if (!b.dataset.label) b.dataset.label = b.textContent;
        b.textContent = b.dataset.label;
        b.style.display = on ? '' : 'none';
        b.disabled = !on;
    });
}

async function cancelOperation() {
    document.querySelectorAll('.op-cancel').forEach(b => { b.disabled = true; b.textContent = OP_T.cancelling; });
    const r = await apiFetch('/cancel', { method: 'POST' });
    if (!r.success) {
        showToast(r.error || 'Ошибка', 'error');
        opCancelShow(true);
    }
}

function opCancelled(target) {
    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + escapeHtml(OP_T.cancelled), target);
    showToast(OP_T.cancelled, 'warning');
    setTimeout(() => {
        showProgress(false);
        refreshStatus();
        refreshLogs();
        refreshStats();
        setButtonsDisabled(false);
    }, 2500);
}

linkInit();
setInterval(refreshStatus, 10000);
setInterval(refreshStats, 10000);
</script>
</body>
</html>'''

class QuietHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    # Многопоточный сервер: медленная проверка облака в /api/status
    # не блокирует остальные запросы (загрузку страницы, логи, прогресс).
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Клиент (телефон/браузер) оборвал соединение посреди запроса -
        # обычное дело при слабом Wi-Fi или закрытии вкладки, не ошибка
        # сервера. Не засоряем консоль трейсбеком в этом случае, но
        # оставляем вывод для действительно неожиданных ошибок.
        # ВАЖНО: handle_error - это метод СЕРВЕРА (socketserver.BaseServer),
        # а не обработчика запроса, поэтому переопределять его нужно здесь,
        # а не в классе Handler.
        exc_type = sys.exc_info()[0]
        if exc_type in (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            return
        super().handle_error(request, client_address)

if __name__ == "__main__":
    ip = "0.0.0.0"
    port = 8080
    
    # Получаем IP так же, как в диагностике
    try:
        result = subprocess.run(['ip', '-4', 'addr', 'show'], capture_output=True, text=True)
        import re
        ips = re.findall(r'inet\s+(\d+\.\d+\.\d+\.\d+)', result.stdout)
        ip_addr = next((ip for ip in ips if not ip.startswith('127.')), 'localhost')
    except:
        ip_addr = 'localhost'
    
    print(f"\n✅ Save Sync Web UI v1.4.7 запущен")
    print(f"🌐 Откройте: http://{ip_addr}:{port}")
    print(f"⏹️  Ctrl+C для остановки\n")
    
    server = QuietHTTPServer((ip, port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n⏹️  Сервер остановлен")
EOF

    # Подставляем реальные пути текущей системы вместо плейсхолдеров.
    # Без этого веб-интерфейс работал бы только на Batocera/KNULLI.
    sed -i \
        -e "s|__SS_BASE__|$BASE|g" \
        -e "s|__SS_CONFIG_FILE__|$CONFIG_FILE|g" \
        -e "s|__SS_LOG_FILE__|$LOG_FILE|g" \
        -e "s|__SS_SAVE_DIR__|$SAVE_DIR|g" \
        -e "s|__SS_ROMS_DIR__|$ROMS_DIR|g" \
        -e "s|__SS_STATUS_FILE__|$STATUS_FILE|g" \
        -e "s|__SS_DOWNLOAD_SCRIPT__|$DOWNLOAD_SCRIPT|g" \
        -e "s|__SS_UPLOAD_SCRIPT__|$UPLOAD_SCRIPT|g" \
        -e "s|__SS_DOWNLOAD_ROMS__|$DOWNLOAD_ROMS|g" \
        -e "s|__SS_UPLOAD_ROMS__|$UPLOAD_ROMS|g" \
        -e "s|__SS_ROMS_FILTER_FILE__|$ROMS_FILTER_FILE|g" \
        -e "s|__SS_LAST_SYNC_TIME__|$LAST_SYNC_TIME|g" \
        -e "s|__SS_RCLONE_PATH__|$RCLONE_PATH|g" \
        -e "s|__SS_RCLONE_CONF__|$RCLONE_CONF|g" \
        -e "s|__SS_REMOTE_ROMS__|$REMOTE_ROMS|g" \
        -e "s|__SS_REMOTE_SAVES__|$REMOTE|g" \
        -e "s|__SS_LINK_SCRIPT__|$LINK_SCRIPT|g" \
        "$WEB_DIR/server.py"

    # Запускаем сервер
    cd "$WEB_DIR" || { echo "❌ Не удалось перейти в $WEB_DIR"; return 1; }
    python3 server.py &
    WEB_PID=$!
    echo $WEB_PID > /tmp/save_sync_web.pid
    
    # Ждем завершения
    wait $WEB_PID
    
    # Очистка
    rm -f /tmp/save_sync_web.pid
    rm -rf "$WEB_DIR"
    echo ""
    echo "✅ Веб-сервер остановлен"
}

# === ОБРАБОТКА КОМАНД ===
if [ "$1" = "--web" ] || [ "$1" = "--webui" ]; then
    start_web
    exit 0
fi
    
############################################
# Режим диагностики
############################################

if [ "$1" = "--info" ]; then
    # Загружаем конфиг
    load_config
    
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " Save Sync Diagnostics v1.4.7"
    echo " Система: $SYSTEM"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    ERRORS=0
    WARNINGS=0

    # Считаем длину строки в реальных символах, а не байтах — на
    # системах с локалью C/POSIX (часто на Recalbox/embedded) обычный
    # ${#label} считает БАЙТЫ, а не символы, и кириллица (2 байта на
    # символ в UTF-8) ломает выравнивание столбцов.
    utf8_strlen() {
        local str="$1"
        local len=0
        local i=0
        local byte
        local LC_ALL=C
        while [ $i -lt ${#str} ]; do
            byte=$(printf '%d' "'${str:$i:1}")
            if [ $byte -lt 128 ] || [ $byte -ge 192 ]; then
                len=$((len+1))
            fi
            i=$((i+1))
        done
        echo "$len"
    }

    print_2col() {
        local label="$1"
        local value="$2"
        local label_len
        label_len=$(utf8_strlen "$label")
        local col1_width=20
        local spaces=$((col1_width - label_len))
        [ $spaces -lt 1 ] && spaces=1
        printf "  %s:%${spaces}s %s\n" "$label" "" "$value"
    }

    # ============================================
    # 1. УСТРОЙСТВО И СИСТЕМА
    # ============================================
    echo "── УСТРОЙСТВО И СИСТЕМА ──"
    print_2col "Устройство" "${DEVICE_NAME:-неизвестно}"
    print_2col "Процессор" "${DEVICE_CPU:-неизвестно}"
    print_2col "Архитектура" "${DEVICE_ARCH:-неизвестно}"
    print_2col "Прошивка" "$SYSTEM (${CFW_VERSION:-неизвестно})"
    print_2col "Ядро" "$(uname -r)"
    print_2col "CPU Ядер" "${CPU_CORES:-неизвестно}"
    print_2col "CPU Частота" "${CPU_FREQ:-неизвестно}"
    print_2col "Температура" "${DEVICE_TEMP:-неизвестно}"
    print_2col "Доступно памяти" "${MEM_INFO:-неизвестно}"
    echo ""

    # ============================================
    # 2. ОБЛАКО И СИНХРОНИЗАЦИЯ
    # ============================================
    echo "── ОБЛАКО И СИНХРОНИЗАЦИЯ ──"
    
    # Статус облака
    if [ -f "$RCLONE_PATH" ] && [ -f "$RCLONE_CONF" ]; then
        if "$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_NAME:" --contimeout 5s >/dev/null 2>&1; then
            CLOUD_STATUS="✅ доступно"
        else
            CLOUD_STATUS="❌ нет подключения"
            ERRORS=$((ERRORS+1))
        fi
    else
        CLOUD_STATUS="❌ не настроено"
        ERRORS=$((ERRORS+1))
    fi
    print_2col "Статус" "$CLOUD_STATUS"
    
    # Использование облака
    CLOUD_ABOUT=$(cloud_about)
    CLOUD_USED=$(printf '%s\n' "$CLOUD_ABOUT" | grep -i "^used" | awk '{print $2, $3}')
    CLOUD_TOTAL=$(printf '%s\n' "$CLOUD_ABOUT" | grep -i "^total" | awk '{print $2, $3}')
    CLOUD_FREE=$(printf '%s\n' "$CLOUD_ABOUT" | grep -i "^free" | awk '{print $2, $3}')
    print_2col "Использовано" "${CLOUD_USED:-$(cloud_free_unknown)}"
    print_2col "Всего" "${CLOUD_TOTAL:-$(cloud_free_unknown)}"
    print_2col "Свободно" "${CLOUD_FREE:-$(cloud_free_unknown)}"
    
    # Последняя синхронизация
    if [ -f "$STATUS_FILE" ]; then
        read -r STATUS STATUS_TIME < "$STATUS_FILE" 2>/dev/null
        TIME_STR=$(date -d @$STATUS_TIME "+%d.%m.%Y %H:%M" 2>/dev/null || echo "неизвестно")
        if [ "$STATUS" = "OK" ]; then
            LAST_SYNC_STATUS="✅ успешно ($TIME_STR)"
        elif [ "$STATUS" = "ERROR" ]; then
            LAST_SYNC_STATUS="❌ ошибка ($TIME_STR)"
            ERRORS=$((ERRORS+1))
        else
            LAST_SYNC_STATUS="неизвестно"
        fi
    else
        LAST_SYNC_STATUS="⏳ ещё не выполнялась"
    fi
    print_2col "Обновлено" "$LAST_SYNC_STATUS"
    
    # Статистика синхронизаций
    sync_stats_counts
    print_2col "Статистика" "$SYNC_NOCHG синхр. ($SYNC_CHG OK, $SYNC_ERR ERR)"
    if [ "$SYNC_ERR" -gt 0 ]; then
        WARNINGS=$((WARNINGS + SYNC_ERR))
    fi
    echo ""

    # ============================================
    # 3. СЕТЬ
    # ============================================
    echo "── СЕТЬ ──"
    
    # IP-адрес
    IP_ADDR=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
    print_2col "IP-адрес" "${IP_ADDR:-неизвестно}"
    
    # WiFi
    SSID=$(iwconfig 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$SSID" ] && print_2col "WiFi" "$SSID"
    
    # Интернет: время TCP-соединения, не ping - в некоторых сетях ping закрыт
    if CONNECT_TIME=$(curl -s -o /dev/null -m 5 -w '%{time_connect}' http://1.1.1.1 2>/dev/null); then
        PING_TIME=$(awk -v t="$CONNECT_TIME" 'BEGIN{printf "%d", t*1000}')
        print_2col "Интернет" "✅ доступен (${PING_TIME}мс)"
    else
        print_2col "Интернет" "❌ недоступен"
        ERRORS=$((ERRORS+1))
    fi
    echo ""

    # ============================================
    # 4. ПРОГРАММНОЕ ОБЕСПЕЧЕНИЕ
    # ============================================
    echo "── ПРОГРАММНОЕ ОБЕСПЕЧЕНИЕ ──"
    
    # Rclone
    if [ -f "$RCLONE_PATH" ]; then
        VER=$("$RCLONE_PATH" version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
        print_2col "Rclone" "✅ найден (v$VER)"
    else
        print_2col "Rclone" "❌ не найден"
        ERRORS=$((ERRORS+1))
    fi
    
    # Конфиг rclone
    if [ -f "$RCLONE_CONF" ]; then
        print_2col "Конфиг rclone" "✅ найден"
    else
        print_2col "Конфиг rclone" "❌ не найден"
        ERRORS=$((ERRORS+1))
    fi
    
    # Скрипты
    if [ "$SYSTEM" = "Recalbox" ]; then
        HOOK_SCRIPT_PATH="/recalbox/share/userscripts/save-sync[endgame].sh"
    else
        HOOK_SCRIPT_PATH="$SCRIPT_DIR/save-sync.sh"
    fi
    for SCRIPT in "$DOWNLOAD_SCRIPT" "$UPLOAD_SCRIPT" "$DOWNLOAD_ROMS" "$UPLOAD_ROMS" "$HOOK_SCRIPT_PATH"; do
        SCRIPT_NAME=$(basename "$SCRIPT")
        if [ -f "$SCRIPT" ]; then
            if [ -x "$SCRIPT" ]; then
                print_2col "$SCRIPT_NAME" "✅ найден, права OK"
            else
                # Даже без бита +x скрипт запустится нормально — все внутренние
                # вызовы идут через "bash script.sh", а не напрямую (важно для
                # разделов с noexec, например /recalbox/share на Recalbox)
                print_2col "$SCRIPT_NAME" "✅ найден (запуск через bash)"
            fi
            else
        print_2col "$SCRIPT_NAME" "❌ не найден"
        ERRORS=$((ERRORS+1))
    fi
done

# Public-link downloader (Python, started via python3)
if [ -f "$LINK_SCRIPT" ]; then
    print_2col "$(basename "$LINK_SCRIPT")" "✅ найден"
else
    print_2col "$(basename "$LINK_SCRIPT")" "❌ не найден"
    ERRORS=$((ERRORS+1))
fi

# Two-way save sync (Python)
if [ -f "$ENGINE_SCRIPT" ]; then
    print_2col "$(basename "$ENGINE_SCRIPT")" "✅ найден"
else
    print_2col "$(basename "$ENGINE_SCRIPT")" "❌ не найден"
    ERRORS=$((ERRORS+1))
fi
if command -v python3 >/dev/null 2>&1; then
    print_2col "python3" "✅ найден"
else
    print_2col "python3" "❌ не найден - сохранения не синхронизируются"
    ERRORS=$((ERRORS+1))
fi

# Автозагрузка сохранений
AUTOLOAD_FOUND=false
if [ -f "$BASE/custom.sh" ]; then
    if grep -q "download_sync.sh" "$BASE/custom.sh" 2>/dev/null; then
        print_2col "Автозагрузка" "✅ настроен (custom.sh)"
        AUTOLOAD_FOUND=true
    fi
fi
if [ -f "$BASE/services/custom_service" ]; then
    if grep -q "download_sync.sh" "$BASE/services/custom_service" 2>/dev/null; then
        if [ "$AUTOLOAD_FOUND" = false ]; then
            print_2col "Автозагрузка" "✅ настроен (custom_service)"
            AUTOLOAD_FOUND=true
        fi
    fi
fi
if [ "$AUTOLOAD_FOUND" = false ]; then
    print_2col "Автозагрузка" "❌ не найден"
    ERRORS=$((ERRORS+1))
fi

# Автозагрузка веб-интерфейса
WEB_AUTOLOAD=false
if [ -f "$BASE/custom.sh" ]; then
    if grep -q "install_sync.sh --web" "$BASE/custom.sh" 2>/dev/null; then
        print_2col "Автозагрузка (веб)" "✅ настроен (custom.sh)"
        WEB_AUTOLOAD=true
    fi
fi
if [ -f "$BASE/services/custom_service" ]; then
    if grep -q "install_sync.sh --web" "$BASE/services/custom_service" 2>/dev/null; then
        if [ "$WEB_AUTOLOAD" = false ]; then
            print_2col "Автозагрузка (веб)" "✅ настроен (custom_service)"
            WEB_AUTOLOAD=true
        fi
    fi
fi
if [ "$WEB_AUTOLOAD" = false ]; then
    print_2col "Автозагрузка (веб)" "❌ не настроен"
    # Это не ошибка, просто информация
fi
echo ""

    # ============================================
    # 5. КОНФИГУРАЦИЯ И ЛОГИ
    # ============================================
    echo "── КОНФИГУРАЦИЯ И ЛОГИ ──"
    
    # Конфиг
    if [ -f "$CONFIG_FILE" ]; then
        print_2col "Главный конфиг" "✅ найден"
        print_2col "Интервал" "$SYNC_INTERVAL сек"
        print_2col "Попытки" "$MAX_RETRIES"
        print_2col "Копии при конфликтах" "$(keep_days_label)"
        print_2col "Уведомления" "$(notify_label)"
        print_2col "После игры" "$(sync_mode_label)"
        print_2col "Исключения" "${EXCLUDED_SYSTEMS:-нет}"
    else
        print_2col "Главный конфиг" "❌ не найден"
        ERRORS=$((ERRORS+1))
    fi
    
    # Лог
    if [ -f "$LOG_FILE" ]; then
        LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        print_2col "Лог" "✅ найден ($LINES записей, ${LOG_SIZE} байт)"
    else
        print_2col "Лог" "ℹ️ не создан"
    fi
    
    # Фильтр ромов
    if [ -n "$ROMS_SYNC_DIRS" ] && [ -f "$ROMS_FILTER_FILE" ]; then
        print_2col "Фильтр ромов" "✅ настроен"
    elif [ -n "$ROMS_SYNC_DIRS" ] && [ ! -f "$ROMS_FILTER_FILE" ]; then
        print_2col "Фильтр ромов" "⚠️ не создан (пересоздайте)"
        WARNINGS=$((WARNINGS+1))
    else
        print_2col "Фильтр ромов" "ℹ️ нет выбранных систем"
    fi
    
    # Копирование медиа
    if [ "$ROMS_SYNC_MEDIA" = "true" ]; then
        print_2col "Копирование медиа" "✅ включено"
    else
        print_2col "Копирование медиа" "❌ выключено"
    fi
    echo ""

    # ============================================
    # 6. ПОСЛЕДНИЕ ЗАПИСИ ЛОГА
    # ============================================
    echo "── ПОСЛЕДНИЕ ЗАПИСИ ЛОГА ──"
    if [ -f "$LOG_FILE" ]; then
        TOTAL_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        echo "  Всего записей: $TOTAL_LINES"
        echo "──────────────────────────────────────────────────────────"
        tail -10 "$LOG_FILE" 2>/dev/null | while read line; do
            echo "  $line"
        done
        echo "──────────────────────────────────────────────────────────"
        echo "  📄 Полный лог: $LOG_FILE"
    else
        echo "  ❌ Лог-файл не найден"
    fi
    echo ""

    # ============================================
    # 7. ИТОГ
    # ============================================
    echo "══════════════════════════════════════════════════════════"
    echo " ИТОГ:"
    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo "✅ Всё работает корректно."
    elif [ $ERRORS -eq 0 ] && [ $WARNINGS -gt 0 ]; then
        echo "⚠️ Обнаружены предупреждения: $WARNINGS"
        echo "   Скрипт работает, но есть моменты, требующие внимания."
    else
        echo "❌ Обнаружены ошибки: $ERRORS, предупреждения: $WARNINGS"
        echo "   Рекомендуется исправить ошибки для корректной работы."
    fi
    echo "══════════════════════════════════════════════════════════"
    exit 0
fi

############################################
# Режим центра управления
############################################

if [ "$1" = "--config" ]; then
    show_control_panel
    exit 0
fi

############################################
# Проверка: уже установлен?
############################################

if [ -f "$RCLONE_CONF" ] && [ -f "$DOWNLOAD_SCRIPT" ] && [ -f "$UPLOAD_SCRIPT" ]; then
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " Save Sync уже установлен ($SYSTEM)"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo " 1 - Обновить до v1.4.7"
    echo " 2 - Переустановить заново"
    echo " 3 - Выход"
    echo ""
    read -p "Выберите вариант (1-3): " REINSTALL_CHOICE
    case "$REINSTALL_CHOICE" in
    1)
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📦 Обновление до v1.4.7"
        echo "══════════════════════════════════════════════════════════"
        echo ""

        if [ ! -f "$CONFIG_FILE" ]; then
            create_default_config
            echo "✅ Создан sync.conf"
        else
            echo "✅ Конфиг уже существует, настройки сохранены"
        fi
        
        create_download_script
        echo "✅ Обновлен download_sync.sh"
        
        create_upload_script
        echo "✅ Обновлен upload_sync.sh"
        
        create_roms_scripts
        echo "✅ Обновлены скрипты ромов"
        
        create_hook_script
        echo "✅ Обновлен хук"
        
        # ============================================
        # НАСТРОЙКА АВТОЗАГРУЗКИ (ОБНОВЛЕНИЕ)
        # ============================================
        
        # Определяем какой файл использовать для автозагрузки
        case "$SYSTEM" in
            Batocera)
                AUTOLOAD_FILE="$BASE/services/custom_service"
                mkdir -p "$BASE/services"
                ;;
            KNULLI)
                AUTOLOAD_FILE="$BASE/custom.sh"
                ;;
            *)
                AUTOLOAD_FILE="$BASE/custom.sh"
                ;;
        esac
        
        # Создаём файл если его нет
        if [ ! -f "$AUTOLOAD_FILE" ]; then
            echo '#!/bin/bash' > "$AUTOLOAD_FILE"
            chmod +x "$AUTOLOAD_FILE"
            echo "✅ Создан $(basename $AUTOLOAD_FILE)"
        fi
        
        # Добавляем download_sync.sh если нет (путь берём из $DOWNLOAD_SCRIPT,
        # чтобы корректно работало на Recalbox, а не только на Batocera/KNULLI)
        if ! grep -q "download_sync.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
            sed -i "/^#!/a [ \"\$1\" = \"stop\" ] || bash $DOWNLOAD_SCRIPT \&" "$AUTOLOAD_FILE"
            echo "✅ Загрузка сохранений добавлена в $(basename $AUTOLOAD_FILE)"
        fi
        
        # Строки автозапуска из старых версий срабатывали и при выключении:
        # система вызывает этот файл с "start" при включении и с "stop" при выключении.
        # оба файла автозапуска (на KNULLI бывают оба), и старый формат строк без bash
        for AF in "$BASE/custom.sh" "$BASE/services/custom_service"; do
            [ -f "$AF" ] || continue
            sed -i -e 's#^\([[:space:]]*\)\(bash \)\{0,1\}\(/[^ ]*download_sync\.sh\) &$#\1[ "$1" = "stop" ] || \2\3 \&#' \
                   -e 's#^\([[:space:]]*\)\(bash \)\{0,1\}\(/[^ ]*install_sync\.sh --web\) &$#\1[ "$1" = "stop" ] || \2\3 \&#' "$AF" 2>/dev/null
        done

        # Добавляем веб-интерфейс если нет
        if ! grep -q "install_sync.sh --web" "$AUTOLOAD_FILE" 2>/dev/null; then
            cat >> "$AUTOLOAD_FILE" << EOF

# Запуск веб-интерфейса Save Sync
(
    for i in \$(seq 1 30); do
        LOCAL_IP=\$(ip -4 addr show 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
        if [ -n "\$LOCAL_IP" ]; then
            break
        fi
        sleep 2
    done
    [ "\$1" = "stop" ] || bash $BASE/install_sync.sh --web &
) &
EOF
            echo "✅ Веб-интерфейс добавлен в $(basename $AUTOLOAD_FILE)"
        fi
        
        echo ""
        echo "✅ Обновление до v1.4.7 завершено!"

        log_msg "Обновление до v1.4.7 завершено"

        restart_web_after_update

        echo ""
        echo "Что нового:"
        echo "  • Веб-интерфейс"
        echo "  • Центр управления"
        echo "  • Выбор систем для синхронизации"
        echo "  • Настройка интервала синхронизации"
        echo "  • Логирование"
        echo "  • Копирование и загрузка ромов"
        echo ""
        echo "🌐 ВЕБ-ИНТЕРФЕЙС: http://$IP_ADDR:8080"
        echo "   (запускается автоматически при включении системы)"
        echo ""
        echo "📋 Управление: ${RUN_PREFIX}$0 --config"
        echo "🔍 Диагностика: ${RUN_PREFIX}$0 --info"
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo " 1 - Открыть центр управления"
        echo " 2 - Перезагрузить систему"
        echo " 3 - Выход"
        echo ""
        read -p "Выберите (1-3): " FINAL_CHOICE
        
        case "$FINAL_CHOICE" in
            1)
                echo ""
                echo "🔄 Открытие центра управления..."
                sleep 1
                exec bash "$0" --config
                ;;
            2)
                echo "🔄 Перезагрузка системы..."
                reboot
                ;;
            3)
                echo "Выход..."
                exit 0
                ;;
            *)
                echo "Неверный выбор. Выход..."
                exit 1
                ;;
        esac
        ;;
    2)
        # Переустановка - удаляем и устанавливаем заново
        echo "🗑️ Удаление старых файлов..."
        rm -f "$DOWNLOAD_SCRIPT" "$UPLOAD_SCRIPT" "$DOWNLOAD_ROMS" "$UPLOAD_ROMS" "$LINK_SCRIPT" 2>/dev/null
        rm -f "$SCRIPT_DIR/save-sync.sh" 2>/dev/null
        rm -f "/recalbox/share/userscripts/save-sync[endgame].sh" 2>/dev/null
        echo "✅ Старые файлы удалены"
        echo ""
        echo "Запуск установки..."
        # Переходим к установке
        ;;
    3)
        echo "Выход..."
        exit 0
        ;;
    *)
        echo "Неверный выбор"
        exit 1
        ;;
    esac
fi

############################################
# Обычная установка
############################################

echo ""
echo "══════════════════════════════════════════════════════════"
echo " Save Sync v1.4.7 - Установка"
echo " $SYSTEM"
echo "══════════════════════════════════════════════════════════"
echo ""

mkdir -p "$BIN_DIR" || { echo "❌ Ошибка создания $BIN_DIR"; exit 1; }
mkdir -p "$CONFIG_DIR" || { echo "❌ Ошибка создания $CONFIG_DIR"; exit 1; }
mkdir -p "$SCRIPT_DIR" || { echo "❌ Ошибка создания $SCRIPT_DIR"; exit 1; }
mkdir -p "$LOG_DIR" || { echo "❌ Ошибка создания $LOG_DIR"; exit 1; }

if [ ! -f "$CONFIG_FILE" ]; then
    create_default_config
    echo "✅ Создан sync.conf"
fi

if [ -f "$RCLONE_BIN" ]; then
    ensure_rclone_executable
    CURRENT_VER=$("$RCLONE_PATH" version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
    echo "✅ rclone найден (v$CURRENT_VER)"
    echo "Проверка обновлений..."
    if download_rclone; then
        NEW_VER=$("$RCLONE_PATH" version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
        if [ "$CURRENT_VER" = "$NEW_VER" ]; then
            echo "✅ rclone актуален (v$CURRENT_VER)"
        else
            echo "✅ rclone обновлён до v$NEW_VER"
        fi
    fi
else
    echo "📥 rclone не найден. Скачивание..."
    if download_rclone; then
        NEW_VER=$("$RCLONE_PATH" version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
        echo "✅ rclone установлен (v$NEW_VER)"
    else
        exit 1
    fi
fi

ask_cloud_config "$RCLONE_CONF" || exit 1

echo "Проверка подключения..."
if cloud_check "$RCLONE_CONF"; then
    echo "✅ Подключение успешно."
else
    echo "❌ Ошибка подключения."
    [ -n "$CLOUD_ERR" ] && echo "   Причина: $CLOUD_ERR"
    exit 1
fi

echo ""
echo "Проверка папки GameSaves..."
"$RCLONE_PATH" --config "$RCLONE_CONF" mkdir "$REMOTE" >/dev/null 2>&1
echo "✅ Готово."
echo ""

echo "📝 Создание скриптов..."
create_download_script
echo "✅ Создан download_sync.sh"

create_upload_script
echo "✅ Создан upload_sync.sh"

create_roms_scripts
echo "✅ Созданы скрипты для ромов"

create_hook_script
echo "✅ Создан хук сохранений"

# ============================================
# НАСТРОЙКА АВТОЗАГРУЗКИ (НОВАЯ УСТАНОВКА)
# ============================================

# Определяем какой файл использовать для автозагрузки
case "$SYSTEM" in
    Batocera)
        AUTOLOAD_FILE="$BASE/services/custom_service"
        mkdir -p "$BASE/services"
        ;;
    KNULLI)
        AUTOLOAD_FILE="$BASE/custom.sh"
        ;;
    *)
        AUTOLOAD_FILE="$BASE/custom.sh"
        ;;
esac

# Создаём файл если его нет
if [ ! -f "$AUTOLOAD_FILE" ]; then
    echo '#!/bin/bash' > "$AUTOLOAD_FILE"
    chmod +x "$AUTOLOAD_FILE"
    echo "✅ Создан $(basename $AUTOLOAD_FILE)"
fi

# Добавляем download_sync.sh если нет (путь берём из $DOWNLOAD_SCRIPT,
# чтобы корректно работало на Recalbox, а не только на Batocera/KNULLI)
if ! grep -q "download_sync.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
    sed -i "/^#!/a [ \"\$1\" = \"stop\" ] || bash $DOWNLOAD_SCRIPT \&" "$AUTOLOAD_FILE"
    echo "✅ Загрузка сохранений добавлена в $(basename $AUTOLOAD_FILE)"
fi

# Строки автозапуска из старых версий срабатывали и при выключении:
# система вызывает этот файл с "start" при включении и с "stop" при выключении.
# оба файла автозапуска (на KNULLI бывают оба), и старый формат строк без bash
for AF in "$BASE/custom.sh" "$BASE/services/custom_service"; do
    [ -f "$AF" ] || continue
    sed -i -e 's#^\([[:space:]]*\)\(bash \)\{0,1\}\(/[^ ]*download_sync\.sh\) &$#\1[ "$1" = "stop" ] || \2\3 \&#' \
           -e 's#^\([[:space:]]*\)\(bash \)\{0,1\}\(/[^ ]*install_sync\.sh --web\) &$#\1[ "$1" = "stop" ] || \2\3 \&#' "$AF" 2>/dev/null
done

# Добавляем веб-интерфейс если нет
if ! grep -q "install_sync.sh --web" "$AUTOLOAD_FILE" 2>/dev/null; then
    cat >> "$AUTOLOAD_FILE" << EOF

# Запуск веб-интерфейса Save Sync
(
    for i in \$(seq 1 30); do
        LOCAL_IP=\$(ip -4 addr show 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
        if [ -n "\$LOCAL_IP" ]; then
            break
        fi
        sleep 2
    done
    [ "\$1" = "stop" ] || bash $BASE/install_sync.sh --web &
) &
EOF
    echo "✅ Веб-интерфейс добавлен в $(basename $AUTOLOAD_FILE)"
else
    echo "✅ Веб-интерфейс уже есть в $(basename $AUTOLOAD_FILE)"
fi

SYSTEM_VERSION=$(get_system_version)

log_msg "Save Sync v1.4.7 | $SYSTEM ($SYSTEM_VERSION) | rclone v${NEW_VER:-unknown}"
log_msg "Установка завершена"

echo ""
echo "══════════════════════════════════════════════════════════"
echo " ✅ УСТАНОВКА ЗАВЕРШЕНА!"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "Настроено:"
echo "✓ rclone v${NEW_VER:-unknown}"
echo "✓ $URL"
echo "✓ Система: $SYSTEM ($SYSTEM_VERSION)"
echo "✓ Устройство: ${DEVICE_NAME:-неизвестно} (${DEVICE_CPU:-неизвестно})"
echo "✓ Папка $REMOTE_FOLDER"
echo "✓ Автовосстановление после сбоя (до $MAX_RETRIES попыток)"
echo "✓ Логирование в $LOG_FILE"
if [ -f "$CONFIG_FILE" ]; then
    echo "✓ Конфиг создан: sync.conf"
fi
echo "✓ Автозагрузка веб-интерфейса настроена"
echo ""
echo "🌐 ВЕБ-ИНТЕРФЕЙС: http://$IP_ADDR:8080"
echo "   (запускается автоматически при включении системы)"
echo ""
echo "📋 ДЛЯ НАСТРОЙКИ ЗАПУСТИТЕ:"
echo "  ${RUN_PREFIX}$0 --config"
echo ""
echo "══════════════════════════════════════════════════════════"
echo ""
echo " 1 - Открыть центр управления"
echo " 2 - Перезагрузить систему"
echo " 3 - Выход"
echo ""
read -p "Выберите (1-3): " FINAL_CHOICE

case "$FINAL_CHOICE" in
    1)
        echo ""
        echo "🔄 Открытие центра управления..."
        sleep 1
        exec bash "$0" --config
        ;;
    2)
        echo "🔄 Перезагрузка системы..."
        reboot
        ;;
    3)
        echo "Выход..."
        exit 0
        ;;
    *)
        echo "Неверный выбор. Выход..."
        exit 0
        ;;
esac