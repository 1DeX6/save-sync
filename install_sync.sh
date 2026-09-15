#!/bin/bash

################################################
# Save Sync Installer v1.4.4
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
# Save Sync v1.4.4 - Главный конфиг
# ========================================

# ── НАСТРОЙКИ СИНХРОНИЗАЦИИ ──
# 0 = всегда, 300 = 5 мин, 900 = 15 мин, 3600 = 1 час
SYNC_INTERVAL="0"

# Количество попыток при ошибке
MAX_RETRIES="3"

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
# Save Sync v1.4.4 - Главный конфиг
# ========================================

# ── НАСТРОЙКИ СИНХРОНИЗАЦИИ ──
SYNC_INTERVAL="$SYNC_INTERVAL"
MAX_RETRIES="$MAX_RETRIES"
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

# --- ИНИЦИАЛИЗАЦИЯ ПЕРЕМЕННЫХ ОБЛАКА ---
REMOTE_NAME="cloud"
REMOTE_FOLDER="GameSaves"
REMOTE="$REMOTE_NAME:$REMOTE_FOLDER"
REMOTE_ROMS="$REMOTE_NAME:GameROMs"
FIRST_SYNC_MARKER="$REMOTE_FOLDER/.first_sync_done"

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
for CMD in curl unzip ping flock; do
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
# create_download_script
############################################

create_download_script() {
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

# Само-восстановление, если раздел с rclone смонтирован noexec
# (например, /recalbox/share на Recalbox)
RCLONE_PATH="\$RCLONE_BIN"
if ! "\$RCLONE_PATH" version >/dev/null 2>&1; then
    mkdir -p /tmp/save_sync_bin 2>/dev/null
    cp -f "\$RCLONE_BIN" /tmp/save_sync_bin/rclone 2>/dev/null
    chmod +x /tmp/save_sync_bin/rclone 2>/dev/null
    if /tmp/save_sync_bin/rclone version >/dev/null 2>&1; then
        RCLONE_PATH="/tmp/save_sync_bin/rclone"
    fi
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

# ======== ОСНОВНАЯ ЛОГИКА ========
save_status() {
    echo "\$1 \$(date +%s)" > "\$STATUS_FILE"
}

exec 200>"\$LOCK_FILE"
flock -n 200 || { echo "\$(date '+%d.%m %H:%M:%S') Пропущено: предыдущая загрузка ещё выполняется" >> "\$LOG_FILE" 2>/dev/null; exit 0; }

# Проверка интервала (ТОЛЬКО если НЕ принудительная синхронизация)
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ \$SYNC_INTERVAL -gt 0 ] && [ -f "\$LAST_SYNC_TIME" ]; then
    LAST=\$(cat "\$LAST_SYNC_TIME" 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [ \$((NOW - LAST)) -lt \$SYNC_INTERVAL ]; then
        exit 0
    fi
fi

# Проверка интернета
COUNT=0
until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
    COUNT=\$((COUNT+1))
    if [ \$COUNT -ge 40 ]; then
        echo "\$(date '+%d.%m %H:%M:%S') Нет сети (ждали 2 мин)" >> "\$LOG_FILE" 2>/dev/null
        save_status "ERROR"
        [ -z "\$1" ] && touch /tmp/save_sync_dirty_session 2>/dev/null
        exit 1
    fi
    sleep 3
done

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

# Проверка облака (с повторами - на случай кратковременного сбоя)
CLOUD_OK=0
for i in \$(seq 1 3); do
    if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsd "\$REMOTE_NAME:" --contimeout 3m >/dev/null 2>&1; then
        CLOUD_OK=1
        break
    fi
    sleep 5
done
if [ \$CLOUD_OK -eq 0 ]; then
    echo "\$(date '+%d.%m %H:%M:%S') Облако недоступно" >> "\$LOG_FILE" 2>/dev/null
    save_status "ERROR"
    [ -z "\$1" ] && touch /tmp/save_sync_dirty_session 2>/dev/null
    exit 0
fi

# Проверяем, есть ли файлы в облаке
FIRST_SYNC_EXISTS=false
if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$FIRST_SYNC_MARKER" 2>/dev/null | grep -q .; then
    FIRST_SYNC_EXISTS=true
fi

CLOUD_HAS_FILES=false
if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$REMOTE" 2>/dev/null | grep -v ".first_sync_done" | grep -q .; then
    CLOUD_HAS_FILES=true
fi

# Формируем фильтры исключений
FILTER_OPTS=()
if [ -n "\$EXCLUDED_SYSTEMS" ]; then
    IFS='|' read -ra EXCLUDED_ARRAY <<< "\$EXCLUDED_SYSTEMS"
    for sys in "\${EXCLUDED_ARRAY[@]}"; do
        sys="\$(echo "\$sys" | xargs)"
        [ -n "\$sys" ] && FILTER_OPTS+=(--exclude "/\$sys/**")
    done
fi

# ======== ПЕРВАЯ ЗАГРУЗКА (если облако пустое) ========
if [ "\$FIRST_SYNC_EXISTS" = false ] && [ "\$CLOUD_HAS_FILES" = false ]; then
    progress_start "download" "Загрузка сохранений"
    if [ -n "\$SHOW_PROGRESS" ] || [ "\$WEB_PROGRESS" = "true" ]; then
        run_transfer copy "\$SAVE_DIR" "\$REMOTE" \
            --exclude ".first_sync_done" --exclude ".DS_Store" --exclude "Thumbs.db" --exclude "*.log" --exclude "*.cache" --exclude ".keep" --exclude "*.keep" \
            "\${FILTER_OPTS[@]}" \
            --no-traverse
    else
        run_transfer copy "\$SAVE_DIR" "\$REMOTE" \
            --exclude ".first_sync_done" --exclude ".DS_Store" --exclude "Thumbs.db" --exclude "*.log" --exclude "*.cache" --exclude ".keep" --exclude "*.keep" \
            "\${FILTER_OPTS[@]}" \
            --no-traverse
    fi
    SYNC_EXIT=\$?
    if [ "\$SYNC_EXIT" -eq 0 ] || [ "\$SYNC_EXIT" -eq 3 ]; then
        echo "first_sync_\$(date +%s)" | "\$RCLONE_PATH" --config "\$RCLONE_CONF" rcat "\$FIRST_SYNC_MARKER" 2>/dev/null
        date +%s > "\$READY_FILE"
        save_status "OK"
        rm -f /tmp/save_sync_dirty_session 2>/dev/null
        echo "\$(date '+%d.%m %H:%M:%S') Первая загрузка из облака: завершена" >> "\$LOG_FILE" 2>/dev/null
        progress_finish true "download" "Загрузка сохранений завершена"
    else
        save_status "ERROR"
        echo "\$(date '+%d.%m %H:%M:%S') Ошибка первой загрузки" >> "\$LOG_FILE" 2>/dev/null
        progress_finish false "download" "Ошибка загрузки сохранений"
    fi
    rm -f /tmp/save_exclude_\$\$.tmp 2>/dev/null
    exit 0
fi

# ======== ОБЫЧНАЯ ЗАГРУЗКА ========
progress_start "download" "Загрузка сохранений"
# Копируем сохранения из облака на устройство.
# ВАЖНО: используем "copy", а НЕ "sync --delete-after" — по документации
# файлы, которых нет в облаке, НЕ должны удаляться с устройства.
for i in \$(seq 1 \$MAX_RETRIES); do
    if [ -n "\$SHOW_PROGRESS" ] || [ "\$WEB_PROGRESS" = "true" ]; then
        run_transfer copy "\$REMOTE" "\$SAVE_DIR" \
            --ignore-times \
            --exclude ".first_sync_done" --exclude ".DS_Store" --exclude "Thumbs.db" --exclude "*.log" --exclude "*.cache" --exclude ".keep" --exclude "*.keep" \
            "\${FILTER_OPTS[@]}" \
            --progress
        SYNC_EXIT=\$?
    else
        "\$RCLONE_PATH" --config "\$RCLONE_CONF" copy "\$REMOTE" "\$SAVE_DIR" \
            --ignore-times \
            --exclude ".first_sync_done" --exclude ".DS_Store" --exclude "Thumbs.db" --exclude "*.log" --exclude "*.cache" --exclude ".keep" --exclude "*.keep" \
            "\${FILTER_OPTS[@]}" \
            > /dev/null 2>&1
        SYNC_EXIT=\$?
    fi
    
    # Коды успеха: 0 - всё ок, 3 - часть файлов не скопирована (не критично)
    if [ \$SYNC_EXIT -eq 0 ] || [ \$SYNC_EXIT -eq 3 ]; then
        date +%s > "\$READY_FILE"
        date +%s > "\$LAST_SYNC_TIME"
        save_status "OK"
        rm -f /tmp/save_sync_dirty_session 2>/dev/null
        echo "\$(date '+%d.%m %H:%M:%S') Сохранения загружены" >> "\$LOG_FILE" 2>/dev/null
        progress_finish true "download" "Загрузка сохранений завершена"
        break
    else
        if [ \$i -eq \$MAX_RETRIES ]; then
            save_status "ERROR"
            echo "\$(date '+%d.%m %H:%M:%S') Ошибка загрузки сохранений (код: \$SYNC_EXIT, попытка \$i)" >> "\$LOG_FILE" 2>/dev/null
            [ -z "\$1" ] && touch /tmp/save_sync_dirty_session 2>/dev/null
            progress_finish false "download" "Ошибка загрузки сохранений"
        else
            sleep 60
        fi
    fi
done
rm -f /tmp/save_exclude_\$\$.tmp 2>/dev/null
exit 0
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

# Само-восстановление, если раздел с rclone смонтирован noexec
# (например, /recalbox/share на Recalbox)
RCLONE_PATH="\$RCLONE_BIN"
if ! "\$RCLONE_PATH" version >/dev/null 2>&1; then
    mkdir -p /tmp/save_sync_bin 2>/dev/null
    cp -f "\$RCLONE_BIN" /tmp/save_sync_bin/rclone 2>/dev/null
    chmod +x /tmp/save_sync_bin/rclone 2>/dev/null
    if /tmp/save_sync_bin/rclone version >/dev/null 2>&1; then
        RCLONE_PATH="/tmp/save_sync_bin/rclone"
    fi
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

# ======== ОСНОВНАЯ ЛОГИКА ========
save_status() {
    echo "\$1 \$(date +%s)" > "\$STATUS_FILE"
}

exec 200>"\$LOCK_FILE"
flock -n 200 || { echo "\$(date '+%d.%m %H:%M:%S') Пропущено: предыдущая выгрузка ещё выполняется" >> "\$LOG_FILE" 2>/dev/null; exit 0; }

# Если загрузка при включении устройства не удалась - предупреждаем
# в логе, что выгрузка сейчас происходит без гарантии, что мы перед
# этим получили самую свежую версию сохранений из облака (актуально
# при использовании нескольких устройств по очереди).
if [ -f /tmp/save_sync_dirty_session ]; then
    echo "\$(date '+%d.%m %H:%M:%S') ⚠️  Внимание: сессия началась без свежей загрузки из облака - выгружаемое сохранение может перезаписать более новую версию" >> "\$LOG_FILE" 2>/dev/null
fi

# Проверка интервала (ТОЛЬКО если НЕ принудительная синхронизация)
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ \$SYNC_INTERVAL -gt 0 ] && [ -f "\$LAST_SYNC_TIME" ]; then
    LAST=\$(cat "\$LAST_SYNC_TIME" 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [ \$((NOW - LAST)) -lt \$SYNC_INTERVAL ]; then
        echo "\$(date '+%d.%m %H:%M:%S') Выгрузка пропущена (интервал \$SYNC_INTERVAL сек)" >> "\$LOG_FILE" 2>/dev/null
        exit 0
    fi
fi

# Проверка интернета
COUNT=0
until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
    COUNT=\$((COUNT+1))
    if [ \$COUNT -ge 40 ]; then
        echo "\$(date '+%d.%m %H:%M:%S') Нет сети (ждали 2 мин)" >> "\$LOG_FILE" 2>/dev/null
        save_status "ERROR"
        exit 1
    fi
    sleep 3
done

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

# Проверка облака (с повторами - на случай кратковременного сбоя)
CLOUD_OK=0
for i in \$(seq 1 3); do
    if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsd "\$REMOTE_NAME:" --contimeout 1m >/dev/null 2>&1; then
        CLOUD_OK=1
        break
    fi
    sleep 5
done
if [ \$CLOUD_OK -eq 0 ]; then
    echo "\$(date '+%d.%m %H:%M:%S') Облако недоступно" >> "\$LOG_FILE" 2>/dev/null
    save_status "ERROR"
    exit 0
fi

# Проверка свободного места в облаке
if [ -z "\$SHOW_PROGRESS" ]; then
    FILES_SIZE=\$(find "\$SAVE_DIR" -type f ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "*.log" ! -name "*.cache" ! -name ".keep" ! -name "*.keep" -printf '%s\n' 2>/dev/null | awk '{sum+=\$1} END {print sum+0}')
    FILES_SIZE=\${FILES_SIZE:-0}
    FILES_SIZE_MB=\$((FILES_SIZE / 1024 / 1024))
    
    CLOUD_FREE=\$("\$RCLONE_PATH" --config "\$RCLONE_CONF" about "\$REMOTE_NAME:" 2>/dev/null | grep -i "free" | awk '{print \$2}' | sed 's/[^0-9]//g')
    CLOUD_FREE=\${CLOUD_FREE:-0}
    CLOUD_FREE_MB=\$((CLOUD_FREE / 1024 / 1024))
    
    if [ "\$FILES_SIZE_MB" -gt 0 ] && [ "\$CLOUD_FREE_MB" -gt 0 ]; then
        NEEDED_MB=\$((FILES_SIZE_MB + FILES_SIZE_MB / 10))
        if [ "\$CLOUD_FREE_MB" -lt "\$NEEDED_MB" ]; then
            echo "\$(date '+%d.%m %H:%M:%S') ⚠️ Недостаточно места в облаке! Нужно ~\${NEEDED_MB} МБ, свободно \${CLOUD_FREE_MB} МБ" >> "\$LOG_FILE" 2>/dev/null
            save_status "ERROR"
            exit 1
        fi
    fi
fi

# Формируем фильтры исключений
FILTER_OPTS=()
if [ -n "\$EXCLUDED_SYSTEMS" ]; then
    IFS='|' read -ra EXCLUDED_ARRAY <<< "\$EXCLUDED_SYSTEMS"
    for sys in "\${EXCLUDED_ARRAY[@]}"; do
        sys="\$(echo "\$sys" | xargs)"
        [ -n "\$sys" ] && FILTER_OPTS+=(--exclude "/\$sys/**")
    done
fi

# Проверяем, есть ли маркер первой синхронизации
FIRST_SYNC_EXISTS=false
if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$FIRST_SYNC_MARKER" 2>/dev/null | grep -q .; then
    FIRST_SYNC_EXISTS=true
fi

# ======== ПЕРВАЯ СИНХРОНИЗАЦИЯ (copy) ========
if [ "\$FIRST_SYNC_EXISTS" = false ]; then
    progress_start "upload" "Выгрузка сохранений"
    if [ -n "\$SHOW_PROGRESS" ] || [ "\$WEB_PROGRESS" = "true" ]; then
        run_transfer copy "\$SAVE_DIR" "\$REMOTE" \
            --exclude ".first_sync_done" --exclude ".DS_Store" --exclude "Thumbs.db" --exclude "*.log" --exclude "*.cache" --exclude ".keep" --exclude "*.keep" \
            "\${FILTER_OPTS[@]}" \
            --no-traverse
    else
        run_transfer copy "\$SAVE_DIR" "\$REMOTE" \
            --exclude ".first_sync_done" --exclude ".DS_Store" --exclude "Thumbs.db" --exclude "*.log" --exclude "*.cache" --exclude ".keep" --exclude "*.keep" \
            "\${FILTER_OPTS[@]}" \
            --no-traverse
    fi
    SYNC_EXIT=\$?
    
    if [ \$SYNC_EXIT -eq 0 ] || [ \$SYNC_EXIT -eq 3 ]; then
        echo "first_sync_\$(date +%s)" | "\$RCLONE_PATH" --config "\$RCLONE_CONF" rcat "\$FIRST_SYNC_MARKER" 2>/dev/null
        date +%s > "\$READY_FILE"
        date +%s > "\$LAST_SYNC_TIME"
        save_status "OK"
        echo "\$(date '+%d.%m %H:%M:%S') Выгрузка сохранений" >> "\$LOG_FILE" 2>/dev/null
        progress_finish true "upload" "Выгрузка сохранений завершена"
    else
        save_status "ERROR"
        echo "\$(date '+%d.%m %H:%M:%S') Ошибка первой выгрузки (код: \$SYNC_EXIT)" >> "\$LOG_FILE" 2>/dev/null
        progress_finish false "upload" "Ошибка выгрузки сохранений"
    fi
    rm -f /tmp/save_exclude_\$\$.tmp 2>/dev/null
    exit 0
fi

# ======== ОБЫЧНАЯ СИНХРОНИЗАЦИЯ (sync с удалением) ========
progress_start "upload" "Выгрузка сохранений"
for i in \$(seq 1 \$MAX_RETRIES); do
    if [ -n "\$SHOW_PROGRESS" ] || [ "\$WEB_PROGRESS" = "true" ]; then
        run_transfer sync "\$SAVE_DIR" "\$REMOTE" \
            --ignore-times \
            --delete-after \
            --exclude ".first_sync_done" --exclude ".DS_Store" --exclude "Thumbs.db" --exclude "*.log" --exclude "*.cache" --exclude ".keep" --exclude "*.keep" \
            "\${FILTER_OPTS[@]}" \
            --progress
        SYNC_EXIT=\$?
    else
        "\$RCLONE_PATH" --config "\$RCLONE_CONF" sync "\$SAVE_DIR" "\$REMOTE" \
            --ignore-times \
            --delete-after \
            --exclude ".first_sync_done" --exclude ".DS_Store" --exclude "Thumbs.db" --exclude "*.log" --exclude "*.cache" --exclude ".keep" --exclude "*.keep" \
            "\${FILTER_OPTS[@]}" \
            > /dev/null 2>&1
        SYNC_EXIT=\$?
    fi
    
    if [ \$SYNC_EXIT -eq 0 ] || [ \$SYNC_EXIT -eq 3 ]; then
        date +%s > "\$LAST_SYNC_TIME"
        save_status "OK"
        echo "\$(date '+%d.%m %H:%M:%S') Выгрузка сохранений" >> "\$LOG_FILE" 2>/dev/null
        progress_finish true "upload" "Выгрузка сохранений завершена"
        break
    else
        if [ \$i -eq \$MAX_RETRIES ]; then
            save_status "ERROR"
            echo "\$(date '+%d.%m %H:%M:%S') Ошибка выгрузки сохранений (код: \$SYNC_EXIT, попытка \$i)" >> "\$LOG_FILE" 2>/dev/null
            progress_finish false "upload" "Ошибка выгрузки сохранений"
        else
            echo "\$(date '+%d.%m %H:%M:%S') Повторная попытка \$i/\$MAX_RETRIES (код: \$SYNC_EXIT)" >> "\$LOG_FILE" 2>/dev/null
            sleep 60
        fi
    fi
done

rm -f /tmp/save_exclude_\$\$.tmp 2>/dev/null
exit 0
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
if ! "\$RCLONE_PATH" version >/dev/null 2>&1; then
    mkdir -p /tmp/save_sync_bin 2>/dev/null
    cp -f "\$RCLONE_BIN" /tmp/save_sync_bin/rclone 2>/dev/null
    chmod +x /tmp/save_sync_bin/rclone 2>/dev/null
    if /tmp/save_sync_bin/rclone version >/dev/null 2>&1; then
        RCLONE_PATH="/tmp/save_sync_bin/rclone"
    fi
fi
RCLONE_CONF="$RCLONE_CONF"
ROMS_DIR="$ROMS_DIR"
REMOTE_ROMS="$REMOTE_ROMS"
FILTER_FILE="$ROMS_FILTER_FILE"
LOG_FILE="$LOG_FILE"
PROGRESS_FILE="/tmp/save_sync_progress.json"
PROGRESS_LOG="/tmp/save_sync_progress.log"
WEB_PROGRESS=false

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

log_msg "Начало загрузки ромов"

"\$RCLONE_PATH" --config "\$RCLONE_CONF" mkdir "\$REMOTE_ROMS" 2>/dev/null

echo "🔄 Загрузка ромов из облака..."

progress_start "roms_download" "Загрузка ромов"
run_transfer copy "\$REMOTE_ROMS" "\$ROMS_DIR" \
    --update \
    --filter-from "\$FILTER_FILE"

EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ] || [ \$EXIT_CODE -eq 3 ]; then
    echo "✅ Загрузка ромов завершена"
    log_msg "Загрузка ромов завершена"
    progress_finish true "roms_download" "Загрузка ромов завершена"
else
    echo "❌ Ошибка загрузки ромов (код: \$EXIT_CODE)"
    log_msg "Ошибка загрузки ромов (код: \$EXIT_CODE)"
    progress_finish false "roms_download" "Ошибка загрузки ромов"
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
if ! "\$RCLONE_PATH" version >/dev/null 2>&1; then
    mkdir -p /tmp/save_sync_bin 2>/dev/null
    cp -f "\$RCLONE_BIN" /tmp/save_sync_bin/rclone 2>/dev/null
    chmod +x /tmp/save_sync_bin/rclone 2>/dev/null
    if /tmp/save_sync_bin/rclone version >/dev/null 2>&1; then
        RCLONE_PATH="/tmp/save_sync_bin/rclone"
    fi
fi
RCLONE_CONF="$RCLONE_CONF"
ROMS_DIR="$ROMS_DIR"
REMOTE_ROMS="$REMOTE_ROMS"
FILTER_FILE="$ROMS_FILTER_FILE"
LOG_FILE="$LOG_FILE"
PROGRESS_FILE="/tmp/save_sync_progress.json"
PROGRESS_LOG="/tmp/save_sync_progress.log"
WEB_PROGRESS=false

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

log_msg "Начало выгрузки ромов"

"\$RCLONE_PATH" --config "\$RCLONE_CONF" mkdir "\$REMOTE_ROMS" 2>/dev/null

# Проверка свободного места в облаке (размер считаем через du -
# читать содержимое файлов, как для сохранений, здесь нельзя:
# коллекция ромов может весить сотни ГБ, и построчное чтение
# заняло бы неоправданно много времени)
ROMS_SIZE_MB=\$(du -sm "\$ROMS_DIR" 2>/dev/null | awk '{print \$1}')
ROMS_SIZE_MB=\${ROMS_SIZE_MB:-0}

CLOUD_FREE=\$("\$RCLONE_PATH" --config "\$RCLONE_CONF" about "\$REMOTE_NAME:" 2>/dev/null | grep -i "free" | awk '{print \$2}' | sed 's/[^0-9]//g')
CLOUD_FREE=\${CLOUD_FREE:-0}
CLOUD_FREE_MB=\$((CLOUD_FREE / 1024 / 1024))

if [ "\$ROMS_SIZE_MB" -gt 0 ] && [ "\$CLOUD_FREE_MB" -gt 0 ]; then
    NEEDED_MB=\$((ROMS_SIZE_MB + ROMS_SIZE_MB / 10))
    if [ "\$CLOUD_FREE_MB" -lt "\$NEEDED_MB" ]; then
        log_msg "⚠️ Недостаточно места в облаке для ромов! Нужно ~\${NEEDED_MB} МБ, свободно \${CLOUD_FREE_MB} МБ"
        exit 1
    fi
fi

echo "🔄 Копирование ромов в облако..."

progress_start "roms_upload" "Выгрузка ромов"
run_transfer sync "\$ROMS_DIR" "\$REMOTE_ROMS" \
    --delete-after \
    --filter-from "\$FILTER_FILE"

EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ] || [ \$EXIT_CODE -eq 3 ]; then
    echo "✅ Выгрузка ромов завершена"
    log_msg "Выгрузка ромов завершена"
    progress_finish true "roms_upload" "Выгрузка ромов завершена"
else
    echo "❌ Ошибка выгрузки ромов (код: \$EXIT_CODE)"
    log_msg "❌ Ошибка выгрузки ромов (код: \$EXIT_CODE)"
    progress_finish false "roms_upload" "Ошибка выгрузки ромов"
fi

log_msg "Конец выгрузки ромов"

exit \$EXIT_CODE
ENDOFSCRIPT
    
    chmod +x "$UPLOAD_ROMS"
    
    echo "✅ Скрипты для ромов созданы (с логированием)"
}

############################################
# Создание фильтра для ромов
############################################

create_roms_filter() {
    # Создаем фильтр с базовыми исключениями
    cat > "$ROMS_FILTER_FILE" << 'EOF'
# Фильтр для синхронизации ромов
# Создан автоматически, не редактируйте вручную

# Исключаем системные файлы
- **/_info.txt
EOF
    
    # Если медиа выключена - исключаем медиа файлы
    if [ "$ROMS_SYNC_MEDIA" != "true" ]; then
        cat >> "$ROMS_FILTER_FILE" << 'EOF'

# Исключаем медиа-папки
- **/images/**
- **/media/**
- **/videos/**
- **/manuals/**
- **/screenshots/**
- **/thumbnails/**

# Исключаем медиа-файлы (изображения)
- **.png
- **.jpg
- **.jpeg
- **.gif
- **.bmp
EOF
    fi
    
    # ВСЕГДА исключаем видео (WebDAV не любит большие файлы)
    cat >> "$ROMS_FILTER_FILE" << 'EOF'

# Исключаем видео файлы (WebDAV ограничения)
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
    
    # Добавляем выбранные системы
    if [ -n "$ROMS_SYNC_DIRS" ]; then
        IFS='|' read -ra DIRS <<< "$ROMS_SYNC_DIRS"
        for dir in "${DIRS[@]}"; do
            dir=$(echo "$dir" | xargs)
            if [ -n "$dir" ]; then
                echo "+ /$dir/**" >> "$ROMS_FILTER_FILE"
            fi
        done
    fi
    
    # Исключаем всё, что не выбрано
    echo "- **" >> "$ROMS_FILTER_FILE"
}

############################################
# Управление исключениями (сохранения)
############################################

manage_exclusions() {
    # Загружаем конфиг
    load_config
    
    while true; do
        SYSTEMS=()
        
        # Рекурсивный поиск систем с ромами
        for dir in "$ROMS_DIR"/*/; do
            [ -d "$dir" ] || continue
            BASENAME=$(basename "$dir")
            
            if find "$dir" -type f ! -name "gamelist.xml" ! -name "_info.txt" ! -name "*.dat" ! -name "*.txt" ! -name "*.log" ! -name "*.cache" ! -path "*/images/*" ! -path "*/media/*" ! -path "*/videos/*" 2>/dev/null | head -1 | grep -q .; then
                SYSTEMS+=("$BASENAME")
            fi
        done
        
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
                    if [ "$excluded" = true ]; then
                        echo "  $idx - $sys ⚠️ УЖЕ ИСКЛЮЧЕНА"
                    else
                        echo "  $idx - $sys"
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
                    if [ "$excluded" = true ]; then
                        echo "  $idx - $sys ❌ (исключена)"
                    else
                        echo "  $idx - $sys ✅ (синхронизируется)"
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
        echo " 1 - 📂 Выбор систем для резервного копирования"
        echo " 2 - 🖼️ Включить/выключить копирование изображений"
        echo " 3 - 📥 Загрузить ромы из облака"
        echo " 4 - 📤 Выгрузить ромы в облако"
        echo " 0 - Назад"
        echo ""
        read -p "Выберите (0-4): " roms_choice
        
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
            *)
                echo "❌ Неверный выбор"
                sleep 1
                ;;
        esac
    done
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
        
        if find "$dir" -type f ! -name "gamelist.xml" ! -name "_info.txt" ! -name "*.dat" ! -name "*.txt" ! -name "*.log" ! -name "*.cache" ! -path "*/images/*" ! -path "*/media/*" ! -path "*/videos/*" 2>/dev/null | head -1 | grep -q .; then
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
        echo " 📁 Выбор систем для резервного копирования"
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
            TOTAL=$(grep -c "Загрузка сохранений\|Выгрузка сохранений" "$LOG_FILE" 2>/dev/null)
            ERR=$(grep -c "Ошибка\|недоступны" "$LOG_FILE" 2>/dev/null)
            [ -z "$TOTAL" ] && TOTAL=0
            [ -z "$ERR" ] && ERR=0
            OK=$((TOTAL - ERR))
            [ $OK -lt 0 ] && OK=0
            
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
    DETECT_METHOD="неизвестно"
    
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        SYSTEM_VERSION=$(get_system_version)
        
        if [ -n "$ID" ]; then
            DETECT_METHOD="по /etc/os-release (ID: $ID)"
        else
            DETECT_METHOD="по /etc/os-release"
        fi
    fi
    
    if [ "$SYSTEM" = "KNULLI" ]; then
        if [ -f "/usr/share/knulli/knulli.version" ]; then
            DETECT_METHOD="по файлу /usr/share/knulli/knulli.version"
        elif [ -f "/etc/knulli-release" ]; then
            DETECT_METHOD="по файлу /etc/knulli-release"
        fi
    fi
    
    if [ "$SYSTEM" = "Batocera" ]; then
        if [ -f "/etc/batocera-release" ] && [ -s "/etc/batocera-release" ]; then
            DETECT_METHOD="по файлу /etc/batocera-release"
        elif [ -f "/boot/batocera" ] || [ -f "/usr/bin/batocera-es-swissknife" ]; then
            DETECT_METHOD="по наличию файлов Batocera"
        fi
    fi
    
    # Загружаем конфиг
    load_config
    
    REAL_INTERVAL=$SYNC_INTERVAL
    REAL_RETRIES=$MAX_RETRIES
    REAL_MIN_FREE=$MIN_FREE_KB
    REAL_LOG_SIZE=$MAX_LOG_SIZE
    
    if [ -f "$RCLONE_PATH" ]; then
        RCLONE_STATUS="✓ найден (v$($RCLONE_PATH version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//'))"
    else
        RCLONE_STATUS="✗ не найден"
    fi
    
    if [ -f "$RCLONE_PATH" ] && [ -f "$RCLONE_CONF" ]; then
        if "$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_NAME:" --contimeout 5s >/dev/null 2>&1; then
            CLOUD_STATUS="✓ подключено"
            CLOUD_FREE=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "free" | awk '{print $2, $3}')
            [ -z "$CLOUD_FREE" ] && CLOUD_FREE="неизвестно"
        else
            CLOUD_STATUS="✗ нет подключения"
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
        if [ -n "$FILE_SIZE_BYTES" ] && [ "$FILE_SIZE_BYTES" -gt 0 ]; then
            if [ "$FILE_SIZE_BYTES" -gt 1048576 ]; then
                FILE_SIZE=$(echo "scale=1; $FILE_SIZE_BYTES / 1048576" | bc)
                FILE_SIZE="${FILE_SIZE} МБ"
            elif [ "$FILE_SIZE_BYTES" -gt 1024 ]; then
                FILE_SIZE=$(echo "scale=1; $FILE_SIZE_BYTES / 1024" | bc)
                FILE_SIZE="${FILE_SIZE} КБ"
            else
                FILE_SIZE="${FILE_SIZE_BYTES} Б"
            fi
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
    TOTAL_SYNC=$(grep -c "Сохранения загружены\|Выгрузка сохранений" "$LOG_FILE" 2>/dev/null)
    ERR_SYNC=$(grep -c "Ошибка\|недоступны" "$LOG_FILE" 2>/dev/null)
    [ -z "$TOTAL_SYNC" ] && TOTAL_SYNC=0
    [ -z "$ERR_SYNC" ] && ERR_SYNC=0
    OK_SYNC=$((TOTAL_SYNC - ERR_SYNC))
    [ $OK_SYNC -lt 0 ] && OK_SYNC=0
    SYNC_STATS="$TOTAL_SYNC синхр. ($OK_SYNC OK, $ERR_SYNC ERR)"
    
    # ── ИСПОЛЬЗОВАНИЕ ОБЛАКА ──
    CLOUD_USED=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "used" | awk '{print $2, $3}')
    CLOUD_TOTAL=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "total" | awk '{print $2, $3}')
    if [ -n "$CLOUD_USED" ] && [ -n "$CLOUD_TOTAL" ]; then
        CLOUD_USED_DISPLAY="$CLOUD_USED из $CLOUD_TOTAL"
    else
        CLOUD_USED_DISPLAY="неизвестно"
    fi
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
        echo "           Save Sync - Центр управления v1.4.4"
        echo "" 
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo " 🖥️ Система:        $SYSTEM (${CFW_VERSION:-неизвестно})"
        echo " 💾 Сохранений:     $SAVES_STATUS"
        echo " ☁️ Облако:         $CLOUD_STATUS"
        echo " 📦 Свободно:       $FREE (локально) / $CLOUD_FREE (облако)"
        echo " 🔄 Обновлено:      $LAST_SYNC_STATUS"
        echo " 📊 Статистика:     $SYNC_STATS"
        echo " 📁 Исключения:     $EXCLUDE_DISPLAY"
        echo " ⏱️ Интервал:       $INTERVAL_DISPLAY"
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
        echo ""
        
        echo " ── ИНФОРМАЦИЯ ──"
        echo "  8 - 📊 Статистика и логи"
        echo "  9 - 🔍 Полная диагностика"
        echo ""
        
        echo " ── СИСТЕМА ──"
        echo " 10 - 🗑️ Очистить временные файлы"
        echo " 11 - 🔄 Перезагрузить устройство"
        echo ""
        
        echo " ── ВЕБ-ИНТЕРФЕЙС ──"
        echo "      🌐 http://$IP_ADDR:8080"
        echo " 12 - 🔄 Перезапустить веб-интерфейс"
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo "  0 - 🚪 Выход"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        read -p "Выберите действие (0-12): " choice
        
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
                echo "  • Если в облаке нет файла — он НЕ УДАЛЯЕТСЯ с устройства"
                echo "  • Загружаются только новые или измененные файлы"
                echo "  • Если облако пустое — НЕЛЬЗЯ загружаться, иначе"
                echo "    синхронизация удалит все локальные сохранения!"
                echo ""
                
                CLOUD_HAS_SAVES=false
                if "$RCLONE_PATH" --config "$RCLONE_CONF" lsf "$REMOTE" 2>/dev/null | grep -v ".first_sync_done" | grep -q .; then
                    CLOUD_HAS_SAVES=true
                fi
                
                if [ "$CLOUD_HAS_SAVES" = false ]; then
                    echo "══════════════════════════════════════════════════════════"
                    echo " ⛔ ОСТАНОВКА! В облаке нет сохранений."
                    echo ""
                    echo "Если продолжить, синхронизация УДАЛИТ все локальные сохранения!"
                    echo ""
                    echo "РЕКОМЕНДАЦИЯ: сначала сделайте ВЫГРУЗКУ (пункт 2)."
                    echo "══════════════════════════════════════════════════════════"
                    echo ""
                    read -p "Продолжить загрузку? (y/n): " confirm
                    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                        echo "❌ Отменено."
                        echo ""
                        pause
                        continue
                    fi
                else
                    echo "══════════════════════════════════════════════════════════"
                    echo ""
                    read -p "Продолжить загрузку? (y/n): " confirm
                    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                        echo "❌ Отменено."
                        echo ""
                        pause
                        continue
                    fi
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
                echo "  • Если файла нет на устройстве — он УДАЛЯЕТСЯ из облака"
                echo "  • Выгружаются только новые или измененные файлы"
                echo "  • Удаление синхронизируется между устройствами"
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
                echo "     (если в облаке нет файла — он НЕ УДАЛЯЕТСЯ с устройства)"
                echo ""
                echo "  2. Затем ВЫГРУЗИТ сохранения в облако"
                echo "     (если файла нет на устройстве — он УДАЛЯЕТСЯ из облака)"
                echo ""
                echo " ⚠️ ВНИМАНИЕ: удаление синхронизируется в обе стороны!"
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
                bash "$DOWNLOAD_SCRIPT" --verbose
                echo ""
                echo "--- Шаг 2: Выгрузка в облако ---"
                bash "$UPLOAD_SCRIPT" --verbose
                echo ""
                echo "✅ Полная синхронизация завершена!"
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
                show_statistics
                ;;
            9)
                echo ""
                bash "$0" --info
                echo ""
                pause
                ;;
            10)
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
            11)
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
            12)
                echo ""
                echo "🔄 Перезапуск веб-интерфейса..."
                # Останавливаем старый
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

start_web() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " 🌐 Save Sync - Веб-интерфейс v1.4.4"
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
        if kill -0 "$PID" 2>/dev/null; then
            echo "⚠️ Веб-интерфейс уже запущен (PID: $PID)"
            echo "🌐 Откройте: http://${IP_ADDR}:8080"
            echo ""
            echo "Для остановки: kill $PID"
            return 1
        fi
    fi
    
    # Создаем директорию для веб-интерфейса
    WEB_DIR="/tmp/save_sync_web"
    mkdir -p "$WEB_DIR"
    
    # Создаем Python сервер
    cat > "$WEB_DIR/server.py" << 'EOF'
#!/usr/bin/env python3
import http.server
import json
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

class Handler(http.server.BaseHTTPRequestHandler):
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
            with open(CONFIG_FILE, "w") as f:
                f.write("# ========================================\n")
                f.write("# Save Sync v1.4.4 - Главный конфиг\n")
                f.write("# ========================================\n\n")
                f.write("# ---- НАСТРОЙКИ СИНХРОНИЗАЦИИ ----\n")
                f.write(f'SYNC_INTERVAL="{current.get("SYNC_INTERVAL", 0)}"\n')
                f.write(f'MAX_RETRIES="{current.get("MAX_RETRIES", 3)}"\n')
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
        config = self.read_config()
        roms_sync_dirs = config.get("ROMS_SYNC_DIRS", "")
        roms_sync_media = config.get("ROMS_SYNC_MEDIA", "false")
        
        try:
            with open(ROMS_FILTER_FILE, "w") as f:
                f.write("# Фильтр для синхронизации ромов\n")
                f.write("# Создан автоматически, не редактируйте вручную\n\n")
                f.write("# Исключаем системные файлы\n")
                f.write("- **/_info.txt\n\n")
                if roms_sync_media != "true":
                    f.write("# Исключаем медиа-папки\n")
                    f.write("- **/images/**\n")
                    f.write("- **/media/**\n")
                    f.write("- **/videos/**\n")
                    f.write("- **/manuals/**\n")
                    f.write("- **/screenshots/**\n")
                    f.write("- **/thumbnails/**\n\n")
                    f.write("# Исключаем медиа-файлы\n")
                    f.write("- **.png\n")
                    f.write("- **.jpg\n")
                    f.write("- **.jpeg\n")
                    f.write("- **.gif\n")
                    f.write("- **.bmp\n\n")
                f.write("# Исключаем видео файлы\n")
                f.write("- **.mp4\n")
                f.write("- **.avi\n")
                f.write("- **.webm\n")
                f.write("- **.wmv\n")
                f.write("- **.mkv\n")
                f.write("- **.mov\n")
                f.write("- **.m4v\n")
                f.write("- **.mpg\n")
                f.write("- **.mpeg\n\n")
                if roms_sync_dirs:
                    f.write("# Добавляем выбранные системы\n")
                    for dir in roms_sync_dirs.split("|"):
                        dir = dir.strip()
                        if dir:
                            f.write(f"+ /{dir}/**\n")
                    f.write("\n")
                f.write("# Исключаем всё, что не выбрано\n")
                f.write("- **\n")
            return True
        except:
            return False
    
    def get_stats(self):
        stats = {"sync": {"total": 0, "ok": 0, "error": 0}, "roms": {"total": 0, "ok": 0, "error": 0}}
        if os.path.exists(LOG_FILE):
            try:
                with open(LOG_FILE, "r") as f:
                    content = f.read()
                    stats["sync"]["total"] = len(re.findall(r"Сохранения загружены|Выгрузка сохранений", content))
                    stats["sync"]["ok"] = len(re.findall(r"Сохранения загружены", content)) + len(re.findall(r"Выгрузка сохранений", content))
                    stats["sync"]["error"] = len(re.findall(r"Ошибка|недоступны", content))
                    stats["roms"]["total"] = len(re.findall(r"Выгрузка ромов завершена|Загрузка ромов завершена", content))
                    stats["roms"]["ok"] = len(re.findall(r"Выгрузка ромов завершена|Загрузка ромов завершена", content))
                    stats["roms"]["error"] = len(re.findall(r"Ошибка загрузки ромов|Ошибка выгрузки ромов", content))
            except:
                pass
        return stats

    def do_GET(self):
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
        else:
            self.send_error(404)

    def do_POST(self):
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
            "cloud": {"status": "disconnected", "free": "0", "used": "0", "total": "0"},
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
                result = subprocess.run(
                    [RCLONE_PATH, "--config", RCLONE_CONF, "lsd", "cloud:", "--contimeout", "3s"],
                    capture_output=True,
                    timeout=5
                )
                if result.returncode == 0:
                    status["cloud"]["status"] = "connected"
                    about = subprocess.run(
                        [RCLONE_PATH, "--config", RCLONE_CONF, "about", "cloud:"],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    if about.returncode == 0:
                        for line in about.stdout.split("\n"):
                            if "Total:" in line:
                                status["cloud"]["total"] = line.split(":", 1)[1].strip()
                            elif "Used:" in line:
                                status["cloud"]["used"] = line.split(":", 1)[1].strip()
                            elif "Free:" in line:
                                status["cloud"]["free"] = line.split(":", 1)[1].strip()
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
        
        # Интернет
        try:
            result = subprocess.run(["ping", "-c1", "-W2", "1.1.1.1"], capture_output=True, timeout=3)
            status["internet"] = result.returncode == 0
        except:
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

    def api_systems(self):
        systems = []
        if os.path.exists(ROMS_DIR):
            for d in os.listdir(ROMS_DIR):
                path = os.path.join(ROMS_DIR, d)
                if os.path.isdir(path):
                    has_roms = False
                    for root, dirs, files in os.walk(path):
                        if any(x in root for x in ["/images/", "/media/", "/videos/"]):
                            continue
                        for f in files:
                            if not f.endswith((".xml", ".txt", ".dat", ".png", ".jpg", ".jpeg", ".gif", ".bmp")):
                                has_roms = True
                                break
                        if has_roms:
                            break
                    if has_roms:
                        systems.append(d)
        
        # Дополнительно проверяем облако - там могут быть системы,
        # которых ещё нет на устройстве (например, ромы закинули прямо
        # в облако с компьютера, не трогая устройство). Без этого их
        # нельзя было бы выбрать и, соответственно, скачать.
        cloud_only = []
        try:
            result = subprocess.run(
                [RCLONE_PATH, "--config", RCLONE_CONF, "lsd", REMOTE_ROMS],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
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
        
        config = self.read_config()
        excluded = config.get("EXCLUDED_SYSTEMS", "").split("|") if config.get("EXCLUDED_SYSTEMS") else []
        selected = config.get("ROMS_SYNC_DIRS", "").split("|") if config.get("ROMS_SYNC_DIRS") else []
        
        self.send_json({
            "all": systems,
            "cloud_only": cloud_only,
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

        stats = self._read_rclone_stats()
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
                    subprocess.Popen(["bash", DOWNLOAD_SCRIPT, "--web-progress"], 
                                   stdout=subprocess.DEVNULL, 
                                   stderr=subprocess.DEVNULL)
                    self.send_json({"success": True, "message": messages[action]})
                else:
                    self.send_json({"success": False, "error": f"Скрипт не найден: {DOWNLOAD_SCRIPT}"})
            
            elif action == "upload":
                if os.path.exists(UPLOAD_SCRIPT):
                    subprocess.Popen(["bash", UPLOAD_SCRIPT, "--web-progress"], 
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
                subprocess.Popen(
                    ["/bin/sh", "-c", f"bash '{DOWNLOAD_SCRIPT}' --web-progress; rc=$?; if [ $rc -eq 0 ]; then bash '{UPLOAD_SCRIPT}' --web-progress; else exit $rc; fi"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                self.send_json({"success": True, "message": messages[action]})
            
            elif action == "roms_download":
                if os.path.exists(DOWNLOAD_ROMS):
                    subprocess.Popen(["bash", DOWNLOAD_ROMS, "--web-progress"], 
                                   stdout=subprocess.DEVNULL, 
                                   stderr=subprocess.DEVNULL)
                    self.send_json({"success": True, "message": messages[action]})
                else:
                    self.send_json({"success": False, "error": f"Скрипт не найден: {DOWNLOAD_ROMS}"})
            
            elif action == "roms_upload":
                if os.path.exists(UPLOAD_ROMS):
                    subprocess.Popen(["bash", UPLOAD_ROMS, "--web-progress"], 
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
    <div class="value" id="syncStats">0 —  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> 0 • <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> 0</div>
   </div>
    <div class="status-item">
      <div class="label"><svg width="13" height="13" viewBox="-6 -6 36 36" fill="none" style="vertical-align:0px;margin-right:3px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Сохранений</div>
      <div class="value" id="sysSaves">-</div>
    </div>
    <div class="status-item">
      <div class="label"><svg width="17" height="12" viewBox="-192 -123 1664 1068" style="vertical-align:0px;margin-right:3px"><g transform="translate(0,822) scale(0.1,-0.1)" fill="currentColor"><path d="M7121 8205 c-484 -56 -926 -221 -1315 -494 -238 -166 -476 -397 -637 -618 -23 -32 -44 -60 -45 -62 -2 -2 -40 8 -84 23 -117 38 -260 73 -385 92 -150 23 -442 23 -590 0 -611 -94 -1127 -423 -1468 -934 -235 -353 -362 -809 -344 -1229 l6 -132 -32 -5 c-18 -3 -72 -10 -122 -16 -413 -50 -861 -242 -1201 -515 -434 -349 -738 -846 -852 -1395 -38 -183 -47 -272 -46 -495 0 -243 14 -368 63 -571 221 -899 936 -1599 1835 -1794 268 -58 -2 -55 4336 -55 3806 0 4011 1 4125 18 649 97 1197 373 1635 824 142 145 217 237 324 396 233 346 381 728 448 1162 18 116 22 183 22 395 0 282 -16 420 -74 657 -180 738 -643 1363 -1298 1752 -333 198 -715 326 -1104 371 -117 14 -118 14 -118 89 0 95 -59 403 -107 556 -75 243 -205 524 -331 715 -452 687 -1140 1129 -1947 1250 -185 28 -520 35 -694 15z"/></g></svg>Облако</div>
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
    <button class="tab active" data-tab="saves"><svg width="16" height="16" viewBox="-6 -6 36 36" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Сохранения</button>
    <button class="tab" data-tab="roms"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>Ромы</button>
    <button class="tab" data-tab="stats"><svg width="13" height="13" viewBox="-312 -312 3120 3120" style="vertical-align:-2px;margin-right:4px"><g transform="translate(0,2496) scale(0.1,-0.1)" fill="currentColor"><path d="M9350 12533 c0 -6836 3 -12452 6 -12480 l7 -53 3153 0 3154 0 0 4408 c0 2425 -3 8041 -7 12480 l-6 8072 -3154 0 -3153 0 0 -12427z"/><path d="M521 15176 c-9 -10 -10 -1883 -5 -7595 l7 -7581 3154 0 3153 0 0 7583 c0 5885 -3 7586 -12 7595 -9 9 -722 12 -3149 12 -2662 0 -3138 -2 -3148 -14z"/><path d="M19945 7610 l-1750 -5 -3 -3803 -2 -3802 3162 0 3161 0 -6 3802 c-6 3005 -10 3804 -20 3810 -12 8 -1345 7 -4542 -2z"/></g></svg>Статистика</button>
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
</div>

    <!-- ОБЩАЯ ПОДПИСЬ -->
    <div class="sync-note">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>ВАЖНО:</strong></p>
        <p>• <strong>Загрузка:</strong> Это действие ЗАГРУЗИТ сохранения из облака на устройство. Если в облаке нет файла — он НЕ УДАЛЯЕТСЯ с устройства. Загружаются только новые или измененные файлы. Если облако пустое — НЕЛЬЗЯ загружаться, иначе синхронизация удалит все локальные сохранения!</p>
        <p>• <strong>Выгрузка:</strong> Это действие ВЫГРУЗИТ сохранения из устройства в облако. Если файла нет на устройстве — он УДАЛЯЕТСЯ из облака. Выгружаются только новые или измененные файлы. Удаление синхронизируется между устройствами.</p>
        <p>• <strong>Полная синхронизация:</strong> Это действие выполнит ПОЛНУЮ синхронизацию. Сначала ЗАГРУЗИТ сохранения из облака (если в облаке нет файла — он НЕ УДАЛЯЕТСЯ с устройства). Затем ВЫГРУЗИТ сохранения в облако (если файла нет на устройстве — он УДАЛЯЕТСЯ из облака). ВНИМАНИЕ: удаление синхронизируется в обе стороны!</p>
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
    
<!-- ПРОГРЕСС-БАР РОМОВ -->
<div id="syncProgressRoms" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--border-color)">
    <div style="display:flex;justify-content:space-between;margin-bottom:5px">
        <span id="syncProgressTextRoms" style="color:var(--text-secondary);font-size:13px">Синхронизация...</span>
        <span id="syncProgressPercentRoms" style="color:var(--accent);font-size:13px;font-weight:bold">Идёт передача</span>
    </div>
    <div style="width:100%;height:8px;background:var(--bg-primary);border-radius:4px;overflow:hidden">
        <div id="syncProgressBarRoms" style="width:35%;height:100%;background:linear-gradient(90deg,var(--accent),var(--accent-hover));border-radius:4px;animation:syncProgressMove 1.4s ease-in-out infinite;"></div>
    </div>
</div>

    <!-- ОБЩАЯ ПОДПИСЬ -->
    <div class="sync-note">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>ВАЖНО:</strong></p>
        <p>• <strong>Загрузка ромов:</strong> Это действие ЗАГРУЗИТ ромы из облака на устройство. Файлы на устройстве НЕ УДАЛЯЮТСЯ. Будут загружены только новые или измененные файлы.</p>
        <p>• <strong>Выгрузка ромов:</strong> Это действие УДАЛИТ из облака ромы, которых нет на устройстве. Если на устройстве не хватает каких-то ромов, они исчезнут из облака без возможности восстановления! Рекомендуется сначала ЗАГРУЗИТЬ ромы из облака или сделать бэкап облака.</p>
    </div>
    
    <div class="section-title" style="margin-top:20px"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M20 6h-8l-2-2H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z" fill="currentColor"/></svg>Выбор систем для резервного копирования</div>
    <div style="margin-bottom:10px;display:flex;gap:10px;flex-wrap:wrap;align-items:center">
        <button class="btn" onclick="selectAllRoms()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg>Выбрать все</button>
        <button class="btn btn-danger" onclick="deselectAllRoms()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>Очистить все</button>
        <button class="btn" onclick="toggleMedia()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z" fill="currentColor"/></svg>Медиа: <span id="mediaStatus">-</span></button>
        <span style="color:var(--text-secondary);font-size:12px">Кликните по системе, чтобы выбрать/отменить</span>
    </div>
    <div class="system-list" id="romsList"><div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Загрузка систем...</div></div>
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
      <label>Логирование:</label>
      <select id="settingLogEnabled">
        <option value="true">Включено</option>
        <option value="false">Выключено</option>
      </select>
    </div>
    <!-- div class="settings-row">
      <label>Уровень логов:</label>
      <select id="settingLogLevel">
        <option value="info">Info</option>
        <option value="debug">Debug</option>
        <option value="error">Error</option>
      </select>
    </div -->
    <div class="settings-row">
      <label>Макс. размер лога:</label>
      <input type="number" id="settingLogSize" value="102400" step="1024">
      <span style="color:var(--text-secondary);font-size:12px">байт</span>
    </div>
    <button class="btn btn-primary" onclick="saveSettings()">Сохранить настройки</button>
  </div>

  <!-- ВКЛАДКА: СТАТИСТИКА -->
  <div id="tab-stats" class="tab-content">
    <div class="stats-group-label"><svg width="14" height="14" viewBox="-6 -6 36 36" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Сохранения</div>
    <div class="stats-grid" id="statsGridSaves">
      <div class="stats-item">
        <div class="num" id="statSyncTotal">0</div>
        <div class="label">Всего синхр.</div>
      </div>
      <div class="stats-item">
        <div class="num ok" id="statSyncOk">0</div>
        <div class="label">Успешно</div>
      </div>
      <div class="stats-item">
        <div class="num error" id="statSyncError">0</div>
        <div class="label">Ошибок</div>
      </div>
    </div>
    <div class="stats-group-label"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>Ромы</div>
    <div class="stats-grid" id="statsGridRoms">
      <div class="stats-item">
        <div class="num" id="statRomsTotal">0</div>
        <div class="label">Всего ромов</div>
      </div>
      <div class="stats-item">
        <div class="num ok" id="statRomsOk">0</div>
        <div class="label">Ромов успешно</div>
      </div>
      <div class="stats-item">
        <div class="num error" id="statRomsError">0</div>
        <div class="label">Ромов ошибок</div>
      </div>
    </div>
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

async function apiFetch(endpoint, options = {}) {
  try {
    const res = await fetch(API + endpoint, options);
    return await res.json();
  } catch (e) {
    return { success: false, error: e.message };
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
    const barEl = document.getElementById(target === 'roms' ? 'syncProgressBarRoms' : 'syncProgressBarSaves');
    const percentEl = document.getElementById(target === 'roms' ? 'syncProgressPercentRoms' : 'syncProgressPercentSaves');
    if (!barEl || !percentEl) return;

    if (typeof data.percent === 'number' && data.totalBytes > 0) {
        const pct = Math.min(100, Math.max(0, data.percent));
        barEl.style.animation = 'none';
        barEl.style.width = pct + '%';
        let label = pct + '%';
        if (data.speed > 0) label += ' · ' + formatBytes(data.speed) + '/с';
        if (data.eta > 0) label += ' · осталось ' + Math.round(data.eta) + ' сек';
        if (data.totalTransfers > 0) label += ' · ' + (data.transfers || 0) + '/' + data.totalTransfers + ' файлов';
        percentEl.textContent = label;
    } else {
        barEl.style.animation = 'syncProgressMove 1.4s ease-in-out infinite';
        barEl.style.width = '35%';
        percentEl.textContent = 'Идёт передача';
    }
}

// ========== ЗАПУСК СИНХРОНИЗАЦИИ ==========

// ========== ЗАПУСК СИНХРОНИЗАЦИИ ==========

async function runSyncWithProgress(action) {
    setButtonsDisabled(true);

    const names = {
        'download': 'Загрузка сохранений',
        'upload': 'Выгрузка сохранений',
        'full': 'Полная синхронизация',
        'roms_download': 'Загрузка ромов',
        'roms_upload': 'Выгрузка ромов'
    };

    // Определяем target один раз
    const target = (action === 'roms_download' || action === 'roms_upload') ? 'roms' : 'saves';
    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> ' + names[action] + ' запускается...', target);

    let polling = null;
    let seenActive = false;

    const stopPolling = () => {
        if (polling) {
            clearInterval(polling);
            polling = null;
        }
        window._syncPolling = null;
    };

    const poll = async () => {
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
        const res = await apiFetch('/sync?action=' + action, { method: 'POST' });
        if (!res.success) {
            stopPolling();
            showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Ошибка: ' + (res.error || 'Неизвестная ошибка'), target);
            showToast((res.error || 'Ошибка'), 'error');
            setTimeout(() => { showProgress(false); setButtonsDisabled(false); }, 2500);
            return;
        }

        // Ждём немного, чтобы скрипт успел запуститься
        await new Promise(r => setTimeout(r, 500));
        
        await poll();
        polling = setInterval(poll, 1000);
        window._syncPolling = polling;
    } catch (e) {
        stopPolling();
        showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Ошибка: ' + e.message, target);
        showToast('Ошибка: ' + e.message, 'error');
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
    if (this.dataset.tab === 'stats') refreshStats();
  });
});

// ========== СТАТУС (НЕ ОБНОВЛЯЕТ НАСТРОЙКИ) ==========

async function refreshStatus() {
  try {
    const data = await apiFetch('/status');
    
    // Статистика
    const total = data.stats?.sync?.total || 0;
    const ok = data.stats?.sync?.ok || 0;
    const err = data.stats?.sync?.error || 0;
    document.getElementById('syncStats').innerHTML = total + ' —  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> ' + ok + ' • <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + err;
    const savesCount = data.saves?.count ?? 0;
    const savesSize = data.saves?.size ?? '0 Б';
    document.getElementById('sysSaves').textContent = savesCount + ' файл., ' + savesSize;
    
    const cloudEl = document.getElementById('sysCloud');
    if (data.cloud?.status === 'connected') {
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> ' + (data.cloud.free || '0');
      cloudEl.className = 'value ok';
    } else {
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Не подключено';
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
      document.getElementById('settingLogEnabled').value = data.config.LOG_ENABLED || 'true';
      document.getElementById('settingLogLevel').value = data.config.LOG_LEVEL || 'info';
      document.getElementById('settingLogSize').value = data.config.MAX_LOG_SIZE || 102400;
    }
  } catch (e) {
    console.error('Load settings error:', e);
  }
}

// ========== ЛОГИ ==========

async function refreshLogs() {
  try {
    const data = await apiFetch('/logs?lines=20');
    const container = document.getElementById('logContainer');
    if (data.lines && data.lines.length > 0) {
      container.innerHTML = data.lines.map(line => {
        return `<div class="log-line">${escapeHtml(line)}</div>`;
      }).join('');
      container.scrollTop = container.scrollHeight;
    } else {
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
    showToast('Ошибка: ' + e.message, 'error');
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
        await apiFetch('/roms', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({action: 'select', systems: selected})
        });
        refreshStatus();
    } catch (e) {
        console.error('Save error:', e);
    }
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
            showToast(res.message, 'success');  // ← ЭТУ СТРОКУ ДОБАВИТЬ
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
    showToast('Ошибка: ' + e.message, 'error');
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
    } else {
      romsContainer.innerHTML = '<div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3H4.99c-1.11 0-1.98.9-1.98 2L3 19c0 1.1.88 2 1.99 2H19c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 12h-4c0 1.66-1.35 3-3 3s-3-1.34-3-3H4.99V5H19v10z" fill="currentColor"/></svg>Нет систем с ромами</div>';
    }
    
    const excludeContainer = document.getElementById('excludeList');
    if (data.all && data.all.length > 0) {
      excludeContainer.innerHTML = data.all.map(sys => {
        const isExcluded = data.excluded.includes(sys);
        return `<div class="system-item ${isExcluded ? 'excluded' : ''}" onclick="excludeAction('${isExcluded ? 'remove' : 'add'}', '${sys}')">
          <span class="name">${sys}</span>
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
    showToast('Ошибка: ' + e.message, 'error');
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
    LOG_ENABLED: document.getElementById('settingLogEnabled').value,
    // LOG_LEVEL: document.getElementById('settingLogLevel').value,  // ← ЗАКОММЕНТИРОВАТЬ ИЛИ УДАЛИТЬ
    MAX_LOG_SIZE: parseInt(document.getElementById('settingLogSize').value) || 102400
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
    showToast('Ошибка: ' + e.message, 'error');
  }
}

// ========== СТАТИСТИКА ==========

async function refreshStats() {
  try {
    const data = await apiFetch('/stats');
    if (data) {
      document.getElementById('statSyncTotal').textContent = data.sync?.total || 0;
      document.getElementById('statSyncOk').textContent = data.sync?.ok || 0;
      document.getElementById('statSyncError').textContent = data.sync?.error || 0;
      document.getElementById('statRomsTotal').textContent = data.roms?.total || 0;
      document.getElementById('statRomsOk').textContent = data.roms?.ok || 0;
      document.getElementById('statRomsError').textContent = data.roms?.error || 0;
    }
  } catch (e) {
    console.error('Stats error:', e);
  }
}

// ========== ЗАПУСК ==========

loadTheme();
loadSettings();        // загружаем настройки один раз при старте
refreshStatus();
refreshLogs();
refreshStats();
loadSystems();         // ЗАГРУЖАЕМ СИСТЕМЫ ПРИ СТАРТЕ

// Автообновление (настройки НЕ обновляются)
setInterval(refreshStatus, 10000);
setInterval(refreshLogs, 8000);
setInterval(refreshStats, 10000);
</script>
</body>
</html>'''

class QuietHTTPServer(http.server.HTTPServer):
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
    
    print(f"\n✅ Save Sync Web UI v1.4.4 запущен")
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
    echo " Save Sync Diagnostics v1.4.4"
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
    CLOUD_USED=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "used" | awk '{print $2, $3}')
    CLOUD_TOTAL=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "total" | awk '{print $2, $3}')
    CLOUD_FREE=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "free" | awk '{print $2, $3}')
    print_2col "Использовано" "${CLOUD_USED:-неизвестно}"
    print_2col "Всего" "${CLOUD_TOTAL:-неизвестно}"
    print_2col "Свободно" "${CLOUD_FREE:-неизвестно}"
    
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
    TOTAL_SYNC=$(grep -c "Сохранения загружены\|Выгрузка сохранений" "$LOG_FILE" 2>/dev/null)
    ERR_SYNC=$(grep -c "Ошибка\|недоступны" "$LOG_FILE" 2>/dev/null)
    [ -z "$TOTAL_SYNC" ] && TOTAL_SYNC=0
    [ -z "$ERR_SYNC" ] && ERR_SYNC=0
    OK_SYNC=$((TOTAL_SYNC - ERR_SYNC))
    [ $OK_SYNC -lt 0 ] && OK_SYNC=0
    print_2col "Статистика" "$TOTAL_SYNC синхр. ($OK_SYNC OK, $ERR_SYNC ERR)"
    if [ "$ERR_SYNC" -gt 0 ]; then
        WARNINGS=$((WARNINGS + ERR_SYNC))
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
    
    # Интернет
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        PING_TIME=$(ping -c1 -W2 1.1.1.1 2>/dev/null | grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}')
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

# Автозагрузка сохранений
AUTOLOAD_FOUND=false
if [ -f "$BASE/custom.sh" ]; then
    if grep -q "download_sync.sh" "$BASE/custom.sh" 2>/dev/null || grep -q "download_saves.sh" "$BASE/custom.sh" 2>/dev/null; then
        print_2col "Автозагрузка" "✅ настроен (custom.sh)"
        AUTOLOAD_FOUND=true
    fi
fi
if [ -f "$BASE/services/custom_service" ]; then
    if grep -q "download_sync.sh" "$BASE/services/custom_service" 2>/dev/null || grep -q "download_saves.sh" "$BASE/services/custom_service" 2>/dev/null; then
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

if [ -f "$RCLONE_CONF" ] && { [ -f "$DOWNLOAD_SCRIPT" ] || [ -f "$BASE/download_saves.sh" ]; } && { [ -f "$UPLOAD_SCRIPT" ] || [ -f "$BASE/upload_saves.sh" ]; }; then
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " Save Sync уже установлен ($SYSTEM)"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo " 1 - Обновить до v1.4.4"
    echo " 2 - Переустановить заново"
    echo " 3 - Выход"
    echo ""
    read -p "Выберите вариант (1-3): " REINSTALL_CHOICE
    case "$REINSTALL_CHOICE" in
    1)
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📦 Обновление до v1.4.4"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        
        echo "🗑️ Удаление старых файлов (v1.2)..."
        
        if [ -f "$BASE/download_saves.sh" ]; then
            rm -f "$BASE/download_saves.sh"
            echo "✅ Удален download_saves.sh"
        fi
        if [ -f "$BASE/upload_saves.sh" ]; then
            rm -f "$BASE/upload_saves.sh"
            echo "✅ Удален upload_saves.sh"
        fi
        
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
        
        # Обновляем ссылку на download_sync.sh если была старая
        if [ -f "$AUTOLOAD_FILE" ]; then
            if grep -q "download_saves.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
                sed -i "s|download_saves.sh|download_sync.sh|g" "$AUTOLOAD_FILE"
                echo "✅ Ссылка в $(basename $AUTOLOAD_FILE) обновлена"
            fi
        fi
        
        # Создаём файл если его нет
        if [ ! -f "$AUTOLOAD_FILE" ]; then
            echo '#!/bin/bash' > "$AUTOLOAD_FILE"
            chmod +x "$AUTOLOAD_FILE"
            echo "✅ Создан $(basename $AUTOLOAD_FILE)"
        fi
        
        # Добавляем download_sync.sh если нет (путь берём из $DOWNLOAD_SCRIPT,
        # чтобы корректно работало на Recalbox, а не только на Batocera/KNULLI)
        if ! grep -q "download_sync.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
            sed -i "/^#!/a bash $DOWNLOAD_SCRIPT &" "$AUTOLOAD_FILE"
            echo "✅ Загрузка сохранений добавлена в $(basename $AUTOLOAD_FILE)"
        fi
        
        # Добавляем веб-интерфейс если нет
        if ! grep -q "install_sync.sh --web" "$AUTOLOAD_FILE" 2>/dev/null; then
            cat >> "$AUTOLOAD_FILE" << EOF

# Запуск веб-интерфейса Save Sync
(
    for i in \$(seq 1 30); do
        if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
            bash $BASE/install_sync.sh --web &
            break
        fi
        sleep 2
    done
) &
EOF
            echo "✅ Веб-интерфейс добавлен в $(basename $AUTOLOAD_FILE)"
        fi
        
        echo ""
        echo "✅ Обновление до v1.4.4 завершено!"

        log_msg "Обновление до v1.4.4 завершено"

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
        rm -f "$DOWNLOAD_SCRIPT" "$UPLOAD_SCRIPT" "$DOWNLOAD_ROMS" "$UPLOAD_ROMS" 2>/dev/null
        rm -f "$BASE/download_saves.sh" "$BASE/upload_saves.sh" 2>/dev/null
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
echo " Save Sync v1.4.4 - Установка"
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
echo ""

read -p "Введите номер (1-7): " CHOICE

BACKEND_TYPE="webdav"

case "$CHOICE" in
1) URL="https://webdav.yandex.ru"; VENDOR="yandex" ;;
2) URL="https://webdav.cloud.mail.ru"; VENDOR="other" ;;
3) URL="https://webdav.pcloud.com"; VENDOR="other" ;;
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
*) echo "❌ Неверный выбор."; exit 1 ;;
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
    cat > "$RCLONE_CONF" <<EOF
[$REMOTE_NAME]
type = mega
user = $YUSER
pass = $PASS
EOF
else
    cat > "$RCLONE_CONF" <<EOF
[$REMOTE_NAME]
type = webdav
url = $URL
vendor = $VENDOR
user = $YUSER
pass = $PASS
EOF
fi

chmod 600 "$RCLONE_CONF"

echo "Проверка подключения..."
if "$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_NAME:" >/dev/null 2>&1; then
    echo "✅ Подключение успешно."
else
    echo "❌ Ошибка подключения."
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
if ! grep -q "download_sync.sh" "$AUTOLOAD_FILE" 2>/dev/null && ! grep -q "download_saves.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
    sed -i "/^#!/a bash $DOWNLOAD_SCRIPT &" "$AUTOLOAD_FILE"
    echo "✅ Загрузка сохранений добавлена в $(basename $AUTOLOAD_FILE)"
fi

# Добавляем веб-интерфейс если нет
if ! grep -q "install_sync.sh --web" "$AUTOLOAD_FILE" 2>/dev/null; then
    cat >> "$AUTOLOAD_FILE" << EOF

# Запуск веб-интерфейса Save Sync
(
    for i in \$(seq 1 30); do
        if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
            bash $BASE/install_sync.sh --web &
            break
        fi
        sleep 2
    done
) &
EOF
    echo "✅ Веб-интерфейс добавлен в $(basename $AUTOLOAD_FILE)"
else
    echo "✅ Веб-интерфейс уже есть в $(basename $AUTOLOAD_FILE)"
fi

SYSTEM_VERSION=$(get_system_version)

log_msg "Save Sync v1.4.4 | $SYSTEM ($SYSTEM_VERSION) | rclone v${NEW_VER:-unknown}"
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