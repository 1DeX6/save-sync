#!/bin/bash

################################################
# Save Sync Installer v1.4.4
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
# Save Sync v1.4.4 - Main config
# ========================================

# ── SYNC SETTINGS ──
# 0 = always, 300 = 5 min, 900 = 15 min, 3600 = 1 hour
SYNC_INTERVAL="0"

# Number of retries on error
MAX_RETRIES="3"

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
# Save Sync v1.4.4 - Main config
# ========================================

# ── SYNC SETTINGS ──
SYNC_INTERVAL="$SYNC_INTERVAL"
MAX_RETRIES="$MAX_RETRIES"
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

# --- INITIALIZE CLOUD VARIABLES ---
REMOTE_NAME="cloud"
REMOTE_FOLDER="GameSaves"
REMOTE="$REMOTE_NAME:$REMOTE_FOLDER"
REMOTE_ROMS="$REMOTE_NAME:GameROMs"
FIRST_SYNC_MARKER="$REMOTE_FOLDER/.first_sync_done"

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
for CMD in curl unzip ping flock; do
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

# ======== MAIN LOGIC ========
save_status() {
    echo "\$1 \$(date +%s)" > "\$STATUS_FILE"
}

exec 200>"\$LOCK_FILE"
flock -n 200 || { echo "\$(date '+%d.%m %H:%M:%S') Skipped: a previous download is still running" >> "\$LOG_FILE" 2>/dev/null; exit 0; }

# Check interval (ONLY if NOT a forced sync)
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ \$SYNC_INTERVAL -gt 0 ] && [ -f "\$LAST_SYNC_TIME" ]; then
    LAST=\$(cat "\$LAST_SYNC_TIME" 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [ \$((NOW - LAST)) -lt \$SYNC_INTERVAL ]; then
        exit 0
    fi
fi

# Check internet
COUNT=0
until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
    COUNT=\$((COUNT+1))
    if [ \$COUNT -ge 40 ]; then
        echo "\$(date '+%d.%m %H:%M:%S') No network (waited 2 min)" >> "\$LOG_FILE" 2>/dev/null
        save_status "ERROR"
        [ -z "\$1" ] && touch /tmp/save_sync_dirty_session 2>/dev/null
        exit 1
    fi
    sleep 3
done

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

# Check the cloud (with retries - in case of a brief outage)
CLOUD_OK=0
for i in \$(seq 1 3); do
    if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsd "\$REMOTE_NAME:" --contimeout 3m >/dev/null 2>&1; then
        CLOUD_OK=1
        break
    fi
    sleep 5
done
if [ \$CLOUD_OK -eq 0 ]; then
    echo "\$(date '+%d.%m %H:%M:%S') Cloud unavailable" >> "\$LOG_FILE" 2>/dev/null
    save_status "ERROR"
    [ -z "\$1" ] && touch /tmp/save_sync_dirty_session 2>/dev/null
    exit 0
fi

# Check whether there are files in the cloud
FIRST_SYNC_EXISTS=false
if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$FIRST_SYNC_MARKER" 2>/dev/null | grep -q .; then
    FIRST_SYNC_EXISTS=true
fi

CLOUD_HAS_FILES=false
if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$REMOTE" 2>/dev/null | grep -v ".first_sync_done" | grep -q .; then
    CLOUD_HAS_FILES=true
fi

# Build exclusion filters
FILTER_OPTS=()
if [ -n "\$EXCLUDED_SYSTEMS" ]; then
    IFS='|' read -ra EXCLUDED_ARRAY <<< "\$EXCLUDED_SYSTEMS"
    for sys in "\${EXCLUDED_ARRAY[@]}"; do
        sys="\$(echo "\$sys" | xargs)"
        [ -n "\$sys" ] && FILTER_OPTS+=(--exclude "/\$sys/**")
    done
fi

# ======== FIRST DOWNLOAD (if the cloud is empty) ========
if [ "\$FIRST_SYNC_EXISTS" = false ] && [ "\$CLOUD_HAS_FILES" = false ]; then
    progress_start "download" "Downloading saves"
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
        echo "\$(date '+%d.%m %H:%M:%S') First download from cloud: complete" >> "\$LOG_FILE" 2>/dev/null
        progress_finish true "download" "Save download complete"
    else
        save_status "ERROR"
        echo "\$(date '+%d.%m %H:%M:%S') First download error" >> "\$LOG_FILE" 2>/dev/null
        progress_finish false "download" "Save download error"
    fi
    rm -f /tmp/save_exclude_\$\$.tmp 2>/dev/null
    exit 0
fi

# ======== REGULAR DOWNLOAD ========
progress_start "download" "Downloading saves"
# Copy saves from the cloud to the device.
# IMPORTANT: we use "copy", NOT "sync --delete-after" - per the documented
# behavior, files missing from the cloud must NOT be deleted from the device.
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
    
    # Success codes: 0 - all OK, 3 - some files not copied (not critical)
    if [ \$SYNC_EXIT -eq 0 ] || [ \$SYNC_EXIT -eq 3 ]; then
        date +%s > "\$READY_FILE"
        date +%s > "\$LAST_SYNC_TIME"
        save_status "OK"
        rm -f /tmp/save_sync_dirty_session 2>/dev/null
        echo "\$(date '+%d.%m %H:%M:%S') Saves downloaded" >> "\$LOG_FILE" 2>/dev/null
        progress_finish true "download" "Save download complete"
        break
    else
        if [ \$i -eq \$MAX_RETRIES ]; then
            save_status "ERROR"
            echo "\$(date '+%d.%m %H:%M:%S') Save download error (code: \$SYNC_EXIT, attempt \$i)" >> "\$LOG_FILE" 2>/dev/null
            [ -z "\$1" ] && touch /tmp/save_sync_dirty_session 2>/dev/null
            progress_finish false "download" "Save download error"
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

# ======== MAIN LOGIC ========
save_status() {
    echo "\$1 \$(date +%s)" > "\$STATUS_FILE"
}

exec 200>"\$LOCK_FILE"
flock -n 200 || { echo "\$(date '+%d.%m %H:%M:%S') Skipped: a previous upload is still running" >> "\$LOG_FILE" 2>/dev/null; exit 0; }

# If the boot-time download failed - warn
# in the log that this upload is happening without a guarantee that we
# first got the latest version of the saves from the cloud (relevant
# when using multiple devices in rotation).
if [ -f /tmp/save_sync_dirty_session ]; then
    echo "\$(date '+%d.%m %H:%M:%S') ⚠️  Warning: this session started without a fresh download from the cloud - the save being uploaded may overwrite a newer version" >> "\$LOG_FILE" 2>/dev/null
fi

# Check interval (ONLY if NOT a forced sync)
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ \$SYNC_INTERVAL -gt 0 ] && [ -f "\$LAST_SYNC_TIME" ]; then
    LAST=\$(cat "\$LAST_SYNC_TIME" 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [ \$((NOW - LAST)) -lt \$SYNC_INTERVAL ]; then
        echo "\$(date '+%d.%m %H:%M:%S') Upload skipped (interval \$SYNC_INTERVAL sec)" >> "\$LOG_FILE" 2>/dev/null
        exit 0
    fi
fi

# Check internet
COUNT=0
until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
    COUNT=\$((COUNT+1))
    if [ \$COUNT -ge 40 ]; then
        echo "\$(date '+%d.%m %H:%M:%S') No network (waited 2 min)" >> "\$LOG_FILE" 2>/dev/null
        save_status "ERROR"
        exit 1
    fi
    sleep 3
done

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

# Check the cloud (with retries - in case of a brief outage)
CLOUD_OK=0
for i in \$(seq 1 3); do
    if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsd "\$REMOTE_NAME:" --contimeout 1m >/dev/null 2>&1; then
        CLOUD_OK=1
        break
    fi
    sleep 5
done
if [ \$CLOUD_OK -eq 0 ]; then
    echo "\$(date '+%d.%m %H:%M:%S') Cloud unavailable" >> "\$LOG_FILE" 2>/dev/null
    save_status "ERROR"
    exit 0
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
            exit 1
        fi
    fi
fi

# Build exclusion filters
FILTER_OPTS=()
if [ -n "\$EXCLUDED_SYSTEMS" ]; then
    IFS='|' read -ra EXCLUDED_ARRAY <<< "\$EXCLUDED_SYSTEMS"
    for sys in "\${EXCLUDED_ARRAY[@]}"; do
        sys="\$(echo "\$sys" | xargs)"
        [ -n "\$sys" ] && FILTER_OPTS+=(--exclude "/\$sys/**")
    done
fi

# Check for the first-sync marker
FIRST_SYNC_EXISTS=false
if "\$RCLONE_PATH" --config "\$RCLONE_CONF" lsf "\$FIRST_SYNC_MARKER" 2>/dev/null | grep -q .; then
    FIRST_SYNC_EXISTS=true
fi

# ======== FIRST SYNC (copy) ========
if [ "\$FIRST_SYNC_EXISTS" = false ]; then
    progress_start "upload" "Uploading saves"
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
        echo "\$(date '+%d.%m %H:%M:%S') Saves uploaded" >> "\$LOG_FILE" 2>/dev/null
        progress_finish true "upload" "Save upload complete"
    else
        save_status "ERROR"
        echo "\$(date '+%d.%m %H:%M:%S') First upload error (code: \$SYNC_EXIT)" >> "\$LOG_FILE" 2>/dev/null
        progress_finish false "upload" "Save upload error"
    fi
    rm -f /tmp/save_exclude_\$\$.tmp 2>/dev/null
    exit 0
fi

# ======== REGULAR SYNC (sync with deletion) ========
progress_start "upload" "Uploading saves"
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
        echo "\$(date '+%d.%m %H:%M:%S') Saves uploaded" >> "\$LOG_FILE" 2>/dev/null
        progress_finish true "upload" "Save upload complete"
        break
    else
        if [ \$i -eq \$MAX_RETRIES ]; then
            save_status "ERROR"
            echo "\$(date '+%d.%m %H:%M:%S') Save upload error (code: \$SYNC_EXIT, attempt \$i)" >> "\$LOG_FILE" 2>/dev/null
            progress_finish false "upload" "Save upload error"
        else
            echo "\$(date '+%d.%m %H:%M:%S') Retry \$i/\$MAX_RETRIES (code: \$SYNC_EXIT)" >> "\$LOG_FILE" 2>/dev/null
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
    
    while true; do
        SYSTEMS=()
        
        # Recursive search for systems with ROMs
        for dir in "$ROMS_DIR"/*/; do
            [ -d "$dir" ] || continue
            BASENAME=$(basename "$dir")
            
            if find "$dir" -type f ! -name "gamelist.xml" ! -name "_info.txt" ! -name "*.dat" ! -name "*.txt" ! -name "*.log" ! -name "*.cache" ! -path "*/images/*" ! -path "*/media/*" ! -path "*/videos/*" 2>/dev/null | head -1 | grep -q .; then
                SYSTEMS+=("$BASENAME")
            fi
        done
        
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
                    if [ "$excluded" = true ]; then
                        echo "  $idx - $sys ⚠️ ALREADY EXCLUDED"
                    else
                        echo "  $idx - $sys"
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
                    if [ "$excluded" = true ]; then
                        echo "  $idx - $sys ❌ (excluded)"
                    else
                        echo "  $idx - $sys ✅ (syncing)"
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
        echo " 1 - 📂 Select systems to back up"
        echo " 2 - 🖼️ Enable/disable image copying"
        echo " 3 - 📥 Download ROMs from cloud"
        echo " 4 - 📤 Upload ROMs to cloud"
        echo " 0 - Back"
        echo ""
        read -p "Choose (0-4): " roms_choice
        
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
                echo "❌ Invalid choice"
                sleep 1
                ;;
        esac
    done
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
        echo " 📁 Select systems to back up"
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
    TOTAL_SYNC=$(grep -c "Saves downloaded\|Saves uploaded" "$LOG_FILE" 2>/dev/null)
    ERR_SYNC=$(grep -c "error\|unavailable" "$LOG_FILE" 2>/dev/null)
    [ -z "$TOTAL_SYNC" ] && TOTAL_SYNC=0
    [ -z "$ERR_SYNC" ] && ERR_SYNC=0
    OK_SYNC=$((TOTAL_SYNC - ERR_SYNC))
    [ $OK_SYNC -lt 0 ] && OK_SYNC=0
    SYNC_STATS="$TOTAL_SYNC syncs ($OK_SYNC OK, $ERR_SYNC ERR)"
    
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
        echo "           Save Sync - Control Panel v1.4.4"
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
        echo ""
        
        echo " ── INFO ──"
        echo "  8 - 📊 Statistics and logs"
        echo "  9 - 🔍 Full diagnostics"
        echo ""
        
        echo " ── SYSTEM ──"
        echo " 10 - 🗑️ Clear temporary files"
        echo " 11 - 🔄 Reboot device"
        echo ""
        
        echo " ── WEB INTERFACE ──"
        echo "      🌐 http://$IP_ADDR:8080"
        echo " 12 - 🔄 Restart web interface"
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo "  0 - 🚪 Exit"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        read -p "Choose an action (0-12): " choice
        
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
                echo "  • If a file is missing from the cloud, it is NOT deleted from the device"
                echo "  • Only new or changed files are downloaded"
                echo "  • If the cloud is empty — do NOT download, or the"
                echo "    sync will delete all local saves!"
                echo ""
                
                CLOUD_HAS_SAVES=false
                if "$RCLONE_PATH" --config "$RCLONE_CONF" lsf "$REMOTE" 2>/dev/null | grep -v ".first_sync_done" | grep -q .; then
                    CLOUD_HAS_SAVES=true
                fi
                
                if [ "$CLOUD_HAS_SAVES" = false ]; then
                    echo "══════════════════════════════════════════════════════════"
                    echo " ⛔ STOP! There are no saves in the cloud."
                    echo ""
                    echo "If you continue, sync will DELETE all local saves!"
                    echo ""
                    echo "RECOMMENDATION: do an UPLOAD first (option 2)."
                    echo "══════════════════════════════════════════════════════════"
                    echo ""
                    read -p "Continue with download? (y/n): " confirm
                    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                        echo "❌ Cancelled."
                        echo ""
                        pause
                        continue
                    fi
                else
                    echo "══════════════════════════════════════════════════════════"
                    echo ""
                    read -p "Continue with download? (y/n): " confirm
                    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                        echo "❌ Cancelled."
                        echo ""
                        pause
                        continue
                    fi
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
                echo "  • If a file is missing from the device, it IS deleted from the cloud"
                echo "  • Only new or changed files are uploaded"
                echo "  • Deletions are synced between devices"
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
                echo "     (missing files are NOT deleted from the device)"
                echo ""
                echo "  2. Then UPLOADS saves to the cloud"
                echo "     (missing files ARE deleted from the cloud)"
                echo ""
                echo " ⚠️ WARNING: deletions sync both ways!"
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
                bash "$DOWNLOAD_SCRIPT" --verbose
                echo ""
                echo "--- Step 2: Upload to cloud ---"
                bash "$UPLOAD_SCRIPT" --verbose
                echo ""
                echo "✅ Full sync complete!"
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
            11)
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
            12)
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

restart_web_if_running() {
    if [ -f "/tmp/save_sync_web.pid" ] && kill -0 "$(cat /tmp/save_sync_web.pid 2>/dev/null)" 2>/dev/null; then
        WAS_RUNNING=true
    elif pgrep -f "python3.*server.py" >/dev/null 2>&1; then
        WAS_RUNNING=true
    else
        WAS_RUNNING=false
    fi

    if [ "$WAS_RUNNING" = true ]; then
        echo "🔄 Running web interface detected, restarting with the new version..."
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
        echo "✅ Web interface restarted"
    fi
}

start_web() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " 🌐 Save Sync - Web Interface v1.4.4"
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
        if kill -0 "$PID" 2>/dev/null; then
            echo "⚠️ Web interface is already running (PID: $PID)"
            echo "🌐 Open: http://${IP_ADDR}:8080"
            echo ""
            echo "To stop it: kill $PID"
            return 1
        fi
    fi
    
    # Create the web interface directory
    WEB_DIR="/tmp/save_sync_web"
    mkdir -p "$WEB_DIR"
    
    # Create the Python server
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
                f.write("# Save Sync v1.4.4 - Main config\n")
                f.write("# ========================================\n\n")
                f.write("# ---- SYNC SETTINGS ----\n")
                f.write(f'SYNC_INTERVAL="{current.get("SYNC_INTERVAL", 0)}"\n')
                f.write(f'MAX_RETRIES="{current.get("MAX_RETRIES", 3)}"\n')
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
        stats = {"sync": {"total": 0, "ok": 0, "error": 0}, "roms": {"total": 0, "ok": 0, "error": 0}}
        if os.path.exists(LOG_FILE):
            try:
                with open(LOG_FILE, "r") as f:
                    content = f.read()
                    stats["sync"]["total"] = len(re.findall(r"Saves downloaded|Saves uploaded", content))
                    stats["sync"]["ok"] = len(re.findall(r"Saves downloaded", content)) + len(re.findall(r"Saves uploaded", content))
                    stats["sync"]["error"] = len(re.findall(r"error|unavailable", content))
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
        
        # Internet
        try:
            result = subprocess.run(["ping", "-c1", "-W2", "1.1.1.1"], capture_output=True, timeout=3)
            status["internet"] = result.returncode == 0
        except:
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
                    subprocess.Popen(["bash", DOWNLOAD_SCRIPT, "--web-progress"], 
                                   stdout=subprocess.DEVNULL, 
                                   stderr=subprocess.DEVNULL)
                    self.send_json({"success": True, "message": messages[action]})
                else:
                    self.send_json({"success": False, "error": f"Script not found: {DOWNLOAD_SCRIPT}"})
            
            elif action == "upload":
                if os.path.exists(UPLOAD_SCRIPT):
                    subprocess.Popen(["bash", UPLOAD_SCRIPT, "--web-progress"], 
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
                    self.send_json({"success": False, "error": f"Script not found: {DOWNLOAD_ROMS}"})
            
            elif action == "roms_upload":
                if os.path.exists(UPLOAD_ROMS):
                    subprocess.Popen(["bash", UPLOAD_ROMS, "--web-progress"], 
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
    <div class="value" id="syncStats">0 —  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> 0 • <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> 0</div>
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
</div>

    <!-- Info note -->
    <div class="sync-note">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>IMPORTANT:</strong></p>
        <p>• <strong>Download:</strong> This will DOWNLOAD saves from the cloud to the device. If a file is missing from the cloud, it is NOT deleted from the device. Only new or changed files are downloaded. If the cloud is empty — do NOT download, or sync will delete all local saves!</p>
        <p>• <strong>Upload:</strong> This will UPLOAD saves from the device to the cloud. If a file is missing from the device, it IS deleted from the cloud. Only new or changed files are uploaded. Deletions are synced between devices.</p>
        <p>• <strong>Full sync:</strong> This performs a FULL sync. First DOWNLOADS saves from the cloud (missing files are NOT deleted from the device). Then UPLOADS saves to the cloud (missing files ARE deleted from the cloud). WARNING: deletions sync both ways!</p>
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
</div>

    <!-- Info note -->
    <div class="sync-note">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>IMPORTANT:</strong></p>
        <p>• <strong>Download ROMs:</strong> This will DOWNLOAD ROMs from the cloud to the device. Files on the device are NOT deleted. Only new or changed files are downloaded.</p>
        <p>• <strong>Upload ROMs:</strong> This will DELETE from the cloud any ROMs missing on the device. If some ROMs are missing on the device, they will disappear from the cloud with no way to recover them! It is recommended to DOWNLOAD ROMs from the cloud first, or back up the cloud.</p>
    </div>
    
    <div class="section-title" style="margin-top:20px"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M20 6h-8l-2-2H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z" fill="currentColor"/></svg>Select systems to back up</div>
    <div style="margin-bottom:10px;display:flex;gap:10px;flex-wrap:wrap;align-items:center">
        <button class="btn" onclick="selectAllRoms()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg>Select all</button>
        <button class="btn btn-danger" onclick="deselectAllRoms()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>Deselect all</button>
        <button class="btn" onclick="toggleMedia()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z" fill="currentColor"/></svg>Media: <span id="mediaStatus">-</span></button>
        <span style="color:var(--text-secondary);font-size:12px">Click a system to select/deselect it</span>
    </div>
    <div class="system-list" id="romsList"><div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> Loading systems...</div></div>
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
      <div class="stats-item">
        <div class="num" id="statSyncTotal">0</div>
        <div class="label">Total syncs</div>
      </div>
      <div class="stats-item">
        <div class="num ok" id="statSyncOk">0</div>
        <div class="label">Successful</div>
      </div>
      <div class="stats-item">
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
    const barEl = document.getElementById(target === 'roms' ? 'syncProgressBarRoms' : 'syncProgressBarSaves');
    const percentEl = document.getElementById(target === 'roms' ? 'syncProgressPercentRoms' : 'syncProgressPercentSaves');
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

async function runSyncWithProgress(action) {
    setButtonsDisabled(true);

    const names = {
        'download': 'Downloading saves',
        'upload': 'Uploading saves',
        'full': 'Full sync',
        'roms_download': 'Downloading ROMs',
        'roms_upload': 'Uploading ROMs'
    };

    // Determine target once
    const target = (action === 'roms_download' || action === 'roms_upload') ? 'roms' : 'saves';
    showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="currentColor"/></svg> ' + names[action] + ' starting...', target);

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
        const res = await apiFetch('/sync?action=' + action, { method: 'POST' });
        if (!res.success) {
            stopPolling();
            showProgress(true, '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> Error: ' + (res.error || 'Unknown error'), target);
            showToast((res.error || 'Error'), 'error');
            setTimeout(() => { showProgress(false); setButtonsDisabled(false); }, 2500);
            return;
        }

        // Wait a bit for the script to start
        await new Promise(r => setTimeout(r, 500));
        
        await poll();
        polling = setInterval(poll, 1000);
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
    const total = data.stats?.sync?.total || 0;
    const ok = data.stats?.sync?.ok || 0;
    const err = data.stats?.sync?.error || 0;
    document.getElementById('syncStats').innerHTML = total + ' —  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> ' + ok + ' • <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + err;
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
      document.getElementById('settingLogEnabled').value = data.config.LOG_ENABLED || 'true';
      document.getElementById('settingLogLevel').value = data.config.LOG_LEVEL || 'info';
      document.getElementById('settingLogSize').value = data.config.MAX_LOG_SIZE || 102400;
    }
  } catch (e) {
    console.error('Load settings error:', e);
  }
}

// ========== LOGS ==========

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
    } else {
      romsContainer.innerHTML = '<div class="loading"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M19 3H4.99c-1.11 0-1.98.9-1.98 2L3 19c0 1.1.88 2 1.99 2H19c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 12h-4c0 1.66-1.35 3-3 3s-3-1.34-3-3H4.99V5H19v10z" fill="currentColor"/></svg>No systems with ROMs</div>';
    }
    
    const excludeContainer = document.getElementById('excludeList');
    if (data.all && data.all.length > 0) {
      excludeContainer.innerHTML = data.all.map(sys => {
        const isExcluded = data.excluded.includes(sys);
        return `<div class="system-item ${isExcluded ? 'excluded' : ''}" onclick="excludeAction('${isExcluded ? 'remove' : 'add'}', '${sys}')">
          <span class="name">${sys}</span>
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

// ========== STARTUP ==========

loadTheme();
loadSettings();        // load settings once on startup
refreshStatus();
refreshLogs();
refreshStats();
loadSystems();         // LOAD SYSTEMS ON STARTUP

// Auto-refresh (settings are NOT updated)
setInterval(refreshStatus, 10000);
setInterval(refreshLogs, 8000);
setInterval(refreshStats, 10000);
</script>
</body>
</html>'''

class QuietHTTPServer(http.server.HTTPServer):
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
    
    print(f"\n✅ Save Sync Web UI v1.4.4 started")
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
    echo " Save Sync Diagnostics v1.4.4"
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
    TOTAL_SYNC=$(grep -c "Saves downloaded\|Saves uploaded" "$LOG_FILE" 2>/dev/null)
    ERR_SYNC=$(grep -c "error\|unavailable" "$LOG_FILE" 2>/dev/null)
    [ -z "$TOTAL_SYNC" ] && TOTAL_SYNC=0
    [ -z "$ERR_SYNC" ] && ERR_SYNC=0
    OK_SYNC=$((TOTAL_SYNC - ERR_SYNC))
    [ $OK_SYNC -lt 0 ] && OK_SYNC=0
    print_2col "Statistics" "$TOTAL_SYNC syncs ($OK_SYNC OK, $ERR_SYNC ERR)"
    if [ "$ERR_SYNC" -gt 0 ]; then
        WARNINGS=$((WARNINGS + ERR_SYNC))
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
    
    # Internet
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        PING_TIME=$(ping -c1 -W2 1.1.1.1 2>/dev/null | grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}')
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
    echo " 1 - Update to v1.4.4"
    echo " 2 - Reinstall from scratch"
    echo " 3 - Exit"
    echo ""
    read -p "Choose an option (1-3): " REINSTALL_CHOICE
    case "$REINSTALL_CHOICE" in
    1)
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📦 Updating to v1.4.4"
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
        if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
            bash $BASE/install_sync.sh --web &
            break
        fi
        sleep 2
    done
) &
EOF
            echo "✅ Web interface added to $(basename $AUTOLOAD_FILE)"
        fi
        
        echo ""
        echo "✅ Update to v1.4.4 complete!"

        log_msg "Update to v1.4.4 complete"

        restart_web_if_running

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
        rm -f "$DOWNLOAD_SCRIPT" "$UPLOAD_SCRIPT" "$DOWNLOAD_ROMS" "$UPLOAD_ROMS" 2>/dev/null
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
echo " Save Sync v1.4.4 - Installation"
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
        if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
            bash $BASE/install_sync.sh --web &
            break
        fi
        sleep 2
    done
) &
EOF
    echo "✅ Web interface added to $(basename $AUTOLOAD_FILE)"
else
    echo "✅ Web interface already present in $(basename $AUTOLOAD_FILE)"
fi

SYSTEM_VERSION=$(get_system_version)

log_msg "Save Sync v1.4.4 | $SYSTEM ($SYSTEM_VERSION) | rclone v${NEW_VER:-unknown}"
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