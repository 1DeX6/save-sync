#!/bin/bash

################################################
# Save Sync Installer v1.4.5
# Cloud sync for saves and ROMs
# Batocera / KNULLI / Recalbox
#
# Commands:
#  install_sync.sh      - install / update
#  install_sync.sh --info          - diagnostics
#  install_sync.sh --config   - control panel
#  install_sync.sh --web         - web interface
################################################

# Clean up temp files on exit
trap 'rm -rf /tmp/rclone.zip /tmp/rclone-* /tmp/save_sync_web' EXIT

# --- Global variables (set after detect_system) ---
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

# Status files (system-independent)
STATUS_FILE="/tmp/save_sync_last_status"
LAST_SYNC_TIME="/tmp/save_sync_last_time"

# --- Default settings (overridden from config) ---
SYNC_INTERVAL=0
MAX_RETRIES=3
CONFLICT_KEEP_DAYS=3
MIN_FREE_KB=51200
MAX_LOG_SIZE=102400
ROMS_SYNC_DIRS=""
ROMS_SYNC_MEDIA="false"
EXCLUDED_SYSTEMS=""
LOG_ENABLED="true"
LOG_LEVEL="info"
LOG_KEEP_COUNT=3

# --- Cloud variables ---
REMOTE_NAME="cloud"
REMOTE_FOLDER="GameSaves"
REMOTE=""
REMOTE_ROMS=""
FIRST_SYNC_MARKER=""

# Pause function
pause() {
    echo
    read -p "Press Enter to continue..."
}

############################################
# Check whether rclone is actually executable
############################################
# On some systems (Recalbox in particular) the
# /recalbox/share partition is mounted with noexec (or uses
# a filesystem that doesn't support execute bits).
# chmod +x succeeds without error in that case, but the
# binary itself can't be run ("Permission denied").
# If detected, we copy rclone to a temporary
# directory in /tmp (tmpfs, always executable) and switch
# RCLONE_PATH to that copy. This must be called again
# on every script run, since /tmp is cleared on
# device reboot.
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
# Config-handling functions
############################################

create_default_config() {
    cat > "$CONFIG_FILE" << 'EOF'
# ========================================
# Save Sync v1.4.5 - Main config
# ========================================

# ── SYNC SETTINGS ──
# 0 = always, 300 = 5 min, 900 = 15 min, 3600 = 1 hour
SYNC_INTERVAL="0"

# Number of retries on error
MAX_RETRIES="3"

# How many days conflict copies of saves are kept in the cloud (0 = do not keep)
CONFLICT_KEEP_DAYS="3"

# Free space threshold (KB) below which sync is skipped
MIN_FREE_KB="51200"

# ── ROM SETTINGS ──
ROMS_SYNC_DIRS=""
ROMS_SYNC_MEDIA="false"
EXCLUDED_SYSTEMS=""

# ── LOGGING SETTINGS ──
LOG_ENABLED="true"
MAX_LOG_SIZE="102400"
LOG_LEVEL="info"
LOG_KEEP_COUNT="3"
EOF
    chmod 644 "$CONFIG_FILE"
}

sync_stats_counts() {
    SYNC_OK=$(grep -cE "Saves downloaded|Saves uploaded" "$LOG_FILE" 2>/dev/null); SYNC_OK=${SYNC_OK:-0}
    # "with changes" = the log line says what was moved: "(sent: 1, ...)"; a plain line or "(no changes)" means nothing was transferred
    SYNC_NOTED=$(grep -cE "(Saves downloaded|Saves uploaded) \(" "$LOG_FILE" 2>/dev/null); SYNC_NOTED=${SYNC_NOTED:-0}
    SYNC_EMPTY=$(grep -cE "(Saves downloaded|Saves uploaded) \(no changes\)" "$LOG_FILE" 2>/dev/null); SYNC_EMPTY=${SYNC_EMPTY:-0}
    SYNC_CHG=$((SYNC_NOTED - SYNC_EMPTY))
    SYNC_NOCHG=$((SYNC_OK - SYNC_CHG))
    SYNC_ERR=$(grep -cE "Save (download|upload) error|First (download|upload) error|Upload error for saves|Cloud unavailable \(no network" "$LOG_FILE" 2>/dev/null); SYNC_ERR=${SYNC_ERR:-0}
}

keep_days_label() {
    if [ "${CONFLICT_KEEP_DAYS:-3}" = "0" ]; then echo "not kept"; else echo "${CONFLICT_KEEP_DAYS:-3} days"; fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # Safe config loading - read line by line
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            
            # Trim whitespace and quotes
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs | sed -e 's/^"//' -e 's/"$//')
            
            # Assign the variable
            case "$key" in
                SYNC_INTERVAL) SYNC_INTERVAL="$value" ;;
                MAX_RETRIES) MAX_RETRIES="$value" ;;
                CONFLICT_KEEP_DAYS) CONFLICT_KEEP_DAYS="$value" ;;
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
        # After creating the config, load it safely
        load_config
        return 1
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# ========================================
# Save Sync v1.4.5 - Main config
# ========================================

# ── SYNC SETTINGS ──
SYNC_INTERVAL="$SYNC_INTERVAL"
MAX_RETRIES="$MAX_RETRIES"
CONFLICT_KEEP_DAYS="$CONFLICT_KEEP_DAYS"
MIN_FREE_KB="$MIN_FREE_KB"

# ── ROM SETTINGS ──
ROMS_SYNC_DIRS="$ROMS_SYNC_DIRS"
ROMS_SYNC_MEDIA="$ROMS_SYNC_MEDIA"
EXCLUDED_SYSTEMS="$EXCLUDED_SYSTEMS"

# ── LOGGING SETTINGS ──
LOG_ENABLED="$LOG_ENABLED"
MAX_LOG_SIZE="$MAX_LOG_SIZE"
LOG_LEVEL="$LOG_LEVEL"
LOG_KEEP_COUNT="$LOG_KEEP_COUNT"
EOF
    chmod 644 "$CONFIG_FILE"
}

############################################
# Auto-detect the system
############################################

detect_system() {
    # 1. Check via /etc/os-release
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
                echo "❌ ArkOS/EmuELEC system detected."
                echo ""
                echo "Unfortunately, ArkOS and EmuELEC are no longer supported by this script:"
                echo "on these systems the save folder is the same as the ROM folder, so"
                echo "a 'save' sync would risk uploading your entire ROM collection"
                echo "to the cloud."
                echo ""
                echo "Supported systems: Batocera, KNULLI, Recalbox."
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
    
    # 2. Check via KNULLI files
    if [ -f "/usr/share/knulli/knulli.version" ] || [ -f "/etc/knulli-release" ] || [ -f "/boot/knulli" ]; then
        SYSTEM="KNULLI"
        BASE="/userdata/system"
        SAVE_DIR="/userdata/saves"
        ROMS_DIR="/userdata/roms"
        return 0
    fi
    
    # 3. Check for Batocera
    if [ -f "/boot/batocera" ] || [ -f "/etc/batocera-release" ] || [ -f "/usr/bin/batocera-es-swissknife" ]; then
        SYSTEM="Batocera"
        BASE="/userdata/system"
        SAVE_DIR="/userdata/saves"
        ROMS_DIR="/userdata/roms"
        return 0
    fi

    # 4. ArkOS/EmuELEC are no longer supported - report clearly and exit,
    # instead of falling through to a generic "system not detected"
    if [ -f "/etc/emuelec-release" ] || [ -d "/storage/.config/emuelec" ] || [ -f "/etc/arkos-release" ] || [ -f "/opt/.arkos" ]; then
        echo "❌ ArkOS/EmuELEC system detected."
        echo ""
        echo "Unfortunately, ArkOS and EmuELEC are no longer supported by this script:"
        echo "on these systems the save folder is the same as the ROM folder, so"
        echo "a 'save' sync would risk uploading your entire ROM collection"
        echo "to the cloud."
        echo ""
        echo "Supported systems: Batocera, KNULLI, Recalbox."
        exit 1
    fi
    
    # 5. Check for Recalbox
    if [ -f "/etc/recalbox-release" ] || [ -f "/recalbox/recalbox" ]; then
        SYSTEM="Recalbox"
        BASE="/recalbox/share/system"
        SAVE_DIR="/recalbox/share/saves"
        ROMS_DIR="/recalbox/share/roms"
        return 0
    fi
    
    # 6. Check for characteristic files
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
    
    # 7. Check for folders (as a fallback)
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
    
    # System not detected
    return 1
}

# Run system detection
if detect_system; then
    echo "✅ Detected system: $SYSTEM"
    
    # Get IP address for display (globally)
    IP_ADDR=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR="localhost"
    fi
    
    # On Batocera/KNULLI the partition with install_sync.sh is usually ext4 - "bash"
    # isn't needed before the command. On Recalbox the partition may be mounted
    # such that the file can't run directly (see fix_recalbox_boot_hook) -
    # so the user-facing hints only show "bash" where
    # it's actually needed.
    if [ "$SYSTEM" = "Recalbox" ]; then
        RUN_PREFIX="bash "
    else
        RUN_PREFIX=""
    fi
else
    echo "❌ System not detected"
    echo ""
    echo "Information to add support:"
    echo "Copy the output below and send it to the 4pda forum thread - https://clck.ru/3V3gTJ."
    echo "══════════════════════════════════════════════════════════"
    echo ">>> Saves:"
    find / -name "*.srm" -o -name "*.state" -o -name "*.sav" -o -name "*.mcd" -o -name "*.eep" -o -name "*.fla" -o -name "*.mcr" 2>/dev/null | head -10
    echo ""
    echo ">>> /etc/os-release:"
    cat /etc/os-release 2>/dev/null || echo "File not found"
    echo ""
    echo ">>> Available folders:"
    ls -la /userdata/ /recalbox/ /roms/ /opt/ /MUOS/ /.userdata/ /storage/ 2>/dev/null
    echo ""
    echo ">>> All .sh files in system folders:"
    find / \( -path "/userdata" -o -path "/recalbox" -o -path "/opt" -o -path "/MUOS" -o -path "/mnt" -o -path "/storage" \) -name "*.sh" 2>/dev/null | head -15
    echo ""
    echo ">>> Script folders:"
    ls -la /etc/init.d/*custom* /etc/init.d/*user* 2>/dev/null
    echo ""
    echo ">>> System version:"
    cat /etc/os-release 2>/dev/null | head -5 || cat /etc/release 2>/dev/null || uname -a
    echo ""
    echo ">>> Emulator events:"
    ls -la /userdata/system/scripts/ /recalbox/share/system/scripts/ /opt/system/scripts/ 2>/dev/null
    echo "══════════════════════════════════════════════════════════"
    exit 1
fi

# ============================================
# DEVICE DETECTION
# ============================================

detect_device() {
    # 1. DEVICE DETECTION
    if [ -z "$DEVICE_NAME" ]; then
        if [ -f "/proc/device-tree/model" ]; then
            DEVICE_NAME=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
        elif [ -f "/sys/firmware/devicetree/base/model" ]; then
            DEVICE_NAME=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
        fi
    fi
    
    if [ -z "$DEVICE_NAME" ] || [ "$DEVICE_NAME" = "unknown" ]; then
        case $(uname -m) in
            aarch64) DEVICE_NAME="ARM64 device" ;;
            armv7l)  DEVICE_NAME="ARMv7 device" ;;
            x86_64)  DEVICE_NAME="x86_64 device" ;;
            *)       DEVICE_NAME="unknown ($(uname -m))" ;;
        esac
    fi
    
    # 2. PROCESSOR DETECTION (AUTOMATIC)
    if [ -z "$DEVICE_CPU" ] || [ "$DEVICE_CPU" = "unknown" ]; then
        # Try via /proc/device-tree/compatible
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
        
        # If not detected, try /proc/cpuinfo
        if [ -z "$DEVICE_CPU" ] || [ "$DEVICE_CPU" = "unknown" ]; then
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
    
    # 3. ARCHITECTURE
    if [ -z "$DEVICE_ARCH" ]; then
        DEVICE_ARCH=$(uname -m)
    fi
    
    # 4. FIRMWARE VERSION
    if [ -z "$CFW_VERSION" ] || [ "$CFW_VERSION" = "unknown" ]; then
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
        
        if [ -z "$CFW_VERSION" ] || [ "$CFW_VERSION" = "unknown" ]; then
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
    
    # 5. ADDITIONAL INFO
    if [ -z "$CPU_CORES" ]; then
        CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null)
        [ -z "$CPU_CORES" ] && CPU_CORES="unknown"
    fi
    
    if [ -z "$CPU_FREQ" ]; then
        if [ -f "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq" ]; then
            CPU_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
            CPU_FREQ="$((CPU_FREQ / 1000)) MHz"
        fi
        [ -z "$CPU_FREQ" ] && CPU_FREQ="unknown"
    fi
    
    if [ -z "$DEVICE_TEMP" ]; then
        if [ -f "/sys/class/thermal/thermal_zone0/temp" ]; then
            DEVICE_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
            DEVICE_TEMP="$((DEVICE_TEMP / 1000))°C"
        fi
        [ -z "$DEVICE_TEMP" ] && DEVICE_TEMP="unknown"
    fi
    
    if [ -z "$MEM_INFO" ]; then
        MEM_TOTAL=$(grep "MemTotal" /proc/meminfo 2>/dev/null | awk '{print $2}')
        MEM_AVAIL=$(grep "MemAvailable" /proc/meminfo 2>/dev/null | awk '{print $2}')
        if [ -n "$MEM_TOTAL" ] && [ -n "$MEM_AVAIL" ]; then
            MEM_INFO="$((MEM_AVAIL / 1024))/$((MEM_TOTAL / 1024)) MB"
        fi
        [ -z "$MEM_INFO" ] && MEM_INFO="unknown"
    fi
}
# Run device detection
detect_device

# --- INITIALIZE ALL PATHS AFTER SYSTEM DETECTION ---
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
# Persistent sync state (survives reboots, unlike /tmp):
# PENDING_UPLOAD=1 - local saves changed but were not uploaded yet
# LAST_GOOD_SYNC=<unix time> - last moment device and cloud were in sync
STATE_FILE="$BASE/.sync_state"
LINK_SCRIPT="$BASE/link_download.py"
ENGINE_SCRIPT="$BASE/sync_engine.py"

# --- INITIALIZE CLOUD VARIABLES ---
REMOTE_NAME="cloud"
REMOTE_FOLDER="GameSaves"
REMOTE="$REMOTE_NAME:$REMOTE_FOLDER"
REMOTE_ROMS="$REMOTE_NAME:GameROMs"
# The remote name is required: without "cloud:" rclone treats the path as
# a LOCAL one, and the marker never reaches the cloud.
FIRST_SYNC_MARKER="$REMOTE_NAME:$REMOTE_FOLDER/.first_sync_done"

# Load the config
load_config

# If rclone was already installed previously, but the partition is mounted noexec -
# switch immediately to the executable copy in the temp directory.
ensure_rclone_executable

# Auto-detect architecture
SYS_ARCH=$(uname -m)
case "$SYS_ARCH" in
    armv6*|armv7*)  SYS_ARCH="arm" ;;
    aarch64|arm64)  SYS_ARCH="arm64" ;;
    i386|i686)      SYS_ARCH="386" ;;
    x86_64)         SYS_ARCH="amd64" ;;
    *) echo "Architecture not supported."; exit 1 ;;
esac

RCLONE_URL="https://downloads.rclone.org/rclone-current-linux-${SYS_ARCH}.zip"

# Check dependencies
MISSING=""
for CMD in curl unzip flock; do
    command -v $CMD >/dev/null 2>&1 || MISSING="$MISSING $CMD"
done

if [ -n "$MISSING" ]; then
    echo "Missing required utilities:$MISSING"
    echo "Install them manually and run the script again."
    exit 1
fi

############################################
# Functions
############################################

rotate_log() {
    # Load the config to get MAX_LOG_SIZE
    load_config
    
    mkdir -p "$LOG_DIR" || return 1
    if [ -f "$LOG_FILE" ] && [ $(wc -c < "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
    fi
}

log_msg() {
    # Check whether logging is enabled
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
    [ ! -f /tmp/rclone.zip ] && { echo "Error downloading rclone."; return 1; }
    unzip -o /tmp/rclone.zip -d /tmp || { echo "Error extracting rclone."; return 1; }
    DIR_NAME=$(find /tmp -maxdepth 1 -type d -name "rclone-*-linux-${SYS_ARCH}" 2>/dev/null | head -1)
    [ -z "$DIR_NAME" ] && { echo "Error extracting rclone."; return 1; }
    cp "$DIR_NAME/rclone" "$RCLONE_BIN" || return 1
    chmod +x "$RCLONE_BIN" || return 1
    ensure_rclone_executable
}

############################################
# System version detection function
############################################

get_system_version() {
    local SYSTEM_VER="unknown"
    
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
    
    # Add device information
    if [ -n "$DEVICE_NAME" ] && [ "$DEVICE_NAME" != "unknown" ]; then
        SYSTEM_VER="$SYSTEM_VER ($DEVICE_NAME)"
    fi
    
    echo "$SYSTEM_VER"
}

############################################
# create_engine_script - two-way save sync (Python)
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
# Usage: sync_engine.py sync [--web-progress] [--verbose]
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
import time
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

SKIP_NAMES = [".first_sync_done", ".DS_Store", "Thumbs.db", "*.log", "*.cache", ".keep", "*.keep",
              MANIFEST, "*.partial", ".ss_tmp*"]
PORT_SAVE_DIRS = ("saves", "conf")
# caches of the graphics driver and of emulators: created by every device for its
# own GPU, useless elsewhere and can grow large - never synced, wherever they are
CACHE_DIRS = {"mesa_shader_cache", "mesa_shader_cache_db", ".cache", "shader_cache", "shadercache"}
PORT_SKIP_DIRS = {"textures", "screenshots", "cache", "shaders", "logs", "tmp", "temp"} | CACHE_DIRS
PORT_SKIP_WORDS = ("settings", "config", "options", "controls", "keymap", "gptk")
PORT_GAMEDATA_EXT = (".ini", ".sav", ".dat", ".json")
PORT_MAX = 10 * 1024 * 1024
PORT_GAMEDATA_MAX = 1024 * 1024

MSG = {
    "en": {
        "conflict_local": "Save conflict: {rel} was changed on different devices - kept the newer version from this device",
        "conflict_cloud": "Save conflict: {rel} was changed on different devices - kept the newer version from {dev}",
        "copy_kept": ", the older one is kept for {days} d. in {dir}",
        "deleted_here": "Removed here (deleted on another device): {rel}",
        "deleted_cloud": "Removed from the cloud: {rel}",
        "guard": "Warning: {n} files look deleted at once ({where}) - that looks like a failure, not a deletion; nothing was deleted",
        "where_here": "on this device", "where_cloud": "in the cloud",
        "summary": "Downloaded: {d}, uploaded: {u}, conflicts: {c}, deleted: {x}",
        "n_sent": "sent: {n}", "n_recv": "received: {n}", "n_del": "deleted: {n}", "n_conf": "conflicts: {n}",
        "no_changes": "no changes",
        "other_device": "another device",
    },
    "ru": {
        "conflict_local": "Конфликт сохранений: {rel} изменён на разных устройствах - оставлена более новая версия с этого устройства",
        "conflict_cloud": "Конфликт сохранений: {rel} изменён на разных устройствах - оставлена более новая версия с {dev}",
        "copy_kept": ", более старая хранится {days} дн. в {dir}",
        "deleted_here": "Удалено здесь (удалено на другом устройстве): {rel}",
        "deleted_cloud": "Удалено из облака: {rel}",
        "guard": "Предупреждение: сразу {n} файлов выглядят удалёнными ({where}) - похоже на сбой, а не на удаление; ничего не удалено",
        "where_here": "на устройстве", "where_cloud": "в облаке",
        "summary": "Скачано: {d}, выгружено: {u}, конфликтов: {c}, удалено: {x}",
        "n_sent": "отправлено: {n}", "n_recv": "получено: {n}", "n_del": "удалено: {n}", "n_conf": "конфликтов: {n}",
        "no_changes": "изменений нет",
        "other_device": "другого устройства",
    },
}

VERBOSE = False
WEB = False


def keep_days():
    """Days to keep conflict copies (setting CONFLICT_KEEP_DAYS); 0 = no copies."""
    try:
        return max(0, int(os.environ.get("SS_KEEP_DAYS", "3")))
    except ValueError:
        return 3


def t(key, **kw):
    text = MSG.get(LANG, MSG["en"])[key]
    return text.format(**kw) if kw else text


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
    return [os.environ.get("SS_RCLONE") or "rclone", "--config", RCLONE_CONF] + args


def rclone(args, check=True, stats=False, timeout=3600):
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


def skip_path(parts):
    """Leftovers of an interrupted run and cache folders are never synced."""
    return any(p.startswith(".ss_tmp") or p.lower() in CACHE_DIRS for p in parts[:-1])


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


NOT_ROMS_EXT = (".xml", ".txt", ".dat", ".log", ".cache")
NOT_ROMS_DIRS = {"images", "media", "videos"}


def _has_files(path, skip_media):
    for root, dirs, files in os.walk(path):
        if skip_media:
            dirs[:] = [d for d in dirs if d.lower() not in NOT_ROMS_DIRS]
        if any(not f.lower().endswith(NOT_ROMS_EXT) for f in files):
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
                d = os.path.join(ROMS_DIR, system)
                ok = os.path.isdir(d) and _has_files(d, True)
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
        return not skip_name(parts[-1])
    return accept


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
def run():
    now = int(time.time())
    clock_ok = now > SANE_TIME
    dev = device_name()
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S") if clock_ok else "time-unknown-%d" % random.randint(0, 99999)
    base_all = load_json(BASE_FILE, {})
    base_roots = base_all.get("roots", {})
    new_base_roots = {}
    total = {"d": 0, "u": 0, "c": 0, "x": 0}

    for root in roots():
        base = base_roots.get(root.name, {})
        L = local_list(root, base)
        C = {r: v for r, v in cloud_list(root.remote).items() if root.accept(r, v[0])}
        rc, mout = rclone(["cat", root.remote + "/" + MANIFEST], check=False)
        try:
            M = json.loads(mout) if rc == 0 and mout.strip() else {}
        except ValueError:
            M = {}
        M = M.get("files", {}) if isinstance(M, dict) else {}

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
            rclone(["copy", root.remote, tmpdir, "--files-from-raw", lst, "--ignore-times"])
            for rel in need:
                p = os.path.join(tmpdir, *rel.split("/"))
                if os.path.isfile(p):
                    known[rel] = md5(p)
                    fetched[rel] = p

        up, down, del_cloud, del_local, same = [], [], [], [], []
        conflicts = []

        for rel in sorted(set(L) | set(C) | set(base)):
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

            # mass-deletion guard: an empty listing is a failure, not a deletion
            limit = max(5, len(base) // 2)
            if len(del_local) > limit:
                log(t("guard", n=len(del_local), where=t("where_cloud")))
                del_local = []
            if len(del_cloud) > limit:
                log(t("guard", n=len(del_cloud), where=t("where_here")))
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

            # 2. uploads
            ups = up + won_local
            if ups:
                with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
                    f.write("\n".join(ups) + "\n")
                try:
                    rclone(["copy", root.local, root.remote, "--files-from-raw", f.name, "--ignore-times"], stats=True)
                finally:
                    os.remove(f.name)
                done.update(ups)

            # 3. downloads (conflicts already fetched are moved into place)
            downs = [r for r in down + won_cloud if r not in fetched]
            for rel in down + won_cloud:
                if rel in fetched:
                    dst = os.path.join(root.local, *rel.split("/"))
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.move(fetched[rel], dst)
                    done.add(rel)
            if downs:
                os.makedirs(root.local, exist_ok=True)
                with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
                    f.write("\n".join(downs) + "\n")
                try:
                    rclone(["copy", root.remote, root.local, "--files-from-raw", f.name, "--ignore-times"], stats=True)
                finally:
                    os.remove(f.name)
                done.update(downs)

            # 4. deletions (the copies are already in _conflicts)
            for rel in del_cloud:
                rclone(["deletefile", root.remote + "/" + rel])
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
        total["d"] += n(down) + n(won_cloud)
        total["u"] += n(up) + n(won_local)
        total["c"] += n(conflicts)
        total["x"] += n(del_cloud) + n(del_local)

        # ---- new state: everything that is now the same on both sides
        changed_cloud = bool(up or won_local or del_cloud)
        C2 = {r: v for r, v in cloud_list(root.remote).items() if root.accept(r, v[0])} if changed_cloud else C
        L2 = local_list(root, base)
        nb = {}
        for rel in set(same) | done:
            l, c = L2.get(rel), C2.get(rel)
            if l is None or c is None:
                continue
            nb[rel] = {"h": l["h"], "s": l["s"], "m": l["m"], "ns": l["ns"], "cs": c[0], "ct": c[1]}
        new_base_roots[root.name] = nb

        # ---- manifest in the cloud: who wrote which version, and when. It is read
        # again right before writing, so what another device wrote meanwhile stays.
        uploaded = set(up) | set(won_local)
        rc, mout = rclone(["cat", root.remote + "/" + MANIFEST], check=False)
        try:
            fresh = json.loads(mout).get("files", {}) if rc == 0 and mout.strip() else {}
        except (ValueError, AttributeError):
            fresh = {}
        newM = dict(fresh)
        for rel in list(newM):
            if not root.accept(rel, None):
                continue            # not ours (excluded, or no games here): another device's entry stays
            if rel not in C2 or rel in del_cloud:
                newM.pop(rel, None)
        for rel, e in nb.items():
            c = C2[rel]
            old_e = newM.get(rel) or M.get(rel) or {}
            if rel in uploaded:
                newM[rel] = {"h": e["h"], "s": c[0], "ct": c[1], "d": dev, "t": L2[rel]["m"]}
            elif old_e.get("h") != e["h"] or old_e.get("s") != c[0]:
                if rel in fresh and fresh[rel].get("h") != M.get(rel, {}).get("h"):
                    continue        # changed by another device right now: its entry wins
                newM[rel] = {"h": e["h"], "s": c[0], "ct": c[1], "d": old_e.get("d", ""),
                             "t": old_e.get("t") or parse_time(c[1])}
        if newM != fresh:
            data = json.dumps({"version": 1, "files": newM}, ensure_ascii=False, separators=(",", ":")).encode()
            subprocess.run(rclone_cmd(["rcat", root.remote + "/" + MANIFEST]), input=data,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # a failed manifest write is harmless: it is only a hint for the other devices

    base_all["roots"] = new_base_roots
    base_all["device"] = dev
    save_json(BASE_FILE, base_all)

    # old conflict copies are removed by any device during its sync (at most once
    # a day, or right away after the setting changed). The age is taken from the
    # date in the copy's name, i.e. from the moment the conflict happened.
    keep = keep_days()
    if clock_ok and (now - base_all.get("cleaned", 0) > 86400 or base_all.get("cleaned_keep") != keep):
        if clean_conflicts(keep, now):
            base_all["cleaned"] = now
            base_all["cleaned_keep"] = keep
            save_json(BASE_FILE, base_all)

    summary = t("summary", d=total["d"], u=total["u"], c=total["c"], x=total["x"])
    # short note for the "Saves uploaded / downloaded" log line of the calling script
    parts = [t(k, n=total[v]) for k, v in (("n_sent", "u"), ("n_recv", "d"), ("n_del", "x"), ("n_conf", "c")) if total[v]]
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


STAMP_RE = re.compile(r"\.(\d{4})-(\d\d)-(\d\d)_(\d\d)-(\d\d)-(\d\d)(?:\.deleted)?$")


def clean_conflicts(keep, now):
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
        if keep == 0 or made < limit:
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


def main(argv):
    global VERBOSE, WEB
    if not argv or argv[0] != "sync":
        print(__doc__ or "usage: sync_engine.py sync")
        return 2
    VERBOSE = "--verbose" in argv
    WEB = "--web-progress" in argv
    try:
        lock = open(ENGINE_LOCK, "w")
        fcntl.flock(lock, fcntl.LOCK_EX)     # a boot download and a game-exit upload never overlap
        return run()
    except SyncError as e:
        sys.stderr.write("%s\n" % e)
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
        -e "s|__SS_LANG__|en|g" \
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
    command -v python3 >/dev/null 2>&1 || echo "⚠️  python3 not found - save sync will not work on this device"
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

# Self-heal if the rclone partition is mounted noexec
# (e.g. /recalbox/share on Recalbox)
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

# ======== ARGUMENT HANDLING ========
SHOW_PROGRESS=""
FORCE_SYNC=false

if [ "\$1" = "--detach" ]; then
    # Background run. The interval is preserved for automatic events.
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

# ======== PROGRESS FOR WEB UI ========
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

# ======== MAIN LOGIC ========
save_status() {
    echo "\$1 \$(date +%s)" > "\$STATUS_FILE"
}

# ======== PERSISTENT SYNC STATE ========
# Stored on the share partition, so it survives reboots (unlike /tmp).
# Written only by the sync scripts, never by the Web UI.
state_get() {
    [ -f "\$STATE_FILE" ] || return 0
    grep "^\$1=" "\$STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# state_set KEY VALUE  (an empty VALUE removes the key)
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
flock -n 200 || { echo "\$(date '+%d.%m %H:%M:%S') Skipped: a previous download is still running" >> "\$LOG_FILE" 2>/dev/null; exit 0; }

# ======== CANCEL (Web UI "Cancel", Ctrl+C, shutdown) ========
# rclone receives the same signal and stops; here only the result is
# recorded, so the Web UI does not show an endless progress bar.
on_cancel() {
    trap - TERM INT
    save_status "ERROR"
    echo "\$(date '+%d.%m %H:%M:%S') Save download cancelled" >> "\$LOG_FILE" 2>/dev/null
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false,"cancelled":true}\n' \
            "download" "Save download cancelled" > "\$PROGRESS_FILE"
    fi
    exit 130
}
trap on_cancel TERM INT

# Syncing is done by sync_engine.py (needs python3). If something is
# missing, do nothing and write a clear error to the log.
ENGINE_ERR=""
command -v python3 >/dev/null 2>&1 || ENGINE_ERR="python3 not found - saves cannot be synced without it"
[ -f "\$ENGINE_SCRIPT" ] || ENGINE_ERR="sync_engine.py not found - reinstall Save Sync"
if [ -n "\$ENGINE_ERR" ]; then
    save_status "ERROR"
    echo "\$(date '+%d.%m %H:%M:%S') Save download error: \$ENGINE_ERR" >> "\$LOG_FILE" 2>/dev/null
    [ -n "\$SHOW_PROGRESS" ] && echo "❌ \$ENGINE_ERR"
    progress_start "download" "Save download error"
    progress_finish false "download" "Save download error: \$ENGINE_ERR"
    exit 1
fi


# Check interval (ONLY if NOT a forced sync)
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ \$SYNC_INTERVAL -gt 0 ] && [ -f "\$LAST_SYNC_TIME" ]; then
    LAST=\$(cat "\$LAST_SYNC_TIME" 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [ \$((NOW - LAST)) -lt \$SYNC_INTERVAL ]; then
        exit 0
    fi
fi

# Wait until the clock is reasonable. Raspberry Pi has no RTC,
# and before NTP sync the date can be 01.01 - because of this
# the HTTPS connection to the cloud fails certificate validation, even
# if the network is already up.
CLOCK_WAIT=0
while [ "\$(date +%Y)" -lt 2024 ]; do
    CLOCK_WAIT=\$((CLOCK_WAIT+1))
    if [ \$CLOCK_WAIT -ge 20 ]; then
        break
    fi
    sleep 3
done

# Wait for the cloud. Right after boot the network may still be coming up,
# so it is retried for about 2 minutes. The cloud itself is checked, not a
# ping to 1.1.1.1: some networks block ping while the cloud works fine.
# The deadline uses the uptime counter - the clock can jump on NTP sync.
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
    echo "\$(date '+%d.%m %H:%M:%S') Cloud unavailable (no network or the cloud does not respond)" >> "\$LOG_FILE" 2>/dev/null
    save_status "ERROR"
    exit 1
fi

# ======== TWO-WAY SYNC (sync_engine.py) ========
# The device and the cloud are compared with the last sync: only what changed
# in the cloud is downloaded, only what changed here is uploaded. If a save was
# changed on different devices, the newer one is kept and the older one is copied to
# the _conflicts folder (how long - the "Conflict copies" setting). Nothing is asked.
progress_start "download" "Downloading saves"
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
    "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$FIRST_SYNC_MARKER" 2>/dev/null | grep -q . || \
        echo "first_sync_\$(date +%s)" | "\$RCLONE_PATH" --config "\$RCLONE_CONF" rcat "\$FIRST_SYNC_MARKER" 2>/dev/null
    date +%s > "\$READY_FILE"
    date +%s > "\$LAST_SYNC_TIME"
    save_status "OK"
    state_set PENDING_UPLOAD ""
    state_set LAST_GOOD_SYNC "\$(date +%s)"
    SYNC_NOTE=\$(cat "/tmp/save_sync_result.\$\$" 2>/dev/null); rm -f "/tmp/save_sync_result.\$\$"
    echo "\$(date '+%d.%m %H:%M:%S') Saves downloaded\${SYNC_NOTE:+ (\$SYNC_NOTE)}" >> "\$LOG_FILE" 2>/dev/null
    progress_finish true "download" "Save download complete"
    exit 0
fi
save_status "ERROR"
echo "\$(date '+%d.%m %H:%M:%S') Save download error (code: \$ENGINE_EXIT)" >> "\$LOG_FILE" 2>/dev/null
progress_finish false "download" "Save download error"
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

# Self-heal if the rclone partition is mounted noexec
# (e.g. /recalbox/share on Recalbox)
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

# ======== ARGUMENT HANDLING ========
SHOW_PROGRESS=""
FORCE_SYNC=false

if [ "\$1" = "--detach" ]; then
    # Background run. The interval is preserved for automatic events.
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

# ======== PROGRESS FOR WEB UI ========
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

# ======== MAIN LOGIC ========
save_status() {
    echo "\$1 \$(date +%s)" > "\$STATUS_FILE"
}

# ======== PERSISTENT SYNC STATE ========
# Stored on the share partition, so it survives reboots (unlike /tmp).
# Written only by the sync scripts, never by the Web UI.
state_get() {
    [ -f "\$STATE_FILE" ] || return 0
    grep "^\$1=" "\$STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# state_set KEY VALUE  (an empty VALUE removes the key)
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
flock -n 200 || { echo "\$(date '+%d.%m %H:%M:%S') Skipped: a previous upload is still running" >> "\$LOG_FILE" 2>/dev/null; exit 0; }

# ======== CANCEL (Web UI "Cancel", Ctrl+C, shutdown) ========
# rclone receives the same signal and stops; here only the result is
# recorded, so the Web UI does not show an endless progress bar.
on_cancel() {
    trap - TERM INT
    save_status "ERROR"
    state_set PENDING_UPLOAD 1
    echo "\$(date '+%d.%m %H:%M:%S') Save upload cancelled - the changes will be uploaded next time" >> "\$LOG_FILE" 2>/dev/null
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false,"cancelled":true}\n' \
            "upload" "Save upload cancelled - the changes will be uploaded next time" > "\$PROGRESS_FILE"
    fi
    exit 130
}
trap on_cancel TERM INT

# Syncing is done by sync_engine.py (needs python3). If something is
# missing, do nothing and write a clear error to the log.
ENGINE_ERR=""
command -v python3 >/dev/null 2>&1 || ENGINE_ERR="python3 not found - saves cannot be synced without it"
[ -f "\$ENGINE_SCRIPT" ] || ENGINE_ERR="sync_engine.py not found - reinstall Save Sync"
if [ -n "\$ENGINE_ERR" ]; then
    save_status "ERROR"
    echo "\$(date '+%d.%m %H:%M:%S') Save upload error: \$ENGINE_ERR" >> "\$LOG_FILE" 2>/dev/null
    [ -n "\$SHOW_PROGRESS" ] && echo "❌ \$ENGINE_ERR"
    state_set PENDING_UPLOAD 1
    progress_start "upload" "Save upload error"
    progress_finish false "upload" "Save upload error: \$ENGINE_ERR"
    exit 1
fi


# Check interval (ONLY if NOT a forced sync)
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ \$SYNC_INTERVAL -gt 0 ] && [ -f "\$LAST_SYNC_TIME" ]; then
    LAST=\$(cat "\$LAST_SYNC_TIME" 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [ \$((NOW - LAST)) -lt \$SYNC_INTERVAL ]; then
        echo "\$(date '+%d.%m %H:%M:%S') Upload skipped (interval \$SYNC_INTERVAL sec)" >> "\$LOG_FILE" 2>/dev/null
        # Not an error, but the changes are still only on this device
        state_set PENDING_UPLOAD 1
        exit 0
    fi
fi

# Wait until the clock is reasonable. Raspberry Pi has no RTC,
# and before NTP sync the date can be 01.01 - because of this
# the HTTPS connection to the cloud fails certificate validation, even
# if the network is already up.
CLOCK_WAIT=0
while [ "\$(date +%Y)" -lt 2024 ]; do
    CLOCK_WAIT=\$((CLOCK_WAIT+1))
    if [ \$CLOCK_WAIT -ge 20 ]; then
        break
    fi
    sleep 3
done

# Wait for the cloud. Right after boot the network may still be coming up,
# so it is retried for about 2 minutes. The cloud itself is checked, not a
# ping to 1.1.1.1: some networks block ping while the cloud works fine.
# The deadline uses the uptime counter - the clock can jump on NTP sync.
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
    echo "\$(date '+%d.%m %H:%M:%S') Cloud unavailable (no network or the cloud does not respond)" >> "\$LOG_FILE" 2>/dev/null
    save_status "ERROR"
    state_set PENDING_UPLOAD 1
    exit 1
fi

# Check free space in the cloud
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
            echo "\$(date '+%d.%m %H:%M:%S') ⚠️ Not enough space in the cloud! Need ~\${NEEDED_MB} MB, free \${CLOUD_FREE_MB} MB" >> "\$LOG_FILE" 2>/dev/null
            save_status "ERROR"
            state_set PENDING_UPLOAD 1
            exit 1
        fi
    fi
fi

# ======== TWO-WAY SYNC (sync_engine.py) ========
# The device and the cloud are compared with the last sync: only what changed
# in the cloud is downloaded, only what changed here is uploaded. If a save was
# changed on different devices, the newer one is kept and the older one is copied to
# the _conflicts folder (how long - the "Conflict copies" setting). Nothing is asked.
progress_start "upload" "Uploading saves"
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
    "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$FIRST_SYNC_MARKER" 2>/dev/null | grep -q . || \
        echo "first_sync_\$(date +%s)" | "\$RCLONE_PATH" --config "\$RCLONE_CONF" rcat "\$FIRST_SYNC_MARKER" 2>/dev/null
    date +%s > "\$READY_FILE"
    date +%s > "\$LAST_SYNC_TIME"
    save_status "OK"
    state_set PENDING_UPLOAD ""
    state_set LAST_GOOD_SYNC "\$(date +%s)"
    SYNC_NOTE=\$(cat "/tmp/save_sync_result.\$\$" 2>/dev/null); rm -f "/tmp/save_sync_result.\$\$"
    echo "\$(date '+%d.%m %H:%M:%S') Saves uploaded\${SYNC_NOTE:+ (\$SYNC_NOTE)}" >> "\$LOG_FILE" 2>/dev/null
    progress_finish true "upload" "Save upload complete"
    exit 0
fi
save_status "ERROR"
echo "\$(date '+%d.%m %H:%M:%S') Save upload error (code: \$ENGINE_EXIT)" >> "\$LOG_FILE" 2>/dev/null
state_set PENDING_UPLOAD 1
progress_finish false "upload" "Save upload error"
exit 1
ENDOFSCRIPT
    chmod +x "$UPLOAD_SCRIPT"
}

############################################
# create_hook_script
############################################

create_hook_script() {
    if [ "$SYSTEM" = "Recalbox" ]; then
        # Recalbox uses a completely different hook mechanism than
        # Batocera: scripts go in /recalbox/share/userscripts,
        # the game-exit event is called EndGame (not gameStop),
        # the event filter is set with square brackets in the FILE NAME,
        # and arguments are passed as "-action ACTION -statefile FILE",
        # not as a positional $1.
        # See https://wiki.recalbox.com/en/advanced-usage/scripts-on-emulationstation-events
        local USERSCRIPTS_DIR="/recalbox/share/userscripts"
        mkdir -p "$USERSCRIPTS_DIR" 2>/dev/null
        # Remove the old (Batocera-style) hook format if left over from
        # a previous version of the script
        rm -f "$SCRIPT_DIR/save-sync.sh" 2>/dev/null

        cat > "$USERSCRIPTS_DIR/save-sync[endgame].sh" << ENDOFSCRIPT
#!/bin/sh

LOG_FILE="$LOG_FILE"

echo "\$(date '+%d.%m %H:%M:%S') Game exit" >> "\$LOG_FILE" 2>/dev/null
bash "$UPLOAD_SCRIPT" --detach &
ENDOFSCRIPT
        chmod +x "$USERSCRIPTS_DIR/save-sync[endgame].sh" 2>/dev/null
    else
        cat > "$SCRIPT_DIR/save-sync.sh" << ENDOFSCRIPT
#!/bin/bash

# Hook for Batocera - called on emulator events
LOG_FILE="$LOG_FILE"

log_hook() {
    echo "\$(date '+%d.%m %H:%M:%S') \$1" >> "\$LOG_FILE" 2>/dev/null
}

case "\$1" in
    gameStop)
        log_hook "Game exit"
        bash "$UPLOAD_SCRIPT" --detach &
        ;;
esac
exit 0
ENDOFSCRIPT
        chmod +x "$SCRIPT_DIR/save-sync.sh"
    fi
}

############################################
# Create ROM scripts (with logging)
############################################

create_roms_scripts() {
    load_config
    create_roms_filter
    
    cat > "$DOWNLOAD_ROMS" << ENDOFSCRIPT
#!/bin/bash

RCLONE_BIN="$RCLONE_BIN"

# Self-heal if the rclone partition is mounted noexec
# (e.g. /recalbox/share on Recalbox)
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

# Logging function
log_msg() {
    echo "\$(date '+%d.%m %H:%M:%S') \$1" >> "\$LOG_FILE"
}

log_msg "Starting ROM download"

# ======== CANCEL (Web UI "Cancel", Ctrl+C, shutdown) ========
# rclone receives the same signal and stops; here only the result is
# recorded, so the Web UI does not show an endless progress bar.
on_cancel() {
    trap - TERM INT
    echo "\$(date '+%d.%m %H:%M:%S') ROM download cancelled" >> "\$LOG_FILE" 2>/dev/null
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false,"cancelled":true}\n' \
            "roms_download" "ROM download cancelled" > "\$PROGRESS_FILE"
    fi
    exit 130
}
trap on_cancel TERM INT


"\$RCLONE_PATH" --config "\$RCLONE_CONF" mkdir "\$REMOTE_ROMS" 2>/dev/null

echo "🔄 Downloading ROMs from cloud..."

progress_start "roms_download" "Downloading ROMs"
run_transfer copy "\$REMOTE_ROMS" "\$ROMS_DIR" \
    --update \
    --filter-from "\$FILTER_FILE"

EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ] || [ \$EXIT_CODE -eq 3 ]; then
    echo "✅ ROM download complete"
    log_msg "ROM download complete"
    progress_finish true "roms_download" "ROM download complete"
else
    echo "❌ ROM download error (code: \$EXIT_CODE)"
    log_msg "ROM download error (code: \$EXIT_CODE)"
    progress_finish false "roms_download" "ROM download error"
fi

log_msg "Finished ROM download"

exit \$EXIT_CODE
ENDOFSCRIPT
    
    chmod +x "$DOWNLOAD_ROMS"
    
    cat > "$UPLOAD_ROMS" << ENDOFSCRIPT
#!/bin/bash

RCLONE_BIN="$RCLONE_BIN"

# Self-heal if the rclone partition is mounted noexec
# (e.g. /recalbox/share on Recalbox)
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

# Logging function
log_msg() {
    echo "\$(date '+%d.%m %H:%M:%S') \$1" >> "\$LOG_FILE"
}

log_msg "Starting ROM upload"

# ======== CANCEL (Web UI "Cancel", Ctrl+C, shutdown) ========
# rclone receives the same signal and stops; here only the result is
# recorded, so the Web UI does not show an endless progress bar.
on_cancel() {
    trap - TERM INT
    echo "\$(date '+%d.%m %H:%M:%S') ROM upload cancelled" >> "\$LOG_FILE" 2>/dev/null
    if [ "\$WEB_PROGRESS" = "true" ]; then
        printf '{"active":false,"action":"%s","phase":"%s","percent":0,"bytes":0,"totalBytes":0,"speed":0,"eta":0,"transfers":0,"totalTransfers":0,"success":false,"cancelled":true}\n' \
            "roms_upload" "ROM upload cancelled" > "\$PROGRESS_FILE"
    fi
    exit 130
}
trap on_cancel TERM INT


"\$RCLONE_PATH" --config "\$RCLONE_CONF" mkdir "\$REMOTE_ROMS" 2>/dev/null

# Check free space in the cloud (size is calculated via du - reading
# file contents, like for saves, isn't viable here: a ROM collection
# can be hundreds of GB, and reading it byte by byte would take an
# unreasonable amount of time)
ROMS_SIZE_MB=\$(du -sm "\$ROMS_DIR" 2>/dev/null | awk '{print \$1}')
ROMS_SIZE_MB=\${ROMS_SIZE_MB:-0}

CLOUD_FREE=\$("\$RCLONE_PATH" --config "\$RCLONE_CONF" about "\$REMOTE_NAME:" 2>/dev/null | grep -i "free" | awk '{print \$2}' | sed 's/[^0-9]//g')
CLOUD_FREE=\${CLOUD_FREE:-0}
CLOUD_FREE_MB=\$((CLOUD_FREE / 1024 / 1024))

if [ "\$ROMS_SIZE_MB" -gt 0 ] && [ "\$CLOUD_FREE_MB" -gt 0 ]; then
    NEEDED_MB=\$((ROMS_SIZE_MB + ROMS_SIZE_MB / 10))
    if [ "\$CLOUD_FREE_MB" -lt "\$NEEDED_MB" ]; then
        log_msg "⚠️ Not enough space in the cloud for ROMs! Need ~\${NEEDED_MB} MB, \${CLOUD_FREE_MB} MB free"
        exit 1
    fi
fi

echo "🔄 Copying ROMs to cloud..."

progress_start "roms_upload" "Uploading ROMs"
run_transfer sync "\$ROMS_DIR" "\$REMOTE_ROMS" \
    --delete-after \
    --filter-from "\$FILTER_FILE"

EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ] || [ \$EXIT_CODE -eq 3 ]; then
    echo "✅ ROM upload complete"
    log_msg "ROM upload complete"
    progress_finish true "roms_upload" "ROM upload complete"
else
    echo "❌ ROM upload error (code: \$EXIT_CODE)"
    log_msg "❌ ROM upload error (code: \$EXIT_CODE)"
    progress_finish false "roms_upload" "ROM upload error"
fi

log_msg "Finished ROM upload"

exit \$EXIT_CODE
ENDOFSCRIPT
    
    chmod +x "$UPLOAD_ROMS"
    
    echo "✅ ROM scripts created (with logging)"
    create_link_script
}

############################################
# create_link_script - download from a public link (Python)
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
              "screenshots", "thumbnails")
NOT_GAMES = ("gamelist.xml", "_info.txt")


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
    if ok and not quiet:
        if dest.kind == "cloud":
            con(t("cloud_done", dest=dest.label) + "\n")
        else:
            con(t("es_hint") + "\n")
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
        try:
            src, root = load_tree(url, password=password, quiet=True)
            entries = []
            for rel in items:
                e = find_entry(root, rel, src)
                if e is None:
                    raise LinkError("not found: " + rel)
                entries.append(e)
            plan = build_plan(root, entries)
            return run_download(src, plan, dest, url, web=web, quiet=True)
        except LinkError as e:
            print(e)
            log(t("log_error", err=str(e).splitlines()[0].lstrip("❌ ")))
            if web:
                write_progress(False, 0, 0, 0, 0, 0, 0, 0, success=False,
                               phase=str(e).splitlines()[0].lstrip("❌ "))
            return 1
        except KeyboardInterrupt:
            if web:
                write_progress(False, 0, 0, 0, 0, 0, 0, 0, success=False, phase=t("cancelled_web"))
            return 130

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
        -e "s|__SS_LANG__|en|g" \
        -e "s|__SS_ROMS_DIR__|$ROMS_DIR|g" \
        -e "s|__SS_LOG_FILE__|$LOG_FILE|g" \
        -e "s|__SS_RCLONE_BIN__|$RCLONE_BIN|g" \
        -e "s|__SS_RCLONE_CONF__|$RCLONE_CONF|g" \
        -e "s|__SS_REMOTE_ROMS__|$REMOTE_ROMS|g" \
        "$LINK_SCRIPT"
    chmod +x "$LINK_SCRIPT" 2>/dev/null
}

############################################
# Create the ROM filter
############################################

create_roms_filter() {
    # Create the filter with basic exclusions
    cat > "$ROMS_FILTER_FILE" << 'EOF'
# ROM sync filter
# Created automatically, do not edit by hand

# Exclude system files
- **/_info.txt
EOF
    
    # If media is disabled - exclude media files
    if [ "$ROMS_SYNC_MEDIA" != "true" ]; then
        cat >> "$ROMS_FILTER_FILE" << 'EOF'

# Exclude media folders
- **/images/**
- **/media/**
- **/videos/**
- **/manuals/**
- **/screenshots/**
- **/thumbnails/**

# Exclude media files (images)
- **.png
- **.jpg
- **.jpeg
- **.gif
- **.bmp
EOF
    fi
    
    # ALWAYS exclude video (WebDAV doesn't like large files)
    cat >> "$ROMS_FILTER_FILE" << 'EOF'

# Exclude video files (WebDAV limitations)
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
    
    # Add the selected systems
    if [ -n "$ROMS_SYNC_DIRS" ]; then
        IFS='|' read -ra DIRS <<< "$ROMS_SYNC_DIRS"
        for dir in "${DIRS[@]}"; do
            dir=$(echo "$dir" | xargs)
            if [ -n "$dir" ]; then
                echo "+ /$dir/**" >> "$ROMS_FILTER_FILE"
            fi
        done
    fi
    
    # Exclude everything not selected
    echo "- **" >> "$ROMS_FILTER_FILE"
}

############################################
# Manage exclusions (saves)
############################################

manage_exclusions() {
    # Load the config
    load_config

    # Systems whose ROMs are only in the cloud (uploaded from another device) are
    # listed too, so they can be excluded before their saves are downloaded here.
    local CLOUD_ROM_SYS=()
    local CLOUD_PORTS=false
    local CLOUD_SAVE_SYS=()
    if [ -n "$RCLONE_PATH" ] && [ -f "$RCLONE_PATH" ]; then
        echo "🔍 Checking the cloud: systems whose ROMs are only there..."
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
        
        # Recursive search for systems with ROMs
        for dir in "$ROMS_DIR"/*/; do
            [ -d "$dir" ] || continue
            BASENAME=$(basename "$dir")
            
            if find "$dir" -type f ! -name "gamelist.xml" ! -name "_info.txt" ! -name "*.dat" ! -name "*.txt" ! -name "*.log" ! -name "*.cache" ! -path "*/images/*" ! -path "*/media/*" ! -path "*/videos/*" 2>/dev/null | head -1 | grep -q .; then
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
        
        # Parse exclusions from the variable
        EXCLUDED_SYSTEMS_LIST=()
        if [ -n "$EXCLUDED_SYSTEMS" ]; then
            IFS='|' read -ra EXCLUDED_SYSTEMS_LIST <<< "$EXCLUDED_SYSTEMS"
        fi
        
        clear
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " Exclude systems (saves)"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        
        if [ ${#EXCLUDED_SYSTEMS_LIST[@]} -gt 0 ]; then
            echo "Excluded:"
            for sys in "${EXCLUDED_SYSTEMS_LIST[@]}"; do
                [ -n "$sys" ] && echo "  • $sys"
            done
        else
            echo "  All systems are syncing"
        fi
        
        echo ""
        echo "Total systems with ROMs: ${#SYSTEMS[@]}"
        echo "Excluded: ${#EXCLUDED_SYSTEMS_LIST[@]}"
        echo "Syncing: $((${#SYSTEMS[@]} - ${#EXCLUDED_SYSTEMS_LIST[@]}))"
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo ""
        echo " 1 - Add a system to exclusions"
        echo " 2 - Remove a system from exclusions"
        echo " 3 - Clear all exclusions"
        echo " 4 - Show all systems"
        echo " 0 - Back"
        echo ""
        read -p "Choose (0-4): " excl_choice
        
        case "$excl_choice" in
            1)
                echo ""
                echo "Available systems to exclude (0 - cancel):"
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
                    for co in "${CLOUD_ONLY_SYS[@]}"; do [ "$co" = "$sys" ] && ctag=" (cloud only)"; done
                    if [ "$excluded" = true ]; then
                        echo "  $idx - $sys$ctag ⚠️ ALREADY EXCLUDED"
                    else
                        echo "  $idx - $sys$ctag"
                    fi
                done
                echo ""
                read -p "Enter system numbers separated by spaces (0 - cancel): " -a ADD_NUMS
                
                local cancel=false
                for num in "${ADD_NUMS[@]}"; do
                    if [ "$num" = "0" ]; then
                        cancel=true
                        break
                    fi
                done
                if [ "$cancel" = true ]; then
                    echo "Cancelled"
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
                            echo "  ✅ $sys_name added to exclusions"
                        else
                            echo "  ⚠️ $sys_name already excluded"
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
                    echo "No exclusions to remove."
                    pause
                    continue
                fi
                
                echo ""
                echo "Current exclusions (0 - cancel):"
                echo ""
                local idx=0
                for sys in "${EXCLUDED_SYSTEMS_LIST[@]}"; do
                    [ -n "$sys" ] && idx=$((idx+1)) && echo "  $idx - $sys"
                done
                echo ""
                read -p "Enter system numbers to remove (0 - cancel): " -a REMOVE_NUMS
                
                local cancel=false
                for num in "${REMOVE_NUMS[@]}"; do
                    if [ "$num" = "0" ]; then
                        cancel=true
                        break
                    fi
                done
                if [ "$cancel" = true ]; then
                    echo "Cancelled"
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
                        echo "  ✅ $sys removed from exclusions"
                    fi
                done
                EXCLUDED_SYSTEMS="$new_list"
                save_config
                echo ""
                pause
                ;;
            3)
                echo ""
                read -p "Remove all exclusions? (y/n): " clean_excl
                if [ "$clean_excl" = "y" ] || [ "$clean_excl" = "Y" ]; then
                    EXCLUDED_SYSTEMS=""
                    save_config
                    echo "✅ All exclusions removed"
                else
                    echo "Cancelled"
                fi
                echo ""
                pause
                ;;
            4)
                echo ""
                echo "All systems with ROMs:"
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
                    for co in "${CLOUD_ONLY_SYS[@]}"; do [ "$co" = "$sys" ] && ctag=" (cloud only)"; done
                    if [ "$excluded" = true ]; then
                        echo "  $idx - $sys$ctag ❌ (excluded)"
                    else
                        echo "  $idx - $sys$ctag ✅ (syncing)"
                    fi
                done
                echo ""
                pause
                ;;
            0)
                return
                ;;
            *)
                echo "❌ Invalid choice"
                sleep 1
                ;;
        esac
    done
}

############################################
# Manage ROM sync
############################################

manage_roms_sync() {
    # Load the config
    load_config
    
    while true; do
        clear
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📁 Copy and download ROMs"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        
        if [ -n "$ROMS_SYNC_DIRS" ]; then
            echo "Selected systems: ${ROMS_SYNC_DIRS//|/, }"
            echo "Total systems: $(echo "$ROMS_SYNC_DIRS" | tr '|' '\n' | grep -c .)"
        else
            echo "Systems: not selected"
        fi
        
        if [ "$ROMS_SYNC_MEDIA" = "true" ]; then
            echo "Media copying: ✅ ENABLED"
        else
            echo "Media copying: ❌ DISABLED"
        fi
        
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo ""
        echo " 1 - 📂 Select systems to upload and download"
        echo " 2 - 🖼️ Enable/disable image copying"
        echo " 3 - 📥 Download ROMs from cloud"
        echo " 4 - 📤 Upload ROMs to cloud"
        echo " 5 - 🔗 Download from a public link (Yandex Disk, pCloud, Nextcloud, archive.org)"
        echo " 0 - Back"
        echo ""
        read -p "Choose (0-5): " roms_choice
        
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
                echo "❌ Invalid choice"
                sleep 1
                ;;
        esac
    done
}

link_download_menu() {
    clear
    if ! command -v python3 >/dev/null 2>&1; then
        echo "❌ python3 not found - link download is not available on this system."
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
        echo "❌ Folder $ROMS_DIR not found"
        sleep 2
        return
    fi
    
    echo "🔍 Searching for systems with ROMs (local and cloud)..."
    
    for dir in "$ROMS_DIR"/*/; do
        [ -d "$dir" ] || continue
        BASENAME=$(basename "$dir")
        
        if find "$dir" -type f ! -name "gamelist.xml" ! -name "_info.txt" ! -name "*.dat" ! -name "*.txt" ! -name "*.log" ! -name "*.cache" ! -path "*/images/*" ! -path "*/media/*" ! -path "*/videos/*" 2>/dev/null | head -1 | grep -q .; then
            SYSTEMS_LIST+=("$BASENAME")
        fi
    done
    
    # Also check the cloud - there may be systems
    # not yet on the device (e.g. ROMs were dropped directly
    # into the cloud from a computer, without touching the device). Without this
    # they couldn't be selected and thus couldn't be downloaded.
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
        echo "❌ No systems with ROMs found locally or in the cloud"
        sleep 2
        return
    fi
    
    echo "✅ Systems found: ${#SYSTEMS_LIST[@]}"
    if [ ${#CLOUD_ONLY[@]} -gt 0 ]; then
        echo "   of which cloud-only: ${#CLOUD_ONLY[@]} (can be selected and downloaded)"
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
        echo " 📁 Select systems to upload and download"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo "Choose which systems will be backed up"
        echo ""
        echo "Current selection:"
        if [ ${#SELECTED[@]} -gt 0 ]; then
            echo "  ${SELECTED[*]}"
        else
            echo "  ❌ No systems selected"
        fi
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo "Available systems (${#SYSTEMS_LIST[@]}):"
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
                    cloud_tag=" (cloud only)"
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
        echo " 1 - Add systems"
        echo " 2 - Select all systems"
        echo " 3 - Deselect all"
        echo " 4 - Remove systems"
        echo " 0 - Apply and exit"
        echo ""
        read -p "Choose (0-4): " sys_choice
        
        case "$sys_choice" in
            0)
                if [ ${#SELECTED[@]} -gt 0 ]; then
                    ROMS_SYNC_DIRS=$(IFS='|'; echo "${SELECTED[*]}")
                    echo "✅ Selected systems: ${ROMS_SYNC_DIRS//|/, }"
                    save_config
                    create_roms_filter
                    sleep 1
                else
                    ROMS_SYNC_DIRS=""
                    save_config
                    create_roms_filter
                    echo "ℹ️ No systems selected. ROM backup is disabled."
                    sleep 1
                fi
                return
                ;;
            1)
                echo ""
                read -p "Enter system numbers separated by spaces (0 - cancel): " -a ADD_NUMS
                local cancel=false
                for num in "${ADD_NUMS[@]}"; do
                    if [ "$num" = "0" ]; then
                        cancel=true
                        break
                    fi
                done
                if [ "$cancel" = true ]; then
                    echo "Cancelled"
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
                            echo "  ✅ $sys_name added"
                        else
                            echo "  ⚠️ $sys_name already selected"
                        fi
                    else
                        echo "  ⚠️ Invalid number: $num (skipped)"
                    fi
                done
                
                if [ ${#SELECTED[@]} -gt 0 ]; then
                    echo ""
                    echo "✅ Systems now selected: ${#SELECTED[@]}"
                    sleep 1
                fi
                ;;
            2)
                SELECTED=("${SYSTEMS_LIST[@]}")
                echo "✅ All systems selected (${#SELECTED[@]})"
                sleep 1
                ;;
            3)
                SELECTED=()
                echo "✅ All systems deselected"
                sleep 1
                ;;
            4)
                if [ ${#SELECTED[@]} -eq 0 ]; then
                    echo ""
                    echo "⚠️ No selected systems to remove"
                    sleep 1
                    continue
                fi
                
                echo ""
                echo "Current selection:"
                local idx=0
                for sys in "${SELECTED[@]}"; do
                    idx=$((idx+1))
                    echo "  $idx - $sys"
                done
                echo ""
                echo "Enter system numbers to REMOVE:"
                echo ""
                read -p "Enter system numbers separated by spaces (0 - cancel): " -a REMOVE_NUMS
                local cancel=false
                for num in "${REMOVE_NUMS[@]}"; do
                    if [ "$num" = "0" ]; then
                        cancel=true
                        break
                    fi
                done
                if [ "$cancel" = true ]; then
                    echo "Cancelled"
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
                        echo "  ✅ $sys removed"
                    fi
                done
                SELECTED=("${NEW_SELECTED[@]}")
                
                if [ ${#SELECTED[@]} -gt 0 ]; then
                    echo ""
                    echo "✅ Systems remaining: ${#SELECTED[@]}"
                else
                    echo ""
                    echo "⚠️ No systems left selected"
                fi
                sleep 1
                ;;
            *)
                echo "❌ Invalid choice"
                sleep 1
                ;;
        esac
    done
}

toggle_roms_media() {
    if [ "$ROMS_SYNC_MEDIA" = "true" ]; then
        ROMS_SYNC_MEDIA="false"
        echo "✅ Media copying DISABLED"
    else
        ROMS_SYNC_MEDIA="true"
        echo "✅ Media copying ENABLED"
    fi
    save_config
    create_roms_filter
    sleep 1
}

manual_roms_download() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " 📥 Downloading ROMs from cloud"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo "This will DOWNLOAD ROMs from the cloud to the device."
    echo "Files on the device are NOT deleted."
    echo ""
    echo "Only new or changed files will be downloaded."
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo ""
    read -p "Continue with download? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "❌ Cancelled."
        echo ""
        pause
        return
    fi
    
    echo ""
    echo "🔄 Downloading ROMs from cloud..."
    if [ -f "$DOWNLOAD_ROMS" ]; then
        bash "$DOWNLOAD_ROMS"
    else
        echo "❌ Script download_roms.sh not found"
    fi
    echo ""
    pause
}

manual_roms_upload() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " ⚠️  WARNING! Uploading ROMs to cloud"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo "This will DELETE ROMs from the cloud"
    echo "that are missing from the device."
    echo ""
    echo "If some ROMs are missing on the device,"
    echo "they will disappear from the cloud with no way to recover them!"
    echo ""
    echo "It's recommended to DOWNLOAD ROMs from the cloud first (option 3)"
    echo "or back up the cloud."
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo ""
    read -p "Continue with upload? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "❌ Cancelled."
        echo ""
        pause
        return
    fi
    
    echo ""
    echo "🔄 Uploading ROMs to cloud..."
    if [ -f "$UPLOAD_ROMS" ]; then
        bash "$UPLOAD_ROMS"
    else
        echo "❌ Script upload_roms.sh not found"
    fi
    echo ""
    pause
}

############################################
# Statistics and logs function
############################################

show_statistics() {
    while true; do
        clear
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📊 STATISTICS AND LOGS"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        
        if [ -f "$LOG_FILE" ]; then
            TOTAL=$(grep -c "Downloading saves\|Saves uploaded" "$LOG_FILE" 2>/dev/null)
            ERR=$(grep -c "error\|unavailable" "$LOG_FILE" 2>/dev/null)
            [ -z "$TOTAL" ] && TOTAL=0
            [ -z "$ERR" ] && ERR=0
            OK=$((TOTAL - ERR))
            [ $OK -lt 0 ] && OK=0
            
            echo "📈 Save statistics:"
            echo "  Total syncs: $TOTAL"
            echo "  Successful: $OK"
            echo "  Errors: $ERR"
            echo ""
            
            ROMS_TOTAL=$(grep -c "ROM upload complete\|ROM download complete" "$LOG_FILE" 2>/dev/null)
            ROMS_ERR=$(grep -c "ROM download error\|ROM upload error" "$LOG_FILE" 2>/dev/null)
            [ -z "$ROMS_TOTAL" ] && ROMS_TOTAL=0
            [ -z "$ROMS_ERR" ] && ROMS_ERR=0
            ROMS_OK=$((ROMS_TOTAL - ROMS_ERR))
            [ $ROMS_OK -lt 0 ] && ROMS_OK=0
            
            echo "📈 ROM statistics:"
            echo "  Total syncs: $ROMS_TOTAL"
            echo "  Successful: $ROMS_OK"
            echo "  Errors: $ROMS_ERR"
            echo ""
            
            LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null)
            [ -z "$LOG_LINES" ] && LOG_LINES=0
            
            if [ "$LOG_LINES" -eq 0 ]; then
                echo "📭 Log is empty"
                echo ""
                echo "  0 - Back"
                echo ""
                read -p "Choose (0): " log_action
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
            
            echo "📋 Last $SHOW_LINES entries (total: $LOG_LINES):"
            echo "──────────────────────────────────────────────────────────"
            tail -$SHOW_LINES "$LOG_FILE" 2>/dev/null
            echo "──────────────────────────────────────────────────────────"
            
            echo ""
            echo "Actions:"
            echo "  1 - Show more entries"
            echo "  2 - Show full log"
            echo "  3 - Clear log"
            echo "  0 - Back"
            echo ""
            read -p "Choose (0-3): " log_action
            
            case "$log_action" in
                0)
                    return
                    ;;
                1)
                    echo ""
                    if [ "$LOG_LINES" -gt 3 ]; then
                        echo "Enter number of entries (3-$LOG_LINES):"
                        read -p "→ " custom_lines
                        if [[ "$custom_lines" =~ ^[0-9]+$ ]] && [ "$custom_lines" -ge 3 ] && [ "$custom_lines" -le "$LOG_LINES" ]; then
                            echo ""
                            echo "📋 Last $custom_lines entries:"
                            echo "──────────────────────────────────────────────────────────"
                            tail -$custom_lines "$LOG_FILE"
                            echo "──────────────────────────────────────────────────────────"
                        else
                            echo "❌ Invalid amount (must be 3 to $LOG_LINES)"
                        fi
                    else
                        echo "❌ The log only has $LOG_LINES entries"
                    fi
                    echo ""
                    pause
                    ;;
                2)
                    echo ""
                    echo "📋 FULL LOG"
                    echo "══════════════════════════════════════════════════════════"
                    cat "$LOG_FILE"
                    echo "══════════════════════════════════════════════════════════"
                    echo ""
                    pause
                    ;;
                3)
                    echo ""
                    read -p "Clear the log file? (y/n): " clean_confirm
                    if [ "$clean_confirm" = "y" ] || [ "$clean_confirm" = "Y" ]; then
                        > "$LOG_FILE"
                        echo "✅ Log cleared"
                    else
                        echo "Cancelled"
                    fi
                    echo ""
                    pause
                    ;;
                *)
                    echo "❌ Invalid choice"
                    echo ""
                    pause
                    ;;
            esac
        else
            echo "❌ Log file not found: $LOG_FILE"
            echo ""
            echo "The log will be created automatically after the first sync."
            echo ""
            echo "  0 - Back"
            echo ""
            read -p "Choose (0): " log_action
            if [ "$log_action" = "0" ]; then
                return
            fi
        fi
    done
}

############################################
# Status function for the menu
############################################

get_status_info() {
    SYSTEM_VERSION="unknown"
    DETECT_METHOD="unknown"
    
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        SYSTEM_VERSION=$(get_system_version)
        
        if [ -n "$ID" ]; then
            DETECT_METHOD="via /etc/os-release (ID: $ID)"
        else
            DETECT_METHOD="via /etc/os-release"
        fi
    fi
    
    if [ "$SYSTEM" = "KNULLI" ]; then
        if [ -f "/usr/share/knulli/knulli.version" ]; then
            DETECT_METHOD="via file /usr/share/knulli/knulli.version"
        elif [ -f "/etc/knulli-release" ]; then
            DETECT_METHOD="via file /etc/knulli-release"
        fi
    fi
    
    if [ "$SYSTEM" = "Batocera" ]; then
        if [ -f "/etc/batocera-release" ] && [ -s "/etc/batocera-release" ]; then
            DETECT_METHOD="via file /etc/batocera-release"
        elif [ -f "/boot/batocera" ] || [ -f "/usr/bin/batocera-es-swissknife" ]; then
            DETECT_METHOD="via presence of Batocera files"
        fi
    fi
    
    # Load the config
    load_config
    
    REAL_INTERVAL=$SYNC_INTERVAL
    REAL_RETRIES=$MAX_RETRIES
    REAL_MIN_FREE=$MIN_FREE_KB
    REAL_LOG_SIZE=$MAX_LOG_SIZE
    
    if [ -f "$RCLONE_PATH" ]; then
        RCLONE_STATUS="✓ found (v$($RCLONE_PATH version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//'))"
    else
        RCLONE_STATUS="✗ not found"
    fi
    
    if [ -f "$RCLONE_PATH" ] && [ -f "$RCLONE_CONF" ]; then
        if "$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_NAME:" --contimeout 5s >/dev/null 2>&1; then
            CLOUD_STATUS="✓ connected"
            CLOUD_FREE=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "free" | awk '{print $2, $3}')
            [ -z "$CLOUD_FREE" ] && CLOUD_FREE="unknown"
        else
            CLOUD_STATUS="✗ not connected"
            CLOUD_FREE="unknown"
        fi
    else
        CLOUD_STATUS="✗ not configured"
        CLOUD_FREE="unknown"
    fi
    
   if [ -d "$SAVE_DIR" ]; then
    # Count only save files
    FILE_COUNT=$(find "$SAVE_DIR" -type f ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "*.log" ! -name "*.cache" ! -name ".keep" ! -name "*.keep" 2>/dev/null | wc -l)
    
    # Calculate size in bytes (like in Python)
    if [ "$FILE_COUNT" -gt 0 ]; then
        FILE_SIZE_BYTES=$(find "$SAVE_DIR" -type f ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "*.log" ! -name "*.cache" ! -name ".keep" ! -name "*.keep" -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
        if [ -n "$FILE_SIZE_BYTES" ] && [ "$FILE_SIZE_BYTES" -gt 0 ]; then
            if [ "$FILE_SIZE_BYTES" -gt 1048576 ]; then
                FILE_SIZE=$(echo "scale=1; $FILE_SIZE_BYTES / 1048576" | bc)
                FILE_SIZE="${FILE_SIZE} MB"
            elif [ "$FILE_SIZE_BYTES" -gt 1024 ]; then
                FILE_SIZE=$(echo "scale=1; $FILE_SIZE_BYTES / 1024" | bc)
                FILE_SIZE="${FILE_SIZE} KB"
            else
                FILE_SIZE="${FILE_SIZE_BYTES} B"
            fi
        else
            FILE_SIZE="0"
        fi
    else
        FILE_SIZE="0"
    fi
    
    SAVES_STATUS="$FILE_COUNT files, $FILE_SIZE"
else
    SAVES_STATUS="folder not found"
fi
    
    if [ -f "$STATUS_FILE" ]; then
        read -r STATUS STATUS_TIME < "$STATUS_FILE" 2>/dev/null
        TIME_STR=$(date -d @$STATUS_TIME "+%d.%m.%Y %H:%M" 2>/dev/null || echo "unknown")
        if [ "$STATUS" = "OK" ]; then
            LAST_SYNC_STATUS="✓ successful ($TIME_STR)"
        elif [ "$STATUS" = "ERROR" ]; then
            LAST_SYNC_STATUS="✗ error ($TIME_STR)"
        else
            LAST_SYNC_STATUS="unknown"
        fi
    else
        LAST_SYNC_STATUS="not run yet"
    fi
    
    FREE=$(df -h "$SAVE_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    [ -z "$FREE" ] && FREE="unknown"
    
    if [ "$REAL_INTERVAL" -eq 0 ]; then
        INTERVAL_DISPLAY="Every time you quit a game"
    elif [ "$REAL_INTERVAL" -lt 60 ]; then
        INTERVAL_DISPLAY="Every ${REAL_INTERVAL} sec after quitting a game"
    elif [ "$REAL_INTERVAL" -lt 3600 ]; then
        INTERVAL_DISPLAY="Every $((REAL_INTERVAL / 60)) min after quitting a game"
    else
        INTERVAL_DISPLAY="Every $((REAL_INTERVAL / 3600)) h after quitting a game"
    fi
    
    if [ -n "$EXCLUDED_SYSTEMS" ]; then
        EXCLUDE_DISPLAY="${EXCLUDED_SYSTEMS//|/, }"
    else
        EXCLUDE_DISPLAY="All systems syncing"
    fi
    
    # ============================================
    # SYNC STATISTICS
    # ============================================
    sync_stats_counts
    SYNC_STATS="$SYNC_NOCHG syncs ($SYNC_CHG OK, $SYNC_ERR ERR)"
    
    # ── CLOUD USAGE ──
    CLOUD_USED=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "used" | awk '{print $2, $3}')
    CLOUD_TOTAL=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "total" | awk '{print $2, $3}')
    if [ -n "$CLOUD_USED" ] && [ -n "$CLOUD_TOTAL" ]; then
        CLOUD_USED_DISPLAY="$CLOUD_USED of $CLOUD_TOTAL"
    else
        CLOUD_USED_DISPLAY="unknown"
    fi
}

############################################
# Control panel (flat menu with grouping)
############################################

show_control_panel() {
    while true; do
        get_status_info
        
        clear
        echo ""
        echo "══════════════════════════════════════════════════════════" 
        echo ""
        echo "           Save Sync - Control Panel v1.4.5"
        echo "" 
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo " 🖥️ System:          $SYSTEM (${CFW_VERSION:-unknown})"
        echo " 💾 Saves:           $SAVES_STATUS"
        echo " ☁️ Cloud:           $CLOUD_STATUS"
        echo " 📦 Free space:      $FREE (local) / $CLOUD_FREE (cloud)"
        echo " 🔄 Updated:         $LAST_SYNC_STATUS"
        echo " 📊 Statistics:      $SYNC_STATS"
        echo " 📁 Exclusions:      $EXCLUDE_DISPLAY"
        echo " ⏱️ Interval:        $INTERVAL_DISPLAY"
        echo "" 
        echo "──────────────────────────────────────────────────────────"
        echo ""
        echo " ── SAVES ──"
        echo "  1 - 📥 Download saves from cloud"
        echo "  2 - 📤 Upload saves to cloud"
        echo "  3 - 🔄 Full sync"
        
        # Show the number of excluded systems
        if [ -n "$EXCLUDED_SYSTEMS" ]; then
            EXCL_COUNT=$(echo "$EXCLUDED_SYSTEMS" | tr '|' '\n' | grep -c .)
            echo "  4 - 📁 Exclude systems (${EXCL_COUNT} excluded)"
        else
            echo "  4 - 📁 Exclude systems (all systems syncing)"
        fi
        echo ""
        
        echo " ── ROMS ──"
        echo "  5 - 📁 Copy and download ROMs"
        echo ""
        
        echo " ── SAVE SETTINGS ──"
        echo "  6 - ⏱️ Sync interval (currently: $REAL_INTERVAL sec)"
        echo "  7 - 🔄 Retry count (currently: $REAL_RETRIES)"
        echo "  8 - 🗂️ Conflict copies (now: $(keep_days_label))"
        echo ""
        
        echo " ── INFO ──"
        echo "  9 - 📊 Statistics and logs"
        echo " 10 - 🔍 Full diagnostics"
        echo ""
        
        echo " ── SYSTEM ──"
        echo " 11 - 🗑️ Clear temporary files"
        echo " 12 - 🔄 Reboot device"
        echo ""
        
        echo " ── WEB INTERFACE ──"
        echo "      🌐 http://$IP_ADDR:8080"
        echo " 13 - 🔄 Restart web interface"
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo "  0 - 🚪 Exit"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        read -p "Choose an action (0-13): " choice
        
        case $choice in
            1) 
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo " 📥 Downloading saves from cloud"
                echo "══════════════════════════════════════════════════════════"
                echo ""
                echo "This will DOWNLOAD saves from the cloud to the device."
                echo ""
                echo " ⚠️ IMPORTANT:"
                echo "  • Only saves changed on other devices are downloaded"
                echo "  • If a save was deleted on another device, it is deleted here too"
                echo "  • Saves changed on this device are not replaced,"
                echo "    they are sent to the cloud"
                echo "  • If a save was changed both here and on another device,"
                echo "    the newer one is kept"
                if ! "$RCLONE_PATH" --config "$RCLONE_CONF" lsf "$REMOTE" 2>/dev/null | grep -v -e ".first_sync_done" -e ".sync_manifest.json" | grep -q .; then
                    echo ""
                    echo " ℹ️  There are no saves in the cloud yet - saves from the device"
                    echo "    will be copied to the cloud."
                fi
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo ""
                read -p "Continue with download? (y/n): " confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    echo "❌ Cancelled."
                    echo ""
                    pause
                    continue
                fi
                echo ""
                echo "🔄 Downloading saves from cloud..."
                bash "$DOWNLOAD_SCRIPT" --verbose
                echo ""
                pause
                ;;
            2)
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo " 📤 Uploading saves to cloud"
                echo "══════════════════════════════════════════════════════════"
                echo ""
                echo "This will UPLOAD saves from the device to the cloud."
                echo ""
                echo " ⚠️ IMPORTANT:"
                echo "  • Only new or changed files are uploaded"
                echo "  • If a file was deleted on the device, it IS deleted from the cloud"
                echo "  • Deletions are synced between devices"
                echo "  • Saves changed on other devices are not overwritten,"
                echo "    they are downloaded here"
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo ""
                read -p "Continue with upload? (y/n): " confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    echo "❌ Cancelled."
                    echo ""
                    pause
                    continue
                fi
                echo ""
                echo "🔄 Uploading saves to cloud..."
                bash "$UPLOAD_SCRIPT" --verbose
                echo ""
                pause
                ;;
            3)
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo " 🔄 Full save sync"
                echo "══════════════════════════════════════════════════════════"
                echo ""
                echo "This will perform a FULL sync:"
                echo ""
                echo "  1. First DOWNLOADS saves from the cloud"
                echo "  2. Then UPLOADS saves to the cloud"
                echo ""
                echo " ⚠️ If the download fails, the upload is skipped."
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo ""
                read -p "Continue with full sync? (y/n): " confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    echo "❌ Cancelled."
                    echo ""
                    pause
                    continue
                fi
                echo ""
                echo "🔄 Running full save sync..."
                echo ""
                echo "--- Step 1: Download from cloud ---"
                if bash "$DOWNLOAD_SCRIPT" --verbose; then
                    echo ""
                    echo "--- Step 2: Upload to cloud ---"
                    if bash "$UPLOAD_SCRIPT" --verbose; then
                        echo ""
                        echo "✅ Full sync complete!"
                    else
                        echo ""
                        echo "❌ Upload failed. Details: menu 9 (Statistics and logs)."
                    fi
                else
                    echo ""
                    echo "❌ Download failed - the upload was not run."
                    echo "   Details: menu 9 (Statistics and logs)."
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
                echo "Current interval: $REAL_INTERVAL sec"
                echo ""
                echo "How often should it sync?"
                echo " 1 - Every time you quit a game (0 sec)"
                echo " 2 - Every 5 minutes (300 sec)"
                echo " 3 - Every 15 minutes (900 sec)"
                echo " 4 - Every 30 minutes (1800 sec)"
                echo " 5 - Every hour (3600 sec)"
                echo " 6 - Custom interval"
                echo ""
                read -p "Choose (1-6): " int_choice
                case "$int_choice" in
                    1) NEW_INTERVAL=0 ;;
                    2) NEW_INTERVAL=300 ;;
                    3) NEW_INTERVAL=900 ;;
                    4) NEW_INTERVAL=1800 ;;
                    5) NEW_INTERVAL=3600 ;;
                    6) read -p "Enter interval in seconds: " NEW_INTERVAL ;;
                    *) echo "❌ Invalid choice"; pause; continue ;;
                esac
                
                SYNC_INTERVAL=$NEW_INTERVAL
                save_config
                
                echo ""
                echo "✅ Interval changed to $NEW_INTERVAL sec"
                echo ""
                echo "💡 Changes applied. No reboot needed."
                echo ""
                pause
                ;;
            7)
                echo ""
                echo "Current value: $REAL_RETRIES attempts"
                echo ""
                echo "How many times should it retry on error?"
                echo " 1 - 1 time"
                echo " 2 - 2 times"
                echo " 3 - 3 times (default)"
                echo " 4 - 5 times"
                echo " 5 - 10 times"
                echo ""
                read -p "Choose (1-5): " retry_choice
                case "$retry_choice" in
                    1) NEW_RETRIES=1 ;;
                    2) NEW_RETRIES=2 ;;
                    3) NEW_RETRIES=3 ;;
                    4) NEW_RETRIES=5 ;;
                    5) NEW_RETRIES=10 ;;
                    *) echo "❌ Invalid choice"; pause; continue ;;
                esac
                
                MAX_RETRIES=$NEW_RETRIES
                save_config
                
                echo ""
                echo "✅ Retry count changed to $NEW_RETRIES"
                echo ""
                echo "Changes applied. No reboot needed."
                echo ""
                pause
                ;;
            8)
                echo ""
                echo "Now: $(keep_days_label)"
                echo ""
                echo "If the same save was changed on different devices, the newest version"
                echo "is kept. The older one can be kept in the cloud (GameSaves_conflicts"
                echo "folder) so you can restore it by hand if needed."
                echo "How many days to keep such copies?"
                echo " 1 - Do not keep"
                echo " 2 - 1 day"
                echo " 3 - 3 days (default)"
                echo " 4 - 7 days"
                echo " 5 - 30 days"
                echo ""
                read -p "Choose (1-5): " keep_choice
                case "$keep_choice" in
                    1) CONFLICT_KEEP_DAYS=0 ;;
                    2) CONFLICT_KEEP_DAYS=1 ;;
                    3) CONFLICT_KEEP_DAYS=3 ;;
                    4) CONFLICT_KEEP_DAYS=7 ;;
                    5) CONFLICT_KEEP_DAYS=30 ;;
                    *) echo "❌ Invalid choice"; pause; continue ;;
                esac
                save_config
                echo ""
                echo "✅ Conflict copies: $(keep_days_label)"
                echo ""
                pause
                ;;
            9)
                show_statistics
                ;;
            10)
                echo ""
                bash "$0" --info
                echo ""
                pause
                ;;
            11)
                echo ""
                echo " 🗑️  Clearing temporary files"
                echo ""
                echo "The following will be removed:"
                echo "  • /tmp/save_sync_*"
                echo "  • /tmp/rclone_*"
                echo "  • /tmp/*.lock"
                echo ""
                read -p "Continue? (y/n): " clean_confirm
                if [ "$clean_confirm" = "y" ] || [ "$clean_confirm" = "Y" ]; then
                    rm -rf /tmp/save_sync_* /tmp/rclone_* /tmp/*.lock 2>/dev/null
                    echo "✅ Temporary files removed"
                else
                    echo "Cancelled"
                fi
                echo ""
                pause
                ;;
            12)
                echo ""
                echo "⚠️ WARNING!"
                echo "The device will be rebooted."
                echo ""
                read -p "Reboot now? (y/n): " reboot_confirm
                if [ "$reboot_confirm" = "y" ] || [ "$reboot_confirm" = "Y" ]; then
                    echo "🔄 Rebooting..."
                    sleep 1
                    reboot
                    exit 0
                else
                    echo "Cancelled"
                fi
                echo ""
                pause
                ;;
            13)
                echo ""
                echo "🔄 Restarting web interface..."
                # Stop the old one
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
                # Start a new one
                bash "$0" --web &
                echo "✅ Web interface restarted"
                echo "🌐 Open: http://$IP_ADDR:8080"
                echo ""
                pause
                ;;
            0)
                echo "🚪 Exiting..."
                exit 0
                ;;
            *)
                echo "❌ Invalid choice"
                sleep 1
                ;;
        esac
    done
}

############################################
# WEB INTERFACE (IMPROVED, NO EXPORT/IMPORT, NO AUTO-SAVE)
############################################

restart_web_after_update() {
    echo "🔄 Restarting web interface with the new version..."
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
    echo "✅ Web interface started"
}

start_web() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " 🌐 Save Sync - Web Interface v1.4.5"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    
    # Get IP address (same as in diagnostics)
    IP_ADDR=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
    if [ -z "$IP_ADDR" ]; then
        IP_ADDR="localhost"
    fi
    
    # Check for Python
    if ! command -v python3 &> /dev/null; then
        if ! command -v python3 &> /dev/null; then
            echo "❌ Python3 not found and could not be installed automatically."
            echo "Install python3 manually for your system and run --web again."
            return 1
        fi
        echo "✅ Python3 installed"
    fi
    
    # Check whether the server is already running
    if [ -f "/tmp/save_sync_web.pid" ]; then
        PID=$(cat /tmp/save_sync_web.pid 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && grep -q "server.py" "/proc/$PID/cmdline" 2>/dev/null; then
            echo "⚠️ Web interface is already running (PID: $PID)"
            echo "🌐 Open: http://${IP_ADDR}:8080"
            echo ""
            echo "To stop it: kill $PID"
            return 1
        else
            # Stale PID file: the process is gone, or its number was
            # reused by a different process after a reboot
            rm -f "/tmp/save_sync_web.pid"
        fi
    fi
    
    # Create the web interface directory
    WEB_DIR="/tmp/save_sync_web"
    mkdir -p "$WEB_DIR"
    
    # Create the Python server
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
                f.write("# Save Sync v1.4.5 - Main config\n")
                f.write("# ========================================\n\n")
                f.write("# ---- SYNC SETTINGS ----\n")
                f.write(f'SYNC_INTERVAL="{current.get("SYNC_INTERVAL", 0)}"\n')
                f.write(f'MAX_RETRIES="{current.get("MAX_RETRIES", 3)}"\n')
                f.write(f'CONFLICT_KEEP_DAYS="{current.get("CONFLICT_KEEP_DAYS", 3)}"\n')
                f.write(f'MIN_FREE_KB="{current.get("MIN_FREE_KB", 51200)}"\n\n')
                f.write("# ---- ROM SETTINGS ----\n")
                f.write(f'ROMS_SYNC_DIRS="{current.get("ROMS_SYNC_DIRS", "")}"\n')
                f.write(f'ROMS_SYNC_MEDIA="{current.get("ROMS_SYNC_MEDIA", "false")}"\n')
                f.write(f'EXCLUDED_SYSTEMS="{current.get("EXCLUDED_SYSTEMS", "")}"\n\n')
                f.write("# ---- LOGGING SETTINGS ----\n")
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
    # IMPROVED SYSTEM DETECTION FUNCTION
    # ========================================
    def get_system(self):
        # 1. Try via /etc/os-release
        if os.path.exists("/etc/os-release"):
            with open("/etc/os-release", "r") as f:
                for line in f:
                    if line.startswith("ID="):
                        id_ = line.split("=")[1].strip().strip('"')
                        if id_ == "batocera": return "Batocera"
                        if id_ == "knulli": return "KNULLI"
                        if id_ == "recalbox": return "Recalbox"
        
        # 2. Check for Batocera (extended)
        if os.path.exists("/boot/batocera") or os.path.exists("/etc/batocera-release") or os.path.exists("/usr/bin/batocera-es-swissknife"):
            return "Batocera"
        
        # 3. Check for KNULLI
        if os.path.exists("/usr/share/knulli/knulli.version") or os.path.exists("/etc/knulli-release") or os.path.exists("/boot/knulli"):
            return "KNULLI"
        
        # 4. Check for Recalbox
        if os.path.exists("/etc/recalbox-release") or os.path.exists("/recalbox/recalbox"):
            return "Recalbox"
        
        # 5. Check for folders (as a fallback)
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
        return "Unknown"
    
    def get_version(self):
        # Priority: system-specific files
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
        
        # Try /etc/os-release
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
        
        return "Unknown"
    
    def update_roms_filter(self):
        config = self.read_config()
        roms_sync_dirs = config.get("ROMS_SYNC_DIRS", "")
        roms_sync_media = config.get("ROMS_SYNC_MEDIA", "false")
        
        try:
            with open(ROMS_FILTER_FILE, "w") as f:
                f.write("# Filter for ROM sync\n")
                f.write("# Created automatically, do not edit by hand\n\n")
                f.write("# Exclude system files\n")
                f.write("- **/_info.txt\n\n")
                if roms_sync_media != "true":
                    f.write("# Exclude media folders\n")
                    f.write("- **/images/**\n")
                    f.write("- **/media/**\n")
                    f.write("- **/videos/**\n")
                    f.write("- **/manuals/**\n")
                    f.write("- **/screenshots/**\n")
                    f.write("- **/thumbnails/**\n\n")
                    f.write("# Exclude media files\n")
                    f.write("- **.png\n")
                    f.write("- **.jpg\n")
                    f.write("- **.jpeg\n")
                    f.write("- **.gif\n")
                    f.write("- **.bmp\n\n")
                f.write("# Exclude video files\n")
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
                    f.write("# Add selected systems\n")
                    for dir in roms_sync_dirs.split("|"):
                        dir = dir.strip()
                        if dir:
                            f.write(f"+ /{dir}/**\n")
                    f.write("\n")
                f.write("# Exclude everything not selected\n")
                f.write("- **\n")
            return True
        except:
            return False
    
    def get_stats(self):
        stats = {"sync": {"total": 0, "ok": 0, "changed": 0, "unchanged": 0, "error": 0}, "roms": {"total": 0, "ok": 0, "error": 0}}
        if os.path.exists(LOG_FILE):
            try:
                with open(LOG_FILE, "r") as f:
                    content = f.read()
                    stats["sync"]["ok"] = len(re.findall(r"Saves downloaded|Saves uploaded", content))
                    # "(изменений нет)" / "(no changes)": the sync ran fine, but everything already matched
                    # with changes = the log line says what was moved ("(sent: 1, ...)"); a plain line or "(no changes)" means nothing was transferred
                    noted = len(re.findall(r"(?:Saves downloaded|Saves uploaded) \(", content))
                    empty = len(re.findall(r"(?:Saves downloaded|Saves uploaded) \(no changes\)", content))
                    stats["sync"]["changed"] = noted - empty
                    stats["sync"]["unchanged"] = stats["sync"]["ok"] - stats["sync"]["changed"]
                    stats["sync"]["total"] = stats["sync"]["ok"]
                    # only save errors: ROM and link download errors have their own lines in the log
                    stats["sync"]["error"] = len(re.findall(r"Save (?:download|upload) error|First (?:download|upload) error|Upload error for saves|Cloud unavailable \(no network", content))
                    stats["roms"]["total"] = len(re.findall(r"ROM upload complete|ROM download complete", content))
                    stats["roms"]["ok"] = len(re.findall(r"ROM upload complete|ROM download complete", content))
                    stats["roms"]["error"] = len(re.findall(r"ROM download error|ROM upload error", content))
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
        elif path == "/api/link/dests":
            self.api_link_dests(parsed.query)
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
        else:
            self.send_error(404)

    def api_status(self):
        config = self.read_config()
        stats = self.get_stats()
        
        system_name = self.get_system()
        system_version = self.get_version()
        device_name = self.get_device()

    # Build the system display like in the control panel
        if system_name == "KNULLI":
        # Try to get the scarab version
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
                system_display = f"{system_name} ({system_version})" if system_version != "Unknown" else system_name
        else:
            system_display = system_name if system_version == "Unknown" else f"{system_name} ({system_version})"
        
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
        
        # Saves
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
                size_str = f"{size/(1024*1024):.1f} MB" if size > 1024*1024 else f"{size/1024:.1f} KB" if size > 1024 else f"{size} B"
                status["saves"] = {"count": count, "size": size_str}
            except:
                pass
        
        # Cloud
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
        
        # Last sync
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
        
        # Internet: if the cloud answered, the internet works.
        # Otherwise a TCP connection check - not ping: some networks
        # block ping while everything else works.
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
        
        # Exclusions
        if config.get("EXCLUDED_SYSTEMS"):
            status["excluded"] = [x.strip() for x in config["EXCLUDED_SYSTEMS"].split("|") if x.strip()]
        
        # ROMs
        if config.get("ROMS_SYNC_DIRS"):
            status["roms_selected"] = [x.strip() for x in config["ROMS_SYNC_DIRS"].split("|") if x.strip()]
        
        # Check whether a sync is in progress
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
                result["lines"] = ["Log cleared"]
                self.send_json(result)
                return
        
        if os.path.exists(LOG_FILE):
            try:
                with open(LOG_FILE, "r") as f:
                    all_lines = f.readlines()
                    last = all_lines[-lines:] if len(all_lines) > lines else all_lines
                    result["lines"] = [l.strip() for l in last if l.strip()]
            except:
                result["lines"] = ["Error reading log"]
        else:
            result["lines"] = ["Log not created yet"]
        
        self.send_json(result)

    def api_config(self):
        self.send_json(self.read_config())

    def api_config_save(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_json({"success": False, "error": "No data"})
            return
        
        try:
            data = json.loads(self.rfile.read(length))
            if self.save_config(data):
                self.update_roms_filter()
                self.send_json({"success": True, "message": "Settings saved"})
            else:
                self.send_json({"success": False, "error": "Save error"})
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
        
        # Also check the cloud - there may be systems
        # not yet on the device (e.g. ROMs were dropped directly
        # into the cloud from a computer, without touching the device). Without this
        # they couldn't be selected and thus couldn't be downloaded.
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
            self.send_json({"success": False, "error": "No data"})
            return
        try:
            data = json.loads(self.rfile.read(length))
            theme = data.get("theme", "dark")
            with open("/tmp/save_sync_theme", "w") as f:
                f.write(theme)
            self.send_json({"success": True, "theme": theme})
        except:
            self.send_json({"success": False, "error": "Error saving theme"})

    def api_sync(self, query):
        params = urllib.parse.parse_qs(query)
        action = params.get("action", ["full"])[0]
        
        messages = {
            "download": "Save download started",
            "upload": "Save upload started",
            "full": "Full sync started",
            "roms_download": "ROM download started",
            "roms_upload": "ROM upload started"
        }
        
        # Reset the progress state right away, before spawning the child process.
        # Otherwise the browser's first poll could see stale success/error data
        # from a previous run, before the script itself reaches its own
        # progress_start call and overwrites the file with current state.
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
                    self.send_json({"success": False, "error": f"Script not found: {DOWNLOAD_SCRIPT}"})
            
            elif action == "upload":
                if os.path.exists(UPLOAD_SCRIPT):
                    self._spawn_op(action, ["bash", UPLOAD_SCRIPT, "--web-progress"], 
                                   stdout=subprocess.DEVNULL, 
                                   stderr=subprocess.DEVNULL)
                    self.send_json({"success": True, "message": messages[action]})
                else:
                    self.send_json({"success": False, "error": f"Script not found: {UPLOAD_SCRIPT}"})
            
            elif action == "full":
                if not os.path.exists(DOWNLOAD_SCRIPT) or not os.path.exists(UPLOAD_SCRIPT):
                    self.send_json({"success": False, "error": "Sync script not found"})
                    return
                # One process runs download -> upload sequentially,
                # so the Web UI sees the real current stage of the full sync.
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
                    self.send_json({"success": False, "error": f"Script not found: {DOWNLOAD_ROMS}"})
            
            elif action == "roms_upload":
                if os.path.exists(UPLOAD_ROMS):
                    self._spawn_op(action, ["bash", UPLOAD_ROMS, "--web-progress"], 
                                   stdout=subprocess.DEVNULL, 
                                   stderr=subprocess.DEVNULL)
                    self.send_json({"success": True, "message": messages[action]})
                else:
                    self.send_json({"success": False, "error": f"Script not found: {UPLOAD_ROMS}"})
            
            else:
                self.send_json({"success": False, "error": "Unknown action"})
        
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})

    def api_exclude(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_json({"success": False, "error": "No data"})
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
                        self.send_json({"success": True, "message": f"{system} excluded"})
                    else:
                        self.send_json({"success": False, "error": "Save error"})
                else:
                    self.send_json({"success": False, "error": "System already excluded"})
            
            elif action == "remove":
                if system in excluded_list:
                    excluded_list.remove(system)
                    config["EXCLUDED_SYSTEMS"] = "|".join(excluded_list)
                    if self.save_config(config):
                        self.send_json({"success": True, "message": f"{system} restored"})
                    else:
                        self.send_json({"success": False, "error": "Save error"})
                else:
                    self.send_json({"success": False, "error": "System not in exclusions"})
            
            elif action == "clear":
                config["EXCLUDED_SYSTEMS"] = ""
                if self.save_config(config):
                    self.send_json({"success": True, "message": "All exclusions cleared"})
                else:
                    self.send_json({"success": False, "error": "Save error"})
            
            else:
                self.send_json({"success": False, "error": "Unknown action"})
        
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})

    def api_roms(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_json({"success": False, "error": "No data"})
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
                    self.send_json({"success": True, "message": f"Systems selected: {len(systems)}"})
                else:
                    self.send_json({"success": False, "error": "Save error"})
            
            elif action == "toggle_media":
                current = config.get("ROMS_SYNC_MEDIA", "false")
                config["ROMS_SYNC_MEDIA"] = "true" if current == "false" else "false"
                if self.save_config(config):
                    self.update_roms_filter()
                    status = "enabled" if config["ROMS_SYNC_MEDIA"] == "true" else "disabled"
                    self.send_json({"success": True, "message": f"Media {status}"})
                else:
                    self.send_json({"success": False, "error": "Save error"})
            
            else:
                self.send_json({"success": False, "error": "Unknown action"})
        
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
            self.send_json({"error": "No link"})
            return
        if not os.path.exists(LINK_SCRIPT):
            self.send_json({"error": "link_download.py not found - reinstall Save Sync"})
            return
        try:
            r = subprocess.run([sys.executable, LINK_SCRIPT, "--list-json", url],
                               capture_output=True, text=True, timeout=600,
                               env=self._link_env(data.get("password") or ""))
            lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
            result = json.loads(lines[-1]) if lines else {"error": (r.stderr or "no output")[-300:]}
        except subprocess.TimeoutExpired:
            result = {"error": "The service took too long to return the file list"}
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
            result = {"error": "Reading the archive took too long"}
        except Exception as e:
            result = {"error": str(e)}
        self.send_json(result)

    def api_link_download(self):
        data = self._json_body()
        url = (data.get("url") or "").strip()
        dest = (data.get("dest") or "").strip()
        items = [i for i in (data.get("items") or []) if isinstance(i, str)]
        if not url:
            self.send_json({"success": False, "error": "No link"})
            return
        if not dest:
            self.send_json({"success": False, "error": "Choose where to put the files"})
            return
        if not os.path.exists(LINK_SCRIPT):
            self.send_json({"success": False, "error": "link_download.py not found - reinstall Save Sync"})
            return
        if self._link_pid() is not None:
            self.send_json({"success": False, "error": "A link download is already running"})
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
                    json.dump({"active": False, "action": action, "phase": "Operation cancelled", "percent": 0,
                               "success": False, "cancelled": True}, f)
            except OSError:
                pass

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
            self.send_json({"success": False, "error": "No operation is running"})
            return
        if not self._group_alive(pgid):
            self.send_json({"success": False, "error": "No operation is running"})
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
            self.send_json({"success": False, "error": "No link download is running"})
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

/* Progress bar animation */
@keyframes syncProgressMove {
    0% { transform: translateX(-140%); }
    50% { transform: translateX(120%); }
    100% { transform: translateX(280%); }
}

/* ========================================
   MATERIAL DESIGN - DARK THEME (Moonlit Night)
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
   MATERIAL DESIGN - LIGHT THEME (Sky Blue)
   ======================================== */
/* ========================================
   MATERIAL DESIGN - LIGHT THEME (Cloudy Morning)
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

/* ========== HIDE LOGS ON THE SETTINGS TAB ========== */

/* Logs are visible by default */
.log-wrapper {
    display: block;
}

/* Hide the whole logs block when the Settings tab is active */
#tab-settings.active ~ .log-wrapper {
    display: none !important;
}

/* Styles inside the wrapper (unchanged) */
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

/* ========== HEADER ========== */
.header{text-align:center;margin-bottom:24px;position:relative}
.header h1{font-size:28px;font-weight:500;letter-spacing:-0.5px;color:var(--text-primary)}
.header .sub{color:var(--text-secondary);font-size:14px;font-weight:400;margin-top:4px}
.header .device{color:var(--text-muted);font-size:12px;margin-top:4px}

/* ========== THEME BUTTON ========== */
.header .theme-toggle {
    position: fixed;
    top: 16px;
    right: 16px;
    background: transparent;           /* ← TRANSPARENT */
    border: none;                      /* ← NO OUTLINE */
    color: var(--text-primary);
    padding: 0;
    border-radius: 0;
    cursor: pointer;
    font-size: 32px;
    box-shadow: none;                  /* ← SHADOW REMOVED, USING FILTER INSTEAD */
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
    /* ← SHADOW VIA FILTER FOR THE MOON */
    filter: drop-shadow(0 4px 6px rgba(0, 0, 0, 0.4));
}

/* SHADOW ON HOVER */
@media (hover: hover) {
    .header .theme-toggle:hover {
        transform: scale(1.15);
        filter: drop-shadow(0 6px 12px rgba(0, 0, 0, 0.6));
    }
}

/* ON CLICK */
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

/* ========== STATUS PANEL ========== */
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

/* ========== TABS ========== */
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

/* ========== SECTION HEADERS ========== */
.section-title{font-size:14px;font-weight:500;color:var(--text-secondary);margin-bottom:12px;padding-bottom:4px;border-bottom:2px solid var(--accent);display:inline-block;letter-spacing:0.3px}

/* ========== BUTTONS ========== */
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

/* ========== PRIMARY BUTTON (DARK TEXT) ========== */
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

/* ========== DANGER BUTTON ========== */
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

.btn:disabled{opacity:0.5;cursor:not-allowed;transform:none!important;box-shadow:none!important}

/* ========== BUTTON GROUPS ========== */
.actions{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px;margin-bottom:16px}

/* ========== SETTINGS ========== */
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

/* ========== STATISTICS ========== */
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

/* ========== SYSTEMS ========== */
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

/* ========== CAPTION UNDER BUTTONS ========== */
.sync-note{margin-top:6px;padding:10px 16px;background:var(--bg-card);border-radius:var(--radius);border-left:4px solid var(--warning);font-size:11px;color:var(--text-secondary);line-height:1.6;box-shadow:var(--elevation-0)}
.sync-note p{margin:3px 0}
.sync-note strong{color:var(--text-primary)}

/* ========== DEVICE ========== */
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

/* ========== CLOUD BACKGROUND ========== */
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

/* ========== RESPONSIVE ========== */
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
    <div class="sub">Cloud sync control</div>
    <div class="device" id="deviceInfo">Loading...</div>
  </div>

  <!-- STATUS PANEL -->
  <div class="status-grid" id="statusGrid">
    <div class="status-item">
    <div class="label"><svg width="12" height="11" viewBox="-312 -312 3120 3120" style="vertical-align:0px;margin-right:3px"><g transform="translate(0,2496) scale(0.1,-0.1)" fill="currentColor"><path d="M9350 12533 c0 -6836 3 -12452 6 -12480 l7 -53 3153 0 3154 0 0 4408 c0 2425 -3 8041 -7 12480 l-6 8072 -3154 0 -3153 0 0 -12427z"/><path d="M521 15176 c-9 -10 -10 -1883 -5 -7595 l7 -7581 3154 0 3153 0 0 7583 c0 5885 -3 7586 -12 7595 -9 9 -722 12 -3149 12 -2662 0 -3138 -2 -3148 -14z"/><path d="M19945 7610 l-1750 -5 -3 -3803 -2 -3802 3162 0 3161 0 -6 3802 c-6 3005 -10 3804 -20 3810 -12 8 -1345 7 -4542 -2z"/></g></svg>Statistics</div>
    <div class="value" id="syncStats" title="No changes / With changes / Errors">0 • <svg width="13" height="13" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M16 17.01V10h-2v7.01h-3L15 21l4-3.99h-3zM9 3L5 6.99h3V14h2V6.99h3L9 3z" fill="currentColor"/></svg> 0 • <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> 0</div>
   </div>
    <div class="status-item">
      <div class="label"><svg width="13" height="13" viewBox="-6 -6 36 36" fill="none" style="vertical-align:0px;margin-right:3px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Saves</div>
      <div class="value" id="sysSaves">-</div>
    </div>
    <div class="status-item">
      <div class="label"><svg width="17" height="12" viewBox="-192 -123 1664 1068" style="vertical-align:0px;margin-right:3px"><g transform="translate(0,822) scale(0.1,-0.1)" fill="currentColor"><path d="M7121 8205 c-484 -56 -926 -221 -1315 -494 -238 -166 -476 -397 -637 -618 -23 -32 -44 -60 -45 -62 -2 -2 -40 8 -84 23 -117 38 -260 73 -385 92 -150 23 -442 23 -590 0 -611 -94 -1127 -423 -1468 -934 -235 -353 -362 -809 -344 -1229 l6 -132 -32 -5 c-18 -3 -72 -10 -122 -16 -413 -50 -861 -242 -1201 -515 -434 -349 -738 -846 -852 -1395 -38 -183 -47 -272 -46 -495 0 -243 14 -368 63 -571 221 -899 936 -1599 1835 -1794 268 -58 -2 -55 4336 -55 3806 0 4011 1 4125 18 649 97 1197 373 1635 824 142 145 217 237 324 396 233 346 381 728 448 1162 18 116 22 183 22 395 0 282 -16 420 -74 657 -180 738 -643 1363 -1298 1752 -333 198 -715 326 -1104 371 -117 14 -118 14 -118 89 0 95 -59 403 -107 556 -75 243 -205 524 -331 715 -452 687 -1140 1129 -1947 1250 -185 28 -520 35 -694 15z"/></g></svg>Cloud</div>
      <div class="value" id="sysCloud">-</div>
    </div>
    <div class="status-item">
      <div class="label"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" style="vertical-align:0px;margin-right:3px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg>Updated</div>
      <div class="value" id="sysLastSync">-</div>
    </div>
    <div class="status-item">
      <div class="label"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" style="vertical-align:0px;margin-right:3px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm6.93 6h-2.95c-.32-1.25-.78-2.45-1.38-3.56 1.84.63 3.37 1.9 4.33 3.56zM12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96zM4.26 14C4.1 13.36 4 12.69 4 12s.1-1.36.26-2h3.38c-.08.66-.14 1.32-.14 2 0 .68.06 1.34.14 2H4.26zm.82 2h2.95c.32 1.25.78 2.45 1.38 3.56-1.84-.63-3.37-1.9-4.33-3.56zm2.95-8H5.08c.96-1.66 2.49-2.93 4.33-3.56C8.81 5.55 8.35 6.75 8.03 8zM12 19.96c-.83-1.2-1.48-2.53-1.91-3.96h3.82c-.43 1.43-1.08 2.76-1.91 3.96zM14.34 14H9.66c-.09-.66-.16-1.32-.16-2 0-.68.07-1.35.16-2h4.68c.09.65.16 1.32.16 2 0 .68-.07 1.34-.16 2zm.25 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95c-.96 1.65-2.49 2.93-4.33 3.56zM16.36 14c.08-.66.14-1.32.14-2 0-.68-.06-1.34-.14-2h3.38c.16.64.26 1.31.26 2s-.1 1.36-.26 2h-3.38z" fill="currentColor"/></svg>Internet</div>
      <div class="value" id="sysInternet">-</div>
    </div>
    <div class="status-item">
      <div class="label"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" style="vertical-align:0px;margin-right:3px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg>Excluded</div>
      <div class="value" id="sysExcluded">-</div>
    </div>
  </div>

  <!-- TABS -->
  <div class="tabs">
    <button class="tab active" data-tab="saves"><svg width="16" height="16" viewBox="-6 -6 36 36" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Saves</button>
    <button class="tab" data-tab="roms"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>ROMs</button>
    <button class="tab" data-tab="stats"><svg width="13" height="13" viewBox="-312 -312 3120 3120" style="vertical-align:-2px;margin-right:4px"><g transform="translate(0,2496) scale(0.1,-0.1)" fill="currentColor"><path d="M9350 12533 c0 -6836 3 -12452 6 -12480 l7 -53 3153 0 3154 0 0 4408 c0 2425 -3 8041 -7 12480 l-6 8072 -3154 0 -3153 0 0 -12427z"/><path d="M521 15176 c-9 -10 -10 -1883 -5 -7595 l7 -7581 3154 0 3153 0 0 7583 c0 5885 -3 7586 -12 7595 -9 9 -722 12 -3149 12 -2662 0 -3138 -2 -3148 -14z"/><path d="M19945 7610 l-1750 -5 -3 -3803 -2 -3802 3162 0 3161 0 -6 3802 c-6 3005 -10 3804 -20 3810 -12 8 -1345 7 -4542 -2z"/></g></svg>Statistics</button>
    <button class="tab" data-tab="settings"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z" fill="currentColor"/></svg>Settings</button>
</div>

<!-- Saves tab -->
<div id="tab-saves" class="tab-content active">
    <div class="section-title"><svg width="16" height="16" viewBox="-6 -6 36 36" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Saves</div>
    
    <div class="actions">
        <button class="btn btn-primary" onclick="runSyncWithProgress('download')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z" fill="currentColor"/></svg>Download saves from cloud</button>
        <button class="btn btn-primary" onclick="runSyncWithProgress('upload')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M9 16h6v-6h4l-7-7-7 7h4v6zm-4 2h14v2H5v-2z" fill="currentColor"/></svg>Upload saves to cloud</button>
        <button class="btn btn-primary btn-full" onclick="runSyncWithProgress('full')"><svg width="16" height="16" viewBox="0 0 512 512" style="vertical-align:-3px;margin-right:4px"><g transform="translate(0,512) scale(0.1,-0.1)" fill="currentColor"><path d="M2360 4782 l0 -279 -57 -7 c-581 -68 -1130 -424 -1450 -939 -194 -313 -293 -668 -293 -1047 0 -314 65 -597 200 -875 53 -110 165 -289 222 -358 l23 -27 245 195 c135 108 249 200 253 204 5 5 -17 44 -48 87 -103 143 -184 335 -222 522 -24 120 -24 384 0 504 56 281 186 518 392 716 191 185 399 296 652 352 l83 18 2 -226 3 -225 485 408 c267 224 489 411 493 415 5 4 -42 51 -105 103 -373 314 -781 658 -826 695 l-52 44 0 -280z"/><path d="M3900 3558 c-124 -99 -236 -188 -248 -199 l-24 -18 56 -84 c153 -230 220 -458 220 -747 0 -230 -32 -382 -125 -579 -110 -235 -329 -470 -556 -598 -127 -71 -305 -133 -455 -158 l-38 -6 -2 276 -3 276 -485 -408 c-267 -224 -488 -412 -490 -417 -3 -4 216 -194 485 -420 l490 -413 3 227 2 227 68 6 c164 14 424 86 594 165 505 234 893 666 1067 1190 71 212 101 402 101 632 0 314 -65 597 -200 875 -72 149 -206 356 -228 354 -4 0 -108 -81 -232 -181z"/></g></svg>Full sync</button>
    </div> 

     
<!-- Saves progress bar -->
<div id="syncProgressSaves" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--border-color)">
    <div style="display:flex;justify-content:space-between;margin-bottom:5px">
        <span id="syncProgressTextSaves" style="color:var(--text-secondary);font-size:13px">Syncing...</span>
        <span id="syncProgressPercentSaves" style="color:var(--accent);font-size:13px;font-weight:bold">Transferring</span>
    </div>
    <div style="width:100%;height:8px;background:var(--bg-primary);border-radius:4px;overflow:hidden">
        <div id="syncProgressBarSaves" style="width:35%;height:100%;background:linear-gradient(90deg,var(--accent),var(--accent-hover));border-radius:4px;animation:syncProgressMove 1.4s ease-in-out infinite;"></div>
    </div>
    <div class="op-cancel-row"><button class="btn btn-danger op-cancel" id="opCancelSaves" onclick="cancelOperation()" style="display:none">Cancel</button></div>
</div>

    <!-- Info note -->
    <div class="sync-note">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>IMPORTANT:</strong></p>
        <p>• <strong>Download:</strong> This will DOWNLOAD saves from the cloud to the device. Only saves changed on other devices are downloaded. If a save was deleted on another device, it is deleted here too. Saves changed on this device are not replaced, they are sent to the cloud. If a save was changed both here and on another device, the newer one is kept. If the cloud is empty, saves from the device are copied to the cloud.</p>
        <p>• <strong>Upload:</strong> This will UPLOAD saves from the device to the cloud. Only new or changed files are uploaded. If a file was deleted on the device, it IS deleted from the cloud. Deletions are synced between devices. Saves changed on other devices are not overwritten, they are downloaded here.</p>
        <p>• <strong>Full sync:</strong> This will perform a FULL sync. First DOWNLOADS saves from the cloud, then UPLOADS saves to the cloud. If the download fails, the upload is skipped.</p>
    </div>
     
    <div class="section-title" style="margin-top:20px"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg>Exclusions</div>
    <div style="margin-bottom:10px;display:flex;gap:10px;flex-wrap:wrap;align-items:center">
        <button class="btn btn-danger" onclick="excludeAction('clear')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>Clear all exclusions</button>
        <span style="color:var(--text-secondary);font-size:12px">Click a system to exclude/restore it</span>
    </div>
    <div class="system-list" id="excludeList"><div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Loading systems...</div></div>
</div>

  <!-- ROMs tab -->
<div id="tab-roms" class="tab-content">
    <div class="section-title"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>ROMs</div>
    <div class="actions">
        <button class="btn btn-primary" onclick="runSyncWithProgress('roms_download')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z" fill="currentColor"/></svg>Download ROMs</button>
        <button class="btn btn-primary" onclick="runSyncWithProgress('roms_upload')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M9 16h6v-6h4l-7-7-7 7h4v6zm-4 2h14v2H5v-2z" fill="currentColor"/></svg>Upload ROMs</button>
    </div>
    
<!-- ROMs progress bar -->
<div id="syncProgressRoms" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--border-color)">
    <div style="display:flex;justify-content:space-between;margin-bottom:5px">
        <span id="syncProgressTextRoms" style="color:var(--text-secondary);font-size:13px">Syncing...</span>
        <span id="syncProgressPercentRoms" style="color:var(--accent);font-size:13px;font-weight:bold">Transferring</span>
    </div>
    <div style="width:100%;height:8px;background:var(--bg-primary);border-radius:4px;overflow:hidden">
        <div id="syncProgressBarRoms" style="width:35%;height:100%;background:linear-gradient(90deg,var(--accent),var(--accent-hover));border-radius:4px;animation:syncProgressMove 1.4s ease-in-out infinite;"></div>
    </div>
    <div class="op-cancel-row"><button class="btn btn-danger op-cancel" id="opCancelRoms" onclick="cancelOperation()" style="display:none">Cancel</button></div>
</div>

    <!-- Info note -->
    <div class="sync-note">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>IMPORTANT:</strong></p>
        <p>• <strong>Download ROMs:</strong> This will DOWNLOAD ROMs from the cloud to the device. Files on the device are NOT deleted. Only new or changed files are downloaded.</p>
        <p>• <strong>Upload ROMs:</strong> This will DELETE from the cloud any ROMs missing on the device. If some ROMs are missing on the device, they will disappear from the cloud with no way to recover them! It is recommended to DOWNLOAD ROMs from the cloud first, or back up the cloud.</p>
    </div>
    
    <div class="section-title" style="margin-top:20px"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M20 6h-8l-2-2H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z" fill="currentColor"/></svg>Select systems to upload and download</div>
    <div style="margin-bottom:10px;display:flex;gap:10px;flex-wrap:wrap;align-items:center">
        <button class="btn" onclick="selectAllRoms()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg>Select all</button>
        <button class="btn btn-danger" onclick="deselectAllRoms()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>Deselect all</button>
        <button class="btn" onclick="toggleMedia()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z" fill="currentColor"/></svg>Media: <span id="mediaStatus">-</span></button>
        <span style="color:var(--text-secondary);font-size:12px">Click a system to select/deselect it</span>
    </div>
    <div class="system-list" id="romsList"><div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Loading systems...</div></div>

    <!-- Download from a public link -->
    <div class="section-title" style="margin-top:20px"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z" fill="currentColor"/></svg>Download from a public link</div>
    <div class="link-box" id="linkBox">
      <div class="link-input-row">
        <input id="linkUrl" class="link-input" type="url" autocomplete="off" placeholder="Paste a link: Yandex Disk, pCloud, Nextcloud, archive.org" onkeydown="if(event.key==='Enter')linkOpen()">
        <button class="btn btn-primary" id="linkOpenBtn" onclick="linkOpen()">Open</button>
      </div>
      <div class="link-input-row" id="linkPwRow" style="display:none;margin-top:8px">
        <input id="linkPw" class="link-input" type="password" autocomplete="off" placeholder="Link password" onkeydown="if(event.key==='Enter')linkOpen()">
      </div>
      <div class="link-hint">Yandex Disk, pCloud, Nextcloud / ownCloud, archive.org. You can pick single files and folders. A zip archive opens like a folder: you can take only the files you need. Files already on the device are skipped; an interrupted download resumes.</div>
      <div class="link-status" id="linkStatus"></div>
      <div id="linkBrowser" style="display:none">
        <div class="link-crumbs" id="linkCrumbs"></div>
        <div class="link-list" id="linkList"></div>
        <div class="link-target">
          <span>Where:</span>
          <label><input type="radio" name="linkTarget" value="device" checked onchange="linkTargetChanged()">To the device</label>
          <label><input type="radio" name="linkTarget" value="cloud" onchange="linkTargetChanged()">To the cloud</label>
        </div>
        <label class="link-unpack" id="linkUnpackRow" style="display:none"><input type="checkbox" id="linkUnpack" onchange="linkUpdateSummary()"><span id="linkUnpackText">Unpack archives after download</span></label>
        <div class="link-controls">
          <select id="linkDest" onchange="linkUpdateSummary()"></select>
          <button class="btn btn-primary" id="linkStartBtn" onclick="linkDownload()">Download</button>
        </div>
        <div class="link-summary" id="linkSummary"></div>
      </div>
    </div>
    <div id="syncProgressLink" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--border-color)">
        <div style="display:flex;justify-content:space-between;margin-bottom:5px">
            <span id="syncProgressTextLink" style="color:var(--text-secondary);font-size:13px">Syncing...</span>
            <span id="syncProgressPercentLink" style="color:var(--accent);font-size:13px;font-weight:bold">Transferring</span>
        </div>
        <div style="width:100%;height:8px;background:var(--bg-primary);border-radius:4px;overflow:hidden">
            <div id="syncProgressBarLink" style="width:35%;height:100%;background:linear-gradient(90deg,var(--accent),var(--accent-hover));border-radius:4px;animation:syncProgressMove 1.4s ease-in-out infinite;"></div>
        </div>
        <div class="op-cancel-row"><button class="btn btn-danger op-cancel" id="opCancelLink" onclick="cancelOperation()" style="display:none">Cancel</button></div>
    </div>
</div>

  <!-- SETTINGS TAB -->
  <div id="tab-settings" class="tab-content">
    <div class="settings-row">
      <label>Interval (sec):</label>
      <input type="number" id="settingInterval" value="0" min="0" step="60">
      <span style="color:var(--text-secondary);font-size:12px">0 = always</span>
    </div>
    <div class="settings-row">
      <label>Quick select:</label>
      <div class="quick-intervals">
        <button onclick="setIntervalQuick(0)">Always</button>
        <button onclick="setIntervalQuick(300)">5 min</button>
        <button onclick="setIntervalQuick(900)">15 min</button>
        <button onclick="setIntervalQuick(3600)">1 hour</button>
      </div>
    </div>
    <div class="settings-row">
      <label>Retries:</label>
      <input type="number" id="settingRetries" value="3" min="1" max="10">
    </div>
    <div class="settings-row">
      <label>Conflict copies:</label>
      <select id="settingKeepDays">
        <option value="0">Do not keep</option>
        <option value="1">1 day</option>
        <option value="3">3 days</option>
        <option value="7">7 days</option>
        <option value="30">30 days</option>
      </select>
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px">If the same save was changed on different devices, the newest version is kept and the older one is stored in the cloud, in GameSaves_conflicts, for the chosen time.</div>
    <div class="settings-row">
      <label>Logging:</label>
      <select id="settingLogEnabled">
        <option value="true">Enabled</option>
        <option value="false">Disabled</option>
      </select>
    </div>
    <!-- div class="settings-row">
      <label>Log level:</label>
      <select id="settingLogLevel">
        <option value="info">Info</option>
        <option value="debug">Debug</option>
        <option value="error">Error</option>
      </select>
    </div -->
    <div class="settings-row">
      <label>Max log size:</label>
      <input type="number" id="settingLogSize" value="102400" step="1024">
      <span style="color:var(--text-secondary);font-size:12px">bytes</span>
    </div>
    <button class="btn btn-primary" onclick="saveSettings()">Save settings</button>
  </div>

  <!-- STATISTICS TAB -->
  <div id="tab-stats" class="tab-content">
    <div class="stats-group-label"><svg width="14" height="14" viewBox="-6 -6 36 36" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Saves</div>
    <div class="stats-grid" id="statsGridSaves">
      <div class="stats-item" title="Successful syncs: everything already matched, nothing to transfer">
        <div class="num" id="statSyncUnchanged">0</div>
        <div class="label">No changes</div>
      </div>
      <div class="stats-item" title="Successful syncs where something was transferred or deleted">
        <div class="num ok" id="statSyncChanged">0</div>
        <div class="label">With changes</div>
      </div>
      <div class="stats-item" title="Syncs that failed">
        <div class="num error" id="statSyncError">0</div>
        <div class="label">Errors</div>
      </div>
    </div>
    <div class="stats-group-label"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>ROMs</div>
    <div class="stats-grid" id="statsGridRoms">
      <div class="stats-item">
        <div class="num" id="statRomsTotal">0</div>
        <div class="label">Total ROM syncs</div>
      </div>
      <div class="stats-item">
        <div class="num ok" id="statRomsOk">0</div>
        <div class="label">ROMs successful</div>
      </div>
      <div class="stats-item">
        <div class="num error" id="statRomsError">0</div>
        <div class="label">ROM errors</div>
      </div>
    </div>
  </div>

  <!-- LOGS -->
  <div class="log-wrapper">
    <div class="log-header">
      <span><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3h-4.18C14.4 1.84 13.3 1 12 1c-1.3 0-2.4.84-2.82 2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 0c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1zm7 16H5V5h2v3h10V5h2v14z" fill="currentColor"/></svg>Recent logs</span>
      <div class="log-actions">
        <button onclick="refreshLogs()"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z" fill="currentColor"/></svg>Refresh</button>
        <button onclick="clearLogs()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>Clear</button>
      </div>
    </div>
    <div class="log-container" id="logContainer"><div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Loading logs...</div></div>
  </div>
</div>

<div class="toast" id="toast"><span class="icon" id="toastIcon"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg></span><span id="toastMsg">Done!</span></div>

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

// ========== UNIVERSAL PROGRESS BAR ==========

function showProgress(show, text, target) {
    let container, textEl, percentEl, barEl;
    
    if (show) {
        // Show the specific bar
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
        if (percentEl) percentEl.textContent = 'Transferring';
    } else {
        // Hide BOTH bars
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
        if (percentSaves) percentSaves.textContent = 'Transferring';
        if (percentRoms) percentRoms.textContent = 'Transferring';
        const link = document.getElementById('syncProgressLink');
        if (link) {
            link.style.display = 'none';
            const bar = document.getElementById('syncProgressBarLink');
            if (bar) { bar.style.width = '0%'; bar.style.animation = 'none'; }
            const pl = document.getElementById('syncProgressPercentLink');
            if (pl) pl.textContent = 'Transferring';
        }
    }
}

function formatBytes(n) {
  if (!n || n <= 0) return '0 B';
  const units = ['B','KB','MB','GB'];
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
        let label = pct + '%';
        if (data.speed > 0) label += ' · ' + formatBytes(data.speed) + '/s';
        if (data.eta > 0) label += ' · ' + Math.round(data.eta) + ' sec left';
        if (data.totalTransfers > 0) label += ' · ' + (data.transfers || 0) + '/' + data.totalTransfers + ' files';
        percentEl.textContent = label;
    } else {
        barEl.style.animation = 'syncProgressMove 1.4s ease-in-out infinite';
        barEl.style.width = '35%';
        percentEl.textContent = 'Transferring';
    }
}

// ========== RUN SYNC ==========

// ========== RUN SYNC ==========

async function runSyncWithProgress(action, starter) {
    setButtonsDisabled(true);
    opCancelShow(true);

    const names = {
        'link_download': LINK_T.phase,
        'download': 'Downloading saves',
        'upload': 'Uploading saves',
        'full': 'Full sync',
        'roms_download': 'Downloading ROMs',
        'roms_upload': 'Uploading ROMs'
    };

    // Determine target once
    // a link download has its own progress bar in its own section
    const target = action === 'link_download' ? 'link' : (action === 'roms_download' || action === 'roms_upload') ? 'roms' : 'saves';
    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> ' + names[action] + ' starting...', target);

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

            // If progress is active - show it
            if (data.active) {
                seenActive = true;
                showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> ' + (data.phase || names[action] || 'Sync') + ' — transferring data...', target);
                updateProgressBar(data, target);
                return;
            }

            // If the operation finished very quickly (e.g. all files were already identical),
            // we may have missed seeing active=true between the start and the first poll.
            // So we check for a final result first.
            if (data.success !== null && data.success !== undefined) {
                // For a full sync - intermediate stage
                if (action === 'full' && data.action === 'download' && data.success) {
                    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Save download complete, starting upload...', 'saves');
                    return;
                }

                stopPolling();
                finished = true;
                opCancelShow(false);
                if (action === 'link_download') { linkFinished(data); return; }
                if (data.cancelled) { opCancelled(target); return; }
                if (data.success) {
                    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> ' + (data.phase || names[action]) + ' complete!', target);
                    updateProgressBar({ ...data, percent: 100 }, target);
                    showToast('Operation complete', 'success');
                } else {
                    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + (data.phase || 'Sync error'), target);
                    showToast('Operation failed', 'error');
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

            // If we haven't seen an active state yet and there's no final result,
            // show the starting state. This is normal in the first moments.
            if (!seenActive) {
                showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> ' + names[action] + ' starting...', target);
                return;
            }

            // If more than 60 seconds passed with no change - hide it
            if (seenActive && !data.active && data.success === null) {
                // Wait a bit longer
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
            showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Error: ' + (res.error || 'Unknown error'), target);
            showToast((res.error || 'Error'), 'error');
            setTimeout(() => { showProgress(false); setButtonsDisabled(false); }, 2500);
            return;
        }

        // Wait a bit for the script to start
        await new Promise(r => setTimeout(r, 500));
        
        await poll();
        if (!finished) polling = setInterval(poll, 1000);
        window._syncPolling = polling;
    } catch (e) {
        stopPolling();
        showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Error: ' + e.message, target);
        showToast('Error: ' + e.message, 'error');
        setTimeout(() => { showProgress(false); setButtonsDisabled(false); }, 3000);
    }
}

// ========== THEME ==========

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
      // Sync the icon
      const icon = document.getElementById('themeIcon');
      if (icon) {
        icon.textContent = res.theme === 'light' ? '🌑' : '🌕';
      }
    }
  } catch (e) {}
}

// ========== TABS ==========

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

// ========== STATUS (DOES NOT UPDATE SETTINGS) ==========

async function refreshStatus() {
  try {
    const data = await apiFetch('/status');
    
    // Statistics
    const unch = data.stats?.sync?.unchanged || 0;
    const chg = data.stats?.sync?.changed || 0;
    const err = data.stats?.sync?.error || 0;
    document.getElementById('syncStats').innerHTML = unch + ' • <svg width="13" height="13" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M16 17.01V10h-2v7.01h-3L15 21l4-3.99h-3zM9 3L5 6.99h3V14h2V6.99h3L9 3z" fill="currentColor"/></svg> ' + chg + ' • <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + err;
    const savesCount = data.saves?.count ?? 0;
    const savesSize = data.saves?.size ?? '0 B';
    document.getElementById('sysSaves').textContent = savesCount + ' files, ' + savesSize;
    
    const cloudEl = document.getElementById('sysCloud');
    if (data.cloud?.status === 'connected') {
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> ' + (data.cloud.free || '0');
      cloudEl.className = 'value ok';
    } else {
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Not connected';
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
      netEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Available';
      netEl.className = 'value ok';
    } else {
      netEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> None';
      netEl.className = 'value error';
    }
    
    const excl = data.excluded || [];
    document.getElementById('sysExcluded').textContent = excl.length > 0 ? excl.length + ' systems' : 'None';
    
    // Show the system like in the control panel
    const devicePart = data.device || 'Device';
    const systemPart = (data.system || 'unknown') + ' (' + (data.version || '?') + ')';
    document.getElementById('deviceInfo').innerHTML = '<svg width="11" height="11" viewBox="0 0 512 512" style="vertical-align:-2px"><path d="M84.54,0v512h259.252c46.209,0,83.669-37.459,83.669-83.669V0H84.54z M138.121,53.582H373.88v189.321H138.121V53.582z M215.931,382.887h-25.6v25.6H156.94v-25.6h-25.6v-33.391h25.6v-25.6h33.391v25.6h25.6V382.887z M284.507,445.972c-17.976,0-32.6-14.624-32.6-32.6s14.624-32.6,32.6-32.6s32.6,14.624,32.6,32.6S302.482,445.972,284.507,445.972z M342.138,377.21c-17.976,0-32.6-14.624-32.6-32.6s14.624-32.6,32.6-32.6s32.6,14.624,32.6,32.6S360.114,377.21,342.138,377.21z" fill="currentColor"/></svg> <span style="white-space:nowrap">' + devicePart + '</span> • <span style="white-space:nowrap">' + systemPart + '</span>';
    
    // ================================================================
    // ⚠️ SETTINGS ARE NOT UPDATED AUTOMATICALLY!
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

// ========== LOAD SETTINGS ON START ==========

async function loadSettings() {
  try {
    const data = await apiFetch('/status');
    if (data.config) {
      document.getElementById('settingInterval').value = data.config.SYNC_INTERVAL || 0;
      document.getElementById('settingRetries').value = data.config.MAX_RETRIES || 3;
      const kd = data.config.CONFLICT_KEEP_DAYS;
      document.getElementById('settingKeepDays').value = (kd === undefined || kd === '') ? '3' : String(kd);
      document.getElementById('settingLogEnabled').value = data.config.LOG_ENABLED || 'true';
      // the log level field is hidden in the markup - skip it if absent
      const logLevelEl = document.getElementById('settingLogLevel');
      if (logLevelEl) logLevelEl.value = data.config.LOG_LEVEL || 'info';
      document.getElementById('settingLogSize').value = data.config.MAX_LOG_SIZE || 102400;
    }
  } catch (e) {
    console.error('Load settings error:', e);
  }
}

// ========== LOGS ==========

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
      container.innerHTML = '<div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3H4.99c-1.11 0-1.98.9-1.98 2L3 19c0 1.1.88 2 1.99 2H19c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 12h-4c0 1.66-1.35 3-3 3s-3-1.34-3-3H4.99V5H19v10z" fill="currentColor"/></svg>Log is empty</div>';
    }
  } catch (e) {
    console.error('Logs error:', e);
  }
}

// Automatically refresh the log while the web interface is open.
setInterval(refreshLogs, 2000);

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

async function clearLogs() {
  if (!confirm('Clear the log file?')) return;
  try {
    await apiFetch('/logs?action=clear');
    showToast('Log cleared');
    refreshLogs();
  } catch (e) {
    showToast('Error: ' + e.message, 'error');
  }
}

// ========== ROMS (AUTO-SAVE) ==========

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
                badge.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Selected';
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
            showToast(res.message, 'success');  // ← ADD THIS LINE
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
        if (badge) { badge.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Selected'; badge.className = 'badge selected'; }
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
        config.ROMS_SYNC_MEDIA === 'true' ? 'ON' : 'OFF';
      showToast(res.message, 'success');
      refreshStatus();
    } else {
      showToast((res.error || 'Error'), 'error');
    }
  } catch (e) {
    showToast('Error: ' + e.message, 'error');
  }
}

// ========== SYSTEMS ==========

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
            ${isCloudOnly ? '<span class="cloud-badge"><svg width="12" height="8" viewBox="0 0 1280 822" style="vertical-align:-1px;margin-right:2px"><g transform="translate(0,822) scale(0.1,-0.1)" fill="currentColor"><path d="M7121 8205 c-484 -56 -926 -221 -1315 -494 -238 -166 -476 -397 -637 -618 -23 -32 -44 -60 -45 -62 -2 -2 -40 8 -84 23 -117 38 -260 73 -385 92 -150 23 -442 23 -590 0 -611 -94 -1127 -423 -1468 -934 -235 -353 -362 -809 -344 -1229 l6 -132 -32 -5 c-18 -3 -72 -10 -122 -16 -413 -50 -861 -242 -1201 -515 -434 -349 -738 -846 -852 -1395 -38 -183 -47 -272 -46 -495 0 -243 14 -368 63 -571 221 -899 936 -1599 1835 -1794 268 -58 -2 -55 4336 -55 3806 0 4011 1 4125 18 649 97 1197 373 1635 824 142 145 217 237 324 396 233 346 381 728 448 1162 18 116 22 183 22 395 0 282 -16 420 -74 657 -180 738 -643 1363 -1298 1752 -333 198 -715 326 -1104 371 -117 14 -118 14 -118 89 0 95 -59 403 -107 556 -75 243 -205 524 -331 715 -452 687 -1140 1129 -1947 1250 -185 28 -520 35 -694 15z"/></g></svg>cloud only</span>' : ''}
          </div>
          <span class="badge ${isSelected ? 'selected' : ''}">${isSelected ? '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Selected' : '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg>'}</span>
        </div>`;
      }).join('');
      if (data.cloud_error) {
        romsContainer.insertAdjacentHTML('afterbegin', '<div class="cloud-note" style="grid-column:1/-1;font-size:12px;color:var(--text-secondary);padding:4px 2px 8px">⚠️ The cloud did not respond: systems that exist only in the cloud are not shown right now. Open the tab again later.</div>');
      }
    } else {
      romsContainer.innerHTML = '<div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3H4.99c-1.11 0-1.98.9-1.98 2L3 19c0 1.1.88 2 1.99 2H19c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 12h-4c0 1.66-1.35 3-3 3s-3-1.34-3-3H4.99V5H19v10z" fill="currentColor"/></svg>No systems with ROMs</div>';
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
            ${isCloudOnly ? '<span class="cloud-badge"><svg width="12" height="8" viewBox="0 0 1280 822" style="vertical-align:-1px;margin-right:2px"><g transform="translate(0,822) scale(0.1,-0.1)" fill="currentColor"><path d="M7121 8205 c-484 -56 -926 -221 -1315 -494 -238 -166 -476 -397 -637 -618 -23 -32 -44 -60 -45 -62 -2 -2 -40 8 -84 23 -117 38 -260 73 -385 92 -150 23 -442 23 -590 0 -611 -94 -1127 -423 -1468 -934 -235 -353 -362 -809 -344 -1229 l6 -132 -32 -5 c-18 -3 -72 -10 -122 -16 -413 -50 -861 -242 -1201 -515 -434 -349 -738 -846 -852 -1395 -38 -183 -47 -272 -46 -495 0 -243 14 -368 63 -571 221 -899 936 -1599 1835 -1794 268 -58 -2 -55 4336 -55 3806 0 4011 1 4125 18 649 97 1197 373 1635 824 142 145 217 237 324 396 233 346 381 728 448 1162 18 116 22 183 22 395 0 282 -16 420 -74 657 -180 738 -643 1363 -1298 1752 -333 198 -715 326 -1104 371 -117 14 -118 14 -118 89 0 95 -59 403 -107 556 -75 243 -205 524 -331 715 -452 687 -1140 1129 -1947 1250 -185 28 -520 35 -694 15z"/></g></svg>cloud only</span>' : ''}
          </div>
          <span class="badge ${isExcluded ? 'excluded' : ''}">${isExcluded ? '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="currentColor"/></svg> Excl.' : '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> Sync.'}</span>
        </div>`;
      }).join('');
    } else {
      excludeContainer.innerHTML = '<div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3H4.99c-1.11 0-1.98.9-1.98 2L3 19c0 1.1.88 2 1.99 2H19c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 12h-4c0 1.66-1.35 3-3 3s-3-1.34-3-3H4.99V5H19v10z" fill="currentColor"/></svg>No systems with ROMs</div>';
    }
    
    const config = await apiFetch('/config');
    document.getElementById('mediaStatus').textContent = config.ROMS_SYNC_MEDIA === 'true' ? 'ON' : 'OFF';
  } catch (e) {
    console.error('Systems error:', e);
  }
}

// ========== EXCLUSIONS ==========

async function excludeAction(action, system) {
  if (action === 'clear') {
    if (!confirm('Remove all exclusions?')) return;
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
      showToast((res.error || 'Error'), 'error');
    }
  } catch (e) {
    showToast('Error: ' + e.message, 'error');
  }
}

// ========== SETTINGS (MANUAL SAVE ONLY) ==========

function setIntervalQuick(seconds) {
  document.getElementById('settingInterval').value = seconds;
}

async function saveSettings() {
  const config = {
    SYNC_INTERVAL: parseInt(document.getElementById('settingInterval').value) || 0,
    MAX_RETRIES: parseInt(document.getElementById('settingRetries').value) || 3,
    CONFLICT_KEEP_DAYS: parseInt(document.getElementById('settingKeepDays').value) || 0,
    LOG_ENABLED: document.getElementById('settingLogEnabled').value,
    // LOG_LEVEL: document.getElementById('settingLogLevel').value,  // ← COMMENT OUT OR REMOVE
    MAX_LOG_SIZE: parseInt(document.getElementById('settingLogSize').value) || 102400
  };
  
  try {
    const res = await apiFetch('/config', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(config)
    });
    if (res.success) {
      showToast('Settings saved', 'success');
      await loadSettings();
    } else {
      showToast((res.error || 'Error'), 'error');
    }
  } catch (e) {
    showToast('Error: ' + e.message, 'error');
  }
}

// ========== STATISTICS ==========

async function refreshStats() {
  try {
    const data = await apiFetch('/stats');
    if (data) {
      document.getElementById('statSyncUnchanged').textContent = data.sync?.unchanged || 0;
      document.getElementById('statSyncChanged').textContent = data.sync?.changed || 0;
      document.getElementById('statSyncError').textContent = data.sync?.error || 0;
      document.getElementById('statRomsTotal').textContent = data.roms?.total || 0;
      document.getElementById('statRomsOk').textContent = data.roms?.ok || 0;
      document.getElementById('statRomsError').textContent = data.roms?.error || 0;
    }
  } catch (e) {
    console.error('Stats error:', e);
  }
}

// ========== STARTUP ==========

loadTheme();
loadSettings();        // load settings once on startup
refreshStatus();
refreshLogs();
refreshStats();
loadSystems();         // LOAD SYSTEMS ON STARTUP

// Auto-refresh (settings are NOT updated)
// ========== DOWNLOAD FROM A PUBLIC LINK ==========
const LINK_T = {"enterUrl": "Paste a link first", "loading": "Reading the file list… big folders can take a minute.", "needPw": "The link is password-protected: enter the password and press Open.", "empty": "There are no files at this link.", "files": "files", "nothingSel": "Tick the files or folders to download", "selected": "Selected: {n}", "free": "free on the card: {free}", "noSpace": "not enough space", "contents": "The contents of “{name}” will be placed into {dest}", "items": "The selected items will be placed into {dest}", "chooseDest": "— choose a system —", "needDest": "Choose where to put the files", "phase": "Downloading from link", "done": "Download from link complete", "failed": "Download from link failed", "unavailable": "Link download is not available on this device (python3 or link_download.py missing).", "selectAll": "Select all", "root": "root", "nfiles": "files: {n}", "grpDeviceFiles": "Systems with games (ROM files)", "grpDeviceOther": "Systems without games", "grpCloudFiles": "Systems in the cloud", "grpCloudOther": "Add a new system to the cloud", "freeCloud": "free in the cloud: {free}", "cloudLabel": "cloud: GameROMs/{sys}", "cloudNote": "Then put them on the device: ROMs → select the system → Download ROMs.", "cloudUnavailable": "The cloud is not available: Save Sync is not set up or rclone does not start.", "loadingDests": "loading…", "zipMeta": "archive · click to open", "zipReading": "Reading archive “{name}”…", "zipContents": "Archive “{name}” will be unpacked into {dest}", "zipItems": "The selected files will be unpacked from the archive into {dest}", "zipAsIs": "Archives are downloaded as is, not unpacked. Cartridge consoles usually run .zip/.7z themselves. Need single games? Open the zip or turn on “Unpack archives”.", "unpackLabel": "Unpack archives after download ({kinds})", "arcMeta": "{kind} archive", "unpackYes": "{kinds}: will be unpacked into the system folder, the archives are deleted", "unpackCannot": "{kinds}: nothing on this device can unpack them — downloaded as is", "unpackCloud": "For the cloud: files from .zip are taken straight from the archive; .7z/.rar are first downloaded to the card for a moment, unpacked and uploaded — this needs about 3× the archive size free on the card."};
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
const OP_T = {"cancelling": "Cancelling…", "cancelled": "Operation cancelled"};

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
        showToast(r.error || 'Error', 'error');
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
setInterval(refreshLogs, 8000);
setInterval(refreshStats, 10000);
</script>
</body>
</html>'''

class QuietHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    # Multi-threaded server: a slow cloud check in /api/status
    # does not block other requests (page load, logs, progress).
    daemon_threads = True

    def handle_error(self, request, client_address):
        # The client (phone/browser) dropped the connection mid-request -
        # normal with weak Wi-Fi or a closed tab, not a server error.
        # We don't clutter the console with a traceback in this case, but
        # we keep the output for genuinely unexpected errors.
        # IMPORTANT: handle_error is a method of the SERVER (socketserver.BaseServer),
        # not of the request handler, so it needs to be overridden here,
        # not in the Handler class.
        exc_type = sys.exc_info()[0]
        if exc_type in (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            return
        super().handle_error(request, client_address)

if __name__ == "__main__":
    ip = "0.0.0.0"
    port = 8080
    
    # Get IP the same way as in diagnostics
    try:
        result = subprocess.run(['ip', '-4', 'addr', 'show'], capture_output=True, text=True)
        import re
        ips = re.findall(r'inet\s+(\d+\.\d+\.\d+\.\d+)', result.stdout)
        ip_addr = next((ip for ip in ips if not ip.startswith('127.')), 'localhost')
    except:
        ip_addr = 'localhost'
    
    print(f"\n✅ Save Sync Web UI v1.4.5 started")
    print(f"🌐 Open: http://{ip_addr}:{port}")
    print(f"⏹️  Ctrl+C to stop\n")
    
    server = QuietHTTPServer((ip, port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n⏹️  Server stopped")
EOF

    # Substitute the current system's real paths for the placeholders.
    # Without this, the web interface would only work on Batocera/KNULLI.
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

    # Start the server
    cd "$WEB_DIR" || { echo "❌ Could not change to $WEB_DIR"; return 1; }
    python3 server.py &
    WEB_PID=$!
    echo $WEB_PID > /tmp/save_sync_web.pid
    
    # Wait for completion
    wait $WEB_PID
    
    # Cleanup
    rm -f /tmp/save_sync_web.pid
    rm -rf "$WEB_DIR"
    echo ""
    echo "✅ Web server stopped"
}

# === COMMAND HANDLING ===
if [ "$1" = "--web" ] || [ "$1" = "--webui" ]; then
    start_web
    exit 0
fi
    
############################################
# Diagnostics mode
############################################

if [ "$1" = "--info" ]; then
    # Load the config
    load_config
    
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " Save Sync Diagnostics v1.4.5"
    echo " System: $SYSTEM"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    ERRORS=0
    WARNINGS=0

    # Count string length in real characters, not bytes - on
    # systems with a C/POSIX locale (often Recalbox/embedded) plain
    # ${#label} counts BYTES, not characters, and Cyrillic (2 bytes per
    # character in UTF-8) breaks column alignment.
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
    # 1. DEVICE AND SYSTEM
    # ============================================
    echo "── DEVICE AND SYSTEM ──"
    print_2col "Device" "${DEVICE_NAME:-unknown}"
    print_2col "Processor" "${DEVICE_CPU:-unknown}"
    print_2col "Architecture" "${DEVICE_ARCH:-unknown}"
    print_2col "Firmware" "$SYSTEM (${CFW_VERSION:-unknown})"
    print_2col "Kernel" "$(uname -r)"
    print_2col "CPU cores" "${CPU_CORES:-unknown}"
    print_2col "CPU frequency" "${CPU_FREQ:-unknown}"
    print_2col "Temperature" "${DEVICE_TEMP:-unknown}"
    print_2col "Available memory" "${MEM_INFO:-unknown}"
    echo ""

    # ============================================
    # 2. CLOUD AND SYNC
    # ============================================
    echo "── CLOUD AND SYNC ──"
    
    # Cloud status
    if [ -f "$RCLONE_PATH" ] && [ -f "$RCLONE_CONF" ]; then
        if "$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_NAME:" --contimeout 5s >/dev/null 2>&1; then
            CLOUD_STATUS="✅ available"
        else
            CLOUD_STATUS="❌ not connected"
            ERRORS=$((ERRORS+1))
        fi
    else
        CLOUD_STATUS="❌ not configured"
        ERRORS=$((ERRORS+1))
    fi
    print_2col "Status" "$CLOUD_STATUS"
    
    # Cloud usage
    CLOUD_USED=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "used" | awk '{print $2, $3}')
    CLOUD_TOTAL=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "total" | awk '{print $2, $3}')
    CLOUD_FREE=$("$RCLONE_PATH" --config "$RCLONE_CONF" about "$REMOTE_NAME:" 2>/dev/null | grep -i "free" | awk '{print $2, $3}')
    print_2col "Used" "${CLOUD_USED:-unknown}"
    print_2col "Total" "${CLOUD_TOTAL:-unknown}"
    print_2col "Free" "${CLOUD_FREE:-unknown}"
    
    # Last sync
    if [ -f "$STATUS_FILE" ]; then
        read -r STATUS STATUS_TIME < "$STATUS_FILE" 2>/dev/null
        TIME_STR=$(date -d @$STATUS_TIME "+%d.%m.%Y %H:%M" 2>/dev/null || echo "unknown")
        if [ "$STATUS" = "OK" ]; then
            LAST_SYNC_STATUS="✅ successful ($TIME_STR)"
        elif [ "$STATUS" = "ERROR" ]; then
            LAST_SYNC_STATUS="❌ error ($TIME_STR)"
            ERRORS=$((ERRORS+1))
        else
            LAST_SYNC_STATUS="unknown"
        fi
    else
        LAST_SYNC_STATUS="⏳ not run yet"
    fi
    print_2col "Updated" "$LAST_SYNC_STATUS"
    
    # Sync statistics
    sync_stats_counts
    print_2col "Statistics" "$SYNC_NOCHG syncs ($SYNC_CHG OK, $SYNC_ERR ERR)"
    if [ "$SYNC_ERR" -gt 0 ]; then
        WARNINGS=$((WARNINGS + SYNC_ERR))
    fi
    echo ""

    # ============================================
    # 3. NETWORK
    # ============================================
    echo "── NETWORK ──"
    
    # IP address
    IP_ADDR=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
    print_2col "IP address" "${IP_ADDR:-unknown}"
    
    # WiFi
    SSID=$(iwconfig 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$SSID" ] && print_2col "WiFi" "$SSID"
    
    # Internet: TCP connection time, not ping - some networks block ping
    if CONNECT_TIME=$(curl -s -o /dev/null -m 5 -w '%{time_connect}' http://1.1.1.1 2>/dev/null); then
        PING_TIME=$(awk -v t="$CONNECT_TIME" 'BEGIN{printf "%d", t*1000}')
        print_2col "Internet" "✅ available (${PING_TIME}ms)"
    else
        print_2col "Internet" "❌ unavailable"
        ERRORS=$((ERRORS+1))
    fi
    echo ""

    # ============================================
    # 4. SOFTWARE
    # ============================================
    echo "── SOFTWARE ──"
    
    # Rclone
    if [ -f "$RCLONE_PATH" ]; then
        VER=$("$RCLONE_PATH" version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
        print_2col "Rclone" "✅ found (v$VER)"
    else
        print_2col "Rclone" "❌ not found"
        ERRORS=$((ERRORS+1))
    fi
    
    # Rclone config
    if [ -f "$RCLONE_CONF" ]; then
        print_2col "Rclone config" "✅ found"
    else
        print_2col "Rclone config" "❌ not found"
        ERRORS=$((ERRORS+1))
    fi
    
    # Scripts
    if [ "$SYSTEM" = "Recalbox" ]; then
        HOOK_SCRIPT_PATH="/recalbox/share/userscripts/save-sync[endgame].sh"
    else
        HOOK_SCRIPT_PATH="$SCRIPT_DIR/save-sync.sh"
    fi
    for SCRIPT in "$DOWNLOAD_SCRIPT" "$UPLOAD_SCRIPT" "$DOWNLOAD_ROMS" "$UPLOAD_ROMS" "$HOOK_SCRIPT_PATH"; do
        SCRIPT_NAME=$(basename "$SCRIPT")
        if [ -f "$SCRIPT" ]; then
            if [ -x "$SCRIPT" ]; then
                print_2col "$SCRIPT_NAME" "✅ found, permissions OK"
            else
                # Even without the +x bit the script will run fine - all internal
                # calls go through "bash script.sh", not directly (important for
                # noexec partitions, e.g. /recalbox/share on Recalbox)
                print_2col "$SCRIPT_NAME" "✅ found (runs via bash)"
            fi
            else
        print_2col "$SCRIPT_NAME" "❌ not found"
        ERRORS=$((ERRORS+1))
    fi
done

# Public-link downloader (Python, started via python3)
if [ -f "$LINK_SCRIPT" ]; then
    print_2col "$(basename "$LINK_SCRIPT")" "✅ found"
else
    print_2col "$(basename "$LINK_SCRIPT")" "❌ not found"
    ERRORS=$((ERRORS+1))
fi

# Two-way save sync (Python)
if [ -f "$ENGINE_SCRIPT" ]; then
    print_2col "$(basename "$ENGINE_SCRIPT")" "✅ found"
else
    print_2col "$(basename "$ENGINE_SCRIPT")" "❌ not found"
    ERRORS=$((ERRORS+1))
fi
if command -v python3 >/dev/null 2>&1; then
    print_2col "python3" "✅ found"
else
    print_2col "python3" "❌ not found - saves are not synced"
    ERRORS=$((ERRORS+1))
fi

# Save autoload
AUTOLOAD_FOUND=false
if [ -f "$BASE/custom.sh" ]; then
    if grep -q "download_sync.sh" "$BASE/custom.sh" 2>/dev/null || grep -q "download_saves.sh" "$BASE/custom.sh" 2>/dev/null; then
        print_2col "Autostart" "✅ configured (custom.sh)"
        AUTOLOAD_FOUND=true
    fi
fi
if [ -f "$BASE/services/custom_service" ]; then
    if grep -q "download_sync.sh" "$BASE/services/custom_service" 2>/dev/null || grep -q "download_saves.sh" "$BASE/services/custom_service" 2>/dev/null; then
        if [ "$AUTOLOAD_FOUND" = false ]; then
            print_2col "Autostart" "✅ configured (custom_service)"
            AUTOLOAD_FOUND=true
        fi
    fi
fi
if [ "$AUTOLOAD_FOUND" = false ]; then
    print_2col "Autostart" "❌ not found"
    ERRORS=$((ERRORS+1))
fi

# Web interface autoload
WEB_AUTOLOAD=false
if [ -f "$BASE/custom.sh" ]; then
    if grep -q "install_sync.sh --web" "$BASE/custom.sh" 2>/dev/null; then
        print_2col "Autostart (web)" "✅ configured (custom.sh)"
        WEB_AUTOLOAD=true
    fi
fi
if [ -f "$BASE/services/custom_service" ]; then
    if grep -q "install_sync.sh --web" "$BASE/services/custom_service" 2>/dev/null; then
        if [ "$WEB_AUTOLOAD" = false ]; then
            print_2col "Autostart (web)" "✅ configured (custom_service)"
            WEB_AUTOLOAD=true
        fi
    fi
fi
if [ "$WEB_AUTOLOAD" = false ]; then
    print_2col "Autostart (web)" "❌ not configured"
    # This isn't an error, just information
fi
echo ""

    # ============================================
    # 5. CONFIGURATION AND LOGS
    # ============================================
    echo "── CONFIGURATION AND LOGS ──"
    
    # Config
    if [ -f "$CONFIG_FILE" ]; then
        print_2col "Main config" "✅ found"
        print_2col "Interval" "$SYNC_INTERVAL sec"
        print_2col "Retries" "$MAX_RETRIES"
        print_2col "Conflict copies" "$(keep_days_label)"
        print_2col "Exclusions" "${EXCLUDED_SYSTEMS:-none}"
    else
        print_2col "Main config" "❌ not found"
        ERRORS=$((ERRORS+1))
    fi
    
    # Log
    if [ -f "$LOG_FILE" ]; then
        LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        print_2col "Log" "✅ found ($LINES entries, ${LOG_SIZE} bytes)"
    else
        print_2col "Log" "ℹ️ not created"
    fi
    
    # ROM filter
    if [ -n "$ROMS_SYNC_DIRS" ] && [ -f "$ROMS_FILTER_FILE" ]; then
        print_2col "ROM filter" "✅ configured"
    elif [ -n "$ROMS_SYNC_DIRS" ] && [ ! -f "$ROMS_FILTER_FILE" ]; then
        print_2col "ROM filter" "⚠️ not created (recreate it)"
        WARNINGS=$((WARNINGS+1))
    else
        print_2col "ROM filter" "ℹ️ no systems selected"
    fi
    
    # Media copying
    if [ "$ROMS_SYNC_MEDIA" = "true" ]; then
        print_2col "Media copying" "✅ enabled"
    else
        print_2col "Media copying" "❌ disabled"
    fi
    echo ""

    # ============================================
    # 6. RECENT LOG ENTRIES
    # ============================================
    echo "── RECENT LOG ENTRIES ──"
    if [ -f "$LOG_FILE" ]; then
        TOTAL_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        echo "  Total entries: $TOTAL_LINES"
        echo "──────────────────────────────────────────────────────────"
        tail -10 "$LOG_FILE" 2>/dev/null | while read line; do
            echo "  $line"
        done
        echo "──────────────────────────────────────────────────────────"
        echo "  📄 Full log: $LOG_FILE"
    else
        echo "  ❌ Log file not found"
    fi
    echo ""

    # ============================================
    # 7. SUMMARY
    # ============================================
    echo "══════════════════════════════════════════════════════════"
    echo " SUMMARY:"
    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo "✅ Everything is working correctly."
    elif [ $ERRORS -eq 0 ] && [ $WARNINGS -gt 0 ]; then
        echo "⚠️ Warnings found: $WARNINGS"
        echo "   The script is working, but a few things need attention."
    else
        echo "❌ Errors found: $ERRORS, warnings: $WARNINGS"
        echo "   Fixing the errors is recommended for correct operation."
    fi
    echo "══════════════════════════════════════════════════════════"
    exit 0
fi

############################################
# Control panel mode
############################################

if [ "$1" = "--config" ]; then
    show_control_panel
    exit 0
fi

############################################
# Check: already installed?
############################################

if [ -f "$RCLONE_CONF" ] && { [ -f "$DOWNLOAD_SCRIPT" ] || [ -f "$BASE/download_saves.sh" ]; } && { [ -f "$UPLOAD_SCRIPT" ] || [ -f "$BASE/upload_saves.sh" ]; }; then
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " Save Sync is already installed ($SYSTEM)"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo " 1 - Update to v1.4.5"
    echo " 2 - Reinstall from scratch"
    echo " 3 - Exit"
    echo ""
    read -p "Choose an option (1-3): " REINSTALL_CHOICE
    case "$REINSTALL_CHOICE" in
    1)
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📦 Updating to v1.4.5"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        
        echo "🗑️ Removing old files (v1.2)..."
        
        if [ -f "$BASE/download_saves.sh" ]; then
            rm -f "$BASE/download_saves.sh"
            echo "✅ Removed download_saves.sh"
        fi
        if [ -f "$BASE/upload_saves.sh" ]; then
            rm -f "$BASE/upload_saves.sh"
            echo "✅ Removed upload_saves.sh"
        fi
        
        if [ ! -f "$CONFIG_FILE" ]; then
            create_default_config
            echo "✅ Created sync.conf"
        else
            echo "✅ Config already exists, settings preserved"
        fi
        
        create_download_script
        echo "✅ Updated download_sync.sh"
        
        create_upload_script
        echo "✅ Updated upload_sync.sh"
        
        create_roms_scripts
        echo "✅ Updated ROM scripts"
        
        create_hook_script
        echo "✅ Updated hook"
        
        # ============================================
        # AUTOLOAD SETUP (UPDATE)
        # ============================================
        
        # Determine which file to use for autoload
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
        
        # Update the reference to download_sync.sh if there was an old one
        if [ -f "$AUTOLOAD_FILE" ]; then
            if grep -q "download_saves.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
                sed -i "s|download_saves.sh|download_sync.sh|g" "$AUTOLOAD_FILE"
                echo "✅ Entry in $(basename $AUTOLOAD_FILE) updated"
            fi
        fi
        
        # Create the file if it doesn't exist
        if [ ! -f "$AUTOLOAD_FILE" ]; then
            echo '#!/bin/bash' > "$AUTOLOAD_FILE"
            chmod +x "$AUTOLOAD_FILE"
            echo "✅ Created $(basename $AUTOLOAD_FILE)"
        fi
        
        # Add download_sync.sh if missing (path taken from $DOWNLOAD_SCRIPT,
        # so it works correctly on Recalbox, not just Batocera/KNULLI)
        if ! grep -q "download_sync.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
            sed -i "/^#!/a bash $DOWNLOAD_SCRIPT &" "$AUTOLOAD_FILE"
            echo "✅ Save download added to $(basename $AUTOLOAD_FILE)"
        fi
        
        # Add the web interface if missing
        if ! grep -q "install_sync.sh --web" "$AUTOLOAD_FILE" 2>/dev/null; then
            cat >> "$AUTOLOAD_FILE" << EOF

# Start the Save Sync web interface
(
    for i in \$(seq 1 30); do
        LOCAL_IP=\$(ip -4 addr show 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
        if [ -n "\$LOCAL_IP" ]; then
            break
        fi
        sleep 2
    done
    bash $BASE/install_sync.sh --web &
) &
EOF
            echo "✅ Web interface added to $(basename $AUTOLOAD_FILE)"
        fi
        
        echo ""
        echo "✅ Update to v1.4.5 complete!"

        log_msg "Update to v1.4.5 complete"

        restart_web_after_update

        echo ""
        echo "What's new:"
        echo "  • Web interface"
        echo "  • Control panel"
        echo "  • System selection for sync"
        echo "  • Sync interval settings"
        echo "  • Logging"
        echo "  • Copy and download ROMs"
        echo ""
        echo "🌐 WEB INTERFACE: http://$IP_ADDR:8080"
        echo "   (starts automatically when the system boots)"
        echo ""
        echo "📋 Control panel: ${RUN_PREFIX}$0 --config"
        echo "🔍 Diagnostics: ${RUN_PREFIX}$0 --info"
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo " 1 - Open control panel"
        echo " 2 - Reboot system"
        echo " 3 - Exit"
        echo ""
        read -p "Choose (1-3): " FINAL_CHOICE
        
        case "$FINAL_CHOICE" in
            1)
                echo ""
                echo "🔄 Opening control panel..."
                sleep 1
                exec bash "$0" --config
                ;;
            2)
                echo "🔄 Rebooting system..."
                reboot
                ;;
            3)
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo "Invalid choice. Exiting..."
                exit 1
                ;;
        esac
        ;;
    2)
        # Reinstall - remove and install again
        echo "🗑️ Removing old files..."
        rm -f "$DOWNLOAD_SCRIPT" "$UPLOAD_SCRIPT" "$DOWNLOAD_ROMS" "$UPLOAD_ROMS" "$LINK_SCRIPT" 2>/dev/null
        rm -f "$BASE/download_saves.sh" "$BASE/upload_saves.sh" 2>/dev/null
        rm -f "$SCRIPT_DIR/save-sync.sh" 2>/dev/null
        rm -f "/recalbox/share/userscripts/save-sync[endgame].sh" 2>/dev/null
        echo "✅ Old files removed"
        echo ""
        echo "Starting installation..."
        # Proceed to installation
        ;;
    3)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
    esac
fi

############################################
# Regular installation
############################################

echo ""
echo "══════════════════════════════════════════════════════════"
echo " Save Sync v1.4.5 - Installation"
echo " $SYSTEM"
echo "══════════════════════════════════════════════════════════"
echo ""

mkdir -p "$BIN_DIR" || { echo "❌ Failed to create $BIN_DIR"; exit 1; }
mkdir -p "$CONFIG_DIR" || { echo "❌ Failed to create $CONFIG_DIR"; exit 1; }
mkdir -p "$SCRIPT_DIR" || { echo "❌ Failed to create $SCRIPT_DIR"; exit 1; }
mkdir -p "$LOG_DIR" || { echo "❌ Failed to create $LOG_DIR"; exit 1; }

if [ ! -f "$CONFIG_FILE" ]; then
    create_default_config
    echo "✅ Created sync.conf"
fi

if [ -f "$RCLONE_BIN" ]; then
    ensure_rclone_executable
    CURRENT_VER=$("$RCLONE_PATH" version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
    echo "✅ rclone found (v$CURRENT_VER)"
    echo "Checking for updates..."
    if download_rclone; then
        NEW_VER=$("$RCLONE_PATH" version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
        if [ "$CURRENT_VER" = "$NEW_VER" ]; then
            echo "✅ rclone is up to date (v$CURRENT_VER)"
        else
            echo "✅ rclone updated to v$NEW_VER"
        fi
    fi
else
    echo "📥 rclone not found. Downloading..."
    if download_rclone; then
        NEW_VER=$("$RCLONE_PATH" version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
        echo "✅ rclone installed (v$NEW_VER)"
    else
        exit 1
    fi
fi

echo ""
echo "Choose a cloud service"
echo ""
echo " 1 - Yandex Disk"
echo " 2 - Mail.ru Cloud"
echo " 3 - pCloud"
echo " 4 - Koofr"
echo " 5 - Nextcloud / OwnCloud / other WebDAV server"
echo " 6 - Fastmail Files"
echo " 7 - Mega"
echo ""

read -p "Enter number (1-7): " CHOICE

BACKEND_TYPE="webdav"

case "$CHOICE" in
1) URL="https://webdav.yandex.ru"; VENDOR="yandex" ;;
2) URL="https://webdav.cloud.mail.ru"; VENDOR="other" ;;
3) URL="https://webdav.pcloud.com"; VENDOR="other" ;;
4) URL="https://app.koofr.net/dav/Koofr"; VENDOR="other" ;;
5)
    echo ""
    read -p "Enter your WebDAV server URL: " URL
    echo ""
    echo "Which one are you using?"
    echo " 1 - Nextcloud"
    echo " 2 - ownCloud"
    echo " 3 - Other WebDAV server"
    read -p "Enter number (1-3): " NC_CHOICE
    case "$NC_CHOICE" in
        2) VENDOR="owncloud" ;;
        3) VENDOR="other" ;;
        *) VENDOR="nextcloud" ;;
    esac
    ;;
6)
    echo ""
    echo "For Fastmail: username is your Fastmail email, password is"
    echo "a dedicated app password with Files (WebDAV) access,"
    echo "which you can create in your Fastmail account settings."
    URL="https://webdav.fastmail.com/"
    VENDOR="fastmail"
    ;;
7)
    echo ""
    echo "For Mega: username is your account email, password is your"
    echo "regular account password."
    echo ""
    echo "⚠️  If your Mega account is brand new, log into it at least"
    echo "    once through a regular browser before this step (Mega"
    echo "    needs to generate encryption keys on its side, or the"
    echo "    connection won't work)."
    BACKEND_TYPE="mega"
    ;;
*) echo "❌ Invalid choice."; exit 1 ;;
esac

echo ""
echo "Enter username:"
IFS= read -r YUSER
echo ""
echo "Enter password (or app password):"
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

echo "Checking connection..."
if "$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_NAME:" >/dev/null 2>&1; then
    echo "✅ Connection successful."
else
    echo "❌ Connection failed."
    exit 1
fi

echo ""
echo "Checking GameSaves folder..."
"$RCLONE_PATH" --config "$RCLONE_CONF" mkdir "$REMOTE" >/dev/null 2>&1
echo "✅ Done."
echo ""

echo "📝 Creating scripts..."
create_download_script
echo "✅ Created download_sync.sh"

create_upload_script
echo "✅ Created upload_sync.sh"

create_roms_scripts
echo "✅ Created ROM scripts"

create_hook_script
echo "✅ Created save hook"

# ============================================
# AUTOLOAD SETUP (NEW INSTALL)
# ============================================

# Determine which file to use for autoload
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

# Create the file if it doesn't exist
if [ ! -f "$AUTOLOAD_FILE" ]; then
    echo '#!/bin/bash' > "$AUTOLOAD_FILE"
    chmod +x "$AUTOLOAD_FILE"
    echo "✅ Created $(basename $AUTOLOAD_FILE)"
fi

# Add download_sync.sh if missing (path taken from $DOWNLOAD_SCRIPT,
# so it works correctly on Recalbox, not just Batocera/KNULLI)
if ! grep -q "download_sync.sh" "$AUTOLOAD_FILE" 2>/dev/null && ! grep -q "download_saves.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
    sed -i "/^#!/a bash $DOWNLOAD_SCRIPT &" "$AUTOLOAD_FILE"
    echo "✅ Save download added to $(basename $AUTOLOAD_FILE)"
fi

# Add the web interface if missing
if ! grep -q "install_sync.sh --web" "$AUTOLOAD_FILE" 2>/dev/null; then
    cat >> "$AUTOLOAD_FILE" << EOF

# Start the Save Sync web interface
(
    for i in \$(seq 1 30); do
        LOCAL_IP=\$(ip -4 addr show 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
        if [ -n "\$LOCAL_IP" ]; then
            break
        fi
        sleep 2
    done
    bash $BASE/install_sync.sh --web &
) &
EOF
    echo "✅ Web interface added to $(basename $AUTOLOAD_FILE)"
else
    echo "✅ Web interface already present in $(basename $AUTOLOAD_FILE)"
fi

SYSTEM_VERSION=$(get_system_version)

log_msg "Save Sync v1.4.5 | $SYSTEM ($SYSTEM_VERSION) | rclone v${NEW_VER:-unknown}"
log_msg "Installation complete"

echo ""
echo "══════════════════════════════════════════════════════════"
echo " ✅ INSTALLATION COMPLETE!"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "Configured:"
echo "✓ rclone v${NEW_VER:-unknown}"
echo "✓ $URL"
echo "✓ System: $SYSTEM ($SYSTEM_VERSION)"
echo "✓ Device: ${DEVICE_NAME:-unknown} (${DEVICE_CPU:-unknown})"
echo "✓ Folder $REMOTE_FOLDER"
echo "✓ Auto-retry on failure (up to $MAX_RETRIES attempts)"
echo "✓ Logging to $LOG_FILE"
if [ -f "$CONFIG_FILE" ]; then
    echo "✓ Config created: sync.conf"
fi
echo "✓ Web interface autostart configured"
echo ""
echo "🌐 WEB INTERFACE: http://$IP_ADDR:8080"
echo "   (starts automatically when the system boots)"
echo ""
echo "📋 TO CONFIGURE, RUN:"
echo "  ${RUN_PREFIX}$0 --config"
echo ""
echo "══════════════════════════════════════════════════════════"
echo ""
echo " 1 - Open control panel"
echo " 2 - Reboot system"
echo " 3 - Exit"
echo ""
read -p "Choose (1-3): " FINAL_CHOICE

case "$FINAL_CHOICE" in
    1)
        echo ""
        echo "🔄 Opening control panel..."
        sleep 1
        exec bash "$0" --config
        ;;
    2)
        echo "🔄 Rebooting system..."
        reboot
        ;;
    3)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo "Invalid choice. Exiting..."
        exit 0
        ;;
esac