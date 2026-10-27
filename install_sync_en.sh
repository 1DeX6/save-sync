#!/bin/bash

################################################
# Save Sync Installer v1.5.0
# Cloud sync for saves and ROMs
# Batocera / KNULLI / Recalbox
#
# Commands:
#  install_sync.sh      - install / update
#  install_sync.sh --info          - diagnostics
#  install_sync.sh --config   - control panel
#  install_sync.sh --web         - web interface
#  install_sync.sh --uninstall   - uninstall
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
WEB_SHOW_ROMS="true"
WEB_SHOW_LINK="true"
WEB_LINKS=""

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
# Save Sync v1.5.0 - Main config
# ========================================

# ── SYNC SETTINGS ──
# 0 = always, 300 = 5 min, 900 = 15 min, 3600 = 1 hour
SYNC_INTERVAL="0"

# Number of retries on error
MAX_RETRIES="3"

# How many days conflict copies of saves are kept in the cloud (0 = do not keep)
CONFLICT_KEEP_DAYS="3"

# On-screen notifications (Batocera, KNULLI): saves received/sent and errors. true / false
NOTIFICATIONS="true"

# Sync after a game: economy (only when changed), fast (after every game) or full
SYNC_MODE="economy"

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

# ── WEB INTERFACE ──
# Web interface only: the sections shown (Settings -> Sections) and the saved links
WEB_SHOW_ROMS="true"
WEB_SHOW_LINK="true"
WEB_LINKS=""
EOF
    chmod 644 "$CONFIG_FILE"
}

sync_stats_counts() {
    SYNC_OK=$(grep -cE "Saves downloaded|Saves uploaded|(Manual s|S)ync \(" "$LOG_FILE" 2>/dev/null); SYNC_OK=${SYNC_OK:-0}
    # "with changes" = the log line says what was moved: "(sent: 1, ...)"; a plain line or "(no changes)" means nothing was transferred
    SYNC_NOTED=$(grep -cE "(Saves downloaded|Saves uploaded|(Manual s|S)ync) \(" "$LOG_FILE" 2>/dev/null); SYNC_NOTED=${SYNC_NOTED:-0}
    SYNC_EMPTY=$(grep -cE "(Saves downloaded|Saves uploaded|(Manual s|S)ync) \(no changes\)" "$LOG_FILE" 2>/dev/null); SYNC_EMPTY=${SYNC_EMPTY:-0}
    SYNC_CHG=$((SYNC_NOTED - SYNC_EMPTY))
    SYNC_NOCHG=$((SYNC_OK - SYNC_CHG))
    SYNC_ERR=$(grep -cE "Save (download|upload) error|First (download|upload) error|Upload error for saves|Cloud unavailable \(no network" "$LOG_FILE" 2>/dev/null); SYNC_ERR=${SYNC_ERR:-0}
}

ask_cloud_config() {
    # asks for the cloud service and login, writes an rclone config to $1;
    # $2 = "cancel": a "0 - Cancel" choice is offered (returns 2)
    local CONF_OUT="$1"
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
    [ "$2" = "cancel" ] && echo " 0 - Cancel"
    echo ""

    if [ "$2" = "cancel" ]; then read -p "Enter number (0-7): " CHOICE; else read -p "Enter number (1-7): " CHOICE; fi
    if [ "$2" = "cancel" ] && [ "$CHOICE" = "0" ]; then echo "❌ Cancelled. The cloud was not changed."; echo ""; return 2; fi

    BACKEND_TYPE="webdav"

    case "$CHOICE" in
    1) URL="https://webdav.yandex.ru"; VENDOR="yandex" ;;
    2) URL="https://webdav.cloud.mail.ru"; VENDOR="other" ;;
    3)
        echo ""
        echo "For pCloud: username is your account email, password is your"
        echo "regular account password. The region (US or EU) is detected"
        echo "automatically. With two-factor authentication on, the"
        echo "connection may not work."
        URL="https://webdav.pcloud.com"; VENDOR="other"
        ;;
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
    *) echo "❌ Invalid choice."; return 1 ;;
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
        "$RCLONE_PATH" --config "$CONF_OUT" lsd "$REMOTE_NAME:" >/dev/null 2>&1 && echo "ℹ️  pCloud: the account is in the EU region."
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
            CLOUD_ERR="wrong username or password (this service may need an app password)"
            grep -q "pcloud" "$1" 2>/dev/null && CLOUD_ERR="wrong username or password. If the pCloud account was created with Google, Apple or Facebook, first set a password on the pCloud website (Forgot password?)" ;;
        *"no such host"*|*"i/o timeout"*|*"connection refused"*|*"network is unreachable"*|*"dial tcp"*)
            CLOUD_ERR="the server does not respond - check the internet connection and the server address" ;;
        *"connection reset"*|*"broken pipe"*|*EOF*|*"TLS handshake"*|*"deadline exceeded"*|*"timeout awaiting"*|*"Client.Timeout"*)
            CLOUD_ERR="the server dropped the connection or did not answer in time - looks like a temporary problem of the service, try again later" ;;
        *"429"*|*"Too Many Requests"*)
            CLOUD_ERR="the service temporarily limits requests - try again later" ;;
        *" 500 "*|*" 502 "*|*" 503 "*|*" 504 "*|*"Internal Server Error"*|*"Bad Gateway"*|*"Service Unavailable"*|*"Gateway Timeout"*)
            CLOUD_ERR="the service is temporarily down (an error on its side) - try again later" ;;
        *)
            CLOUD_ERR="the cloud answered with an error: "$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1 \
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
    if [ "$(cloud_service "$RCLONE_CONF")" = "pCloud" ]; then echo "not reported"; else echo "unknown"; fi
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
    [ -f "$f" ] || { echo "not set up"; return; }
    u=$(sed -n 's/^user = //p' "$f" | head -1)
    url=$(sed -n 's/^url = //p' "$f" | head -1)
    if grep -q "^type = mega" "$f"; then echo "Mega${u:+ ($u)}"; return; fi
    case "$url" in
        *yandex*) echo "Yandex Disk${u:+ ($u)}" ;;
        *mail.ru*) echo "Mail.ru Cloud${u:+ ($u)}" ;;
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
        "Yandex Disk") echo "Yandex Disk:     " ;;
        "Mail.ru Cloud") echo "Mail.ru Cloud:   " ;;
        "pCloud") echo "pCloud:          " ;;
        "Koofr") echo "Koofr:           " ;;
        "Fastmail") echo "Fastmail:        " ;;
        "Mega") echo "Mega:            " ;;
        WebDAV*) echo "WebDAV:          " ;;
        *) echo "Cloud:           " ;;
    esac
}

notify_label() {
    if [ "${NOTIFICATIONS:-true}" = "false" ]; then echo "off"; else echo "on"; fi
}

sync_mode_label() {
    case "${SYNC_MODE:-economy}" in
        full) echo "full" ;;
        fast) echo "after every game" ;;
        *) echo "only when changed" ;;
    esac
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
                WEB_SHOW_ROMS) WEB_SHOW_ROMS="$value" ;;
                WEB_SHOW_LINK) WEB_SHOW_LINK="$value" ;;
                WEB_LINKS) WEB_LINKS="$value" ;;
            esac
        done < "$CONFIG_FILE"
        case "$SYNC_MODE" in
            full|fast|economy) ;;
            *) if [ "$SKIP_UNCHANGED" = "false" ]; then SYNC_MODE="full"; else SYNC_MODE="economy"; fi ;;
        esac
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
# Save Sync v1.5.0 - Main config
# ========================================

# ── SYNC SETTINGS ──
SYNC_INTERVAL="$SYNC_INTERVAL"
MAX_RETRIES="$MAX_RETRIES"
CONFLICT_KEEP_DAYS="$CONFLICT_KEEP_DAYS"
NOTIFICATIONS="${NOTIFICATIONS:-true}"
SYNC_MODE="${SYNC_MODE:-economy}"
MIN_FREE_KB="$MIN_FREE_KB"

# ── ROM SETTINGS ──
ROMS_SYNC_DIRS="$ROMS_SYNC_DIRS"
ROMS_SYNC_MEDIA="$ROMS_SYNC_MEDIA"
EXCLUDED_SYSTEMS="$EXCLUDED_SYSTEMS"

# ── LOGGING SETTINGS ──
LOG_ENABLED="$LOG_ENABLED"
MAX_LOG_SIZE="$MAX_LOG_SIZE"
LOG_LEVEL="$LOG_LEVEL"

# ── WEB INTERFACE ──
WEB_SHOW_ROMS="${WEB_SHOW_ROMS:-true}"
WEB_SHOW_LINK="${WEB_SHOW_LINK:-true}"
WEB_LINKS="$WEB_LINKS"
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
# Since 1.5.0 all files of Save Sync are in their own folder (APP_DIR). Older versions kept
# them right in the system folder: such files are used as they are until "Update" moves them
# (the web interface and the hooks keep working if the installer was only copied over).
# Stay where they were: install_sync.sh itself, the log, the hook, the autostart lines.
APP_DIR="$BASE/save_sync"
LEGACY_LAYOUT=false
if [ ! -f "$APP_DIR/download_sync.sh" ] && [ -f "$BASE/download_sync.sh" ]; then
    LEGACY_LAYOUT=true
fi
set_paths() {
    if [ "$LEGACY_LAYOUT" = true ]; then
        DATA_DIR="$BASE"
        CONFIG_DIR="$BASE/.config/rclone"
    else
        DATA_DIR="$APP_DIR"
        CONFIG_DIR="$APP_DIR"
    fi
    CONFIG_FILE="$DATA_DIR/sync.conf"
    BIN_DIR="$DATA_DIR/bin"
    RCLONE_BIN="$BIN_DIR/rclone"
    RCLONE_PATH="$RCLONE_BIN"
    RCLONE_CONF="$CONFIG_DIR/rclone.conf"
    DOWNLOAD_SCRIPT="$DATA_DIR/download_sync.sh"
    UPLOAD_SCRIPT="$DATA_DIR/upload_sync.sh"
    DOWNLOAD_ROMS="$DATA_DIR/download_roms.sh"
    UPLOAD_ROMS="$DATA_DIR/upload_roms.sh"
    ROMS_FILTER_FILE="$DATA_DIR/roms_filter_sync"
    STATE_FILE="$DATA_DIR/.sync_state"
    LINK_SCRIPT="$DATA_DIR/link_download.py"
    ENGINE_SCRIPT="$DATA_DIR/sync_engine.py"
}
set_paths
LOG_DIR="$BASE/logs"
LOG_FILE="$LOG_DIR/save_sync.log"
SCRIPT_DIR="$BASE/scripts"
# Persistent sync state (survives reboots, unlike /tmp):
# PENDING_UPLOAD=1 - local saves changed but were not uploaded yet
# LAST_GOOD_SYNC=<unix time> - last moment device and cloud were in sync

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
MCACHE_DIR = os.path.join(BASE_DIR, ".sync_manifests")     # copies of the cloud manifests
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
        "manifest_failed": "The cloud manifest was not written - the next sync will be a full one",
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
        "no_changes": "изменений нет",
        "st_scan": "Проверка сохранений на устройстве", "st_compare": "Сравнение с облаком",
        "st_send": "Отправка файлов: {n}", "st_recv": "Получение файлов: {n}",
        "st_delete": "Удаление файлов: {n}", "st_finish": "Сохранение состояния синхронизации",
        "n_guard": "удаление остановлено",
        "manifest_failed": "Манифест в облаке не записан - следующая синхронизация будет полной",
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
    # whole retries are done by the engine (MAX_RETRIES), rclone does not repeat on its own:
    # otherwise on a bad network the attempts multiply and the sync hangs for minutes
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


def refresh_listing(root, C, uploaded, deleted, peek=None):
    """The cloud listing after our own changes: only the files we just sent are asked
    for again (a full listing of a big cloud folder takes long); if that does not
    work out, the whole folder is listed again. peek (a dict): gets the size and date of
    the manifest from the same request."""
    C2 = {r: v for r, v in C.items() if r not in deleted}
    if uploaded:
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
            f.write("\n".join(sorted(uploaded) + ([MANIFEST] if peek is not None else [])) + "\n")
        try:
            rc, out = rclone(["lsjson", "-R", "--files-only", "--no-mimetype", "--files-from-raw", f.name, root.remote], check=False)
        finally:
            os.remove(f.name)
        try:
            got = {i["Path"]: (i.get("Size", -1), i.get("ModTime", "")) for i in json.loads(out or "[]")} if rc == 0 else {}
        except (ValueError, KeyError, TypeError):
            got = {}
        if peek is not None and rc == 0:
            peek["st"] = mstat(got.pop(MANIFEST, None))
            peek["ok"] = True
        if all(r in got for r in uploaded):
            for r in uploaded:
                if root.accept(r, got[r][0]):
                    C2[r] = got[r]
                else:
                    C2.pop(r, None)
            return C2
        return {r: v for r, v in cloud_list(root.remote).items() if root.accept(r, v[0])}
    return C2


# ---- copies of the cloud manifests on the card. Reading a manifest is the slowest part
# of the quick sync (the whole file, for every folder, after every game); its size and
# date are asked for all folders with one short request, and a manifest whose size and
# date did not change is taken from the copy.
def mstat(v):
    """(size, date) of a listing entry in one form (JSON turns tuples into lists)."""
    return [v[0], v[1]] if v and v[1] else None


def manifest_stats(all_roots):
    """{root name: [size, date]} of the manifests in the cloud (a folder without one is
    left out), or None when the cloud did not answer."""
    paths = {}
    for root in all_roots:
        if root.remote == REMOTE:
            paths[MANIFEST] = root.name
        elif root.remote.startswith(REMOTE + "/"):
            paths[root.remote[len(REMOTE) + 1:] + "/" + MANIFEST] = root.name
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
        f.write("\n".join(sorted(paths)) + "\n")
    try:
        rc, out = rclone(["lsjson", "-R", "--files-only", "--no-mimetype", "--files-from-raw", f.name, REMOTE], check=False)
    finally:
        os.remove(f.name)
    if rc != 0:
        return None
    try:
        got = {i["Path"]: (i.get("Size", -1), i.get("ModTime", "")) for i in json.loads(out or "[]")}
    except (ValueError, KeyError, TypeError):
        return None
    return {name: mstat(got[path]) for path, name in paths.items() if path in got}


def one_manifest_stat(root):
    """[size, date] of the manifest of one folder; None = no manifest; False = no answer."""
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
        f.write(MANIFEST + "\n")
    try:
        rc, out = rclone(["lsjson", "-R", "--files-only", "--no-mimetype", "--files-from-raw", f.name, root.remote], check=False)
    finally:
        os.remove(f.name)
    if rc != 0:
        return False
    try:
        got = {i["Path"]: (i.get("Size", -1), i.get("ModTime", "")) for i in json.loads(out or "[]")}
    except (ValueError, KeyError, TypeError):
        return False
    return mstat(got.get(MANIFEST))


def mcache_path(root):
    return os.path.join(MCACHE_DIR, hashlib.md5(root.name.encode("utf-8")).hexdigest()[:12] + ".json")


def mcache_get(root, st):
    """The copy of the manifest if the cloud shows the same size and date as when it was taken."""
    if not st:
        return None
    c = load_json(mcache_path(root), None)
    if isinstance(c, dict) and c.get("root") == root.name and c.get("remote") == root.remote and c.get("st") == st and isinstance(c.get("m"), str):
        return c["m"]
    return None


def mcache_put(root, st, text):
    """Keeps the manifest text with the size and date the cloud showed for it (no date: dropped)."""
    try:
        if not st:
            mcache_drop(root)
            return
        os.makedirs(MCACHE_DIR, exist_ok=True)
        save_json(mcache_path(root), {"root": root.name, "remote": root.remote, "st": st, "m": text})
    except OSError:
        pass


def mcache_drop(root):
    try:
        os.remove(mcache_path(root))
    except OSError:
        pass


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


def write_manifest(remote, data):
    """-> True when the manifest is in the cloud. A failed write is remembered in the base
    (manifest_pending): the other devices learn about changes from the manifest, so the
    next sync here is a full one and writes it again."""
    try:
        r = subprocess.run(rclone_cmd(["rcat", remote + "/" + MANIFEST]), input=data,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        ok = r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        ok = False
    if not ok:
        log(t("manifest_failed"))
    return ok


def unchanged_here():
    """True when nothing on this device changed since the last good sync: the same saves,
    with the same size and modification time as in the base (a file whose time differs is
    read and compared by content). Looks at the local disk only - no cloud, no manifest.
    Any doubt gives False, and then the normal sync runs."""
    base_all = load_json(BASE_FILE, {})
    if base_all.get("manifest_pending"):
        return False                    # the manifest was not written last time: sync again
    base_roots = base_all.get("roots")
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
    manifest_failed = False
    mread = {}          # root name -> [size, date] of the manifest that was read (when known)
    if fast:
        if not base_roots or base_all.get("manifest_pending"):
            fast = False                # a manifest not written last time is written by a full sync
        else:
            stats = manifest_stats(all_roots)

            def read_any_manifest(root):
                if not base_roots.get(root.name):
                    return 1, ""        # nothing synced in this folder yet: new saves there come with the full sync
                st = stats.get(root.name) if stats is not None else None
                text = mcache_get(root, st)
                if text is not None:
                    mread[root.name] = st
                    return 0, text      # not changed since it was read or written here
                rc_m, out_m = rclone(["cat", root.remote + "/" + MANIFEST], check=False)
                if rc_m == 0 and st:
                    # the size and date were asked before reading: if another device wrote in
                    # between, the next sync sees another date and reads it again
                    mcache_put(root, st, out_m)
                    mread[root.name] = st
                return rc_m, out_m
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
            st = mstat(listings[root.name][MANIFEST])
            text = mcache_get(root, st)
            if text is not None:
                mread[root.name] = st
                return 0, text
            rc_m, out_m = rclone(["cat", root.remote + "/" + MANIFEST], check=False)
            if rc_m == 0 and st:
                mcache_put(root, st, out_m)
                mread[root.name] = st
            return rc_m, out_m
        mcache_drop(root)
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
        peek = {}
        C2 = refresh_listing(root, C, set(up) | set(won_local) | moved_to, set(del_cloud) | moved_from, peek) if changed_cloud else C
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
            # read again only when the manifest changed since it was read (its size and date
            # now: from the listing above, or asked); unknown -> read again, as before
            same_st = False
            if mread.get(root.name):
                st_now = peek.get("st") if peek.get("ok") else one_manifest_stat(root)
                same_st = st_now == mread[root.name]
            if not same_st:
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
            mcache_drop(root)
            written = write_manifest(root.remote, data)
            if not written:
                manifest_failed = True
            if TIMING:
                timed("rcat", t0)
            if written:
                # its size and date as the cloud shows them: the next sync takes it from the copy
                st_new = one_manifest_stat(root)
                if st_new and st_new[0] == len(data):
                    mcache_put(root, st_new, data.decode("utf-8"))

    base_all["roots"] = new_base_roots
    base_all["device"] = dev
    if manifest_failed:
        base_all["manifest_pending"] = True
    else:
        base_all.pop("manifest_pending", None)
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
    manifest_failed = False
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
            if not write_manifest(root.remote, data):
                manifest_failed = True
    new_base = {"roots": new_base_roots, "device": dev}
    if manifest_failed:
        new_base["manifest_pending"] = True
    save_json(BASE_FILE, new_base)
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
    parts = ["%s %dx %.1f s" % (k, v[0], v[1]) for k, v in TIMES.items() if k != "scan"]
    scan = TIMES.get("scan", [0, 0.0])[1]
    return "Timing: total %.1f s; rclone: %s; device scan %.1f s" % (total, ", ".join(parts) or "-", scan)


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
        -e "s|__SS_LANG__|en|g" \
        -e "s|__SS_SAVE_DIR__|$SAVE_DIR|g" \
        -e "s|__SS_ROMS_DIR__|$ROMS_DIR|g" \
        -e "s|__SS_REMOTE__|$REMOTE|g" \
        -e "s|__SS_BASE__|$DATA_DIR|g" \
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
# The result is remembered until reboot, as long as rclone itself is not updated.
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

# keep the log within MAX_LOG_SIZE: when it grows past it, the old part moves to .old
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
T_ENG=\$(cut -d. -f1 /proc/uptime 2>/dev/null || date +%s)
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
    [ "\$LOG_LEVEL" = "debug" ] && echo "\$(date '+%d.%m %H:%M:%S') Timing: before the sync started \$((T_ENG - T0)) s" >> "\$LOG_FILE" 2>/dev/null
    SYNC_NOTE=\$(cat "/tmp/save_sync_result.\$\$" 2>/dev/null); rm -f "/tmp/save_sync_result.\$\$"
    if [ "\$FORCE_SYNC" = "true" ]; then SYNC_WHAT="Manual sync"; else SYNC_WHAT="Sync"; fi
    echo "\$(date '+%d.%m %H:%M:%S') \$SYNC_WHAT\${SYNC_NOTE:+ (\$SYNC_NOTE)}" >> "\$LOG_FILE" 2>/dev/null
    if [ -n "\$SYNC_NOTE" ] && [ "\$SYNC_NOTE" != "no changes" ]; then
        case "\$SYNC_NOTE" in
            *conflict*) [ "\${CONFLICT_KEEP_DAYS:-3}" != "0" ] && notify_screen "Save Sync: save conflict - see the web interface" || notify_screen "Save Sync: \$SYNC_NOTE" ;;
            *) notify_screen "Save Sync: \$SYNC_NOTE" ;;
        esac
    fi
    progress_finish true "download" "Save download complete"
    exit 0
fi
save_status "ERROR"
echo "\$(date '+%d.%m %H:%M:%S') Save download error (code: \$ENGINE_EXIT)" >> "\$LOG_FILE" 2>/dev/null
if grep -q "^cloud_full" "/tmp/save_sync_result.\$\$" 2>/dev/null; then
    notify_screen "Save Sync: error - the cloud is out of space"
else
    notify_screen "Save Sync: sync error"
fi
rm -f "/tmp/save_sync_result.\$\$"
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
# The result is remembered until reboot, as long as rclone itself is not updated.
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

# keep the log within MAX_LOG_SIZE: when it grows past it, the old part moves to .old
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


# Sync after a game (setting "Sync after a game", SYNC_MODE):
#   economy - the saves on this device did not change - the cloud is not contacted,
#             they changed - a fast sync
#   fast    - changes and deletions from other devices come from the manifests, the
#             cloud is asked only about those files and the ones changed here
#   full    - the whole list of cloud files, as in earlier versions
# At boot, from the menu, the web interface, with --force and after a failed upload
# (PENDING_UPLOAD) the sync is always full. The old setting SKIP_UNCHANGED:
# on = economy, off = full.
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
        echo "\$(date '+%d.%m %H:%M:%S') Sync (no changes) - the cloud was not contacted" >> "\$LOG_FILE" 2>/dev/null
        exit 0
    else
        LOCAL_CHANGED=1
    fi
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

# Automatic upload after a game: show that it started and, if it takes long,
# remind once a minute that it is still running. Not shown when nothing changed.
if [ "\$FORCE_SYNC" != "true" ] && [ -z "\$SHOW_PROGRESS" ] && [ "\$WEB_PROGRESS" != "true" ]; then
    if [ -n "\$(state_get PENDING_UPLOAD)" ] || [ "\$LOCAL_CHANGED" = "1" ] || \
       { [ -z "\$LOCAL_CHANGED" ] && ! SS_EXCLUDED="\$EXCLUDED_SYSTEMS" python3 "\$ENGINE_SCRIPT" check >/dev/null 2>&1; }; then
        notify_screen "Save Sync: sync started"
        (
            P=\$\$; n=0
            while sleep 60; do
                kill -0 "\$P" 2>/dev/null || break
                n=\$((n+1))
                notify_screen "Save Sync: sync still running (\$n min)"
            done
        ) 200>&- >/dev/null 2>&1 &
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

# Wait for the cloud for about 30 seconds: after a game the network is usually
# up, and if not, the saves go later (PENDING_UPLOAD). The cloud itself is checked, not a
# ping to 1.1.1.1: some networks block ping while the cloud works fine.
# The deadline uses the uptime counter - the clock can jump on NTP sync.
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
    echo "\$(date '+%d.%m %H:%M:%S') Cloud unavailable (no network or the cloud does not respond)" >> "\$LOG_FILE" 2>/dev/null
    notify_screen "Save Sync: no connection to the cloud, the saves will be sent later"
    save_status "ERROR"
    state_set PENDING_UPLOAD 1
    exit 1
fi

# ======== TWO-WAY SYNC (sync_engine.py) ========
# The device and the cloud are compared with the last sync: only what changed
# in the cloud is downloaded, only what changed here is uploaded. If a save was
# changed on different devices, the newer one is kept and the older one is copied to
# the _conflicts folder (how long - the "Conflict copies" setting). Nothing is asked.
T_ENG=\$(cut -d. -f1 /proc/uptime 2>/dev/null || date +%s)
progress_start "upload" "Uploading saves"
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
    [ "\$LOG_LEVEL" = "debug" ] && echo "\$(date '+%d.%m %H:%M:%S') Timing: before the sync started \$((T_ENG - T0)) s" >> "\$LOG_FILE" 2>/dev/null
    SYNC_NOTE=\$(cat "/tmp/save_sync_result.\$\$" 2>/dev/null); rm -f "/tmp/save_sync_result.\$\$"
    if [ "\$FORCE_SYNC" = "true" ]; then SYNC_WHAT="Manual sync"; else SYNC_WHAT="Sync"; fi
    echo "\$(date '+%d.%m %H:%M:%S') \$SYNC_WHAT\${SYNC_NOTE:+ (\$SYNC_NOTE)}" >> "\$LOG_FILE" 2>/dev/null
    if [ -n "\$SYNC_NOTE" ] && [ "\$SYNC_NOTE" != "no changes" ]; then
        case "\$SYNC_NOTE" in
            *conflict*) [ "\${CONFLICT_KEEP_DAYS:-3}" != "0" ] && notify_screen "Save Sync: save conflict - see the web interface" || notify_screen "Save Sync: \$SYNC_NOTE" ;;
            *) notify_screen "Save Sync: \$SYNC_NOTE" ;;
        esac
    fi
    progress_finish true "upload" "Save upload complete"
    exit 0
fi
save_status "ERROR"
echo "\$(date '+%d.%m %H:%M:%S') Save upload error (code: \$ENGINE_EXIT)" >> "\$LOG_FILE" 2>/dev/null
if grep -q "^cloud_full" "/tmp/save_sync_result.\$\$" 2>/dev/null; then
    notify_screen "Save Sync: error - the cloud is out of space"
else
    notify_screen "Save Sync: sync error"
fi
rm -f "/tmp/save_sync_result.\$\$"
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
        mkdir -p "$SCRIPT_DIR" 2>/dev/null
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
# The result is remembered until reboot, as long as rclone itself is not updated.
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

# Logging function
log_msg() {
    echo "\$(date '+%d.%m %H:%M:%S') \$1" >> "\$LOG_FILE"
}

# keep the log within MAX_LOG_SIZE: when it grows past it, the old part moves to .old
if [ -f "\$LOG_FILE" ] && [ "\$(wc -c < "\$LOG_FILE" 2>/dev/null || echo 0)" -gt "\${MAX_LOG_SIZE:-102400}" ] 2>/dev/null; then
    mv -f "\$LOG_FILE" "\$LOG_FILE.old" 2>/dev/null
fi

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

notify_screen "Save Sync: ROMs download started"
(
    P=\$\$; n=0
    while sleep 60; do
        kill -0 "\$P" 2>/dev/null || break
        n=\$((n+1))
        notify_screen "Save Sync: ROMs download still running (\$n min)"
    done
) 200>&- >/dev/null 2>&1 &

progress_start "roms_download" "Downloading ROMs"
# gamelist.xml is not copied over the device's own (play counts, favorites, games that
# are only here would be lost): it is merged in after the transfer
GL_FILTER=()
if [ -f "$LINK_SCRIPT" ] && command -v python3 >/dev/null 2>&1; then
    GL_FILTER=(--filter "- /*/gamelist.xml")
fi
run_transfer copy "\$REMOTE_ROMS" "\$ROMS_DIR" \
    --update \
    "\${GL_FILTER[@]}" \
    --filter-from "\$FILTER_FILE"

EXIT_CODE=\$?
if [ \${#GL_FILTER[@]} -gt 0 ] && { [ \$EXIT_CODE -eq 0 ] || [ \$EXIT_CODE -eq 3 ]; }; then
    python3 "$LINK_SCRIPT" --merge-cloud-gamelists
fi

if [ \$EXIT_CODE -eq 0 ] || [ \$EXIT_CODE -eq 3 ]; then
    echo "✅ ROM download complete"
    log_msg "ROM download complete"
    progress_finish true "roms_download" "ROM download complete"
    notify_screen "Save Sync: ROMs downloaded"
    # new games show up in the EmulationStation list right away (Batocera, KNULLI)
    # when ES is not busy: no game, scraper or update running
    if curl -s -m 3 http://127.0.0.1:1234/isIdle 2>/dev/null | grep -q true; then
        curl -s -m 5 http://127.0.0.1:1234/reloadgames >/dev/null 2>&1 || true
    fi
else
    echo "❌ ROM download error (code: \$EXIT_CODE)"
    log_msg "ROM download error (code: \$EXIT_CODE)"
    progress_finish false "roms_download" "ROM download error"
    notify_screen "Save Sync: ROMs download failed"
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
# The result is remembered until reboot, as long as rclone itself is not updated.
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

# Logging function
log_msg() {
    echo "\$(date '+%d.%m %H:%M:%S') \$1" >> "\$LOG_FILE"
}

# keep the log within MAX_LOG_SIZE: when it grows past it, the old part moves to .old
if [ -f "\$LOG_FILE" ] && [ "\$(wc -c < "\$LOG_FILE" 2>/dev/null || echo 0)" -gt "\${MAX_LOG_SIZE:-102400}" ] 2>/dev/null; then
    mv -f "\$LOG_FILE" "\$LOG_FILE.old" 2>/dev/null
fi

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

echo "🔄 Copying ROMs to cloud..."

notify_screen "Save Sync: ROMs upload started"
(
    P=\$\$; n=0
    while sleep 60; do
        kill -0 "\$P" 2>/dev/null || break
        n=\$((n+1))
        notify_screen "Save Sync: ROMs upload still running (\$n min)"
    done
) 200>&- >/dev/null 2>&1 &

progress_start "roms_upload" "Uploading ROMs"
run_transfer sync "\$ROMS_DIR" "\$REMOTE_ROMS" \
    --delete-after \
    --filter-from "\$FILTER_FILE"

EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ] || [ \$EXIT_CODE -eq 3 ]; then
    echo "✅ ROM upload complete"
    log_msg "ROM upload complete"
    progress_finish true "roms_upload" "ROM upload complete"
    notify_screen "Save Sync: ROMs uploaded"
else
    echo "❌ ROM upload error (code: \$EXIT_CODE)"
    log_msg "❌ ROM upload error (code: \$EXIT_CODE)"
    progress_finish false "roms_upload" "ROM upload error"
    notify_screen "Save Sync: ROMs upload failed"
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
#   link_download.py --catalog-json URL [PATH]               games of the gamelist.xml at/under PATH
#   link_download.py --catalog-media URL DIR FILE OUT        save one media file of a catalog to OUT
#   link_download.py --download URL --dest SYSTEM --catalog DIR --game PATH... [--media TAG,TAG]
#                    [--target device|cloud]
#                    chosen games of a catalog with their media; their entries are
#                    added to the gamelist.xml of the system (on the device or in the cloud)
#   link_download.py --merge-cloud-gamelists
#                    after "Download ROMs": the gamelist.xml of every synced system in the
#                    cloud is merged into the one on the device (nothing is overwritten)
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
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
import zlib
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
# A picture or video of the catalog is asked quickly: a service that hangs must not keep
# the page waiting for minutes. Set per thread by CatalogSession.media.
QUICK_TIMEOUT = 15
# a cover in the catalog list: the service's preview fits this box (bigger pictures are not needed)
CAT_THUMB_W, CAT_THUMB_H = 240, 320
CAT_THUMB_MAX = 1024 * 1024
_NET = threading.local()

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
        "cat_no_gamelist": "❌ No gamelist.xml here: open the folder with the games.",
        "cat_bad_gamelist": "❌ gamelist.xml cannot be read: {err}",
        "cat_too_big": "❌ The file {name} is too big",
        "cat_cloud": "❌ Games from a catalog are downloaded to the device only.",
        "cat_nothing": "❌ None of the chosen games was found in the catalog.",
        "cat_merged": "📝 gamelist.xml: games added or completed: {n}",
        "cat_merge_failed": "⚠️  Could not update gamelist.xml: {err}",
        "gl_merged": "📝 {sys}: gamelist.xml from the cloud merged (games added or completed: {n})",
        "list_time": "{service}: file list received in {s} s (files: {n})",
        "gl_merge_failed": "⚠️  {sys}: gamelist.xml from the cloud was not merged: {err}",
        "cat_cloud_video": "ℹ️  Videos reach the devices only with ROMs -> Media: with videos",
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
        "es_hint_recalbox": "ℹ️  Recalbox will show \"Game list changed!\" - press \"Update\": the new games appear with their descriptions. Do not use the menu item \"Update gamelists\" for this: it would overwrite gamelist.xml.",
        "es_reloaded": "ℹ️  New games were added to the EmulationStation list.",
        "units": ("B", "KB", "MB", "GB", "TB"),
        "log_start": "Link download: {service} {url} -> {dest}",
        "log_done": "Link download complete: {ok} downloaded, {skip} skipped, {fail} failed",
        "log_error": "Link download error: {err}",
        "phase": "Downloading from link",
        "svc_yandex": "Yandex Disk", "svc_pcloud": "pCloud", "svc_nextcloud": "Nextcloud",
        "svc_archive": "archive.org", "svc_direct": "Direct link",
        "direct_page": "❌ The link opens a web page, not a file. Paste a direct link to the file (for example, copied from the download button) or a Yandex Disk, pCloud, Nextcloud or archive.org link.",
        "direct_denied": "❌ The server did not give the file: the link has expired or needs a login. Copy the download link again.",
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
        "cat_no_gamelist": "❌ Здесь нет gamelist.xml: откройте папку с играми.",
        "cat_bad_gamelist": "❌ Не удалось прочитать gamelist.xml: {err}",
        "cat_too_big": "❌ Файл {name} слишком большой",
        "cat_cloud": "❌ Игры из каталога скачиваются только на устройство.",
        "cat_nothing": "❌ Выбранные игры не найдены в каталоге.",
        "cat_merged": "📝 gamelist.xml: добавлено или дополнено игр: {n}",
        "cat_merge_failed": "⚠️  Не удалось обновить gamelist.xml: {err}",
        "gl_merged": "📝 {sys}: gamelist.xml из облака объединён (добавлено или дополнено игр: {n})",
        "list_time": "{service}: список файлов получен за {s} с (файлов: {n})",
        "gl_merge_failed": "⚠️  {sys}: gamelist.xml из облака не объединён: {err}",
        "cat_cloud_video": "ℹ️  Видео попадёт на устройства, только если в ромах выбрано «Медиа: с видео»",
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
        "es_hint_recalbox": "ℹ️  Recalbox покажет окно «Список игр изменён!» - нажмите «Обновить»: новые игры появятся с описаниями. Пункт меню «Обновить списки игр» для этого не используйте: он перезапишет gamelist.xml.",
        "es_reloaded": "ℹ️  Новые игры добавлены в список EmulationStation.",
        "units": ("Б", "КБ", "МБ", "ГБ", "ТБ"),
        "log_start": "Загрузка по ссылке: {service} {url} -> {dest}",
        "log_done": "Загрузка по ссылке завершена: скачано {ok}, пропущено {skip}, с ошибкой {fail}",
        "log_error": "Ошибка загрузки по ссылке: {err}",
        "phase": "Загрузка по ссылке",
        "svc_yandex": "Яндекс.Диск", "svc_pcloud": "pCloud", "svc_nextcloud": "Nextcloud",
        "svc_archive": "archive.org", "svc_direct": "Прямая ссылка",
        "direct_page": "❌ По ссылке открывается страница, а не файл. Вставьте прямую ссылку на файл (например, скопированную с кнопки скачивания) или ссылку Яндекс.Диска, pCloud, Nextcloud, archive.org.",
        "direct_denied": "❌ Сервер не отдал файл: ссылка истекла или нужен вход. Скопируйте ссылку на скачивание заново.",
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
    # quick (catalog pictures): short wait and one retry, only after a dropped connection
    quick = getattr(_NET, "quick", False)
    tries = 1 if quick else RETRIES
    if quick:
        timeout = min(timeout, QUICK_TIMEOUT)
    for attempt in range(tries + 1):
        req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
        try:
            return urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < tries:
                last = e
                time.sleep(1 if quick else 2 + attempt * 4)
                continue
            raise
        except (urllib.error.URLError, socket.timeout, ConnectionError) as e:
            last = e
            timed_out = isinstance(e, socket.timeout) or isinstance(getattr(e, "reason", None), socket.timeout)
            if attempt < tries and not (quick and timed_out):
                time.sleep(1 if quick else 2 + attempt * 4)
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

    def prefetch_tail(self, n):
        """Reads the last n bytes in one request: the zip's table of contents is at the
        end, so opening an archive usually needs a single request instead of several."""
        n = min(n, self.size or 0)
        if n > 0:
            self.buf_start = self.size - n
            self.buf = self._fetch(self.buf_start, n)

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
            rf = RangeFile(src, entry)
            # small archives: a small tail (only the chosen files should be transferred)
            rf.prefetch_tail(min(256 * 1024, max(8 * 1024, (entry.size or 0) // 16)))
            zf = zipfile.ZipFile(rf)
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
        q = {"public_key": self.public_key, "limit": 200, "offset": offset,
             "preview_size": "%dx" % CAT_THUMB_W, "preview_crop": "false"}
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
                    child.preview = it.get("preview")
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


    def thumb_request(self, entry):
        url = getattr(entry, "preview", None)
        return (url, {}) if url else None


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

    def thumb_request(self, entry):
        if self.single_file or not entry.ref:
            return None
        res = self._call(self.api, "getpubthumblink", fileid=entry.ref,
                         size="%dx%d" % (CAT_THUMB_W, CAT_THUMB_H))
        if res.get("result") != 0 or not res.get("hosts"):
            return None
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
        self.base = base
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

    def thumb_request(self, entry):
        if self.password or self.single_file or not entry.ref:
            return None
        q = urllib.parse.urlencode({"file": "/" + entry.ref, "x": CAT_THUMB_W, "y": CAT_THUMB_H, "a": 1})
        return (self.base + "/index.php/apps/files_sharing/publicpreview/" + self.token + "?" + q,
                {"X-Requested-With": "XMLHttpRequest"})


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


# ============================================================== a direct link to a file
class DirectSource:
    """Any other http(s) link: a direct link to one file (a signed CDN link copied from a
    download button, e.g. Boosty). Checked with one small request: a web page is refused."""
    title = t("svc_direct")
    direct = True

    @classmethod
    def match(cls, u):
        return True

    def __init__(self, url, password=None):
        self.url = url
        self.single_file = False

    @staticmethod
    def _file_name(cd, url):
        m = re.search(r"filename\*\s*=\s*[^']*'[^']*'([^;]+)", cd or "", re.I)
        if m:
            return urllib.parse.unquote(m.group(1).strip().strip('"'))
        m = re.search(r'filename\s*=\s*"([^"]+)"', cd or "", re.I) or re.search(r"filename\s*=\s*([^;]+)", cd or "", re.I)
        if m:
            return m.group(1).strip()
        return urllib.parse.unquote(urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1])

    def load(self, scan):
        try:
            with open_url(self.url, {"Range": "bytes=0-3"}) as resp:
                status = getattr(resp, "status", 200)
                ctype = (resp.headers.get("Content-Type") or "").lower()
                cd = resp.headers.get("Content-Disposition") or ""
                crange = resp.headers.get("Content-Range") or ""
                clen = resp.headers.get("Content-Length") or ""
                final = resp.geturl() or self.url
                head = resp.read(4)
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                raise LinkError(t("not_found"))
            if e.code in (401, 403):
                raise LinkError(t("direct_denied"))
            raise LinkError(t("api_error", err="HTTP %d" % e.code))
        if "text/html" in ctype or head[:1] == b"<":
            raise LinkError(t("direct_page"))
        size = None
        m = re.search(r"/(\d+)\s*$", crange)
        if status == 206 and m:
            size = int(m.group(1))
        elif status == 200 and clen.isdigit():
            size = int(clen)
        name = safe_name(self._file_name(cd, final))
        if "." not in name and head == b"PK\x03\x04":
            name += ".zip"                      # a link without a file name: a zip by its bytes
        scan.add()
        root = Entry(urllib.parse.urlsplit(final).hostname or "", True, ref="")
        root.children.append(Entry(name, False, size, self.url))
        return root

    def download_request(self, entry):
        return entry.ref or self.url, {}


SOURCES = (YandexSource, PCloudSource, NextcloudSource, ArchiveSource, DirectSource)


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
        self.lock = threading.RLock()     # small files are fetched by several threads
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
        with self.lock:
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


_PROG_LOCK = threading.Lock()


def write_progress(active, pct, done, total, speed, eta, i, n, success=None, phase=None):
    d = {"active": active, "action": "link_download", "phase": phase or t("phase"), "percent": pct,
         "bytes": done, "totalBytes": total, "speed": int(speed), "eta": eta,
         "transfers": i, "totalTransfers": n}
    if success is not None:
        d["success"] = success
    try:
        with _PROG_LOCK:
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
        progress.update(-got)
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
            _LIVE_PROCS.add(proc)
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
            progress.update(-sent)     # this attempt's bytes are sent again
            if attempt < RETRIES:
                time.sleep(3 + attempt * 5)
        finally:
            _LIVE_PROCS.discard(proc)
            errf.close()
    raise LinkError(str(getattr(last, "reason", last)))


_LIVE_PROCS = set()


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


# ============================================================== small files several at a time
# Media of a catalog and other small files spend more time on the request than on the
# bytes, so up to PAR_WORKERS of them are fetched at once. Big files and archives that
# are unpacked stay one by one (as before), so the speed of a big file is not shared.
PAR_MAX = 2 * 1024 * 1024
PAR_WORKERS = 3


def par_ok(dest, entry, target):
    if entry.is_dir or entry.size is None or entry.size > PAR_MAX:
        return False
    kind = arc_kind(entry)
    if kind and kind in getattr(dest, "unpack", ()):
        return False
    if target in getattr(dest, "present", {}):
        return False
    if entry.zip_file is not None:
        info = entry.ref
        # a file inside a zip is read with one request of its own (the shared archive
        # object reads one file at a time): only plain and deflate files, as zip tools make
        if (not isinstance(info, zipfile.ZipInfo) or info.compress_type not in (0, 8)
                or info.flag_bits & 1 or entry.zip_file.size is None):
            return False
    return True


class _FileProgress:
    """The progress of one file of a parallel batch: counts its own bytes, stops on Cancel."""
    def __init__(self, main, stop):
        self.main, self.stop, self.n = main, stop, 0

    def update(self, n=0, force=False):
        if self.stop.is_set():
            raise KeyboardInterrupt
        self.n += n
        self.main.update(n, force)


class _ZipUrls:
    """One link per archive for all its small files (Yandex Disk and pCloud give a link with
    an API request), asked again after a failure: links expire."""
    def __init__(self, src):
        self.src, self.lock, self.urls = src, threading.Lock(), {}

    def get(self, zentry, fresh=False):
        with self.lock:
            key = id(zentry)
            if fresh or key not in self.urls:
                self.urls[key] = self.src.download_request(zentry)
            return self.urls[key]


def member_small(zurls, entry):
    """A small file inside a zip with one Range request, unpacked in memory."""
    last = None
    for attempt in range(RETRIES + 1):
        try:
            url, headers = zurls.get(entry.zip_file, fresh=attempt > 0)
            data, _final = cat_zip_member(url, headers, entry.zip_file.size, entry.ref)
            return data
        except KeyboardInterrupt:
            raise
        except LinkError as e:
            if str(e) == t("zip_no_range"):
                raise
            last = e
        except (zlib.error, urllib.error.URLError, socket.timeout, ConnectionError, OSError) as e:
            last = e
        if attempt < RETRIES:
            time.sleep(3 + attempt * 5)
    raise LinkError(str(getattr(last, "reason", last)))


def rcat_bytes(data, remote_path):
    rb = rclone_bin()
    proc = None
    errf = tempfile.TemporaryFile()
    try:
        proc = subprocess.Popen([rb, "--config", RCLONE_CONF, "rcat", "--size", str(len(data)), remote_path],
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errf)
        _LIVE_PROCS.add(proc)
        proc.stdin.write(data)
        proc.stdin.close()
        rc = proc.wait(timeout=1800)
        if rc != 0:
            errf.seek(0)
            raise LinkError("rclone: " + _last_line(errf.read().decode("utf-8", "replace")))
    except (OSError, subprocess.SubprocessError) as e:
        _kill(proc)
        raise LinkError(str(e))
    finally:
        _LIVE_PROCS.discard(proc)
        errf.close()


def par_transfer(src, dest, entry, target, fp, zurls):
    if entry.zip_file is None:
        dest.transfer(src, entry, target, fp)
        return
    data = member_small(zurls, entry)
    if fp.stop.is_set():
        raise KeyboardInterrupt
    if dest.kind == "cloud":
        last = None
        for attempt in range(RETRIES + 1):
            try:
                rcat_bytes(data, target)
                break
            except LinkError as e:
                last = e
                if attempt < RETRIES:
                    time.sleep(3 + attempt * 5)
        else:
            raise last
    else:
        tmp = target + ".unzip"
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, target)
        except OSError as e:
            _rm(tmp)
            if e.errno == errno.ENOSPC:
                NO_SPACE["hit"] = True
            raise LinkError(str(e))
    fp.update(len(data))


def run_download(src, plan, dest, url, web=False, quiet=False, confirm=None, start=None, before_reload=None):
    """Returns process exit code."""
    # before start() the lock is not ours: do not touch another download's progress
    pre_web = web and start is None
    if dest.kind == "cloud" and "zip" in dest.unpack:
        plan = expand_zips(src, plan)
    todo, skipped = dest.classify(plan)
    if not todo:
        print(t("nothing_to_do"))
        if before_reload is not None and before_reload():
            es_reload_games()
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
    stop = threading.Event()
    zurls = _ZipUrls(src)
    state = {"ok": 0, "fail": 0, "streak": 0, "halt": False}

    def file_failed(rel, e):
        con("\n" + t("file_failed", path=rel, err=e) + "\n")
        log(t("log_error", err="%s: %s" % (rel, e)))

    def run_batch(batch):
        """batch: [(i, entry, rel, target)] of small files -> fetched PAR_WORKERS at a time.
        The results are counted like the one-by-one loop does (3 failures in a row stop)."""
        jobs = list(batch)
        jlock = threading.Lock()
        results = []          # (i, rel, error or None), in the order they finish
        rcond = threading.Condition()

        def worker():
            while not stop.is_set():
                with jlock:
                    if not jobs or state["halt"]:
                        return
                    i, entry, rel, target = jobs.pop(0)
                    progress.file_i = max(progress.file_i, i)
                if not quiet:
                    con("\r" + " " * 70 + "\r" + t("file_start", i=i, n=len(todo), path=rel) + "\n")
                had = dest.already(target)
                fp = _FileProgress(progress, stop)
                err = None
                try:
                    par_transfer(src, dest, entry, target, fp, zurls)
                    # a restarted transfer re-reads bytes: count this file exactly once
                    progress.update(max(0, entry.size - had) - fp.n)
                except KeyboardInterrupt:
                    return
                except LinkError as e:
                    err = e
                except Exception as e:            # never leave the batch waiting for a dead thread
                    err = LinkError(str(e))
                with rcond:
                    results.append((i, rel, err))
                    rcond.notify()

        threads = [threading.Thread(target=worker, daemon=True) for _ in range(min(PAR_WORKERS, len(jobs)))]
        for th in threads:
            th.start()
        seen = 0
        try:
            while True:
                with rcond:
                    while seen < len(results):
                        _i, rel, err = results[seen]
                        seen += 1
                        if err is None:
                            state["ok"] += 1
                            state["streak"] = 0
                        else:
                            state["fail"] += 1
                            state["streak"] += 1
                            file_failed(rel, err)
                            if "No space" in str(err) or NO_SPACE["hit"] or state["streak"] >= 3:
                                if state["streak"] >= 3 and not state["halt"]:
                                    con(t("too_many_fail") + "\n")
                                state["halt"] = True
                    if not any(th.is_alive() for th in threads) and seen >= len(results):
                        break
                    rcond.wait(0.3)     # short waits: "Cancel" (SIGTERM) is handled in this thread
                progress.update(0, force=True)
        except KeyboardInterrupt:
            stop.set()
            for proc in list(_LIVE_PROCS):
                _kill(proc)
            end = time.time() + 5
            for th in threads:
                th.join(max(0.1, end - time.time()))
            raise

    try:
        i = 0
        while i < len(todo):
            entry, rel, target = todo[i]
            if par_ok(dest, entry, target):
                batch = []
                while i < len(todo) and par_ok(dest, todo[i][0], todo[i][2]):
                    batch.append((i + 1,) + tuple(todo[i]))
                    i += 1
                if len(batch) > 1:
                    state.update(ok=ok, fail=fail, streak=streak)
                    run_batch(batch)
                    ok, fail, streak = state["ok"], state["fail"], state["streak"]
                    if state["halt"]:
                        break
                    continue
                i -= 1          # a single small file: as before
            i += 1
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
                file_failed(rel, e)
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
    changed = before_reload() if before_reload is not None else 0
    reloaded = (ok or changed) and dest.kind != "cloud" and es_reload_games()
    if ok and not quiet:
        if dest.kind == "cloud":
            con(t("cloud_done", dest=dest.label) + "\n")
        else:
            # Recalbox notices a changed gamelist.xml itself and offers to reload it
            hint = "es_hint_recalbox" if changed and ROMS_DIR.startswith("/recalbox") else "es_hint"
            con(t("es_reloaded" if reloaded else hint) + "\n")
    con_drain()
    return 0 if fail == 0 else 1


# ============================================================== game catalog
# A folder with an EmulationStation gamelist.xml is shown as a game catalog:
# names, descriptions, pictures. Only the chosen games are downloaded, each with
# its own media (only the kinds the user wants), and their entries are added to
# roms/<system>/gamelist.xml on the device - the games show up with covers and
# descriptions without scraping.
CAT_MEDIA_TAGS = ("image", "thumbnail", "marquee", "wheel", "boxart", "boxback", "cartridge",
                  "titleshot", "screenshot", "fanart", "mix", "map", "bezel", "video",
                  "manual", "magazine")
# what "Replace description" takes from the collection (the name, favorite and play count stay)
CAT_DESC_TAGS = ("desc", "genre", "developer", "publisher", "releasedate", "players")
CAT_SKIP_DIRS = {"media", "images", "videos", "manuals", "downloaded_images", "downloaded_videos"}
CAT_LIST_EXT = (".m3u", ".cue", ".gdi", ".ccd")
CAT_PREVIEW_MAX = 8 * 1024 * 1024


def cat_norm(p):
    """'./a/b.zip' -> 'a/b.zip' (paths in gamelist.xml are relative to its folder)."""
    p = (p or "").strip().replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    return p.strip("/")


def _nfc(s):
    return unicodedata.normalize("NFC", s).lower()


def cat_find(base, path):
    """The Entry a gamelist path points to (case and Unicode form may differ)."""
    raw = (path or "").strip()
    if not raw or raw.startswith("/") or re.match(r"^[A-Za-z]:", raw):
        return None
    rel = cat_norm(raw)
    if not rel or ".." in rel.split("/"):
        return None
    cur = base
    for part in rel.split("/"):
        if part == ".":
            continue
        if not cur.is_dir:
            return None
        kids = cur.children
        nxt = ([c for c in kids if c.name == part] or [c for c in kids if c.name.lower() == part.lower()]
               or [c for c in kids if _nfc(c.name) == _nfc(part)])
        if not nxt:
            return None
        cur = nxt[0]
    return cur


def cat_rel(base, e):
    """Path of e relative to the catalog folder."""
    pre = base.rel.rstrip("/")
    return e.rel[len(pre) + 1:] if pre else e.rel


def cat_gamelist(d):
    return [c for c in d.children if not c.is_dir and c.name.lower() == "gamelist.xml"]


def cat_find_dir(start, src, depth=3):
    """The folder with gamelist.xml: start itself or a folder below it (a .zip is opened)."""
    if not start.is_dir:
        if not is_zip(start):
            return None
        start = zip_view(src, start)
    found = _cat_bfs(start, depth)
    if found is not None:
        return found
    # a collection packed into one big zip (archive.org items): look inside it,
    # but only when there are just a few - a folder of zipped games is not that
    zips = []

    def walk(d, lvl):
        for c in d.children:
            if c.is_dir and lvl < 2 and c.name.lower() not in CAT_SKIP_DIRS:
                walk(c, lvl + 1)
            elif not c.is_dir and is_zip(c) and (c.size or 0) >= 1024 * 1024:
                zips.append(c)
    walk(start, 0)
    if 0 < len(zips) <= 3:
        for z in sorted(zips, key=lambda c: -(c.size or 0)):
            found = _cat_bfs(zip_view(src, z), depth)
            if found is not None:
                return found
    return None


def _cat_bfs(start, depth):
    queue = [(start, 0)]
    while queue:
        d, lvl = queue.pop(0)
        if cat_gamelist(d):
            return d
        if lvl < depth:
            queue += [(c, lvl + 1) for c in sorted_children(d)
                      if c.is_dir and c.name.lower() not in CAT_SKIP_DIRS]
    return None


def cat_read(src, entry, limit):
    if entry.size is not None and entry.size > limit:
        raise LinkError(t("cat_too_big", name=entry.name))
    with open_stream(src, entry) as f:
        data = f.read(limit + 1)
    if len(data) > limit:
        raise LinkError(t("cat_too_big", name=entry.name))
    return data


def cat_parse(data):
    """gamelist.xml -> root element. Files edited by hand often have a stray '&' or
    control characters: those are fixed instead of giving up."""
    try:
        return ET.fromstring(data)
    except ET.ParseError:
        pass
    text = data.decode("utf-8", "replace") if isinstance(data, bytes) else data
    text = re.sub(r"^<\?xml[^>]*\?>", "", text.lstrip("﻿ \r\n\t"))
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", text)
    text = re.sub(r"&(?!#\d+;|#x[0-9a-fA-F]+;|[A-Za-z][A-Za-z0-9]*;)", "&amp;", text)
    try:
        return ET.fromstring(text)
    except ET.ParseError as e:
        raise LinkError(t("cat_bad_gamelist", err=e))


def cat_open(src, root, rel):
    """-> (catalog folder Entry, gamelist root element)."""
    start = find_entry(root, rel, src) if rel.strip("/") else root
    if start is None:
        raise LinkError(t("not_found"))
    base = cat_find_dir(start, src)
    if base is None:
        raise LinkError(t("cat_no_gamelist"))
    return base, cat_parse(cat_read(src, cat_gamelist(base)[0], 64 * 1024 * 1024))


def cat_base_path(base):
    """How the catalog folder is addressed in later requests ('a.zip/' = inside a.zip)."""
    if base.zip_file is not None and base.rel == base.zip_file.rel:
        return base.rel + "/"
    return base.rel


def cat_media(node, base):
    """{tag: Entry} of the media files of a game that exist on the link."""
    out = {}
    for c in node:
        if c.tag == "path" or not (c.text or "").strip():
            continue
        text = c.text.strip()
        if c.tag not in CAT_MEDIA_TAGS and not text.startswith("./"):
            continue
        if len(text) > 500 or "\n" in text:
            continue
        e = cat_find(base, text)
        if e is not None and not e.is_dir:
            out[c.tag] = e
    return out


def cat_extras_guess(base, rom):
    """Rough size of the files a .cue/.m3u/.gdi lists (exact list is read when downloading)."""
    stem = os.path.splitext(rom.name)[0].lower()
    parent = cat_find(base, os.path.dirname(cat_rel(base, rom))) if "/" in cat_rel(base, rom) else base
    size, seen = 0, set()

    def walk(d, lvl):
        nonlocal size
        for c in d.children:
            if c.is_dir:
                if lvl < 2 and c.name.lower() not in CAT_SKIP_DIRS:
                    walk(c, lvl + 1)
            elif c is not rom and c.name.lower().startswith(stem) and c.rel not in seen:
                seen.add(c.rel)
                size += c.size or 0
    if parent is not None and parent.is_dir:
        walk(parent, 0)
    return size


def cat_system_guess(base):
    name = base.name[:-4] if base.name.lower().endswith(".zip") else base.name
    systems = list_systems()
    exact = [s for s in systems if s == name] or [s for s in systems if s.lower() == name.lower()]
    return exact[0] if exact else None


def catalog_json(src, root, rel):
    base, xml_root = cat_open(src, root, rel)
    return cat_listing(src, base, xml_root)


def cat_listing(src, base, xml_root):
    system = cat_system_guess(base)
    sys_dir = os.path.join(ROMS_DIR, system) if system else None
    games, kinds = [], {}
    for node in xml_root:
        if node.tag != "game":
            continue
        rom = cat_find(base, node.findtext("path"))
        if rom is None:
            continue
        rel_rom = cat_rel(base, rom)
        size = rom.total if rom.is_dir else (rom.size or 0)
        if not rom.is_dir and rom.name.lower().endswith(CAT_LIST_EXT):
            size += cat_extras_guess(base, rom)
        media = {}
        for tag, e in cat_media(node, base).items():
            media[tag] = [cat_rel(base, e), e.size or 0]
            k = kinds.setdefault(tag, {"count": 0, "size": 0})
            k["count"] += 1
            k["size"] += e.size or 0
        g = {"path": rel_rom, "name": (node.findtext("name") or "").strip() or os.path.splitext(rom.name)[0],
             "file": rom.name, "size": size, "media": media}
        for key, tag in (("desc", "desc"), ("genre", "genre"), ("players", "players"),
                         ("developer", "developer"), ("publisher", "publisher"), ("lang", "lang"),
                         ("region", "region")):
            v = (node.findtext(tag) or "").strip()
            if v:
                g[key] = v
        year = (node.findtext("releasedate") or "").strip()[:4]
        if year.isdigit():
            g["year"] = year
        if sys_dir and os.path.exists(os.path.join(sys_dir, *rel_rom.split("/"))):
            g["have"] = True
        games.append(g)
    return {"service": src.title, "dir": cat_base_path(base), "title": base.name,
            "system": system, "games": games, "kinds": kinds}


def cat_list_refs(src, base, entry):
    """Files a .cue/.m3u/.gdi/.ccd refers to (for multi-disc games and CD images)."""
    try:
        data = cat_read(src, entry, 1024 * 1024)
    except LinkError:
        return []
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    ext = os.path.splitext(entry.name)[1].lower()
    names = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ext == ".m3u":
            names.append(line)
        elif ext == ".cue":
            m = re.match(r'(?i)^FILE\s+"([^"]+)"', line) or re.match(r"(?i)^FILE\s+(\S+)", line)
            if m:
                names.append(m.group(1))
        elif ext == ".gdi":
            m = re.match(r'^\d+\s+\d+\s+\d+\s+\d+\s+"([^"]+)"', line) or \
                re.match(r"^\d+\s+\d+\s+\d+\s+\d+\s+(\S+)", line)
            if m:
                names.append(m.group(1))
    if ext == ".ccd":
        stem = os.path.splitext(entry.name)[0]
        names = [stem + ".img", stem + ".sub"]
    folder = os.path.dirname(cat_rel(base, entry))
    out = []
    for n in names:
        n = n.replace("\\", "/")
        e = cat_find(base, (folder + "/" + n) if folder else n)
        if e is not None and not e.is_dir:
            out.append(e)
    return out


def cat_device_media(system_dir):
    """{rom path: set of media tags whose file exists} of roms/<system>/gamelist.xml."""
    out = {}
    p = os.path.join(system_dir, "gamelist.xml")
    try:
        with open(p, "rb") as f:
            root = cat_parse(f.read())
    except (OSError, LinkError):
        return out
    for n in root:
        if n.tag != "game":
            continue
        tags = set()
        for c in n:
            v = (c.text or "").strip()
            if c.tag in CAT_MEDIA_TAGS and v:
                f = v if v.startswith("/") else os.path.join(system_dir, *cat_norm(v).split("/"))
                if os.path.isfile(f):
                    tags.add(c.tag)
        out[cat_norm(n.findtext("path"))] = tags
    return out


def cat_plan(src, base, xml_root, game_paths, kinds, keep=None):
    """-> (plan, gamelist entries to add on the device). keep: {rom: tags} - media the
    device already has for a game: those are not downloaded (no "Replace media")."""
    want = {cat_norm(p) for p in game_paths if p}
    kinds = set(kinds)
    plan, nodes, seen = [], [], set()

    def add(e):
        if e.is_dir:
            for c in e.children:
                add(c)
            return
        r = cat_rel(base, e)
        if r not in seen:
            seen.add(r)
            plan.append((e, r))

    def copy_node(node, media, own=()):
        new = ET.Element(node.tag)
        for c in node:
            if c.tag in CAT_MEDIA_TAGS or ((c.text or "").strip().startswith("./") and c.tag != "path"):
                e = media.get(c.tag)
                if c.tag not in kinds or e is None or c.tag in own:
                    continue
                add(e)
                el = ET.SubElement(new, c.tag)
                el.text = "./" + cat_rel(base, e)
                continue
            if c.tag == "path":
                continue
            el = ET.SubElement(new, c.tag, dict(c.attrib))
            el.text, el.tail = c.text, None
            for sub in c:
                el.append(sub)
        return new

    picked = []
    for node in xml_root:
        if node.tag != "game":
            continue
        rom = cat_find(base, node.findtext("path"))
        if rom is None or cat_rel(base, rom) not in want:
            continue
        rel_rom = cat_rel(base, rom)
        want.discard(rel_rom)
        add(rom)
        if not rom.is_dir and rom.name.lower().endswith(CAT_LIST_EXT):
            for e in cat_list_refs(src, base, rom):
                add(e)
                if e.name.lower().endswith(CAT_LIST_EXT):      # an .m3u listing .cue files
                    for e2 in cat_list_refs(src, base, e):
                        add(e2)
        new = copy_node(node, cat_media(node, base), (keep or {}).get(rel_rom, ()))
        p = ET.Element("path")
        p.text = "./" + rel_rom
        new.insert(0, p)
        nodes.append(new)
        picked.append(rel_rom)
    # folder entries (name, picture) of the folders the chosen games are in
    for node in xml_root:
        if node.tag != "folder":
            continue
        d = cat_find(base, node.findtext("path"))
        if d is None or not d.is_dir:
            continue
        rel_d = cat_rel(base, d)
        if not any(r.startswith(rel_d + "/") for r in picked):
            continue
        new = copy_node(node, cat_media(node, base))
        p = ET.Element("path")
        p.text = "./" + rel_d
        new.insert(0, p)
        nodes.append(new)
    return plan, nodes


def cat_merge(system_dir, nodes, exists_fn=None, path=None, replace_media=False, replace_desc=False):
    """Adds the entries to roms/<system>/gamelist.xml. A game that is already there
    keeps its own values (play count, favorite...): only what it lacks is added.
    exists_fn(rel) tells whether a file is there (the cloud); default: on the card.
    Returns how many games were added or completed."""
    if not nodes:
        return 0
    path = path or os.path.join(system_dir, "gamelist.xml")
    if os.path.isfile(path):
        with open(path, "rb") as f:
            data = f.read()
        root = cat_parse(data) if data.strip() else ET.Element("gameList")
    else:
        root = ET.Element("gameList")
    index = {}
    for n in root:
        if n.tag in ("game", "folder"):
            index[(n.tag, cat_norm(n.findtext("path")))] = n

    def exists(p):
        p = (p or "").strip()
        if not p:
            return False
        if exists_fn is not None:
            return True if p.startswith("/") else exists_fn(cat_norm(p))
        if p.startswith("/"):
            return os.path.exists(p)
        return os.path.exists(os.path.join(system_dir, *cat_norm(p).split("/")))

    changed = 0
    for node in nodes:
        rel = cat_norm(node.findtext("path"))
        if not exists(rel):
            continue                     # the game did not arrive
        for c in list(node):
            if c.tag in CAT_MEDIA_TAGS and not exists(c.text or ""):
                node.remove(c)
        old = index.get((node.tag, rel))
        if old is None:
            root.append(node)
            index[(node.tag, rel)] = node
            changed += 1
            continue
        touched = False
        for c in node:
            cur = old.find(c.tag)
            if cur is None:
                old.append(c)
                touched = True
            elif c.tag in CAT_MEDIA_TAGS and (replace_media or not exists(cur.text or "")):
                if (cur.text or "").strip() != (c.text or "").strip():
                    cur.text = c.text
                    touched = True
            elif replace_desc and c.tag in CAT_DESC_TAGS and (cur.text or "") != (c.text or ""):
                cur.text = c.text
                touched = True
        changed += touched
    if not changed:
        return 0
    try:
        ET.indent(root, space="\t")
    except AttributeError:
        pass
    tmp = path + ".ss_tmp"
    ET.ElementTree(root).write(tmp, encoding="utf-8", xml_declaration=True)
    os.replace(tmp, path)
    return changed


# ---- catalog kept open in the web server (it imports this file): the link's file
# list and the zip's table of contents are read once; each picture is then a single
# HTTP request for exactly its bytes, so pictures load fast and in parallel.
class CatalogSession:
    def __init__(self, url, password=None):
        self.url, self.password = url, password
        self.lock = threading.Lock()
        self.src = self.root = None
        self.bases = {}           # catalog folder path -> Entry
        self.data_urls = {}       # zip path -> its download URL (after redirects)
        self.used = time.time()

    def _tree(self):
        if self.root is None:
            t0 = time.time()
            self.src, self.root = load_tree(self.url, password=self.password, quiet=True)
            # how long the service took: slow answers are usually the service's, not ours
            log(t("list_time", service=self.src.title, s="%.1f" % (time.time() - t0), n=self.root.files))
        return self.root

    def listing(self):
        # the same link opened again: the list already read is shown at once, without
        # waiting for a zip check or a picture of this link that may still be running
        if self.root is None:
            with self.lock:
                self._tree()
        self.used = time.time()
        return {"service": self.src.title, "root": self.root.to_dict(), "direct": bool(getattr(self.src, "direct", False))}

    def probe(self, rel=""):
        """Path of the folder with gamelist.xml at/under rel, or None (nothing is downloaded
        but the table of contents of at most three big zips)."""
        with self.lock:
            self.used = time.time()
            root = self._tree()
            start = find_entry(root, rel, self.src) if rel.strip("/") else root
            base = cat_find_dir(start, self.src) if start is not None else None
            if base is None:
                return None
            self.bases[cat_base_path(base)] = base
            return {"dir": cat_base_path(base), "name": base.name}

    def catalog(self, rel=""):
        with self.lock:
            self.used = time.time()
            root = self._tree()
            base, xml_root = cat_open(self.src, root, rel)
            self.bases[cat_base_path(base)] = base
            return cat_listing(self.src, base, xml_root)

    def thumb(self, folder, rel):
        """The service's small preview of a picture -> (bytes, mime), or None when there is
        none (a zip, archive.org, a share with a password, an error): then the picture itself
        is used. After three failures without a single preview they are not asked any more."""
        if not getattr(self, "thumb_ok", False) and getattr(self, "thumb_fail", 0) >= 3:
            return None
        with self.lock:
            self.used = time.time()
            root = self._tree()
            ask = getattr(self.src, "thumb_request", None)
            if ask is None:
                return None
            base = self.bases.get(folder)
            if base is None:
                base = find_entry(root, folder, self.src) if folder.strip("/") else root
                if base is not None and not base.is_dir and is_zip(base):
                    base = zip_view(self.src, base)
            e = cat_find(base, rel) if base is not None and base.is_dir else None
            if e is None or e.is_dir or e.zip_file is not None:
                return None
        _NET.quick = True
        try:
            req = ask(e)
            if not req:
                return None
            url, headers = req
            with open_url(url, headers) as resp:
                body = resp.read(CAT_THUMB_MAX + 1)
            mime = cat_img_mime(body)
            if not mime or len(body) > CAT_THUMB_MAX:
                raise LinkError("not a picture")
            self.thumb_ok = True
            return body, mime
        except Exception:
            self.thumb_fail = getattr(self, "thumb_fail", 0) + 1
            return None
        finally:
            _NET.quick = False

    def media(self, folder, rel, limit=CAT_PREVIEW_MAX, unlocked=True):
        _NET.quick = True
        try:
            return self._media(folder, rel, limit, unlocked)
        finally:
            _NET.quick = False

    def _media(self, folder, rel, limit, unlocked):
        # unlocked: a plain file (a video of a few MB) is read without holding the lock,
        # so the pictures of other games keep loading meanwhile
        plain = None
        with self.lock:
            self.used = time.time()
            root = self._tree()
            base = self.bases.get(folder)
            if base is None:
                base = find_entry(root, folder, self.src) if folder.strip("/") else root
                if base is not None and not base.is_dir and is_zip(base):
                    base = zip_view(self.src, base)
            e = cat_find(base, rel) if base is not None and base.is_dir else None
            if e is None or e.is_dir:
                raise LinkError(t("not_found"))
            if e.size is not None and e.size > limit:
                raise LinkError(t("cat_too_big", name=e.name))
            z = e.zip_file
            info = e.ref if z is not None else None
            fast = (z is not None and isinstance(info, zipfile.ZipInfo) and info.compress_type in (0, 8)
                    and not info.flag_bits & 1)
            if not fast:
                if not unlocked:
                    return cat_read(self.src, e, limit)      # plain file or unusual zip entry
                plain = e
            url, headers = (self.data_urls.get(z.rel), {}) if plain is None else ("", {})
            if url is None:
                # the archive was opened already: reuse its address (redirects done)
                rf = getattr(_ZIPS.get(id(z)), "fp", None)
                if isinstance(rf, RangeFile) and rf.url:
                    url, headers = rf.url, dict(rf.headers)
                else:
                    url, headers = self.src.download_request(z)
        if plain is not None:
            return cat_read(self.src, plain, limit)
        data = None
        for attempt in range(2):
            try:
                data, final = cat_zip_member(url, headers, z.size, info)
                with self.lock:
                    self.data_urls[z.rel] = final
                break
            except (LinkError, urllib.error.URLError, socket.timeout, ConnectionError, OSError, zlib.error):
                if attempt:
                    raise
                with self.lock:                              # the link may have expired
                    self.data_urls.pop(z.rel, None)
                    url, headers = self.src.download_request(z)
        return data


def cat_img_mime(b):
    if b[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if b[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if b[:4] == b"RIFF" and b[8:12] == b"WEBP":
        return "image/webp"
    return None


def cat_zip_member(url, headers, zip_size, info):
    """One file of a remote zip with a single Range request: its local header plus its
    compressed bytes, unpacked here. -> (data, final URL after redirects)."""
    start = info.header_offset
    end = min(zip_size or (start + 30 + 1024 + info.compress_size), start + 30 + 1024 + info.compress_size) - 1
    hdrs = dict(headers)
    hdrs["Range"] = "bytes=%d-%d" % (start, end)
    with open_url(url, hdrs) as resp:
        if getattr(resp, "status", 200) != 206:
            raise LinkError(t("zip_no_range"))
        buf = resp.read(end - start + 1)
        final = resp.geturl() or url
    if len(buf) < 30 or buf[:4] != b"PK\x03\x04":
        raise LinkError("bad zip header")
    n = int.from_bytes(buf[26:28], "little")
    m = int.from_bytes(buf[28:30], "little")
    first = 30 + n + m
    raw = buf[first:first + info.compress_size]
    if len(raw) != info.compress_size:
        hdrs["Range"] = "bytes=%d-%d" % (start + first, start + first + info.compress_size - 1)
        with open_url(final, hdrs) as resp:
            raw = resp.read(info.compress_size)
    data = raw if info.compress_type == 0 else zlib.decompress(raw, -15)
    if len(data) != info.file_size or (zlib.crc32(data) & 0xffffffff) != info.CRC:
        raise LinkError("zip member check failed")
    return data, final


def cat_merge_cloud(dest, nodes, replace_media=False, replace_desc=False):
    """Catalog into the cloud: GameROMs/<system>/gamelist.xml is fetched, completed with
    the new games and put back."""
    rc, out, _err = rclone(["lsjson", "-R", "--files-only", dest.remote], timeout=600)
    have = set()
    if rc == 0:
        try:
            have = {e["Path"] for e in json.loads(out or "[]")}
        except (ValueError, KeyError, TypeError):
            have = set()

    def exists(rel):
        return rel in have or any(h.startswith(rel + "/") for h in have)
    tmpd = tempfile.mkdtemp(prefix="ss_gamelist_")
    try:
        local = os.path.join(tmpd, "gamelist.xml")
        if "gamelist.xml" in have:
            rc, _o, err = rclone(["copyto", dest.remote + "/gamelist.xml", local], timeout=300)
            if rc != 0:
                raise LinkError(_last_line(err) or "rclone %d" % rc)
        n = cat_merge(tmpd, nodes, exists_fn=exists, path=local, replace_media=replace_media, replace_desc=replace_desc)
        if n:
            rc, _o, err = rclone(["copyto", local, dest.remote + "/gamelist.xml"], timeout=300)
            if rc != 0:
                raise LinkError(_last_line(err) or "rclone %d" % rc)
        return n
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


def merge_cloud_gamelists():
    """After "Download ROMs": gamelist.xml is not copied over the device's one (that would
    lose play counts, favorites and games that are only on this device) - the entries of
    the cloud's gamelist are merged in instead, for every synced system."""
    dirs = []
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            for line in f:
                if line.startswith("ROMS_SYNC_DIRS="):
                    val = line.split("=", 1)[1].strip().strip('"')
                    dirs = [d.strip() for d in val.split("|") if d.strip()]
    except OSError:
        return 0
    total = 0
    for name in dirs:
        local_dir = os.path.join(ROMS_DIR, name)
        if "/" in name or name in (".", "..") or not os.path.isdir(local_dir):
            continue
        tmpd = tempfile.mkdtemp(prefix="ss_gamelist_")
        try:
            cloud_copy = os.path.join(tmpd, "gamelist.xml")
            rc, _o, _e = rclone(["copyto", REMOTE_ROMS.rstrip("/") + "/" + name + "/gamelist.xml", cloud_copy],
                                timeout=300)
            if rc != 0 or not os.path.isfile(cloud_copy):
                continue                       # no gamelist in the cloud for this system
            with open(cloud_copy, "rb") as f:
                root = cat_parse(f.read())
            n = cat_merge(local_dir, [x for x in root if x.tag in ("game", "folder")])
            if n:
                total += n
                print(t("gl_merged", sys=name, n=n))
                log(t("gl_merged", sys=name, n=n).lstrip("📝 "))
        except (LinkError, OSError) as e:
            print(t("gl_merge_failed", sys=name, err=e))
            log(t("gl_merge_failed", sys=name, err=e).strip().lstrip("⚠️ "))
        finally:
            shutil.rmtree(tmpd, ignore_errors=True)
    return total


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
            print(json.dumps({"service": src.title, "root": root.to_dict(), "direct": bool(getattr(src, "direct", False))}, ensure_ascii=False))
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

    if len(argv) >= 2 and argv[0] == "--catalog-json":
        password = os.environ.get("SS_LINK_PASSWORD") or None
        try:
            src, root = load_tree(argv[1], password=password, quiet=True)
            print(json.dumps(catalog_json(src, root, argv[2] if len(argv) >= 3 else ""), ensure_ascii=False))
            return 0
        except LinkError as e:
            print(json.dumps({"error": str(e)}, ensure_ascii=False))
            return 1

    if len(argv) >= 5 and argv[0] == "--catalog-media":
        password = os.environ.get("SS_LINK_PASSWORD") or None
        try:
            src, root = load_tree(argv[1], password=password, quiet=True)
            base = find_entry(root, argv[2], src) if argv[2].strip("/") else root
            if base is not None and not base.is_dir and is_zip(base):
                base = zip_view(src, base)
            e = cat_find(base, argv[3]) if base is not None and base.is_dir else None
            if e is None or e.is_dir:
                raise LinkError(t("not_found"))
            data = cat_read(src, e, CAT_PREVIEW_MAX)
            with open(argv[4], "wb") as f:
                f.write(data)
            print(json.dumps({"ok": True, "size": len(data)}))
            return 0
        except (LinkError, OSError) as e:
            print(json.dumps({"error": str(e)}, ensure_ascii=False))
            return 1

    if argv and argv[0] == "--merge-cloud-gamelists":
        try:
            merge_cloud_gamelists()
        except LinkError as e:
            print(e)
        return 0

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
        catalog, games, kinds = None, [], []
        replace_media = replace_desc = False
        i = 2
        while i < len(argv):
            a = argv[i]
            if a in ("--dest", "--item", "--password", "--target", "--catalog", "--game", "--media") and i + 1 < len(argv):
                val = argv[i + 1]
                if a == "--dest":
                    dest_name = val
                elif a == "--item":
                    items.append(val)
                elif a == "--catalog":
                    catalog = val
                elif a == "--game":
                    games.append(val)
                elif a == "--media":
                    kinds += [k.strip() for k in val.split(",") if k.strip()]
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
            if a == "--replace-media":
                replace_media = True
            if a == "--replace-desc":
                replace_desc = True
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
        if unpack and catalog is None:
            dest.unpack = unpack_kinds()
        lock = take_lock(web)
        if lock is None:
            return 1
        if web:
            write_progress(True, 0, 0, 0, 0, 0, 0, 0)
        ticker = start_ticker('Save Sync: download from the link started', 'Save Sync: download from the link still running ({n} min)')
        try:
            src, root = load_tree(url, password=password, quiet=True)
            hook = None
            if catalog is not None:
                base, xml_root = cat_open(src, root, catalog)
                # media the device already has for a game stay, unless "Replace media"
                keep = None if replace_media or dest.kind != "device" else cat_device_media(dest.path)
                plan, nodes = cat_plan(src, base, xml_root, games, kinds, keep)
                if not plan:
                    raise LinkError(t("cat_nothing"))

                def hook(dest=dest, nodes=nodes):
                    try:
                        n = (cat_merge(dest.path, nodes, replace_media=replace_media, replace_desc=replace_desc)
                             if dest.kind == "device" else
                             cat_merge_cloud(dest, nodes, replace_media=replace_media, replace_desc=replace_desc))
                    except (LinkError, OSError) as e:
                        con(t("cat_merge_failed", err=e) + "\n")
                        log(t("cat_merge_failed", err=e).strip().lstrip("⚠️ "))
                        return 0
                    if n:
                        con(t("cat_merged", n=n) + "\n")
                        log(t("cat_merged", n=n).lstrip("📝 "))
                    return n
            else:
                entries = []
                for rel in items:
                    e = find_entry(root, rel, src)
                    if e is None:
                        raise LinkError("not found: " + rel)
                    entries.append(e)
                plan = build_plan(root, entries)
            rc = run_download(src, plan, dest, url, web=web, quiet=True, before_reload=hook)
            if rc != 130:
                notify_screen('Save Sync: download from the link finished' if rc == 0 else ('Save Sync: not enough space in the cloud for the download from the link' if dest.kind == "cloud" else 'Save Sync: not enough space on the device for the download from the link') if NO_SPACE["hit"] else 'Save Sync: download from the link failed')
            return rc
        except LinkError as e:
            print(e)
            log(t("log_error", err=str(e).splitlines()[0].lstrip("❌ ")))
            notify_screen(('Save Sync: not enough space in the cloud for the download from the link' if dest.kind == "cloud" else 'Save Sync: not enough space on the device for the download from the link') if NO_SPACE["hit"] else 'Save Sync: download from the link failed')
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
        -e "s|__SS_LANG__|en|g" \
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
# Create the ROM filter
############################################

create_roms_filter() {
    # rclone filter: the first matching rule decides. Leftovers of other systems are
    # never synced, media depends on the setting, then only the selected systems.
    local pico=false d
    IFS='|' read -ra DIRS <<< "$ROMS_SYNC_DIRS"
    for d in "${DIRS[@]}"; do
        [ "$(echo "$d" | xargs)" = "pico8" ] && pico=true
    done
    {
        echo "# ROM sync filter"
        echo "# Created automatically, do not edit by hand"
        echo ""
        echo "# Service files and leftovers of other systems (Mac, Windows, NAS)"
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
        if [ "$ROMS_SYNC_MEDIA" != "true" ] && [ "$ROMS_SYNC_MEDIA" != "video" ]; then
            echo ""
            echo "# Media folders"
            echo "- **/{images,media,videos,manuals,screenshots,thumbnails,bezels,covers,backcovers,3dboxes,fanart,marquees,miximages,miximages_v2,physicalmedia,titlescreens,wheel,boxart,snaps,downloaded_images,downloaded_videos,downloaded_media}/**"
            if [ "$pico" = true ]; then
                echo ""
                echo "# PICO-8 games are pictures (.p8.png): not excluded"
                echo "+ /pico8/**.png"
            fi
            echo ""
            echo "# Pictures"
            cat << 'EOF'
- **.png
- **.jpg
- **.jpeg
- **.gif
- **.bmp
EOF
        fi
        if [ "$ROMS_SYNC_MEDIA" != "video" ]; then
        echo ""
        echo "# Videos (only in the \"with videos\" mode)"
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
        fi
        if [ -n "$ROMS_SYNC_DIRS" ]; then
            echo ""
            echo "# Selected systems"
            for d in "${DIRS[@]}"; do
                d=$(echo "$d" | xargs)
                [ -n "$d" ] && echo "+ /$d/**"
            done
        fi
        echo ""
        echo "# Everything else"
        echo "- **"
    } > "$ROMS_FILTER_FILE"
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
        
        case "$ROMS_SYNC_MEDIA" in
            true)  echo "Media copying: ✅ NO VIDEOS" ;;
            video) echo "Media copying: ✅ WITH VIDEOS" ;;
            *)     echo "Media copying: ❌ DISABLED" ;;
        esac
        
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo ""
        echo " 1 - 📂 Select systems to upload and download"
        echo " 2 - 🖼️ Media: off → no videos → with videos"
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
        
        if find "$dir" -type f ! -name "gamelist.xml" ! -name "_info.txt" ! -name "*.dat" ! -name "*.txt" ! -name "*.log" ! -name "*.cache" ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "desktop.ini" ! -name "._*" ! -name "*.pdf" ! -name "*.jpg" ! -name "*.mp4" ! -path "*/images/*" ! -path "*/media/*" ! -path "*/videos/*" ! -path "*/manuals/*" ! -path "*/bezels/*" ! -path "*/downloaded_*" ! -path "*/__MACOSX/*" 2>/dev/null | head -1 | grep -q .; then
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
    case "$ROMS_SYNC_MEDIA" in
        true)
            ROMS_SYNC_MEDIA="video"
            echo "✅ Media: with videos"
            echo "ℹ️  Videos take a lot of space in the cloud and on the device" ;;
        video)
            ROMS_SYNC_MEDIA="false"
            echo "✅ Media: off" ;;
        *)
            ROMS_SYNC_MEDIA="true"
            echo "✅ Media: no videos" ;;
    esac
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
            sync_stats_counts
            TOTAL=$((SYNC_OK + SYNC_ERR))
            OK=$SYNC_OK
            ERR=$SYNC_ERR
            
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
    
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        SYSTEM_VERSION=$(get_system_version)
    fi
    
    # Load the config
    load_config
    
    REAL_INTERVAL=$SYNC_INTERVAL
    REAL_RETRIES=$MAX_RETRIES
    
    if [ -f "$RCLONE_PATH" ] && [ -f "$RCLONE_CONF" ]; then
        # how long the cloud takes to answer is shown too: a slow cloud is not "not connected"
        T0=$SECONDS
        if "$RCLONE_PATH" --config "$RCLONE_CONF" lsd "$REMOTE_NAME:" --contimeout 10s --timeout 15s \
            --low-level-retries 1 --retries 1 >/dev/null 2>&1; then
            T1=$((SECONDS - T0))
            if [ "$T1" -gt 3 ]; then CLOUD_STATUS="⚠ slow (${T1} s)"; else CLOUD_STATUS="✓ connected"; fi
            CLOUD_FREE=$(cloud_about | grep -i "^free" | awk '{print $2, $3}')
            [ -z "$CLOUD_FREE" ] && CLOUD_FREE=$(cloud_free_unknown)
        else
            if timeout 3 bash -c ': > /dev/tcp/1.1.1.1/443' 2>/dev/null || timeout 3 bash -c ': > /dev/tcp/8.8.8.8/443' 2>/dev/null; then
                CLOUD_STATUS="✗ not responding"
            else
                CLOUD_STATUS="✗ no internet"
            fi
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
            FILE_SIZE=$(awk -v n="$FILE_SIZE_BYTES" 'BEGIN { if (n > 1048576) printf "%.1f MB", n/1048576; else if (n > 1024) printf "%.1f KB", n/1024; else printf "%d B", n }')
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
        echo "           Save Sync - Control Panel v1.5.0"
        echo "" 
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo " 🖥️ System:          $SYSTEM (${CFW_VERSION:-unknown})"
        echo " 💾 Saves:           $SAVES_STATUS"
        echo " ☁️ $(cloud_header_label)$CLOUD_STATUS"
        echo " 📦 Free space:      $FREE (local) / $CLOUD_FREE (cloud)"
        echo " 🔄 Updated:         $LAST_SYNC_STATUS"
        echo " 📊 Statistics:      $SYNC_STATS"
        echo " 📁 Exclusions:      $EXCLUDE_DISPLAY"
        echo " ⏱️ Interval:        $INTERVAL_DISPLAY"
        echo " 🌐 Web interface:   http://$IP_ADDR:8080"
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
        echo "  9 - 🎮 Sync (now: $(sync_mode_label))"
        echo ""
        
        echo " ── INFO ──"
        echo " 10 - 📊 Statistics and logs"
        echo " 11 - 🔍 Full diagnostics"
        echo ""
        
        echo " ── SYSTEM ──"
        echo " 12 - 🔔 On-screen notifications (now: $(notify_label))"
        echo " 13 - 🗑️ Clear temporary files"
        echo " 14 - 🔄 Reboot device"
        echo " 15 - 🌐 Restart web interface"
        echo " 16 - ☁️ Change cloud"
        echo ""
        echo "──────────────────────────────────────────────────────────"
        echo "  0 - 🚪 Exit"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        read -p "Choose an action (0-16): " choice
        
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
                        echo "❌ Upload failed. Details: menu 10 (Statistics and logs)."
                    fi
                else
                    echo ""
                    echo "❌ Download failed - the upload was not run."
                    echo "   Details: menu 10 (Statistics and logs)."
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
                echo "folder) and restored in the web interface (Saves)."
                echo "With \"Do not keep\" the device makes no copies and leaves other devices' copies alone."
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
            12)
                echo ""
                echo "Now: $(notify_label)"
                echo ""
                echo "Short notifications about syncs and"
                echo "downloads. Works on Batocera and KNULLI."
                echo ""
                echo " 1 - Turn on"
                echo " 2 - Turn off"
                echo ""
                read -p "Choose (1-2): " notify_choice
                case "$notify_choice" in
                    1) NOTIFICATIONS="true" ;;
                    2) NOTIFICATIONS="false" ;;
                    *) echo "❌ Invalid choice"; pause; continue ;;
                esac
                save_config
                echo ""
                echo "✅ Notifications: $(notify_label)"
                echo ""
                pause
                ;;
            9)
                echo ""
                echo "Now: $(sync_mode_label)"
                echo ""
                echo "How to sync after a game exit:"
                echo ""
                echo " 1 - Only when changed"
                echo "     Saves changed - a sync as in the mode"
                echo "     \"After every game\". Did not change - the"
                echo "     cloud is not contacted, and changes from"
                echo "     other devices arrive at boot or after"
                echo "     a game in which the saves change."
                echo " 2 - After every game"
                echo "     Changes and deletions are sent and"
                echo "     downloaded, without listing all cloud"
                echo "     files. Good if you play on several"
                echo "     devices at the same time."
                echo " 3 - Full"
                echo "     After every game the whole list of cloud"
                echo "     files is compared, including files added"
                echo "     to the cloud by hand. The slowest."
                echo ""
                echo "At boot and on a manual run the sync"
                echo "is always full."
                echo ""
                read -p "Choose (1-3): " mode_choice
                case "$mode_choice" in
                    1) SYNC_MODE="economy" ;;
                    2) SYNC_MODE="fast" ;;
                    3) SYNC_MODE="full" ;;
                    *) echo "❌ Invalid choice"; pause; continue ;;
                esac
                save_config
                echo ""
                echo "✅ Sync: $(sync_mode_label)"
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
                echo " 🗑️  Clearing temporary files"
                echo ""
                # only what nothing needs: not locks, the web interface pid, the rclone copy, the theme
                if sync_busy || pgrep -f "download_roms\.sh|upload_roms\.sh|link_download\.py" >/dev/null 2>&1; then
                    echo "⏳ A sync or a download is running now - clear the files later."
                else
                    CLEAN_OPS=""
                    for p in /tmp/save_sync_result.* /tmp/save_sync_progress.json /tmp/save_sync_progress.log /tmp/save_sync_stage.json /tmp/save_sync_op.json; do
                        [ -e "$p" ] && CLEAN_OPS="$CLEAN_OPS $p"
                    done
                    CLEAN_RCL=""
                    for p in /tmp/rclone.zip /tmp/rclone-*-linux-*; do
                        [ -e "$p" ] && CLEAN_RCL="$CLEAN_RCL $p"
                    done
                    CLEAN_CACHE=""
                    [ -d /tmp/save_sync_catalog_cache ] && CLEAN_CACHE=/tmp/save_sync_catalog_cache
                    CLEAN_ALL="$CLEAN_CACHE$CLEAN_OPS$CLEAN_RCL"
                    if [ -z "$CLEAN_ALL" ]; then
                        echo "✅ There are no temporary files."
                    else
                        clean_size() {
                            local kb
                            kb=$(du -sk $1 2>/dev/null | awk '{s+=$1} END {print s+0}')
                            if [ "$kb" -ge 1024 ]; then echo "$((kb / 1024)) MB"; else echo "$kb KB"; fi
                        }
                        echo "Will be removed:"
                        [ -n "$CLEAN_CACHE" ] && echo "  • game catalog cache: $(clean_size "$CLEAN_CACHE")"
                        [ -n "$CLEAN_OPS" ] && echo "  • files of finished operations"
                        [ -n "$CLEAN_RCL" ] && echo "  • leftovers of the rclone installation"
                        echo "Total: $(clean_size "$CLEAN_ALL")"
                        echo ""
                        echo "Locks, the running web interface and the settings are not touched."
                        echo ""
                        read -p "Continue? (y/n): " clean_confirm
                        if [ "$clean_confirm" = "y" ] || [ "$clean_confirm" = "Y" ]; then
                            rm -rf $CLEAN_ALL 2>/dev/null
                            echo "✅ Temporary files removed"
                        else
                            echo "Cancelled"
                        fi
                    fi
                fi
                echo ""
                pause
                ;;
            14)
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
            15)
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
            16)
                echo ""
                echo "Now: $(cloud_label "$RCLONE_CONF")"
                echo ""
                echo "Change the cloud for saves and ROMs."
                echo "The old cloud is not changed: everything stays there."
                echo ""
                if sync_busy; then
                    echo "⚠️  A sync is running now."
                    echo "   If the old cloud does not respond, it can take long."
                    read -p "Stop it and change the cloud? (y/n): " stop_now
                    if [ "$stop_now" != "y" ] && [ "$stop_now" != "Y" ]; then
                        echo "❌ Cancelled. The cloud was not changed."
                        echo ""
                        pause
                        continue
                    fi
                    echo "⏹️  Stopping the sync..."
                    if ! stop_sync; then
                        echo "❌ Could not stop the sync. Try again later."
                        echo ""
                        pause
                        continue
                    fi
                    echo "✅ The sync is stopped."
                    echo ""
                fi
                NEW_CONF="$RCLONE_CONF.new"
                rm -f "$NEW_CONF"
                # the previous cloud is kept in rclone.conf.bak: it can be switched back to
                PREV_CONF="$RCLONE_CONF.bak"
                cloud_src=1
                if [ -f "$PREV_CONF" ] && grep -q "^\[$REMOTE_NAME\]" "$PREV_CONF" \
                   && [ "$(cat "$PREV_CONF")" != "$(cat "$RCLONE_CONF" 2>/dev/null)" ]; then
                    echo " 1 - Connect another cloud"
                    echo " 2 - Go back to the previous one: $(cloud_label "$PREV_CONF")"
                    echo " 0 - Cancel"
                    echo ""
                    read -p "Choose (0-2): " cloud_src
                    if [ "$cloud_src" != "1" ] && [ "$cloud_src" != "2" ]; then
                        echo "❌ Cancelled. The cloud was not changed."
                        echo ""
                        pause
                        continue
                    fi
                fi
                if [ "$cloud_src" = "2" ]; then
                    cp -f "$PREV_CONF" "$NEW_CONF"
                    chmod 600 "$NEW_CONF"
                elif ! ask_cloud_config "$NEW_CONF" cancel; then
                    rm -f "$NEW_CONF"
                    pause
                    continue
                fi
                echo "Checking the connection..."
                if ! cloud_check "$NEW_CONF"; then
                    rm -f "$NEW_CONF"
                    echo "❌ Could not connect. The cloud was not changed."
                    [ -n "$CLOUD_ERR" ] && echo "   Reason: $CLOUD_ERR"
                    echo ""
                    pause
                    continue
                fi
                echo "✅ Connected."
                echo ""
                echo "What to do with the saves:"
                echo ""
                echo " 1 - Make the cloud a copy of this device"
                echo "     The saves in the cloud become the same"
                echo "     as here: missing ones are sent, different"
                echo "     ones replaced, extra ones deleted."
                echo "     For the first device."
                echo " 2 - Merge saves with the cloud"
                echo "     Others' are downloaded, ours sent,"
                echo "     nothing deleted. For the other devices,"
                echo "     when the cloud is already filled."
                echo " 0 - Cancel"
                echo ""
                read -p "Choose (0-2): " cloud_mode
                if [ "$cloud_mode" != "1" ] && [ "$cloud_mode" != "2" ]; then
                    rm -f "$NEW_CONF"
                    echo "❌ Cancelled. The cloud was not changed."
                    echo ""
                    pause
                    continue
                fi
                if [ "$cloud_mode" = "1" ]; then
                    echo ""
                    echo "⚠️  The GameSaves folder in the new cloud becomes"
                    echo "    a copy of this device's saves. Saves of systems"
                    echo "    this device has no games for are not touched."
                    read -p "Continue? (y/n): " confirm
                    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                        rm -f "$NEW_CONF"
                        echo "❌ Cancelled. The cloud was not changed."
                        echo ""
                        pause
                        continue
                    fi
                fi
                # the previous settings stay in rclone.conf.bak
                cp -f "$RCLONE_CONF" "$RCLONE_CONF.bak" 2>/dev/null
                mv -f "$NEW_CONF" "$RCLONE_CONF"
                chmod 600 "$RCLONE_CONF"
                # the memory of the last sync belongs to the old cloud
                rm -f "$DATA_DIR/.sync_base.json"
                if [ -f "$STATE_FILE" ]; then
                    sed -i -e '/^PENDING_UPLOAD=/d' -e '/^MARKER_DONE=/d' "$STATE_FILE"
                fi
                "$RCLONE_PATH" --config "$RCLONE_CONF" mkdir "$REMOTE" >/dev/null 2>&1
                load_config
                echo ""
                if [ "$cloud_mode" = "1" ]; then
                    echo "🔄 Filling the cloud with this device's saves..."
                    SS_RCLONE="$RCLONE_PATH" SS_EXCLUDED="$EXCLUDED_SYSTEMS" SS_RETRIES="$MAX_RETRIES" \
                        python3 "$ENGINE_SCRIPT" sync --mirror --verbose
                    RC=$?
                    MODE_TXT="copy of this device"
                else
                    echo "🔄 Syncing with the cloud..."
                    bash "$DOWNLOAD_SCRIPT" --verbose
                    RC=$?
                    MODE_TXT="merge"
                fi
                echo ""
                if [ $RC -eq 0 ]; then
                    log_msg "Cloud changed: $(cloud_label "$RCLONE_CONF") ($MODE_TXT)"
                    echo "✅ Cloud changed: $(cloud_label "$RCLONE_CONF")"
                    echo "   Switch the other devices the same way,"
                    echo "   choosing \"Merge saves with the cloud\"."
                else
                    log_msg "Cloud changed: $(cloud_label "$RCLONE_CONF") ($MODE_TXT) - the sync did not finish"
                    echo "⚠️  The cloud was changed, but the sync did not finish."
                    echo "   It runs again after the next game or at boot,"
                    echo "   nothing is lost."
                fi
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
    echo " 🌐 Save Sync - Web Interface v1.5.0"
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
    for key, name in (("yandex", "Yandex Disk"), ("mail.ru", "Mail.ru Cloud"), ("pcloud", "pCloud"),
                      ("koofr", "Koofr"), ("fastmail", "Fastmail")):
        if key in url:
            return name
    return "WebDAV" if url else ""


PREV_CONF = RCLONE_CONF + ".bak"     # the previous cloud, kept when the cloud is changed
CLOUD_SWITCH_LOCK = threading.Lock()


def cloud_label(conf_path):
    """Service and login of an rclone config, as the control center shows it."""
    try:
        with open(conf_path) as f:
            conf = f.read()
    except OSError:
        return ""
    m = re.search(r"^user = (.*)$", conf, re.M)
    user = m.group(1).strip() if m else ""
    m = re.search(r"^url = (.*)$", conf, re.M)
    url = m.group(1).strip() if m else ""
    name = ""
    if re.search(r"^type = mega", conf, re.M):
        name = "Mega"
    else:
        for key, n in (("yandex", "Yandex Disk"), ("mail.ru", "Mail.ru Cloud"), ("pcloud", "pCloud"), ("koofr", "Koofr"), ("fastmail", "Fastmail")):
            if key in url:
                name = n
                break
        if not name:
            name = ("WebDAV " + url) if url else "WebDAV"
    return name + (" (%s)" % user if user else "")


def prev_cloud_ok():
    """The previous cloud can be switched to: its config is there, has the "cloud"
    section and is not the same as the current one."""
    try:
        with open(PREV_CONF) as f:
            prev = f.read()
    except OSError:
        return False
    try:
        with open(RCLONE_CONF) as f:
            cur = f.read()
    except OSError:
        cur = ""
    return bool(re.search(r"^\[cloud\]\s*$", prev, re.M)) and prev.rstrip("\n") != cur.rstrip("\n")


def cloud_check_conf(conf_path):
    """Connection check with an rclone config -> "" or the reason in words."""
    try:
        r = subprocess.run([RCLONE_PATH, "--config", conf_path, "lsd", "cloud:",
                            "--contimeout", "10s", "--timeout", "15s",
                            "--low-level-retries", "1", "--retries", "1"],
                           capture_output=True, text=True, timeout=40)
    except subprocess.TimeoutExpired:
        return "the server does not respond - check the internet connection and the server address"
    except OSError as e:
        return str(e)
    if r.returncode == 0:
        return ""
    out = r.stderr or ""
    if re.search(r"401 Unauthorized|403 Forbidden|[Cc]redentials|password is incorrect|invalid username or password", out):
        return "wrong username or password (this service may need an app password)"
    if re.search(r"no such host|i/o timeout|connection refused|network is unreachable|dial tcp", out):
        return "the server does not respond - check the internet connection and the server address"
    if re.search(r"connection reset|broken pipe|EOF|TLS handshake|deadline exceeded|timeout awaiting|Client\.Timeout", out):
        return "the server dropped the connection or did not answer in time - looks like a temporary problem of the service, try again later"
    if re.search(r"\b429\b|Too Many Requests", out):
        return "the service temporarily limits requests - try again later"
    if re.search(r" 50[0234] |Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout", out):
        return "the service is temporarily down (an error on its side) - try again later"
    lines = [l for l in out.splitlines() if l.strip()]
    last = lines[-1] if lines else "rclone: %d" % r.returncode
    return "the cloud answered with an error: " + re.sub(r"^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]+ [A-Z]+ *: ", "", last)[:200]


def saves_sync_busy():
    """True while a save sync holds its lock (the same check as in the control center)."""
    import fcntl
    for p in ("/tmp/save_sync_download.lock", "/tmp/save_sync_upload.lock"):
        try:
            with open(p, "a") as f:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f, fcntl.LOCK_UN)
        except BlockingIOError:
            return True
        except OSError:
            pass
    return False


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

            # values go into a file that the sync scripts load as shell code:
            # numbers only digits, switches only true/false, text without
            # characters that would break out of the quotes
            int_def = {"SYNC_INTERVAL": 0, "MAX_RETRIES": 3, "CONFLICT_KEEP_DAYS": 3,
                       "MIN_FREE_KB": 51200, "MAX_LOG_SIZE": 102400}
            bool_def = {"NOTIFICATIONS": "true", "SKIP_UNCHANGED": "true",
                        "ROMS_SYNC_MEDIA": "false", "LOG_ENABLED": "true",
                        "WEB_SHOW_ROMS": "true", "WEB_SHOW_LINK": "true"}
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
                    # ROM media has a third mode: with videos
                    allowed = ("true", "false", "video") if key == "ROMS_SYNC_MEDIA" else ("true", "false")
                    current[key] = val if val in allowed else bool_def[key]
                elif key == "LOG_LEVEL":
                    current[key] = val if val in ("info", "debug") else "info"
                else:
                    current[key] = re.sub(r'["$`\\\r\n]', "", val)
            if current.get("SYNC_MODE") not in ("full", "fast", "economy"):
                current["SYNC_MODE"] = "full" if current.get("SKIP_UNCHANGED") == "false" else "economy"
            with open(CONFIG_FILE, "w") as f:
                f.write("# ========================================\n")
                f.write("# Save Sync v1.5.0 - Main config\n")
                f.write("# ========================================\n\n")
                f.write("# ---- SYNC SETTINGS ----\n")
                f.write(f'SYNC_INTERVAL="{current.get("SYNC_INTERVAL", 0)}"\n')
                f.write(f'MAX_RETRIES="{current.get("MAX_RETRIES", 3)}"\n')
                f.write(f'CONFLICT_KEEP_DAYS="{current.get("CONFLICT_KEEP_DAYS", 3)}"\n')
                f.write(f'NOTIFICATIONS="{current.get("NOTIFICATIONS", "true")}"\n')
                f.write(f'SYNC_MODE="{current.get("SYNC_MODE", "economy")}"\n')
                f.write(f'MIN_FREE_KB="{current.get("MIN_FREE_KB", 51200)}"\n\n')
                f.write("# ---- ROM SETTINGS ----\n")
                f.write(f'ROMS_SYNC_DIRS="{current.get("ROMS_SYNC_DIRS", "")}"\n')
                f.write(f'ROMS_SYNC_MEDIA="{current.get("ROMS_SYNC_MEDIA", "false")}"\n')
                f.write(f'EXCLUDED_SYSTEMS="{current.get("EXCLUDED_SYSTEMS", "")}"\n\n')
                f.write("# ---- LOGGING SETTINGS ----\n")
                f.write(f'LOG_ENABLED="{current.get("LOG_ENABLED", "true")}"\n')
                f.write(f'MAX_LOG_SIZE="{current.get("MAX_LOG_SIZE", 102400)}"\n')
                f.write(f'LOG_LEVEL="{current.get("LOG_LEVEL", "info")}"\n\n')
                f.write("# ---- WEB INTERFACE ----\n")
                f.write(f'WEB_SHOW_ROMS="{current.get("WEB_SHOW_ROMS", "true")}"\n')
                f.write(f'WEB_SHOW_LINK="{current.get("WEB_SHOW_LINK", "true")}"\n')
                f.write(f'WEB_LINKS="{current.get("WEB_LINKS", "")}"\n')
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
        # Recalbox 10 has ID=buildroot in /etc/os-release: recognised by its version file
        if os.path.exists("/etc/recalbox-release") or os.path.exists("/recalbox/recalbox") or os.path.exists("/recalbox/recalbox.version"):
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
        """The same filter as create_roms_filter() in the control panel."""
        config = self.read_config()
        dirs = [d.strip() for d in config.get("ROMS_SYNC_DIRS", "").split("|") if d.strip()]
        mode = config.get("ROMS_SYNC_MEDIA", "false")
        media = mode in ("true", "video")
        lines = ["# ROM sync filter", "# Created automatically, do not edit by hand", "", "# Service files and leftovers of other systems (Mac, Windows, NAS)"]
        lines += ['- **/_info.txt', '- .DS_Store', '- Thumbs.db', '- desktop.ini', '- ._*', '- *:Zone.Identifier', '- *.crdownload', '- __MACOSX/**', '- @eaDir/**', '- #recycle/**', '- $RECYCLE.BIN/**', '- System Volume Information/**', '- .Trash-*/**', '- .Trashes/**', '- .Spotlight-V100/**', '- .fseventsd/**']
        if not media:
            lines += ["", "# Media folders", "- **/{images,media,videos,manuals,screenshots,thumbnails,bezels,covers,backcovers,3dboxes,fanart,marquees,miximages,miximages_v2,physicalmedia,titlescreens,wheel,boxart,snaps,downloaded_images,downloaded_videos,downloaded_media}/**"]
            if "pico8" in dirs:
                lines += ["", "# PICO-8 games are pictures (.p8.png): not excluded", "+ /pico8/**.png"]
            lines += ["", "# Pictures"] + ['- **.png', '- **.jpg', '- **.jpeg', '- **.gif', '- **.bmp']
        if mode != "video":
            lines += ["", "# Videos (only in the \"with videos\" mode)"] + ['- **.mp4', '- **.avi', '- **.webm', '- **.wmv', '- **.mkv', '- **.mov', '- **.m4v', '- **.mpg', '- **.mpeg']
        if dirs:
            lines += ["", "# Selected systems"] + ["+ /%s/**" % d for d in dirs]
        lines += ["", "# Everything else", "- **"]
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
                    stats["sync"]["ok"] = len(re.findall(r"Saves downloaded|Saves uploaded|(?:Manual s|S)ync \(", content))
                    # "(изменений нет)" / "(no changes)": the sync ran fine, but everything already matched
                    # with changes = the log line says what was moved ("(sent: 1, ...)"); a plain line or "(no changes)" means nothing was transferred
                    noted = len(re.findall(r"(?:Saves downloaded|Saves uploaded|(?:Manual s|S)ync) \(", content))
                    empty = len(re.findall(r"(?:Saves downloaded|Saves uploaded|(?:Manual s|S)ync) \(no changes\)", content))
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

    # the icon of the page and of a home screen shortcut (kept here, no files on the card)
    APP_FILES = {
        "/icon-192.png": ("image/png", "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"),
        "/icon-512.png": ("image/png", "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"),
        "/manifest.webmanifest": ("application/manifest+json", '{"name":"Save Sync","short_name":"Save Sync","start_url":"/","display":"standalone","background_color":"#0A0E17","theme_color":"#1565C0","icons":[{"src":"/icon-192.png","sizes":"192x192","type":"image/png"},{"src":"/icon-512.png","sizes":"512x512","type":"image/png"}]}'),
    }

    def send_app_file(self, path):
        import base64
        ctype, data = self.APP_FILES[path]
        body = data.encode("utf-8") if ctype.startswith("application/") else base64.b64decode(data)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.request_allowed(False):
            self.send_error(403)
            return
        if self.path == "/" or self.path == "/index.html":
            self.send_html(HTML)
            return
        if self.path in self.APP_FILES:
            self.send_app_file(self.path)
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
        elif path == "/api/cloud/prev":
            self.api_cloud_prev()
        elif path == "/api/sections":
            self.send_json(self._sections())
        elif path == "/api/links/saved":
            self.send_json({"links": self._saved_links()})
        elif path == "/api/config/export":
            self.api_config_export()
        elif path == "/api/link/catalog_file":
            self.api_link_catalog_file(parsed.query)
        elif path == "/api/link/catalog_local":
            self.api_link_catalog_local(parsed.query)
        elif path == "/api/link/catalog_cover":
            self.api_link_catalog_cover(parsed.query)
        elif path == "/api/link/catalog_pic":
            self.api_link_catalog_cover(parsed.query, thumb=False)
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
        elif parsed.path == "/api/link/catalog":
            self.api_link_catalog()
        elif parsed.path == "/api/link/catalog_media":
            self.api_link_catalog_media()
        elif parsed.path == "/api/link/catalog_video":
            self.api_link_catalog_video()
        elif parsed.path == "/api/link/catalog_have_media":
            self.api_link_catalog_have_media()
        elif parsed.path == "/api/link/catalog_device_media":
            self.api_link_catalog_device_media()
        elif parsed.path == "/api/link/catalog_device_covers":
            self.api_link_catalog_device_covers()
        elif parsed.path == "/api/link/catalog_seen":
            self.api_link_catalog_seen()
        elif parsed.path == "/api/link/catalog_cached":
            self.api_link_catalog_cached()
        elif parsed.path == "/api/link/catalog_touch":
            self._cat_call(lambda sess, d: (sess.listing(), {"ok": True})[1])
        elif parsed.path == "/api/link/catalog_probe":
            self.api_link_catalog_probe()
        elif parsed.path == "/api/link/have":
            self.api_link_have()
        elif parsed.path == "/api/link/catalog_get":
            self.api_link_catalog_get()
        elif parsed.path == "/api/cancel":
            self.api_cancel()
        elif parsed.path == "/api/cloud/switch":
            self.api_cloud_switch()
        elif parsed.path == "/api/sections":
            self.api_sections_save()
        elif parsed.path == "/api/links/saved":
            self.api_saved_links_save()
        elif parsed.path == "/api/config/import":
            self.api_config_import()
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
        # (system_has_games: a system folder with games, not only media or leftovers)
        systems = []
        if os.path.exists(ROMS_DIR):
            for d in os.listdir(ROMS_DIR):
                path = os.path.join(ROMS_DIR, d)
                if os.path.isdir(path):
                    if system_has_games(path, d):
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

    # the web interface sections (Settings -> Sections) are kept in sync.conf; only the
    # web page uses them
    SECTION_KEYS = {"roms": ("WEB_SHOW_ROMS", True), "link": ("WEB_SHOW_LINK", True)}

    def _sections(self):
        cfg = self.read_config()
        out = {}
        for name, (key, default) in self.SECTION_KEYS.items():
            v = (cfg.get(key) or "").lower()
            out[name] = (v == "true") if v in ("true", "false") else default
        return out

    def api_sections_save(self):
        data = self._json_body()
        changes = {}
        for name, (key, _default) in self.SECTION_KEYS.items():
            if isinstance(data.get(name), bool):
                changes[key] = "true" if data[name] else "false"
        if changes and not self.save_config(changes):
            self.send_json({"error": "sync.conf"})
            return
        self.send_json(self._sections())

    # saved links of the web interface: WEB_LINKS in sync.conf, "name,url,folder" URL-encoded,
    # separated by spaces. Passwords are not saved: a link with one asks for it again.
    SAVED_MAX = 50

    def _saved_links(self):
        out = []
        for item in (self.read_config().get("WEB_LINKS") or "").split():
            parts = [urllib.parse.unquote(x) for x in item.split(",")]
            if len(parts) >= 2 and parts[1].startswith(("http://", "https://")):
                out.append({"name": parts[0], "url": parts[1], "dir": parts[2] if len(parts) > 2 else ""})
        return out

    # ---- what is new in a saved catalog. .sync_state holds, per saved catalog, a print of
    # every game seen at the last opening: 8 hex of its path + 4 hex of path and size, so
    # a new game and a changed file are told apart. Lines are changed under the same lock
    # as the sync scripts use; the cloud switch keeps them.
    STATE_PATH = os.path.join(BASE, ".sync_state")
    STATE_LOCK = "/tmp/save_sync_state.lock"

    def _state_get(self, key):
        val = None
        try:
            with open(self.STATE_PATH) as f:
                for line in f:
                    if line.startswith(key + "="):
                        val = line.split("=", 1)[1].strip()
        except OSError:
            pass
        return val

    def _state_edit(self, change):
        """change(lines) -> lines; the file is rewritten under the state lock."""
        import fcntl
        try:
            with open(self.STATE_LOCK, "w") as lk:
                fcntl.flock(lk, fcntl.LOCK_EX)
                try:
                    with open(self.STATE_PATH) as f:
                        lines = f.read().splitlines()
                except OSError:
                    lines = []
                new = change(lines)
                if new == lines:
                    return
                tmp = self.STATE_PATH + ".tmp.%d" % os.getpid()
                with open(tmp, "w") as f:
                    f.write("".join(l + "\n" for l in new))
                os.replace(tmp, self.STATE_PATH)
        except OSError:
            pass

    @staticmethod
    def _seen_key(url, folder):
        import hashlib
        folder = "" if folder in ("", "/") else folder
        return "CATALOG_SEEN_" + hashlib.sha1(("%s|%s" % (url, folder)).encode("utf-8")).hexdigest()[:10]

    @staticmethod
    def _seen_prints(games):
        import hashlib
        out = {}
        for path, size in games:
            path = str(path)
            a = hashlib.sha1(path.encode("utf-8")).hexdigest()[:8]
            out[a] = hashlib.sha1(("%s|%s" % (path, size)).encode("utf-8")).hexdigest()[:4]
        return out

    def _seen_saved(self, url, folder):
        folder = "" if folder in ("", "/") else folder
        return any(l["url"] == url and ("" if l["dir"] in ("", "/") else l["dir"]) == folder
                   for l in self._saved_links())

    def _seen_update(self, url, folder, games):
        """Remembers the games of a saved catalog; -> {new: [paths], changed: [paths]} against
        the last opening, or None (not saved, or opened for the first time)."""
        if not url or not self._seen_saved(url, folder):
            return None
        key = self._seen_key(url, folder)
        old_val = self._state_get(key) or ""
        prints = self._seen_prints(games)
        value = "1:" + "".join(a + b for a, b in sorted(prints.items()))
        self._state_edit(lambda lines: [l for l in lines if not l.startswith(key + "=")] + [key + "=" + value])
        if not old_val.startswith("1:"):
            return None
        body = old_val[2:]
        old = {body[i:i + 8]: body[i + 8:i + 12] for i in range(0, len(body) - 11, 12)}
        res = {"new": [], "changed": []}
        import hashlib
        for path, _size in games:
            a = hashlib.sha1(str(path).encode("utf-8")).hexdigest()[:8]
            if a not in old:
                res["new"].append(path)
            elif old[a] != prints[a]:
                res["changed"].append(path)
        return res

    # ---- the list of games of a saved catalog, kept on the card: shown at once when the
    # catalog is opened, while the collection is checked. Only the text (names, descriptions,
    # sizes, which media there are), no pictures. Removed with the saved link.
    LIST_DIR = os.path.join(BASE, ".catalog_cache")

    def _cat_list_file(self, url, folder):
        return os.path.join(self.LIST_DIR, self._seen_key(url, folder)[len("CATALOG_SEEN_"):] + ".json")

    def _cat_list_put(self, url, folder, data):
        try:
            os.makedirs(self.LIST_DIR, exist_ok=True)
            out = self._cat_list_file(url, folder)
            tmp = out + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
            os.replace(tmp, out)
        except (OSError, TypeError, ValueError):
            pass

    def api_link_catalog_cached(self):
        import hashlib
        data = self._json_body()
        url = (data.get("url") or "").strip()
        folder = data.get("dir") or ""
        try:
            with open(self._cat_list_file(url, folder), encoding="utf-8") as f:
                res = json.load(f)
        except (OSError, ValueError):
            self.send_json({})
            return
        if self.get_system() == "Recalbox":
            res["es_media"] = ["image", "thumbnail", "video"]
        res["sid"] = hashlib.sha1(("%s|%s" % (url, data.get("password") or "")).encode("utf-8")).hexdigest()[:16]
        res["cached"] = True
        self.send_json(res)

    def api_link_catalog_seen(self):
        """A catalog just saved: its games are remembered now, so the next opening shows
        what is new."""
        data = self._json_body()
        games = [(g[0], g[1]) for g in (data.get("games") or [])[:20000]
                 if isinstance(g, list) and len(g) == 2]
        url, folder = (data.get("url") or "").strip(), data.get("dir") or ""
        self._seen_update(url, folder, games)
        # the list of the catalog just saved: kept on the card from the last opening
        try:
            _mod, sess = self._cat_session(data)
            last = getattr(sess, "last_catalog", {}).get("" if folder == "/" else folder)
            if last and self._seen_saved(url, folder):
                self._cat_list_put(url, folder, last)
        except Exception:
            pass
        self.send_json({"ok": True})

    # ---- export / import of the settings (Settings -> Moving the settings)
    IMPORT_GROUPS = {
        "sync": ("SYNC_INTERVAL", "MAX_RETRIES", "CONFLICT_KEEP_DAYS", "NOTIFICATIONS", "SYNC_MODE", "MIN_FREE_KB"),
        "excluded": ("EXCLUDED_SYSTEMS",),
        "roms": ("ROMS_SYNC_DIRS", "ROMS_SYNC_MEDIA"),
        "web": ("WEB_SHOW_ROMS", "WEB_SHOW_LINK"),
    }

    def api_config_export(self):
        try:
            with open(CONFIG_FILE, "rb") as f:
                body = f.read()
        except OSError:
            self.send_error(404)
            return
        dev = re.sub(r"[^A-Za-z0-9_-]+", "", self._state_get("DEVICE_NAME") or "") or "device"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Disposition", 'attachment; filename="save_sync_%s.conf"' % dev)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def api_config_import(self):
        """{text: the exported file, groups: [...]} -> only those settings are taken; saved
        links ("links") are added to the ones already here."""
        data = self._json_body()
        text = str(data.get("text") or "")[:200000]
        groups = set(data.get("groups") or [])
        values = {}
        for line in text.splitlines():
            m = re.match(r'^\s*([A-Z_]+)\s*=\s*"?(.*?)"?\s*$', line)
            if m and not line.lstrip().startswith("#"):
                values[m.group(1)] = m.group(2)
        changes, added = {}, 0
        for g, keys in self.IMPORT_GROUPS.items():
            if g in groups:
                for k in keys:
                    if k in values:
                        changes[k] = values[k]
        if "links" in groups and values.get("WEB_LINKS"):
            have = self._saved_links()
            seen = {(l["url"], l["dir"]) for l in have}
            items = [",".join(urllib.parse.quote(x, safe="") for x in (l["name"], l["url"], l["dir"])) for l in have]
            for item in values["WEB_LINKS"].split():
                parts = [urllib.parse.unquote(x) for x in item.split(",")]
                if len(parts) < 2 or not parts[1].startswith(("http://", "https://")):
                    continue
                folder = parts[2] if len(parts) > 2 else ""
                if (parts[1], folder) in seen or len(items) >= self.SAVED_MAX:
                    continue
                seen.add((parts[1], folder))
                items.append(",".join(urllib.parse.quote(x, safe="") for x in (parts[0][:80], parts[1][:2000], folder[:500])))
                added += 1
            changes["WEB_LINKS"] = " ".join(items)
        if not changes:
            self.send_json({"success": False, "error": "nothing"})
            return
        if not self.save_config(changes):
            self.send_json({"success": False, "error": "sync.conf"})
            return
        if "ROMS_SYNC_DIRS" in changes:
            self.update_roms_filter()
        self.send_json({"success": True, "settings": len([k for k in changes if k != "WEB_LINKS"]), "links": added})

    def api_saved_links_save(self):
        data = self._json_body()
        items = []
        for link in (data.get("links") or [])[:self.SAVED_MAX]:
            if not isinstance(link, dict):
                continue
            url = str(link.get("url") or "").strip()[:2000]
            if not url.startswith(("http://", "https://")):
                continue
            name = str(link.get("name") or "").strip()[:80] or url
            folder = str(link.get("dir") or "").strip()[:500]
            items.append(",".join(urllib.parse.quote(x, safe="") for x in (name, url, folder)))
        if not self.save_config({"WEB_LINKS": " ".join(items)}):
            self.send_json({"error": "sync.conf"})
            return
        links = self._saved_links()
        keep = {self._seen_key(l["url"], l["dir"]) for l in links}
        self._state_edit(lambda lines: [l for l in lines if not l.startswith("CATALOG_SEEN_")
                                        or l.split("=", 1)[0] in keep])
        # the cached lists of the links removed
        try:
            for name in os.listdir(self.LIST_DIR):
                if name.endswith(".json") and "CATALOG_SEEN_" + name[:-5] not in keep:
                    os.remove(os.path.join(self.LIST_DIR, name))
        except OSError:
            pass
        self.send_json({"links": links})

    def api_cloud_prev(self):
        ok = prev_cloud_ok()
        self.send_json({"current": cloud_label(RCLONE_CONF), "prev": cloud_label(PREV_CONF) if ok else ""})

    def _busy(self):
        """A save sync, a web operation (ROMs, a conflict) or a link download is running."""
        if saves_sync_busy() or self._link_pid() is not None:
            return True
        try:
            with open(OP_FILE, "r") as f:
                return self._group_alive(int(json.load(f).get("pgid")))
        except Exception:
            return False

    def api_cloud_switch(self):
        """The current cloud and the previous one change places, like "2 - go back to the
        previous one" in the control center; the web page then runs a full sync (merge)."""
        if not CLOUD_SWITCH_LOCK.acquire(blocking=False):
            self.send_json({"success": False, "error": "A sync or download is running now - switch the cloud after it"})
            return
        new = RCLONE_CONF + ".new"
        try:
            if not prev_cloud_ok():
                self.send_json({"success": False, "error": "There is no previous cloud"})
                return
            if self._busy():
                self.send_json({"success": False, "error": "A sync or download is running now - switch the cloud after it"})
                return
            name = cloud_label(PREV_CONF)
            shutil.copyfile(PREV_CONF, new)
            os.chmod(new, 0o600)
            err = cloud_check_conf(new)
            if err:
                self.send_json({"success": False, "error": "Could not connect to {name}. The cloud was not changed. Reason: {err}".replace("{name}", name).replace("{err}", err)})
                return
            if self._busy():               # the check takes a few seconds
                self.send_json({"success": False, "error": "A sync or download is running now - switch the cloud after it"})
                return
            shutil.copyfile(RCLONE_CONF, PREV_CONF)
            os.chmod(PREV_CONF, 0o600)
            os.replace(new, RCLONE_CONF)
            os.chmod(RCLONE_CONF, 0o600)
            # the memory of the last sync belongs to the old cloud
            try:
                os.remove(os.path.join(BASE, ".sync_base.json"))
            except OSError:
                pass
            state = os.path.join(BASE, ".sync_state")
            try:
                with open(state) as f:
                    keep = [l for l in f if not l.startswith(("PENDING_UPLOAD=", "MARKER_DONE="))]
                with open(state, "w") as f:
                    f.writelines(keep)
            except OSError:
                pass
            try:
                subprocess.run([RCLONE_PATH, "--config", RCLONE_CONF, "mkdir", REMOTE_SAVES],
                               capture_output=True, timeout=40)
            except (OSError, subprocess.SubprocessError):
                pass
            with CLOUD_CHECK_LOCK:
                CLOUD_CHECK.clear()
            with CLOUD_ABOUT_LOCK:
                CLOUD_ABOUT_CACHE.clear()
            if self.read_config().get("LOG_ENABLED", "true") != "false":
                try:
                    with open(LOG_FILE, "a") as f:
                        f.write("%s %s\n" % (datetime.now().strftime("%d.%m %H:%M:%S"),
                                               "Cloud changed: {name} (merge, web interface)".replace("{name}", name)))
                except OSError:
                    pass
            self.send_json({"success": True, "current": name})
        except Exception as e:
            self.send_json({"success": False, "error": str(e)})
        finally:
            try:
                os.remove(new)
            except OSError:
                pass
            CLOUD_SWITCH_LOCK.release()

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
                config["ROMS_SYNC_MEDIA"] = {"false": "true", "true": "video"}.get(current, "false")
                if self.save_config(config):
                    self.update_roms_filter()
                    status = {"true": "no videos", "video": "with videos"}.get(config["ROMS_SYNC_MEDIA"], "off")
                    self.send_json({"success": True, "message": f"Media: {status}"})
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
        if url and os.path.exists(LINK_SCRIPT):
            try:
                mod, sess = self._cat_session(data)
            except Exception:
                mod = None                     # fall back to a separate process
            if mod is not None:
                try:
                    self.send_json(sess.listing())
                except mod.LinkError as e:
                    with type(self)._cat_lock:
                        type(self)._cat_sessions.clear()      # a wrong password is not kept
                    self.send_json({"error": str(e), "need_password": str(e) in (mod.t("password_needed"), mod.t("password_wrong"))})
                except Exception as e:
                    self.send_json({"error": str(e)})
                return
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


    # ---- game catalog: a folder with gamelist.xml shown as a list of games.
    # The catalog stays open here (link_download.py is imported): the link's file list
    # and the zip's table of contents are read once, then every picture is one small
    # request. A catalog is forgotten after 10 minutes without use.
    CAT_PIC_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
                     ".webp": "image/webp", ".bmp": "image/bmp"}
    CAT_VIDEO_TYPES = {".mp4": "video/mp4", ".m4v": "video/mp4", ".webm": "video/webm"}
    CAT_VIDEO_MAX = 40 * 1024 * 1024
    CAT_CACHE = "/tmp/save_sync_catalog_cache"
    CAT_CACHE_MAX = 50 * 1024 * 1024        # /tmp is in memory on Batocera / KNULLI
    CAT_IDLE = 600
    _cat_mod = None
    _cat_sessions = {}
    _cat_lock = threading.Lock()

    def _cat_module(self):
        cls = type(self)
        if cls._cat_mod is None:
            import importlib.util
            spec = importlib.util.spec_from_file_location("ss_link_download", LINK_SCRIPT)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            cls._cat_mod = mod
        return cls._cat_mod

    def _cat_session(self, data):
        mod = self._cat_module()
        key = ((data.get("url") or "").strip(), data.get("password") or "")
        cls = type(self)
        with cls._cat_lock:
            now = time.time()
            for k in [k for k, v in cls._cat_sessions.items() if now - v.used > self.CAT_IDLE]:
                del cls._cat_sessions[k]
            sess = cls._cat_sessions.get(key)
            if sess is None:
                # one open catalog at a time: a new link replaces the old one
                cls._cat_sessions.clear()
                sess = cls._cat_sessions[key] = mod.CatalogSession(key[0], key[1] or None)
            return mod, sess

    def _cat_call(self, fn):
        data = self._json_body()
        if not (data.get("url") or "").strip() or not os.path.exists(LINK_SCRIPT):
            self.send_json({"error": "bad request" if os.path.exists(LINK_SCRIPT) else "link_download.py not found - reinstall Save Sync"})
            return
        try:
            mod, sess = self._cat_session(data)
        except Exception as e:
            self.send_json({"error": str(e)})
            return
        try:
            self.send_json(fn(sess, data))
        except mod.LinkError as e:
            self.send_json({"error": str(e)})
        except Exception as e:
            self.send_json({"error": str(e)})

    def api_link_catalog(self):
        def run(sess, d):
            res = sess.catalog(d.get("path") or "")
            # Recalbox shows only these three: other media would be downloaded for nothing
            if self.get_system() == "Recalbox":
                res["es_media"] = ["image", "thumbnail", "video"]
            folder = res.get("dir") or ""
            # kept for the cached list of a saved catalog (written on saving it, too)
            if not hasattr(sess, "last_catalog"):
                sess.last_catalog = {}
            sess.last_catalog[folder] = {k: v for k, v in res.items() if k != "es_media"}
            if self._seen_saved(sess.url, folder):
                self._cat_list_put(sess.url, folder, sess.last_catalog[folder])
            res["sid"] = self._cat_sid(sess)
            seen = self._seen_update(sess.url, res.get("dir") or "", [(g.get("path"), g.get("size")) for g in res.get("games") or []])
            if seen is not None:
                res["seen"] = seen
            return res
        self._cat_call(run)

    def api_link_catalog_probe(self):
        self._cat_call(lambda sess, d: sess.probe(d.get("path") or "") or {})

    def _cat_cache_trim(self):
        try:
            files = [os.path.join(self.CAT_CACHE, f) for f in os.listdir(self.CAT_CACHE)]
            files = [(os.path.getmtime(p), os.path.getsize(p), p) for p in files if os.path.isfile(p)]
        except OSError:
            return
        total = sum(f[1] for f in files)
        for _mt, size, p in sorted(files):
            if total <= self.CAT_CACHE_MAX:
                break
            try:
                os.remove(p)
                total -= size
            except OSError:
                pass

    def _cat_pic_bytes(self, sess, folder, rel):
        """A picture of the catalog, kept in the temporary cache (in memory)."""
        import hashlib
        os.makedirs(self.CAT_CACHE, exist_ok=True)
        key = hashlib.sha1(("%s|%s|%s" % (sess.url, folder, rel)).encode("utf-8")).hexdigest()
        out = os.path.join(self.CAT_CACHE, key)
        if os.path.isfile(out):
            os.utime(out, None)
            with open(out, "rb") as f:
                return f.read()
        body = sess.media(folder, rel)
        with open(out + ".tmp", "wb") as f:
            f.write(body)
        os.replace(out + ".tmp", out)
        self._cat_cache_trim()
        return body

    def api_link_catalog_media(self):
        import base64

        def pic(sess, d):
            folder, rel = d.get("dir") or "", d.get("path") or ""
            mime = self.CAT_PIC_TYPES.get(os.path.splitext(rel)[1].lower())
            if not rel or not mime:
                return {"error": "bad request"}
            body = self._cat_pic_bytes(sess, folder, rel)
            return {"data": "data:%s;base64,%s" % (mime, base64.b64encode(body).decode("ascii"))}
        self._cat_call(pic)

    @staticmethod
    def _cat_sid(sess):
        """The id of an open catalog in the cover links (the link itself is not put in them)."""
        import hashlib
        return hashlib.sha1(("%s|%s" % (sess.url, sess.password or "")).encode("utf-8")).hexdigest()[:16]

    def _no_file(self):
        """404 that the browser does not keep: the picture is asked again later."""
        try:
            self.send_response(404)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def api_link_catalog_cover(self, query, thumb=True):
        """A picture of the catalog by a plain link (the browser keeps it): a cover of the list
        (thumb: the service's small preview when it has one - Yandex Disk, pCloud, Nextcloud
        folders) or a picture of the details. With its size in the link ("s") the picture is
        kept for a month: a changed picture gets another link. Nothing is saved on the card."""
        q = urllib.parse.parse_qs(query)
        arg = lambda k: (q.get(k) or [""])[0]
        sess = None
        with self._cat_lock:
            for v in type(self)._cat_sessions.values():
                if self._cat_sid(v) == arg("sid"):
                    sess = v
        folder, rel = arg("dir"), arg("path")
        mime = self.CAT_PIC_TYPES.get(os.path.splitext(rel)[1].lower())
        if sess is None or not rel or not mime:
            self._no_file()
            return
        try:
            got = sess.thumb(folder, rel) if thumb and hasattr(sess, "thumb") else None
            body, ctype = got if got else (self._cat_pic_bytes(sess, folder, rel), mime)
        except Exception:
            self._no_file()
            return
        try:
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "private, max-age=2592000, immutable" if arg("s") else "private, max-age=3600")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def api_link_catalog_video(self):
        """The video of a game is downloaded into the catalog cache once; the page then
        plays it from api/link/catalog_file (with Range, as phones need for video)."""
        import hashlib

        def vid(sess, d):
            folder, rel = d.get("dir") or "", d.get("path") or ""
            ext = os.path.splitext(rel)[1].lower()
            if not rel or ext not in self.CAT_VIDEO_TYPES:
                return {"error": "bad request"}
            os.makedirs(self.CAT_CACHE, exist_ok=True)
            name = hashlib.sha1(("%s|%s|%s" % (sess.url, folder, rel)).encode("utf-8")).hexdigest() + ext
            out = os.path.join(self.CAT_CACHE, name)
            if os.path.isfile(out):
                os.utime(out, None)
            else:
                body = sess.media(folder, rel, limit=self.CAT_VIDEO_MAX, unlocked=True)
                with open(out + ".tmp", "wb") as f:
                    f.write(body)
                os.replace(out + ".tmp", out)
                self._cat_cache_trim()
            return {"src": "/api/link/catalog_file?id=" + name}
        self._cat_call(vid)

    def api_link_catalog_file(self, query):
        name = (urllib.parse.parse_qs(query).get("id") or [""])[0]
        if not re.match(r"^[0-9a-f]{40}[.](mp4|m4v|webm)$", name):
            self.send_error(404)
            return
        self._send_file(os.path.join(self.CAT_CACHE, name), self.CAT_VIDEO_TYPES[os.path.splitext(name)[1]])

    def _cat_local_path(self, folder, rel):
        """roms/<folder>/<rel> when it is a picture or video inside that system folder."""
        if not folder or "/" in folder or folder in (".", "..") or not rel or rel.startswith("/") or "\x00" in rel:
            return None
        if os.path.splitext(rel)[1].lower() not in self.CAT_PIC_TYPES and os.path.splitext(rel)[1].lower() not in self.CAT_VIDEO_TYPES:
            return None
        base = os.path.realpath(os.path.join(ROMS_DIR, folder))
        p = os.path.realpath(os.path.join(base, *[x for x in rel.split("/") if x not in ("", ".")]))
        if not p.startswith(base + os.sep) or not os.path.isfile(p):
            return None
        return p

    def api_link_catalog_have_media(self):
        """Which media files of a game are already in roms/<dir> with the same size."""
        data = self._json_body()
        folder = (data.get("dir") or "").strip()
        have = []
        for item in (data.get("files") or [])[:50]:
            try:
                rel, size = item[0], int(item[1])
                p = self._cat_local_path(folder, rel)
                if p and os.path.getsize(p) == size:
                    have.append(rel)
            except (OSError, ValueError, TypeError, IndexError, AttributeError):
                pass
        self.send_json({"have": have})

    CAT_DEV_TAGS = ("image", "thumbnail", "boxart", "screenshot", "mix", "titleshot", "fanart", "marquee",
                    "wheel", "cartridge", "boxback", "video")
    CAT_DEV_INFO = ("desc", "genre", "players", "developer", "publisher", "lang", "region", "releasedate")
    _cat_dev_cache = {}

    def _cat_dev_index(self, folder):
        """{rom path: {tag: file}} of roms/<folder>/gamelist.xml, read again when it changes."""
        import xml.etree.ElementTree as ET
        p = os.path.join(ROMS_DIR, folder, "gamelist.xml")
        try:
            st = os.stat(p)
        except OSError:
            return {}
        key = (st.st_mtime, st.st_size)
        hit = self._cat_dev_cache.get(p)
        if hit and hit[0] == key:
            return hit[1]
        index = {}
        try:
            root = ET.parse(p).getroot()
        except (ET.ParseError, OSError):
            root = None
        for n in (root if root is not None else []):
            if n.tag != "game":
                continue
            media, info = {}, {}
            for c in n:
                v = (c.text or "").strip()
                if c.tag in self.CAT_DEV_TAGS and v:
                    media[c.tag] = v
                elif c.tag in self.CAT_DEV_INFO and v:
                    info[c.tag] = v
            if media or info:
                media["__info"] = info
            index[self._cat_rel_norm(n.findtext("path") or "")] = media
        type(self)._cat_dev_cache = {p: (key, index)}
        return index

    @staticmethod
    def _cat_rel_norm(v):
        v = (v or "").strip().replace("\\", "/")
        while v.startswith("./"):
            v = v[2:]
        return os.path.normpath(v).replace(os.sep, "/") if v else ""

    def api_link_catalog_device_media(self):
        """Media of a game from its entry in the device's gamelist.xml: {tag: path in
        roms/<dir>} of the files that exist (shown through api/link/catalog_local)."""
        data = self._json_body()
        folder = (data.get("dir") or "").strip()
        out, info = {}, None
        if folder and "/" not in folder and folder not in (".", ".."):
            out, info = self._cat_dev_media(folder, self._cat_dev_index(folder).get(self._cat_rel_norm(data.get("path") or ""), {}))
        self.send_json({"media": out, "info": info})

    def _cat_dev_media(self, folder, entry):
        """-> ({tag: path in roms/<folder>} of the files that exist, the description or None)"""
        out, info = {}, None
        base = os.path.realpath(os.path.join(ROMS_DIR, folder))
        for tag, v in entry.items():
            if tag == "__info":
                info = v
                continue
            if v.startswith("/"):
                full = os.path.realpath(v)
                if not full.startswith(base + os.sep):
                    continue
                rel = os.path.relpath(full, base).replace(os.sep, "/")
            else:
                rel = self._cat_rel_norm(v)
            if rel and self._cat_local_path(folder, rel):
                out[tag] = rel
        return out, info

    CAT_COVER_ORDER = ("thumbnail", "image", "boxart", "screenshot", "mix", "titleshot", "marquee", "wheel",
                       "cartridge", "fanart")

    def api_link_catalog_device_covers(self):
        """The cover and the short data of each game already on the device, from its
        gamelist.xml (one request for the whole list): {rom path: picture in roms/<dir>},
        {rom path: {year, genre, players, desc}}."""
        data = self._json_body()
        folder = (data.get("dir") or "").strip()
        out, rows = {}, {}
        if folder and "/" not in folder and folder not in (".", ".."):
            index = self._cat_dev_index(folder)
            for p in (data.get("paths") or [])[:5000]:
                if not isinstance(p, str):
                    continue
                media, info = self._cat_dev_media(folder, index.get(self._cat_rel_norm(p), {}))
                if info:
                    row = {k: info[k] for k in ("genre", "players", "desc") if info.get(k)}
                    year = (info.get("releasedate") or "")[:4]
                    if year.isdigit():
                        row["year"] = year
                    if row:
                        rows[p] = row
                for tag in self.CAT_COVER_ORDER:
                    rel = media.get(tag)
                    if rel and os.path.splitext(rel)[1].lower() in self.CAT_PIC_TYPES:
                        out[p] = rel
                        break
        self.send_json({"covers": out, "info": rows})

    def api_link_catalog_local(self, query):
        q = urllib.parse.parse_qs(query)
        p = self._cat_local_path((q.get("dir") or [""])[0], (q.get("path") or [""])[0])
        if not p:
            self.send_error(404)
            return
        ext = os.path.splitext(p)[1].lower()
        self._send_file(p, self.CAT_PIC_TYPES.get(ext) or self.CAT_VIDEO_TYPES[ext])

    def _send_file(self, p, ctype):
        """A file with Range support (a phone's video player needs it)."""
        try:
            size = os.path.getsize(p)
            f = open(p, "rb")
        except OSError:
            self.send_error(404)
            return
        with f:
            start, end = 0, size - 1
            m = re.match(r"bytes=(\d*)-(\d*)$", (self.headers.get("Range") or "").strip())
            if m and (m.group(1) or m.group(2)):
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                else:                              # the last N bytes
                    start = max(0, size - int(m.group(2)))
                if start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.end_headers()
                    return
                self.send_response(206)
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
            else:
                self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    chunk = f.read(min(256 * 1024, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass                               # the player moved on

    def api_link_have(self):
        """Which files of the open folder are already in roms/<system> with the same size
        (that is where ticked files go)."""
        data = self._json_body()
        dest = (data.get("dest") or "").strip()
        have = []
        if dest and "/" not in dest and dest not in (".", ".."):
            base = os.path.join(ROMS_DIR, dest)
            for f in (data.get("files") or [])[:5000]:
                try:
                    name, size = f.get("name") or "", f.get("size")
                    if not name or "/" in name or name in (".", "..") or size is None:
                        continue
                    p = os.path.join(base, name)
                    if os.path.isfile(p) and os.path.getsize(p) == int(size):
                        have.append(name)
                except (OSError, ValueError, TypeError, AttributeError):
                    pass
        self.send_json({"have": have})

    def api_link_catalog_get(self):
        data = self._json_body()
        url = (data.get("url") or "").strip()
        dest = (data.get("dest") or "").strip()
        games = [g for g in (data.get("games") or []) if isinstance(g, str) and g]
        kinds = [k for k in (data.get("media") or []) if isinstance(k, str) and k.isalnum()]
        if not url:
            self.send_json({"success": False, "error": "No link"})
            return
        if not dest:
            self.send_json({"success": False, "error": "Choose the system to put the games into"})
            return
        if not games:
            self.send_json({"success": False, "error": "Tick the games"})
            return
        if not os.path.exists(LINK_SCRIPT):
            self.send_json({"success": False, "error": "link_download.py not found - reinstall Save Sync"})
            return
        if self._link_pid() is not None:
            self.send_json({"success": False, "error": "A download from a link is already running"})
            return
        try:
            with open("/tmp/save_sync_progress.json", "w") as f:
                json.dump({"active": False, "action": "link_download", "phase": "", "percent": None, "success": None}, f)
            with open("/tmp/save_sync_progress.log", "w") as f:
                pass
        except Exception:
            pass
        target = "cloud" if data.get("target") == "cloud" else "device"
        cmd = [sys.executable, LINK_SCRIPT, "--download", url, "--dest", dest, "--target", target,
               "--catalog", data.get("dir") or "", "--media", ",".join(kinds), "--web-progress"]
        if data.get("replace_media"):
            cmd.append("--replace-media")
        if data.get("replace_desc"):
            cmd.append("--replace-desc")
        for g in games:
            cmd += ["--game", g]
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
        self.send_json({"success": False, "error": 'Could not get the list of conflicts'})

    def api_conflict_action(self, action):
        try:
            length = int(self.headers.get("Content-Length", 0))
            cid = str(json.loads(self.rfile.read(length) or b"{}").get("id", "")) if length else ""
        except (ValueError, AttributeError):
            cid = ""
        if not cid:
            self.send_json({"success": False, "error": 'No data'})
            return
        try:
            if action == "delete":
                r = self._engine(["drop", cid], 60)
                if r.returncode == 0:
                    self.send_json({"success": True})
                else:
                    self.send_json({"success": False, "error": 'Could not delete the copy'})
                return
            r = self._engine(["restore", cid], 300)
            if r.returncode == 3:
                self.send_json({"success": False, "error": 'A sync is running now - try again in a minute'})
                return
            if r.returncode != 0:
                self.send_json({"success": False, "error": 'Could not restore the version'})
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
            self.send_json({"success": True, "message": 'Version restored, syncing'})
        except Exception:
            self.send_json({"success": False, "error": 'Could not restore the version'})

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
<title>Save Sync</title>
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png">
<link rel="apple-touch-icon" href="/icon-192.png">
<meta name="theme-color" content="#1565C0">
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
    --panel-border: transparent;   /* cards and panels: no visible outline */
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
    --conf-bg: #2A2416;            /* the save conflicts block */
    --conf-line: #4A3F22;
    --chip-bg: #26344A;
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
    --bg-primary: #ECEEF1;
    --bg-secondary: #F5F6F8;
    --bg-card: #FFFFFF;
    --bg-hover: #ECEEF1;
    --border-color: #DDE0E5;
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
    --conf-bg: #FFF8E1;
    --conf-line: #F3E3B0;
    --chip-bg: #ECEEF1;
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
.container{max-width:1100px;width:100%;background:var(--bg-secondary);border-radius:var(--radius);padding:24px;border:1px solid var(--panel-border);box-shadow:var(--elevation-2);transition:background 0.3s, border 0.3s, box-shadow 0.3s}

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
    border: 1px solid var(--panel-border);
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
}

/* SHADOW ON HOVER */
@media (hover: hover) {
    .header .theme-toggle:hover {
        transform: scale(1.15);
    }
}

/* ON CLICK */
.header .theme-toggle:active {
    transform: scale(0.8);
    transition-duration: 0.05s;
}

/* the sun icon is bigger than the moon so that their discs match (the rays stick out): 50 px (38 px on phones) */
.header .theme-toggle .theme-sun {
    width: 50px;
    height: 50px;
    margin: -9px;                      /* centred on the moon's place: no jump when the theme changes */
}

/* the sun's rays grow out of the disc one by one when the light theme is switched on */
.header .theme-toggle .sun-rays-anim .sun-rays line {
    stroke-dasharray: 1;
    stroke-dashoffset: 1;
    animation: sunRayGrow 0.3s ease-out forwards;
}
@keyframes sunRayGrow {
    to { stroke-dashoffset: 0; }
}
@media (prefers-reduced-motion: reduce) {
    .header .theme-toggle .sun-rays-anim .sun-rays line {
        animation: none;
        stroke-dashoffset: 0;
    }
}

.header .theme-toggle:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
}

/* ========== STATUS PANEL ========== */
.status-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px;margin-bottom:20px}
.status-item{background:var(--bg-card);padding:12px 16px;border-radius:var(--radius);border:1px solid var(--panel-border);transition:all 0.3s;box-shadow:var(--elevation-1)}
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
.tabs{display:flex;gap:4px;margin-bottom:20px;background:var(--bg-card);border-radius:var(--radius);padding:4px;border:1px solid var(--panel-border)}
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
.btn{background:var(--bg-card);border:1px solid var(--panel-border);color:var(--text-secondary);padding:10px 20px;border-radius:var(--radius);cursor:pointer;font-size:13px;font-weight:500;transition:all 0.3s cubic-bezier(0.4, 0, 0.2, 1);text-transform:uppercase;letter-spacing:0.5px;position:relative;overflow:hidden}
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
.settings-row{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin:6px 0;padding:8px 12px;background:var(--bg-card);border-radius:var(--radius);border:1px solid var(--panel-border);transition:all 0.3s}
.settings-row:focus-within{border-color:var(--accent);box-shadow:0 0 0 3px rgba(38,166,154,0.15)}
.settings-row label{color:var(--text-secondary);font-size:13px;min-width:110px;font-weight:500}
.settings-row input,.settings-row select{background:var(--bg-primary);border:1px solid var(--border-color);color:var(--text-primary);padding:8px 12px;border-radius:var(--radius);font-size:13px;flex:1;min-width:100px;transition:border 0.3s;font-family:inherit}
.settings-row input:focus,.settings-row select:focus{outline:none;border-color:var(--accent)}

.quick-intervals{display:flex;gap:6px;flex-wrap:wrap}
.quick-intervals button{background:var(--bg-primary);border:1px solid var(--panel-border);color:var(--text-secondary);padding:4px 12px;border-radius:var(--radius);cursor:pointer;font-size:12px;font-weight:500;transition:all 0.3s}

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
.stats-item{text-align:center;padding:12px 8px;background:var(--bg-card);border-radius:var(--radius);border:1px solid var(--panel-border);transition:all 0.3s;box-shadow:var(--elevation-1)}
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
.roms-stats .chip{display:inline-flex;align-items:center;white-space:nowrap;gap:6px;padding:5px 12px;border-radius:999px;background:var(--bg-card);border:1px solid var(--panel-border);font-size:13px;color:var(--text-secondary)}
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

/* ========== SYSTEMS ========== */
.system-list{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:6px;margin:10px 0}
.system-item{display:flex;align-items:center;gap:8px;padding:8px 12px;background:var(--bg-card);border-radius:var(--radius);border:1px solid var(--panel-border);cursor:pointer;transition:all 0.3s;box-shadow:var(--elevation-0)}
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
.system-item .badge{font-size:10px;padding:2px 12px;border-radius:var(--radius);background:var(--bg-card);color:var(--text-secondary);font-weight:500;border:1px solid var(--panel-border)}
.system-item .badge.excluded{background:rgba(239,83,80,0.12);color:var(--error);border-color:var(--panel-border)}
.system-item .badge.selected{background:rgba(102,187,106,0.12);color:var(--success);border-color:var(--panel-border)}

/* ========== CAPTION UNDER BUTTONS ========== */
.sync-note{margin-top:6px;padding:10px 16px;background:var(--bg-card);border-radius:var(--radius);border-left:4px solid var(--warning);font-size:11px;color:var(--text-secondary);line-height:1.6;box-shadow:var(--elevation-0)}
.sync-note p{margin:3px 0}
.sync-note p:first-child{cursor:pointer;user-select:none}
.sync-note .note-caret::before{content:'Less';margin-left:10px;font-size:12px;font-weight:400;color:var(--accent)}
.sync-note.folded .note-caret::before{content:'More'}
.sync-note .note-caret::after{content:'▾';margin-left:4px;font-size:16px;line-height:1;vertical-align:-2px;color:var(--accent)}
.sync-note.folded .note-caret::after{content:'▸'}
.sync-note.folded p:not(:first-child){display:none}
.sync-note .note-short{display:none;font-weight:400;color:var(--text-primary)}
.sync-note.folded .note-short{display:inline}
.sync-note.folded{padding-top:6px;padding-bottom:6px}
.sync-note strong{color:var(--text-primary)}
.conflicts-box{margin:10px 0 14px;padding:12px 14px;background:var(--conf-bg);border-radius:var(--radius);border:1px solid var(--panel-border)}
.conflicts-head{display:flex;align-items:center;gap:8px;font-size:14px;font-weight:600;color:var(--text-primary)}
.cf-ico{flex:none;width:22px;height:22px;border-radius:50%;background:var(--warning);color:#3A2A00;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:800}
.cf-n{display:inline-block;background:var(--warning);color:#3A2A00;border-radius:999px;font-size:11px;font-weight:700;line-height:1.4;padding:1px 7px}
.conflicts-hint{font-size:12px;color:var(--text-secondary);line-height:1.5;margin:4px 0 2px 30px}
.cf-more{background:none;border:0;padding:0;margin-left:4px;color:var(--accent);font:inherit;cursor:pointer}
.cf-long{display:block;margin-top:4px}
.conflict-row{display:flex;flex-wrap:wrap;align-items:center;gap:8px 12px;padding:10px 0 2px;border-top:1px solid var(--conf-line);margin-top:8px}
.cf-chips{margin-top:4px;line-height:1}
.cf-chip{display:inline-block;font-size:10px;font-weight:600;padding:1px 7px;border-radius:999px;background:var(--chip-bg);color:var(--text-secondary);margin-right:6px;vertical-align:1px;text-transform:uppercase;letter-spacing:0.3px;white-space:nowrap}
.conflict-actions .cf-del{background:rgba(239,83,80,0.12);color:var(--error);box-shadow:none}
.conflict-actions .cf-del:hover{background:rgba(239,83,80,0.22);color:var(--error)}
.conflict-info{flex:1 1 220px;min-width:0}
.conflict-file{font-size:14px;font-weight:600;color:var(--text-primary);word-break:break-word}
.conflict-meta{font-size:12px;color:var(--text-secondary);margin-top:2px}
.conflict-actions{display:flex;gap:8px;flex-shrink:0}
.conflict-actions .btn{padding:6px 14px;font-size:12px;width:auto}
.tab-badge{display:inline-block;padding:1px 7px;margin-left:6px;border-radius:999px;background:var(--warning);color:#3A2A00;font-size:11px;font-weight:700;line-height:1.4;vertical-align:1px}

/* ========== DEVICE ========== */
.device{font-size:11px;color:var(--text-muted);margin-top:2px;text-align:center;line-height:1.4}
.device br{display:none}

/* ========== TOAST ========== */
.toast{position:fixed;bottom:24px;right:24px;background:var(--bg-secondary);padding:12px 24px;border-radius:var(--radius);border:1px solid var(--panel-border);box-shadow:var(--elevation-4);opacity:0;transform:translateY(20px) scale(0.95);transition:all 0.3s cubic-bezier(0.4, 0, 0.2, 1);z-index:1000;font-size:14px;max-width:90%;font-weight:500}
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
    .header .theme-toggle{top:14px;right:15px;width:10px;height:10px;font-size:24px}
    .header .theme-toggle .theme-sun{width:38px;height:38px;margin:-7px}
    .btn{padding:8px 14px;font-size:12px}
    .btn-primary{padding: 14px 14px;}
    .status-item .value{font-size:12px;}
    body{padding:30px 16px}
}


/* ========== DOWNLOAD FROM A PUBLIC LINK ========== */
.link-box{background:var(--bg-card);border:1px solid var(--panel-border);border-radius:var(--radius);padding:12px;margin:10px 0}
.link-input-row{display:flex;gap:8px;flex-wrap:wrap}
.link-input,.link-controls select{flex:1;min-width:0;background:var(--bg-primary);border:1px solid var(--border-color);color:var(--text-primary);padding:9px 12px;border-radius:var(--radius);font-size:13px;font-family:inherit}
.link-input{min-width:0}
.link-input-row .btn{flex:none}
.link-input:focus,.link-controls select:focus{outline:none;border-color:var(--accent)}
.link-saved{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:8px}
.link-saved .ls-label{font-size:12px;color:var(--text-muted);margin-right:2px}
.ls-chip{display:inline-flex;align-items:center;border-radius:999px;background:var(--bg-primary);font-size:12px;overflow:hidden;max-width:100%}
.ls-chip button{border:0;background:none;color:var(--text-primary);font-family:inherit;font-size:12px;cursor:pointer;padding:5px 4px 5px 12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:260px}
.ls-chip button.ls-x{padding:5px 10px 5px 6px;color:var(--text-muted);flex:none;overflow:visible;text-overflow:clip;max-width:none}
.ls-chip button:first-child{min-width:0;flex:0 1 auto}
.ls-chip button.ls-x:hover{color:var(--error)}
.ls-chip .ls-cat{vertical-align:-2px;margin-right:5px;color:var(--accent)}
.ls-chip.on .ls-cat{color:#fff}
.ls-chip.on{background:var(--accent)}
.ls-chip.on button{color:#fff}
.link-save{flex:none;background:var(--bg-primary);color:var(--text-primary)}
.link-save:hover{background:var(--bg-hover)}
.link-save .ls-star{color:var(--warning)}
.link-hint{color:var(--text-muted);font-size:12px;margin-top:8px;line-height:1.4}
.link-status{font-size:13px;margin-top:8px;color:var(--text-secondary)}
.link-status:empty{display:none}
.link-status.error{color:var(--error)}
.link-crumbs{font-size:13px;margin:12px 0 6px;color:var(--text-secondary);word-break:break-all}
.link-crumbs a{color:var(--accent);cursor:pointer}
.link-list{max-height:380px;overflow-y:auto;border:1px solid var(--panel-border);border-radius:var(--radius);background:var(--bg-primary)}
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
.cat-offer{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:6px 0 10px;padding:10px 12px;border:1px solid var(--accent);border-radius:var(--radius);background:var(--bg-primary);font-size:13px;color:var(--text-secondary)}
.cat-offer span{flex:1;min-width:200px}
.cat-head{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:6px 0 8px}
.cat-title{font-weight:600;color:var(--text-primary);flex:1;min-width:0;word-break:break-word;font-size:16px}
.cat-count{font-weight:400;font-size:13px;color:var(--text-muted);white-space:nowrap;margin-left:4px}
.cat-back{padding:6px 12px;text-transform:none;letter-spacing:0;font-size:13px;background:var(--bg-primary);color:var(--accent);flex:none}
.cat-search{width:100%;box-sizing:border-box;margin-bottom:8px}
.cat-kinds{display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center;font-size:13px;color:var(--text-secondary);margin-bottom:8px}
.cat-kinds label{display:inline-flex;gap:5px;align-items:center;cursor:pointer;white-space:nowrap}
.cat-kinds input{accent-color:var(--accent)}
.cat-list{max-height:460px}
.cat-have{color:var(--success,#2e7d32)}
.cat-detail{padding:10px 12px 12px;margin:8px 10px;background:var(--bg-card);border-radius:8px;font-size:13px;color:var(--text-secondary);display:flex;gap:12px;flex-wrap:wrap}
.cat-pic{width:160px;min-height:60px;display:flex;flex-direction:column;align-items:center;gap:6px;color:var(--text-muted);font-size:12px}
.cat-pic-main{display:flex;justify-content:center;min-height:40px}
.cat-pic img,.cat-pic video{max-width:160px;max-height:200px;border-radius:6px}
.cat-shots{display:flex;flex-wrap:wrap;gap:4px;justify-content:center}
.cat-shots button{font-size:11px;padding:2px 8px;border-radius:999px;background:var(--bg-primary);border:1px solid var(--panel-border);white-space:nowrap;color:var(--text-secondary);cursor:pointer;font-family:inherit}
.cat-shots button.on{background:var(--accent);border-color:var(--accent);color:#fff}
.cat-src{display:flex;gap:0;border-radius:999px;overflow:hidden;max-width:100%}
.cat-src button{min-width:0;overflow:hidden;text-overflow:ellipsis;font-size:11px;padding:3px 8px;border:0;background:var(--bg-primary);white-space:nowrap;color:var(--text-secondary);cursor:pointer;font-family:inherit}
.cat-src button.on{background:var(--accent);color:#fff}
.cat-replace{display:flex;flex-wrap:wrap;gap:4px 14px;align-items:center;margin-top:4px}
.cat-info{flex:1;min-width:200px}
.cat-desc{white-space:pre-line;margin-top:6px;line-height:1.45;color:var(--text-primary)}
.cat-more{text-align:center;padding:10px}
.link-row.cat-open{border-bottom:0}
.cat-detail-wrap{border-bottom:1px solid var(--border-color);padding-bottom:2px}
.cat-go{cursor:pointer}
.settings-row .sec-opt{display:inline-flex;align-items:center;gap:6px;cursor:pointer;color:var(--text-primary);font-size:13px;white-space:nowrap}
.settings-row .sec-opt input{flex:none;min-width:0;width:16px;height:16px;padding:0;margin:0;accent-color:var(--accent);cursor:pointer}
.cfg-move{display:flex;gap:8px;flex-wrap:wrap}
.cfg-import{margin-top:6px;padding:12px 14px;background:var(--bg-card);border-radius:var(--radius);font-size:13px;color:var(--text-secondary)}
.cfg-import label{display:flex;gap:8px;align-items:flex-start;margin:6px 0;cursor:pointer;color:var(--text-primary)}
.cfg-import input{accent-color:var(--accent);width:16px;height:16px;margin:2px 0 0;flex:none}
.cfg-import label.off{opacity:0.45;cursor:default}
.cfg-actions{display:flex;gap:8px;margin-top:10px}
.cfg-import .cfg-actions .btn:not(.btn-primary){background:var(--bg-primary)}
@media (max-width:600px){.cfg-move .btn,.cfg-actions .btn{flex:1}}
.cat-wait{opacity:0.5}
.cat-filters{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:8px}
.cat-filters select{background:var(--bg-primary);border:1px solid var(--border-color);color:var(--text-primary);padding:6px 10px;border-radius:var(--radius);font-size:13px;font-family:inherit;max-width:220px}
.cat-filters select:disabled,.cat-search:disabled{opacity:0.5}
.cat-hide{display:inline-flex;gap:5px;align-items:center;font-size:13px;color:var(--text-secondary);cursor:pointer;white-space:nowrap}
.cat-hide input{accent-color:var(--accent)}
.cat-mark{display:inline-block;font-size:10px;font-weight:700;line-height:1.5;padding:0 6px;border-radius:999px;text-transform:uppercase;letter-spacing:0.3px;vertical-align:1px;color:#fff;background:var(--success)}
.cat-mark.chg{background:var(--accent)}
.cat-onlysel{font-size:12px;padding:5px 12px;border-radius:999px;border:0;background:var(--bg-primary);color:var(--text-secondary);cursor:pointer;font-family:inherit;white-space:nowrap}
.cat-onlysel.on{background:var(--accent);color:#fff}
.cat-onlysel:disabled{opacity:0.5;cursor:default}
.cat-pic-main img{cursor:zoom-in}
.cat-zoom{position:fixed;inset:0;z-index:1000;background:rgba(0,0,0,0.88);cursor:zoom-out;user-select:none;touch-action:none;overscroll-behavior:contain}
html.cat-zoom-open,html.cat-zoom-open body{overflow:hidden}
.cat-zoom img{position:absolute;left:16px;top:16px;width:calc(100% - 32px);height:calc(100% - 64px);object-fit:contain}
.cat-zoom-msg{position:absolute;left:16px;right:16px;top:50%;transform:translateY(-50%);text-align:center;color:#fff;font-size:15px;opacity:0.85}
.cat-zoom-cap{position:absolute;left:0;right:0;bottom:16px;text-align:center;color:#fff;font-size:13px;opacity:0.85}
.cat-zoom-nav{position:absolute;top:50%;transform:translateY(-50%);width:44px;height:44px;border-radius:50%;border:0;background:rgba(255,255,255,0.16);color:#fff;font-size:28px;line-height:40px;cursor:pointer;font-family:inherit;padding:0}
.cat-zoom-nav:hover{background:rgba(255,255,255,0.28)}
.cat-zoom.nav img{left:68px;width:calc(100% - 136px)}
.cat-zoom-prev{left:12px}
.cat-zoom-next{right:12px}
.cat-views{display:inline-flex;border-radius:999px;overflow:hidden;flex:none}
.cat-views button{font-size:12px;padding:5px 11px;border:0;background:var(--bg-primary);color:var(--text-secondary);cursor:pointer;font-family:inherit}
.cat-views button.on{background:var(--accent);color:#fff}
.cat-list.cat-covers,.cat-list.cat-grid{max-height:min(640px,72vh)}
.cat-cov{flex:none;width:72px;height:96px;border-radius:6px;overflow:hidden;cursor:pointer;background:var(--bg-primary)}
.cat-cov img{width:100%;height:100%;object-fit:contain;display:block}
.cat-rt{flex:1;min-width:0;display:flex;flex-direction:column;align-items:flex-start;gap:4px}
.cat-rt .link-name{flex:none;max-width:100%}
.cat-rt-meta{font-size:12px;color:var(--text-muted)}
.cat-rt-desc{font-size:12px;line-height:1.4;color:var(--text-secondary);display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden}
.cat-covers .cat-cov{width:90px;height:120px}
.cat-tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));grid-auto-flow:row dense;gap:10px;padding:10px}
.cat-tile{position:relative;background:var(--bg-card);border-radius:8px;padding:6px;min-width:0}
.cat-tile.open{box-shadow:0 0 0 2px var(--accent)}
.cat-tile .cat-cov{width:100%;height:auto;aspect-ratio:3/4;border-radius:6px}
.cat-tile input{position:absolute;top:10px;left:10px;margin:0;width:16px;height:16px;accent-color:var(--accent);cursor:pointer}
.cat-tile-have{position:absolute;top:9px;right:9px;background:var(--success,#2e7d32);color:#fff;border-radius:999px;font-size:10px;line-height:1.5;padding:0 6px}
.cat-tile-name{font-size:12px;line-height:1.25;margin-top:5px;max-height:2.5em;overflow:hidden;word-break:break-word;color:var(--accent);cursor:pointer}
.cat-tile-meta{font-size:11px;color:var(--text-muted);margin-top:2px}
.cat-tiles .cat-detail{grid-column:1/-1;margin:0}
@media (max-width:600px){.link-save{padding-left:14px;padding-right:14px}.link-save .ls-word{display:none}.link-save .ls-star{font-size:16px}.conflict-actions{flex:1 1 100%}.conflict-actions .btn{flex:1;padding:9px 14px}.cat-zoom.nav img{left:16px;width:calc(100% - 32px)}.cat-filters select{flex:1 1 40%;max-width:none;min-width:0}.cat-covers .cat-cov{width:72px;height:96px}.cat-rt-meta{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden}.cat-tiles{grid-template-columns:repeat(auto-fill,minmax(84px,1fr));gap:8px;padding:8px}.cat-head .cat-views{order:3;flex:1 1 100%;display:flex}.cat-views button{flex:1;padding-left:6px;padding-right:6px}.cat-title{min-width:140px}.cat-detail{padding-left:12px}.cat-pic{width:100%;align-items:center}.cat-pic-main,.cat-shots{justify-content:center}.cat-offer .btn{flex:1 1 100%}.cat-pic img,.cat-pic video{max-width:100%}.cat-kinds label{white-space:normal;align-items:flex-start}}
</style>
</head>
<body>

<div class="container">
  <div class="header" style="position:relative">
    <button class="theme-toggle" onclick="toggleTheme()">
    <span id="themeIcon"><svg width="1em" height="1em" aria-hidden="true" style="display:block" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><g transform="rotate(-90 256 256)"><g><g><path style="fill:#FCE4A8;" d="M90.822,60.408c105.574-92.296,264.984-76,357.28,29.574s84.138,262.286-21.436,354.583 S158.688,529.26,66.392,423.687S-14.752,152.704,90.822,60.408z"/><path style="fill:#F6D89C;" d="M107.702,89.331c99.918-87.352,248.823-74.176,333.823,23.051s75.389,243.385-24.528,330.736 c-99.918,87.352-251.733,82.319-336.733-14.909S7.784,176.683,107.702,89.331z"/><g><path style="fill:#F0C684;" d="M244.034,141.578C226.114,178.849,181.001,192.92,143.73,175 c-37.271-17.92-53.236-61.358-35.316-98.629c17.92-37.271,62.836-54.047,100.107-36.127 C245.792,58.164,261.954,104.307,244.034,141.578z"/><path style="opacity:0.06;fill:#040000;" d="M128.089,97.737c17.92-37.271,62.836-54.047,100.107-36.127 c4.127,1.984,7.995,4.316,11.586,6.943c-7.335-11.909-17.951-21.909-31.261-28.309c-37.271-17.92-82.187-1.144-100.107,36.127 c-15.805,32.873-5.247,70.539,23.036,91.267C118.965,147.179,116.792,121.234,128.089,97.737z"/></g><path style="fill:#F0C684;" d="M217.126,218.456c-1.17-5.733,2.71-11.178,8.442-12.348c5.733-1.17,11.248,2.359,12.418,8.092 s-2.456,11.466-8.189,12.636C224.065,228.005,218.296,224.189,217.126,218.456z"/><path style="opacity:0.5;fill:#FFFFFF;" d="M363.159,97.031c-1.17-5.733,2.71-11.178,8.442-12.348s11.248,2.359,12.418,8.092 c1.17,5.733-2.456,11.466-8.189,12.636C370.097,106.581,364.328,102.764,363.159,97.031z"/><path style="fill:#F0C684;" d="M282.758,398.482c8.691-7.598,21.813-6.256,29.411,2.434c7.598,8.691,6.926,21.591-1.765,29.189 c-8.691,7.598-22.06,6.972-29.658-1.719C273.149,419.697,274.067,406.08,282.758,398.482z"/><path style="opacity:0.5;fill:#FFFFFF;" d="M58.328,221.051c-1.17-5.733,2.71-11.178,8.442-12.348 c5.733-1.17,11.248,2.359,12.418,8.092c1.17,5.733-2.456,11.466-8.189,12.636C65.267,230.6,59.498,226.784,58.328,221.051z"/><path style="fill:#F0C684;" d="M468.957,281.792c-3.725,36.65-37.257,62.1-73.907,58.374c-36.65-3.725-63.179-35.28-59.453-71.93 c3.725-36.65,36.273-64.306,72.923-60.581C445.17,211.381,472.683,245.142,468.957,281.792z"/><g><path style="fill:#F0C684;" d="M173.243,331.228c14.631,25.328,4.867,57.296-20.461,71.927 c-25.328,14.631-57.072,6.642-71.703-18.687c-14.631-25.328-6.526-58.259,18.802-72.89 C125.209,296.946,158.611,305.899,173.243,331.228z"/><path style="opacity:0.06;fill:#040000;" d="M112.82,324.421c18.464-10.666,41.211-8.787,57.856,2.82 c-15.693-22.239-46.848-29.497-70.796-15.664c-25.328,14.631-33.433,47.562-18.802,72.89c4.04,6.993,9.388,12.657,15.541,16.895 c-0.915-1.299-1.789-2.644-2.602-4.052C79.387,371.983,87.492,339.052,112.82,324.421z"/></g><path style="opacity:0.06;fill:#040000;" d="M349.708,282.184c3.725-36.65,36.272-64.306,72.923-60.581 c12.217,1.242,23.416,5.824,32.783,12.736c-11.007-14.534-27.695-24.731-46.895-26.682c-36.65-3.725-69.197,23.931-72.922,60.581 c-2.465,24.248,8.316,46.262,26.507,59.465C352.784,315.151,347.977,299.219,349.708,282.184z"/></g><path style="opacity:0.1;fill:#040000;" d="M254.816,381.8c-105.36,0-198.423-52.065-254.726-131.657 C-2.613,349.865,55.643,444.482,154.03,486.89c128.776,55.508,279.654,1.534,335.162-127.242 c15.267-35.419,21.657-72.749,20.289-109.419C453.171,329.772,360.138,381.8,254.816,381.8z"/></g></g></svg></span>
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
      <div class="label"><svg width="17" height="12" viewBox="-192 -123 1664 1068" style="vertical-align:0px;margin-right:3px"><g transform="translate(0,822) scale(0.1,-0.1)" fill="currentColor"><path d="M7121 8205 c-484 -56 -926 -221 -1315 -494 -238 -166 -476 -397 -637 -618 -23 -32 -44 -60 -45 -62 -2 -2 -40 8 -84 23 -117 38 -260 73 -385 92 -150 23 -442 23 -590 0 -611 -94 -1127 -423 -1468 -934 -235 -353 -362 -809 -344 -1229 l6 -132 -32 -5 c-18 -3 -72 -10 -122 -16 -413 -50 -861 -242 -1201 -515 -434 -349 -738 -846 -852 -1395 -38 -183 -47 -272 -46 -495 0 -243 14 -368 63 -571 221 -899 936 -1599 1835 -1794 268 -58 -2 -55 4336 -55 3806 0 4011 1 4125 18 649 97 1197 373 1635 824 142 145 217 237 324 396 233 346 381 728 448 1162 18 116 22 183 22 395 0 282 -16 420 -74 657 -180 738 -643 1363 -1298 1752 -333 198 -715 326 -1104 371 -117 14 -118 14 -118 89 0 95 -59 403 -107 556 -75 243 -205 524 -331 715 -452 687 -1140 1129 -1947 1250 -185 28 -520 35 -694 15z"/></g></svg><span id="sysCloudLabel">Cloud</span></div>
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
    <button class="tab active" data-tab="saves"><svg width="16" height="16" viewBox="-6 -6 36 36" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19,0H1C0.448,0,0,0.448,0,1v22c0,0.552,0.448,1,1,1h22c0.552,0,1-0.448,1-1V5L19,0z M6,3c0-0.552,0.448-1,1-1h10 c0.552,0,1,0.448,1,1v6c0,0.552-0.448,1-1,1H7c-0.552,0-1-0.448-1-1V3z M20,22H4v-7c0-0.552,0.448-1,1-1h14c0.552,0,1,0.448,1,1V22 z" fill="currentColor"/><path d="M16,9h-4V3h4V9z" fill="currentColor"/></svg>Saves<span id="conflictsBadge" class="tab-badge" style="display:none" title="There are save conflicts"></span></button>
    <button class="tab" data-tab="roms"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>ROMs</button>
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
<div id="syncProgressSaves" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--panel-border)">
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

    <div class="sync-note folded" id="noteSaves">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>IMPORTANT</strong><span class="note-short">: uploading deletes from the cloud the saves deleted on the device.</span><span class="note-caret"></span></p>
        <p>• <strong>Download:</strong> This will DOWNLOAD saves from the cloud to the device. Only saves changed on other devices are downloaded. If a save was deleted on another device, it is deleted here too. Saves changed on this device are not replaced, they are sent to the cloud. If a save was changed both here and on another device, the newer one is kept. If the cloud is empty, saves from the device are copied to the cloud.</p>
        <p>• <strong>Upload:</strong> This will UPLOAD saves from the device to the cloud. Only new or changed files are uploaded. If a file was deleted on the device, it IS deleted from the cloud. Deletions are synced between devices. Saves changed on other devices are not overwritten, they are downloaded here.</p>
        <p>• <strong>Full sync:</strong> This will perform a FULL sync. First DOWNLOADS saves from the cloud, then UPLOADS saves to the cloud. If the download fails, the upload is skipped.</p>
    </div>
<!-- КОНФЛИКТЫ СОХРАНЕНИЙ / SAVE CONFLICTS (shown only when there are copies) -->
<div id="conflictsBox" class="conflicts-box" style="display:none">
    <div class="conflicts-head"><span class="cf-ico">!</span><span id="conflictsHead"></span><span class="cf-n" id="conflictsCount"></span></div>
    <div class="conflicts-hint" id="conflictsHint"></div>
    <div id="conflictsList"></div>
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
  <div id="romsSection">
    <div class="section-title"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>ROMs</div>
    <div class="actions">
        <button class="btn btn-primary" onclick="runSyncWithProgress('roms_download')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z" fill="currentColor"/></svg>Download ROMs</button>
        <button class="btn btn-primary" onclick="runSyncWithProgress('roms_upload')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" style="vertical-align:-3px;margin-right:4px"><path d="M9 16h6v-6h4l-7-7-7 7h4v6zm-4 2h14v2H5v-2z" fill="currentColor"/></svg>Upload ROMs</button>
    </div>
    <div id="romsStats" class="roms-stats" title="Statistics of ROM downloads and uploads"></div>
    
<!-- ROMs progress bar -->
<div id="syncProgressRoms" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--panel-border)">
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
    <div class="sync-note folded" id="noteRoms">
        <p><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg><strong>IMPORTANT</strong><span class="note-short">: uploading deletes from the cloud the ROMs that are not on the device.</span><span class="note-caret"></span></p>
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

  </div>
  <div id="linkSection">
    <!-- Download from a public link -->
    <div class="section-title" style="margin-top:20px"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px;margin-right:4px"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z" fill="currentColor"/></svg>Download from a public link</div>
    <div class="link-box" id="linkBox">
      <div class="link-input-row">
        <input id="linkUrl" class="link-input" type="url" autocomplete="off" placeholder="Paste a link: Yandex Disk, pCloud, Nextcloud, archive.org" onkeydown="if(event.key==='Enter')linkOpen()">
        <button class="btn btn-primary" id="linkOpenBtn" onclick="linkOpen()">Open</button>
        <button class="btn link-save" id="linkSaveBtn" style="display:none" onclick="linkSaveToggle()"></button>
      </div>
      <div class="link-saved" id="linkSaved" style="display:none"></div>
      <div class="link-input-row" id="linkPwRow" style="display:none;margin-top:8px">
        <input id="linkPw" class="link-input" type="password" autocomplete="off" placeholder="Link password" onkeydown="if(event.key==='Enter')linkOpen()">
      </div>
      <div class="link-hint">Yandex Disk, pCloud, Nextcloud / ownCloud, archive.org or a direct link to a file. You can pick single files and folders. A zip archive opens like a folder: you can take only the files you need. Files already on the device are skipped; an interrupted download resumes.</div>
      <div class="link-status" id="linkStatus"></div>
      <div id="linkBrowser" style="display:none">
        <div class="link-crumbs" id="linkCrumbs"></div>
        <div class="cat-offer" id="catOffer" style="display:none"><span id="catOfferText"></span><button class="btn btn-primary" onclick="catOpenFromOffer()">Open as a catalog</button></div>
        <div id="catBox" style="display:none">
          <div class="cat-head"><button class="btn cat-back" onclick="catClose()">← Files</button><div class="cat-title" id="catTitle"></div><div class="cat-views" id="catViews"><button type="button" data-view="list" onclick="catSetView('list')">List</button><button type="button" data-view="covers" onclick="catSetView('covers')">With covers</button><button type="button" data-view="grid" onclick="catSetView('grid')">Tiles</button></div></div>
          <input id="catSearch" class="link-input cat-search" type="search" autocomplete="off" placeholder="Search games" oninput="catRender()">
          <div class="cat-filters">
            <select id="catGenre" onchange="catRender()"></select>
            <select id="catPlayers" onchange="catRender()"></select>
            <select id="catSort" onchange="catSortChanged()"></select>
            <label class="cat-hide" id="catNewRow" style="display:none"><input type="checkbox" id="catOnlyNew" onchange="catRender()"><span id="catNewText"></span></label>
            <label class="cat-hide" id="catHideRow"><input type="checkbox" id="catHideHave" onchange="catRender()"><span id="catHideText"></span></label>
            <button type="button" class="cat-onlysel" id="catOnlySel" onclick="catToggleSel()"></button>
          </div>
          <div class="cat-kinds" id="catKinds"></div>
          <div class="link-list cat-list" id="catList"></div>
        </div>
        <div class="link-list" id="linkList"></div>
        <div class="link-target" id="linkTargetRow">
          <span>Where:</span>
          <label><input type="radio" name="linkTarget" value="device" checked onchange="linkTargetChanged()">To the device</label>
          <label><input type="radio" name="linkTarget" value="cloud" onchange="linkTargetChanged()">To the cloud</label>
        </div>
        <label class="link-unpack" id="linkUnpackRow" style="display:none"><input type="checkbox" id="linkUnpack" onchange="linkUpdateSummary()"><span id="linkUnpackText">Unpack archives after download</span></label>
        <div class="link-controls">
          <select id="linkDest" onchange="linkState.destManual = true; linkUpdateSummary()"></select>
          <button class="btn btn-primary" id="linkStartBtn" onclick="linkDownload()">Download</button>
        </div>
        <div class="link-summary" id="linkSummary"></div>
      </div>
    </div>
    <div id="syncProgressLink" style="display:none;margin:10px 0;padding:12px;background:var(--bg-card);border-radius:8px;border:1px solid var(--panel-border)">
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
</div>

  <!-- SETTINGS TAB -->
  <div id="tab-settings" class="tab-content">
    <div class="settings-row" id="cloudSwitchRow" style="display:none">
      <label>Cloud:</label>
      <select id="settingCloud" onchange="cloudSwitch()"></select>
    </div>
    <div class="settings-hint" id="cloudSwitchHint" style="display:none;color:var(--text-secondary);font-size:12px;margin:-4px 0 10px"><span id="cloudSwitchStatus" style="display:none;color:var(--accent);font-weight:500"></span><span id="cloudSwitchText">Switching between this cloud and the previous one, used before the cloud was changed in the control center (item 16). The saves on the device are merged with the chosen cloud: others are downloaded, own ones uploaded, nothing is deleted. Another cloud is connected in the control center.</span></div>
    <div class="settings-row">
      <label>Sections:</label>
      <label class="sec-opt"><input type="checkbox" id="secRoms" checked onchange="saveSections()">ROMs</label>
      <label class="sec-opt"><input type="checkbox" id="secLink" checked onchange="saveSections()">Download from a link</label>
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px">Show in the web interface: ROMs (the system choice, downloading and uploading ROMs) and downloading from a public link with the game catalog.</div>
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
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px">If the same save was changed on different devices, the newest version is kept and the older one is stored in the cloud, in GameSaves_conflicts, for the chosen time - it can be restored in the "Saves" tab. With "Do not keep" this device makes no copies and does not remove the copies of other devices.</div>
    <div class="settings-row">
      <label>On-screen notifications:</label>
      <select id="settingNotifications">
        <option value="true">On</option>
        <option value="false">Off</option>
      </select>
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px">Short notifications about syncs and downloads. Works on Batocera and KNULLI.</div>
    <div class="settings-row">
      <label>Sync after a game:</label>
      <select id="settingSyncMode">
        <option value="economy">Only when changed</option>
        <option value="fast">After every game</option>
        <option value="full">Full</option>
      </select>
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px"><b>Only when changed:</b> if the saves on this device changed - a sync as in the mode &quot;After every game&quot;; if they did not, the cloud is not contacted, and changes from other devices arrive at boot or after a game in which the saves change.<br><b>After every game:</b> changes and deletions are sent and downloaded, without listing all cloud files. Good if you play on several devices at the same time.<br><b>Full:</b> after every game the whole list of cloud files is compared, including files added to the cloud by hand. The slowest.<br>At boot and on a manual run the sync is always full.</div>
    <div class="settings-row">
      <label>Log mode:</label>
      <select id="settingLogLevel">
        <option value="info">Normal</option>
        <option value="debug">Detailed (debug)</option>
      </select>
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:-4px 0 10px"><b>Normal:</b> the results of the syncs are written (the statistics are built from them).<br><b>Detailed (debug):</b> also the sent, received and renamed files, the time of each stage and of the requests to the cloud. Turn it on when you look for the reason of a slow sync.</div>
    <button class="btn btn-primary" onclick="saveSettings()">Save settings</button>
    <div style="margin-top:24px"><div class="section-title">Moving the settings</div></div>
    <div class="cfg-move">
      <button class="btn" onclick="cfgExport()">Export</button>
      <button class="btn" onclick="document.getElementById('cfgFile').click()">Import</button>
      <input type="file" id="cfgFile" accept=".conf,.txt,text/plain" style="display:none" onchange="cfgPick(this)">
    </div>
    <div class="settings-hint" style="color:var(--text-secondary);font-size:12px;margin:6px 0 10px">Export downloads this device's settings file (sync.conf); import takes from such a file only what you choose. The cloud connection is not in it.</div>
    <div class="cfg-import" id="cfgImport" style="display:none"></div>
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

// a browser reports a device that is off or out of reach as "Failed to fetch" (Chrome),
// "NetworkError..." (Firefox) or "Load failed" (Safari) - shown in plain words instead
const NET_ERR = 'No connection to the device';
function netErr(e) {
  const m = (e && e.message) || String(e || '');
  if ((e && e.name === 'TypeError') || /Failed to fetch|NetworkError|Load failed|network/i.test(m)) return NET_ERR;
  return 'Error: ' + m;
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
    return { success: false, error: 'The device answered with an error (code {c})'.replace('{c}', res.status) };
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
        let label = (data.stage ? data.stage + ' · ' : '') + pct + '%';
        if (data.speed > 0) label += ' · ' + formatBytes(data.speed) + '/s';
        if (data.eta > 0) label += ' · ' + Math.round(data.eta) + ' sec left';
        if (data.totalTransfers > 0 && !data.stage) label += ' · ' + (data.transfers || 0) + '/' + data.totalTransfers + ' files';
        percentEl.textContent = label;
    } else {
        barEl.style.animation = 'syncProgressMove 1.4s ease-in-out infinite';
        barEl.style.width = '35%';
        percentEl.textContent = data.stage || 'Transferring';
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
        'roms_upload': 'Uploading ROMs',
        'conflict_restore': 'Restoring a version'
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
                    if (target === 'saves') loadConflicts();
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
        showToast(netErr(e), 'error');
        setTimeout(() => { showProgress(false); setButtonsDisabled(false); }, 3000);
    }
}

// ========== THEME ==========

// theme button: the moon in the dark theme, the sun in the light one
const THEME_ICON_SUN = '<svg class="theme-sun" width="1em" height="1em" aria-hidden="true" style="display:block" xmlns="http://www.w3.org/2000/svg" viewBox="30.4 24.1 464.0 464.0" transform="rotate(180)"><g class="sun-rays" stroke="#ffb300" stroke-width="16" stroke-linecap="round"><line pathLength="1" x1="262.4" y1="80.1" x2="262.4" y2="34.1"/><line pathLength="1" x1="329.7" y1="93.5" x2="338.9" y2="71.3"/><line pathLength="1" x1="386.8" y1="131.6" x2="419.3" y2="99.1"/><line pathLength="1" x1="425.0" y1="188.7" x2="447.1" y2="179.6"/><line pathLength="1" x1="438.4" y1="256.1" x2="484.4" y2="256.1"/><line pathLength="1" x1="425.0" y1="323.4" x2="447.1" y2="332.6"/><line pathLength="1" x1="386.8" y1="380.5" x2="419.3" y2="413.1"/><line pathLength="1" x1="329.7" y1="418.7" x2="338.9" y2="440.9"/><line pathLength="1" x1="262.4" y1="432.1" x2="262.4" y2="478.1"/><line pathLength="1" x1="195.0" y1="418.7" x2="185.8" y2="440.9"/><line pathLength="1" x1="137.9" y1="380.5" x2="105.4" y2="413.1"/><line pathLength="1" x1="99.7" y1="323.4" x2="77.6" y2="332.6"/><line pathLength="1" x1="86.4" y1="256.1" x2="40.4" y2="256.1"/><line pathLength="1" x1="99.7" y1="188.7" x2="77.6" y2="179.6"/><line pathLength="1" x1="137.9" y1="131.6" x2="105.4" y2="99.1"/><line pathLength="1" x1="195.0" y1="93.5" x2="185.8" y2="71.3"/></g><g><g><circle style="fill:#f7c931;" cx="262.352" cy="256.091" r="148.94"/></g><g><path style="fill:#ffb300;" d="M166.905,256.091c0-73.127,52.701-133.942,122.194-146.544c-8.678-1.574-17.617-2.4-26.748-2.4 c-82.26,0-148.944,66.684-148.944,148.944s66.684,148.944,148.944,148.944c9.131,0,18.071-0.826,26.748-2.4 C219.607,390.033,166.905,329.218,166.905,256.091z"/><path style="fill:#ffb300;" d="M367.456,300.387c-0.807,0-1.629-0.125-2.438-0.39c-4.115-1.345-6.36-5.772-5.016-9.887 c3.58-10.952,5.395-22.398,5.395-34.019c0-4.329,3.51-7.84,7.84-7.84s7.84,3.51,7.84,7.84c0,13.279-2.076,26.364-6.17,38.89 C373.825,298.287,370.755,300.387,367.456,300.387z"/><path style="fill:#ffb300;" d="M281.708,378.606c-3.579,0-6.811-2.467-7.638-6.104c-0.96-4.223,1.686-8.423,5.908-9.381 c24.888-5.654,47.207-20.014,62.847-40.436c2.634-3.437,7.555-4.09,10.991-1.458c3.438,2.633,4.09,7.553,1.458,10.991 c-17.863,23.324-43.369,39.729-71.822,46.193C282.869,378.542,282.284,378.606,281.708,378.606z"/></g></g></svg>';
const THEME_ICON_MOON = '<svg width="1em" height="1em" aria-hidden="true" style="display:block" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><g transform="rotate(-90 256 256)"><g><g><path style="fill:#FCE4A8;" d="M90.822,60.408c105.574-92.296,264.984-76,357.28,29.574s84.138,262.286-21.436,354.583 S158.688,529.26,66.392,423.687S-14.752,152.704,90.822,60.408z"/><path style="fill:#F6D89C;" d="M107.702,89.331c99.918-87.352,248.823-74.176,333.823,23.051s75.389,243.385-24.528,330.736 c-99.918,87.352-251.733,82.319-336.733-14.909S7.784,176.683,107.702,89.331z"/><g><path style="fill:#F0C684;" d="M244.034,141.578C226.114,178.849,181.001,192.92,143.73,175 c-37.271-17.92-53.236-61.358-35.316-98.629c17.92-37.271,62.836-54.047,100.107-36.127 C245.792,58.164,261.954,104.307,244.034,141.578z"/><path style="opacity:0.06;fill:#040000;" d="M128.089,97.737c17.92-37.271,62.836-54.047,100.107-36.127 c4.127,1.984,7.995,4.316,11.586,6.943c-7.335-11.909-17.951-21.909-31.261-28.309c-37.271-17.92-82.187-1.144-100.107,36.127 c-15.805,32.873-5.247,70.539,23.036,91.267C118.965,147.179,116.792,121.234,128.089,97.737z"/></g><path style="fill:#F0C684;" d="M217.126,218.456c-1.17-5.733,2.71-11.178,8.442-12.348c5.733-1.17,11.248,2.359,12.418,8.092 s-2.456,11.466-8.189,12.636C224.065,228.005,218.296,224.189,217.126,218.456z"/><path style="opacity:0.5;fill:#FFFFFF;" d="M363.159,97.031c-1.17-5.733,2.71-11.178,8.442-12.348s11.248,2.359,12.418,8.092 c1.17,5.733-2.456,11.466-8.189,12.636C370.097,106.581,364.328,102.764,363.159,97.031z"/><path style="fill:#F0C684;" d="M282.758,398.482c8.691-7.598,21.813-6.256,29.411,2.434c7.598,8.691,6.926,21.591-1.765,29.189 c-8.691,7.598-22.06,6.972-29.658-1.719C273.149,419.697,274.067,406.08,282.758,398.482z"/><path style="opacity:0.5;fill:#FFFFFF;" d="M58.328,221.051c-1.17-5.733,2.71-11.178,8.442-12.348 c5.733-1.17,11.248,2.359,12.418,8.092c1.17,5.733-2.456,11.466-8.189,12.636C65.267,230.6,59.498,226.784,58.328,221.051z"/><path style="fill:#F0C684;" d="M468.957,281.792c-3.725,36.65-37.257,62.1-73.907,58.374c-36.65-3.725-63.179-35.28-59.453-71.93 c3.725-36.65,36.273-64.306,72.923-60.581C445.17,211.381,472.683,245.142,468.957,281.792z"/><g><path style="fill:#F0C684;" d="M173.243,331.228c14.631,25.328,4.867,57.296-20.461,71.927 c-25.328,14.631-57.072,6.642-71.703-18.687c-14.631-25.328-6.526-58.259,18.802-72.89 C125.209,296.946,158.611,305.899,173.243,331.228z"/><path style="opacity:0.06;fill:#040000;" d="M112.82,324.421c18.464-10.666,41.211-8.787,57.856,2.82 c-15.693-22.239-46.848-29.497-70.796-15.664c-25.328,14.631-33.433,47.562-18.802,72.89c4.04,6.993,9.388,12.657,15.541,16.895 c-0.915-1.299-1.789-2.644-2.602-4.052C79.387,371.983,87.492,339.052,112.82,324.421z"/></g><path style="opacity:0.06;fill:#040000;" d="M349.708,282.184c3.725-36.65,36.272-64.306,72.923-60.581 c12.217,1.242,23.416,5.824,32.783,12.736c-11.007-14.534-27.695-24.731-46.895-26.682c-36.65-3.725-69.197,23.931-72.922,60.581 c-2.465,24.248,8.316,46.262,26.507,59.465C352.784,315.151,347.977,299.219,349.708,282.184z"/></g><path style="opacity:0.1;fill:#040000;" d="M254.816,381.8c-105.36,0-198.423-52.065-254.726-131.657 C-2.613,349.865,55.643,444.482,154.03,486.89c128.776,55.508,279.654,1.534,335.162-127.242 c15.267-35.419,21.657-72.749,20.289-109.419C453.171,329.772,360.138,381.8,254.816,381.8z"/></g></g></svg>';

async function toggleTheme() {
    const current = document.documentElement.getAttribute('data-theme');
    const newTheme = current === 'light' ? 'dark' : 'light';
    
    const icon = document.getElementById('themeIcon');
    icon.innerHTML = newTheme === 'light' ? THEME_ICON_SUN : THEME_ICON_MOON;
    // switched to the sun: its rays appear one by one, clockwise (not when the page opens)
    if (newTheme === 'light') {
        const sun = icon.querySelector('svg');
        if (sun) {
            // ray 8 is at the top on screen (the picture is turned by 180 degrees): the wave starts there
            sun.querySelectorAll('.sun-rays line').forEach((l, i) => { l.style.animationDelay = (((i + 8) % 16) * 0.03) + 's'; });
            sun.classList.add('sun-rays-anim');
        }
    }
    
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
        icon.innerHTML = res.theme === 'light' ? THEME_ICON_SUN : THEME_ICON_MOON;
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
    if (this.dataset.tab === 'roms') refreshStats();
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
    // the card is titled with the cloud service in use (Yandex Disk, pCloud...)
    document.getElementById('sysCloudLabel').textContent = data.cloud?.service || 'Cloud';
    if (data.cloud?.status === 'connected' && data.cloud.slow) {
      // the cloud answers, but slowly - that explains a long sync
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z" fill="currentColor"/></svg> slow (' + data.cloud.slow + ' s)';
      cloudEl.className = 'value warning';
    } else if (data.cloud?.status === 'connected') {
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg> ' + ((data.cloud.free && data.cloud.free !== '0') ? data.cloud.free : 'connected');
      cloudEl.className = 'value ok';
    } else {
      cloudEl.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" style="vertical-align:-2px"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" fill="currentColor"/></svg> ' + (data.internet ? 'not responding' : 'no internet');
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

// ========== CLOUD SWITCH (Settings) ==========
// The current cloud and the previous one (kept when the cloud is changed in the control
// center) change places; the item is shown only when there is a previous cloud.
const CLOUD_T = {"confirm": "Switch the cloud to {name}?|The saves on the device will be merged with this cloud: others are downloaded, own ones uploaded, nothing is deleted.|Switch the other devices the same way.", "checking": "Checking the connection to {name}...", "done": "Cloud changed: {name}"};

async function loadCloudSwitch() {
  const res = await apiFetch('/cloud/prev');
  const row = document.getElementById('cloudSwitchRow');
  const hint = document.getElementById('cloudSwitchHint');
  if (!res || !res.prev) { row.style.display = 'none'; hint.style.display = 'none'; return; }
  const sel = document.getElementById('settingCloud');
  sel.innerHTML = '';
  [['cur', res.current], ['prev', res.prev]].forEach(([v, t]) => {
    const o = document.createElement('option');
    o.value = v; o.textContent = t;
    sel.appendChild(o);
  });
  sel.value = 'cur';
  row.style.display = '';
  hint.style.display = '';
}

function cloudSwitchStatus(text, err) {
  const el = document.getElementById('cloudSwitchStatus');
  el.textContent = text || '';
  el.style.display = text ? 'block' : 'none';
  el.style.color = err ? 'var(--error)' : 'var(--accent)';
}

async function cloudSwitch() {
  const sel = document.getElementById('settingCloud');
  if (sel.value !== 'prev') return;
  const name = sel.options[sel.selectedIndex].textContent;
  const NL = String.fromCharCode(10);
  if (!confirm(CLOUD_T.confirm.replace('{name}', name).split('|').join(NL + NL))) { sel.value = 'cur'; return; }
  sel.disabled = true;
  cloudSwitchStatus(CLOUD_T.checking.replace('{name}', name));
  const res = await apiFetch('/cloud/switch', { method: 'POST' });
  sel.disabled = false;
  if (!res.success) {
    sel.value = 'cur';
    cloudSwitchStatus(res.error || 'Error', true);
    showToast(res.error || 'Error', 'error');
    return;
  }
  cloudSwitchStatus('');
  showToast(CLOUD_T.done.replace('{name}', res.current), 'success');
  await loadCloudSwitch();
  refreshStatus();
  // the sync progress is shown in the saves tab
  const tab = document.querySelector('.tab[data-tab="saves"]');
  if (tab) tab.click();
  runSyncWithProgress('full');
}

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
    loadCloudSwitch();
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
    showToast(netErr(e), 'error');
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
        {'true': 'NO VIDEOS', 'video': 'WITH VIDEOS'}[config.ROMS_SYNC_MEDIA] || 'OFF';
      showToast(res.message, 'success');
      refreshStatus();
    } else {
      showToast((res.error || 'Error'), 'error');
    }
  } catch (e) {
    showToast(netErr(e), 'error');
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
    document.getElementById('mediaStatus').textContent = {'true': 'NO VIDEOS', 'video': 'WITH VIDEOS'}[config.ROMS_SYNC_MEDIA] || 'OFF';
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
    showToast(netErr(e), 'error');
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
      showToast('Settings saved', 'success');
      await loadSettings();
    } else {
      showToast((res.error || 'Error'), 'error');
    }
  } catch (e) {
    showToast(netErr(e), 'error');
  }
}

// ========== STATISTICS ==========

async function refreshStats() {
  // the save statistics are in the status bar at the top; the ROM ones are one line in the ROMs tab
  try {
    const data = await apiFetch('/stats');
    const el = document.getElementById('romsStats');
    if (data && el) {
      const total = data.roms?.total || 0, ok = data.roms?.ok || 0, err = data.roms?.error || 0;
      el.innerHTML =
        '<span class="chip">Operations <b>' + total + '</b></span>' +
        '<span class="chip ok">Successful <b>' + ok + '</b></span>' +
        '<span class="chip' + (err > 0 ? ' err' : '') + '">Errors <b>' + err + '</b></span>';
    }
  } catch (e) {
    console.error('Stats error:', e);
  }
}

// ========== STARTUP ==========

// ========== SAVE CONFLICTS ==========
const CONF_T = {"head": "Save conflicts", "hint": "These saves were changed on two devices. The sync kept the newer version and stored the other one here. \\"Restore\\" makes the chosen version the current one on all devices; the current version is stored here too.", "from": "version from {dev}", "left": "kept until {until}", "last": "deleted at the next sync", "notHere": "this file is not on this device", "notSynced": "this system is not synced on this device", "restore": "Restore", "del": "Delete", "confirmRestore": "Restore the version of {file} from {dev} ({time})?\\n\\nIt becomes the current one on all devices, the current version is stored with the conflicts.\\nIf this game is running now, exit it first.", "confirmDel": "Delete the copy of {file} ({dev}, {time})?\\nIt cannot be restored afterwards.", "phase": "Restoring a version", "deleted": "Copy deleted", "badge": "There are save conflicts", "short": "The version from the other device is kept here: restore it or delete it.", "more": "More ▸", "less": "Less ▴", "kindState": "save state", "kindSave": "game save"};

async function loadConflicts() {
  const box = document.getElementById('conflictsBox');
  const badge = document.getElementById('conflictsBadge');
  const res = await apiFetch('/conflicts');
  if (!res.success) return;               // the cloud is not reachable: keep what is shown
  const items = res.items || [];
  badge.style.display = items.length ? '' : 'none';
  badge.textContent = items.length;
  if (!items.length) { box.style.display = 'none'; return; }
  document.getElementById('conflictsHead').textContent = CONF_T.head;
  document.getElementById('conflictsCount').textContent = items.length;
  conflictHint();
  window._conflicts = items;
  document.getElementById('conflictsList').innerHTML = items.map((c, i) => {
    const meta = [CONF_T.from.replace('{dev}', c.dev), c.time,
                  c.until ? CONF_T.left.replace('{until}', c.until) : CONF_T.last];
    if (!c.keep) meta.pop();           // this device does not remove copies: other devices decide
    if (!c.synced) meta.push(CONF_T.notSynced);
    else if (!c.here) meta.push(CONF_T.notHere);
    const g = conflictGame(c);
    return '<div class="conflict-row"><div class="conflict-info">' +
      '<div class="conflict-file" title="' + escapeHtml(c.file) + '">' + escapeHtml(g.name) + '</div>' +
      '<div class="cf-chips">' + (g.sys ? '<span class="cf-chip">' + escapeHtml(g.sys) + '</span>' : '') +
      '<span class="cf-chip">' + escapeHtml(g.kind) + '</span></div>' +
      '<div class="conflict-meta">' + escapeHtml(meta.join(' · ')) + '</div></div>' +
      '<div class="conflict-actions">' +
      '<button class="btn btn-primary" onclick="conflictRestore(' + i + ')"' + (c.synced ? '' : ' disabled') + '>' + CONF_T.restore + '</button>' +
      '<button class="btn cf-del" onclick="conflictDelete(' + i + ')">' + CONF_T.del + '</button>' +
      '</div></div>';
  }).join('');
  box.style.display = '';
}

// "nes/Adventure Island (U).state" -> NES, "state", "Adventure Island (U)"
function conflictGame(c) {
  const parts = c.file.split('/');
  let name = parts[parts.length - 1];
  const dot = name.lastIndexOf('.');
  const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
  if (dot > 0) name = name.slice(0, dot);
  const state = ext.startsWith('state') || ext === 'auto' || name.toLowerCase().endsWith('.state');
  if (name.toLowerCase().endsWith('.state')) name = name.slice(0, -6);
  return { sys: parts.length > 1 ? parts[0] : '', kind: state ? CONF_T.kindState : CONF_T.kindSave, name: name };
}

// the short hint; "More" shows the whole explanation
let conflictHintOpen = false;
function conflictHint() {
  const el = document.getElementById('conflictsHint');
  el.innerHTML = escapeHtml(CONF_T.short) + '<button type="button" class="cf-more" onclick="conflictHintOpen = !conflictHintOpen; conflictHint()">' +
    escapeHtml(conflictHintOpen ? CONF_T.less : CONF_T.more) + '</button>' +
    (conflictHintOpen ? '<span class="cf-long">' + escapeHtml(CONF_T.hint) + '</span>' : '');
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
loadSettings();        // load settings once on startup
refreshStatus();
refreshLogs();
refreshStats();
loadSystems();         // LOAD SYSTEMS ON STARTUP
loadConflicts();

// Auto-refresh (settings are NOT updated)
// ========== DOWNLOAD FROM A PUBLIC LINK ==========
const LINK_T = {"saveCat": "Save catalog", "savedCat": "Game catalog: opens with its list of games", "savedLabel": "Saved:", "save": "Save", "saved": "Saved", "savePrompt": "Name of the link", "unsave": "Remove “{name}” from the saved links?", "savedOk": "Link saved", "enterUrl": "Paste a link first", "loading": "Reading the file list… big folders can take a minute.", "needPw": "The link is password-protected: enter the password and press Open.", "empty": "There are no files at this link.", "files": "files", "nothingSel": "Tick the files or folders to download", "selected": "Selected: {n}", "free": "free on the card: {free}", "noSpace": "not enough space", "contents": "The contents of “{name}” will be placed into {dest}", "items": "The selected items will be placed into {dest}", "chooseDest": "— choose a system —", "needDest": "Choose where to put the files", "phase": "Downloading from link", "done": "Download from link complete", "failed": "Download from link failed", "unavailable": "Link download is not available on this device (python3 or link_download.py missing).", "selectAll": "Select all", "root": "root", "nfiles": "files: {n}", "grpDeviceFiles": "Systems with games (ROM files)", "grpDeviceOther": "Systems without games", "grpCloudFiles": "Systems in the cloud", "grpCloudOther": "Add a new system to the cloud", "freeCloud": "free in the cloud: {free}", "cloudLabel": "cloud: GameROMs/{sys}", "cloudNote": "Then put them on the device: ROMs → select the system → Download ROMs.", "cloudUnavailable": "The cloud is not available: Save Sync is not set up or rclone does not start.", "loadingDests": "loading…", "zipMeta": "archive · click to open", "zipReading": "Reading archive “{name}”…", "zipContents": "Archive “{name}” will be unpacked into {dest}", "zipItems": "The selected files will be unpacked from the archive into {dest}", "zipAsIs": "Archives are downloaded as is, not unpacked. Cartridge consoles usually run .zip/.7z themselves. Need single games? Open the zip or turn on “Unpack archives”.", "unpackLabel": "Unpack archives after download ({kinds})", "arcMeta": "{kind} archive", "unpackYes": "{kinds}: will be unpacked into the system folder, the archives are deleted", "unpackCannot": "{kinds}: nothing on this device can unpack them — downloaded as is", "unpackCloud": "For the cloud: files from .zip are taken straight from the archive; .7z/.rar are first downloaded to the card for a moment, unpacked and uploaded — this needs about 3× the archive size free on the card."};
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
    // a saved list of this link is on the screen: it stays while the link is read
    const keep = !!(catState && catState.cached && linkState.url === url);
    if (!keep) {
        linkSetStatus(LINK_T.loading, false);
        document.getElementById('linkBrowser').style.display = 'none';
    }
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
    if (res.error || !res.root) {
        if (keep && catState && catState.cached) { linkSetStatus(CAT_T.offline + ' ' + (res.error || ''), true); return; }
        linkSetStatus(res.error || 'Error', true); linkSavedRender(); return;
    }
    if (res.root.dir && !res.root.files) { linkSetStatus(LINK_T.empty, true); return; }
    linkState = { url: url, service: res.service, root: res.root, stack: [res.root], password: pw, direct: !!res.direct,
                  target: linkState.target, dests: linkState.dests, probe: null, destManual: false };
    const still = keep && catState && catState.cached;
    if (!still) {
        catState = null;
        catShow(false);
        linkSetStatus('', false);
    }
    if (!pw) document.getElementById('linkPwRow').style.display = 'none';
    document.getElementById('linkBrowser').style.display = 'block';
    linkRender();
    catProbe();
    linkLoadDests(linkState.target).then(() => { linkFillDests(); linkUpdateSummary(); });
    linkSavedRender();
    // a saved link with a catalog: the catalog opens right away
    const want = linkPendingCat;
    linkPendingCat = null;
    if (want && want.url === url && want.dir) catOpen(want.dir === '/' ? '' : want.dir);
    else if (still) linkSetStatus('', false);
}

// ---- saved links (sync.conf, WEB_LINKS)
let linkSaved = [];
const LS_CAT_ICON = '<svg class="ls-cat" width="13" height="13" viewBox="0 0 24 24" fill="none"><rect x="3" y="3" width="7.5" height="7.5" rx="1.5" fill="currentColor"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="1.5" fill="currentColor"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="1.5" fill="currentColor"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1.5" fill="currentColor"/></svg>';
let linkPendingCat = null;

async function linkSavedLoad() {
    const res = await apiFetch('/links/saved');
    linkSaved = (res && res.links) || [];
    linkSavedRender();
}

function linkSavedRender() {
    const box = document.getElementById('linkSaved');
    const cur = linkState.url;
    box.style.display = linkSaved.length ? 'flex' : 'none';
    box.innerHTML = '<span class="ls-label">' + escapeHtml(LINK_T.savedLabel) + '</span>' + linkSaved.map((l, i) =>
        '<span class="ls-chip' + (linkSavedIsCur(l) ? ' on' : '') + '" title="' + escapeHtml(l.url) + '">' +
        // a saved catalog (a collection with gamelist.xml) gets the catalog icon
        '<button type="button" onclick="linkSavedOpen(' + i + ')"' + (l.dir ? ' title="' + escapeHtml(LINK_T.savedCat) + '"' : '') + '>' +
        (l.dir ? LS_CAT_ICON : '') + escapeHtml(l.name) + '</button>' +
        '<button type="button" class="ls-x" onclick="linkSavedRemove(' + i + ')">×</button></span>').join('');
    const btn = document.getElementById('linkSaveBtn');
    // a direct link to a file is temporary (signed links expire): not offered for saving
    const open = !!(linkState.url && linkState.root) && !linkState.direct;
    btn.style.display = open ? '' : 'none';
    const st = linkSavedState();
    const word = st.on ? LINK_T.saved : catState ? LINK_T.saveCat : LINK_T.save;
    // on a phone only the star is shown, so the link field keeps its width
    btn.innerHTML = '<span class="ls-star">' + (st.on ? '★' : '☆') + '</span><span class="ls-word"> ' + escapeHtml(word) + '</span>';
    btn.title = word;
}

// what is open now: a catalog ('/' = at the top of the link) or the files ('')
function linkSavedDir() { return catState ? (catState.dir || '/') : ''; }

function linkSavedIsCur(l) {
    if (l.url !== linkState.url) return false;
    return catState ? (l.dir || '') === linkSavedDir() : true;
}

// {on: saved as it is open now, at: that entry, plain: the same link saved without a catalog}
function linkSavedState() {
    const url = linkState.url;
    const plain = linkSaved.findIndex(l => l.url === url && !l.dir);
    if (catState) {
        const at = linkSaved.findIndex(l => l.url === url && l.dir === linkSavedDir());
        return { on: at >= 0, at: at, plain: plain };
    }
    // the files of a link saved only as catalogs: counted as saved
    const at = plain >= 0 ? plain : linkSaved.findIndex(l => l.url === url);
    return { on: at >= 0, at: at, plain: plain };
}

async function linkSavedOpen(i) {
    const l = linkSaved[i];
    if (!l) return;
    document.getElementById('linkUrl').value = l.url;
    document.getElementById('linkPw').value = '';
    linkPendingCat = { url: l.url, dir: l.dir || '' };
    if (l.dir) {
        // a saved catalog: its saved list is shown at once, the collection is read meanwhile
        const res = await apiFetch('/link/catalog_cached', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: l.url, password: '', dir: l.dir })
        });
        if (res && res.games && linkPendingCat && linkPendingCat.url === l.url) {
            linkState = { url: l.url, service: res.service || '', root: null, stack: [], password: '', direct: false,
                          target: linkState.target, dests: linkState.dests, probe: null, destManual: false };
            catShowCached(res);
            linkLoadDests(linkState.target).then(() => { linkFillDests(); if (catState) catSummary(); });
        }
    }
    linkOpen();
}

async function linkSavedPut(list) {
    const res = await apiFetch('/links/saved', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ links: list })
    });
    if (!res || res.error) { showToast((res && res.error) || 'Error', 'error'); return false; }
    linkSaved = res.links || [];
    linkSavedRender();
    return true;
}

async function linkSavedRemove(i) {
    const l = linkSaved[i];
    if (!l || !confirm(LINK_T.unsave.replace('{name}', l.name))) return;
    await linkSavedPut(linkSaved.filter((_, j) => j !== i));
}

// the open link: saved (with the catalog folder when a catalog is open) or removed
async function linkSaveToggle() {
    const url = linkState.url;
    const st = linkSavedState();
    if (st.on) { linkSavedRemove(st.at); return; }
    const root = (linkState.root && linkState.root.name) || linkState.service;
    const def = catState ? root + ' · ' + catState.title : root;
    const name = prompt(LINK_T.savePrompt, def);
    if (name === null) return;
    const item = { name: name.trim() || def, url: url, dir: linkSavedDir() };
    // a catalog of a link saved without one: that entry becomes the catalog (no second entry)
    const list = catState && st.plain >= 0 ? linkSaved.map((l, j) => j === st.plain ? item : l) : linkSaved.concat([item]);
    if (await linkSavedPut(list)) {
        showToast(LINK_T.savedOk);
        if (catState) apiFetch('/link/catalog_seen', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: url, dir: item.dir, games: catState.games.map(g => [g.path, g.size]) })
        });
    }
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
            '<span class="link-meta" data-mi="' + idx + '">' + escapeHtml(meta) + '</span>';
        const cb = row.querySelector('input');
        if (cb) cb.onchange = linkUpdateSummary;
        if (e.dir) row.querySelector('.link-name').onclick = () => { linkState.stack.push(e); linkRender(); };
        else if (e.zip) row.querySelector('.link-name').onclick = () => linkOpenZip(e);
        list.appendChild(row);
    });
    catOfferUpdate(cur);
    linkHaveKey = '';
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

// The system folder is picked from the names of the link: a ticked "nes.zip", the opened
// folder "snes", an archive.org item "gb_drago557" (its first word), a catalog's folder.
// A system chosen by hand is never changed.
function linkGuessDest() {
    const sel = document.getElementById('linkDest');
    if (!sel || (linkState.destManual && sel.value)) return;
    const opts = Array.from(sel.options).map(o => o.value).filter(Boolean);
    if (!opts.length) return;
    const names = [];
    if (catState) names.push(catState.system, catState.title);
    else {
        const picked = linkCurrent() && linkCurrent().dir ? linkSelected() : [];
        if (picked.length === 1) names.push(picked[0].name);
    }
    linkState.stack.slice().reverse().forEach(e => names.push(e.name));
    for (const raw of names) {
        if (!raw) continue;
        const base = raw.replace(/[.](zip|7z|rar)$/i, '').toLowerCase();
        for (const n of [base, base.split(/[ _.-]/)[0]]) {
            const hit = opts.find(o => o.toLowerCase() === n);
            if (hit) { if (sel.value !== hit) sel.value = hit; return; }
        }
    }
}

// Files of the open folder already on the device (same name and size in roms/<system>,
// where ticked files go) get a mark. Folders are not marked: where their files land
// depends on what else is ticked.
let linkHaveKey = '';
async function linkMarkHave() {
    const cur = linkCurrent();
    const dest = document.getElementById('linkDest').value;
    const files = (cur && cur.dir ? (cur.children || []) : []).map((e, i) => ({ e: e, i: i })).filter(x => !x.e.dir);
    const key = (linkState.url || '') + '|' + (cur ? cur.path : '') + '|' + dest + '|' + linkState.target;
    if (key === linkHaveKey) return;
    linkHaveKey = key;
    const list = document.getElementById('linkList');
    list.querySelectorAll('[data-mi]').forEach(el => { if (el.dataset.orig) el.textContent = el.dataset.orig; });
    if (catState || !dest || linkState.target !== 'device' || !files.length) return;
    const res = await apiFetch('/link/have', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ dest: dest, files: files.map(x => ({ name: x.e.name, size: x.e.size })) })
    });
    if (key !== linkHaveKey || !res || !res.have) return;
    const have = new Set(res.have);
    files.forEach(x => {
        if (!have.has(x.e.name)) return;
        const el = list.querySelector('[data-mi="' + x.i + '"]');
        if (!el) return;
        if (!el.dataset.orig) el.dataset.orig = el.textContent;
        el.innerHTML = '<span class="cat-have">' + escapeHtml(CAT_T.have) + '</span> · ' + escapeHtml(el.dataset.orig);
    });
}

function linkUpdateSummary() {
    linkGuessDest();
    if (!catState) linkMarkHave();
    if (catState) { catSummary(); return; }
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
    if (catState) { catDownload(); return; }
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
    if (catState && ok) {
        if (linkState.target !== 'cloud') catState.games.forEach(g => { if (catState.sel.has(g.path)) g.have = true; });
        catState.sel.clear();
        catRender();
    }
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
        linkHaveKey = '';      // files just downloaded get their mark
        linkLoadDests(linkState.target).then(() => { linkFillDests(); if (linkState.root) linkUpdateSummary(); });
    }, ok ? 2500 : 5000);
}

// ========== GAME CATALOG ==========
// A folder with gamelist.xml (EmulationStation) is shown as a list of games: names,
// descriptions, covers. The chosen games are downloaded with only their own media and
// added to gamelist.xml on the device.
const CAT_T = {"found": "“{name}” has a game list (gamelist.xml): pick games from a list with covers.", "maybe": "Looks like a game collection in an archive: if it has a gamelist.xml inside, it opens as a catalog.", "open": "Open as a catalog", "reading": "Reading the game list… this can take a minute for big collections.", "title": "{name} · {n} games", "count": "{n} games", "selectShown": "Select shown ({n})", "have": "✓ on the device", "noGames": "Nothing found", "media": "Media:", "nothingSel": "Tick the games to download", "selected": "Games selected: {n} · games {roms} + media {media} = {total}", "dest": "The games, their media and gamelist.xml entries go to roms/{dest}", "destNone": "Choose the system to put the games into", "recalboxNote": "On Recalbox, after the download the window “Game list changed!” appears — press “Update”. Do not use the menu item “Update gamelists” for this: it would overwrite the descriptions.", "destCloud": "The games, their media and gamelist.xml entries go to {dest}", "cloudVideo": "Videos reach the devices only with ROMs → Media: with videos", "cloudMedia": "Media reach the devices only when ROMs → Media is on", "noMedia": "No media selected: the games will have no covers", "loadingPic": "Loading the picture…", "noPic": "No picture", "fromDevice": "Device", "fromLink": "Collection", "replaceMedia": "Replace media", "replaceDesc": "Replace description", "replaceHint": "For games already on the device: media and description from the collection replace their own (name, favorite and play count stay)", "replaceNote": "For games already on the device, taken from the collection: {what}", "keepNote": "For games already on the device, their own media and description stay; only what is missing is added", "whatMedia": "media", "whatDesc": "description", "picFailed": "The picture did not load", "shot": {"thumbnail": "Cover", "boxart": "Cover", "image": "Image", "screenshot": "Screenshot", "mix": "Mix", "titleshot": "Title", "fanart": "Fanart"}, "video": "▶ Video · {size}", "loadingVideo": "Loading the video…", "noVideo": "The video did not load", "genre": "Genre", "players": "Players", "developer": "Developer", "publisher": "Publisher", "file": "File", "lang": "Language", "region": "Region", "allGenres": "All genres", "anyPlayers": "Players: any", "players1": "1 player", "playersN": "{n}+ players", "hideHave": "Not on the device", "onlySel": "Selected ({n})", "sorts": {"col": "Collection order", "name": "By name", "yearAsc": "Oldest first", "yearDesc": "Newest first", "sizeAsc": "Smallest first", "sizeDesc": "Largest first"}, "markNew": "new", "markChanged": "updated", "onlyNew": "New and updated ({n})", "checking": "The saved list is shown. Checking the collection for updates…", "offline": "The collection did not answer: the saved list is shown, downloading is not possible.", "waitCheck": "Wait until the collection is checked", "more": "Show more ({n})", "notShown": " (not shown by EmulationStation)", "kinds": {"thumbnail": "Covers", "image": "Image", "marquee": "Logos", "wheel": "Logos (wheel)", "boxart": "Covers (alt)", "boxback": "Box backs", "cartridge": "Cartridges", "titleshot": "Title screens", "screenshot": "Screenshots", "fanart": "Fan art", "mix": "Mixes", "map": "Maps", "bezel": "Bezels", "video": "Videos", "manual": "Manuals", "magazine": "Magazines"}};
const CAT_SKIP = ['media', 'images', 'videos', 'manuals', 'downloaded_images', 'downloaded_videos'];
const CAT_KIND_ORDER = ['thumbnail', 'image', 'marquee', 'wheel', 'boxart', 'screenshot', 'titleshot', 'mix',
                        'cartridge', 'fanart', 'boxback', 'bezel', 'map', 'video', 'manual', 'magazine'];
const CAT_KIND_OFF = ['video', 'manual', 'magazine'];
// media tags EmulationStation shows (Batocera / KNULLI; Recalbox uses fewer): files under
// other tags would show nowhere, so they are not offered
const CAT_ES_TAGS = ['image', 'thumbnail', 'marquee', 'video', 'fanart', 'titleshot', 'manual', 'magazine',
                     'map', 'bezel', 'cartridge', 'boxart', 'boxback', 'wheel', 'mix'];
const CAT_PIC_ORDER = ['thumbnail', 'image', 'boxart', 'screenshot', 'mix', 'titleshot', 'marquee', 'wheel', 'cartridge', 'fanart'];
// what shows the game itself (logos, cartridges, bezels and folder pictures do not)
const CAT_GALLERY = ['thumbnail', 'boxart', 'image', 'screenshot'];
const CAT_PAGE = 300;
let catState = null;
let catOfferPath = null;

function catShow(on) {
    document.getElementById('catBox').style.display = on ? 'block' : 'none';
    document.getElementById('linkList').style.display = on ? 'none' : '';
    if (on) {
        document.getElementById('linkUnpackRow').style.display = 'none';
        document.getElementById('catOffer').style.display = 'none';
    }
}

function catFindDir(e, depth) {
    const queue = [[e, 0]];
    while (queue.length) {
        const [d, lvl] = queue.shift();
        if (!d || !d.dir) continue;
        const kids = d.children || [];
        if (kids.some(c => !c.dir && c.name.toLowerCase() === 'gamelist.xml')) return d;
        if (lvl < depth) kids.forEach(c => { if (c.dir && !CAT_SKIP.includes(c.name.toLowerCase())) queue.push([c, lvl + 1]); });
    }
    return null;
}

function catBigZips(e) {
    const out = [];
    const walk = (d, lvl) => (d.children || []).forEach(c => {
        if (c.dir) { if (lvl < 2 && !CAT_SKIP.includes(c.name.toLowerCase())) walk(c, lvl + 1); }
        else if (c.zip && (c.size || 0) >= 1048576) out.push(c);
    });
    if (e.dir) walk(e, 0);
    return out;
}

function catOfferUpdate(cur) {
    const box = document.getElementById('catOffer');
    catOfferPath = null;
    let text = '';
    if (!catState && cur && cur.dir) {
        const d = catFindDir(cur, 3);
        if (d) {
            catOfferPath = d.path || '';
            text = linkFmt(CAT_T.found, { name: d.name || linkState.service });
        } else if (linkState.probe && linkState.probe.dir.startsWith(cur.path ? cur.path.replace(/[/]$/, '') + '/' : '')) {
            catOfferPath = linkState.probe.dir;
            text = linkFmt(CAT_T.found, { name: linkState.probe.name || linkState.service });
        }
    }
    document.getElementById('catOfferText').textContent = text;
    box.style.display = catOfferPath === null ? 'none' : 'flex';
}

function catOpenFromOffer() { if (catOfferPath !== null) catOpen(catOfferPath); }

// A collection packed into one big zip (archive.org): look for gamelist.xml inside it
// quietly - the offer appears only when there really is one.
async function catProbe() {
    const root = linkState.root, url = linkState.url;
    if (!root || catFindDir(root, 3)) return;
    const zips = catBigZips(root);
    if (!zips.length || zips.length > 3) return;
    const res = await apiFetch('/link/catalog_probe', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url, password: linkState.password, path: '' })
    });
    if (!res || !res.dir || linkState.url !== url || linkState.root !== root) return;
    linkState.probe = res;
    if (!catState) catOfferUpdate(linkCurrent());
}

async function catOpen(path) {
    const prev = catState && catState.cached ? catState : null;     // the saved list on the screen
    document.getElementById('catOffer').style.display = 'none';
    if (!prev) linkSetStatus(CAT_T.reading, false);
    const res = await apiFetch('/link/catalog', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: linkState.url, password: linkState.password, path: path })
    });
    if (!res || res.error || !res.games) {
        if (prev && catState === prev) { linkSetStatus(CAT_T.offline, true); return; }
        linkSetStatus((res && res.error) || 'Error', true);
        catOfferUpdate(linkCurrent());
        return;
    }
    if (prev && catState !== prev) return;                          // another catalog meanwhile
    linkSetStatus('', false);
    catApply(res, prev);
}

// the saved list of a saved catalog, shown at once (the collection is checked meanwhile)
function catShowCached(res) {
    linkSetStatus(CAT_T.checking, false);
    document.getElementById('linkBrowser').style.display = 'block';
    catApply(res, null);
}

function catApply(res, prev) {
    let saved = null;
    try { saved = JSON.parse(localStorage.getItem('ss_cat_kinds2') || 'null'); } catch (e) { saved = null; }
    const allKinds = res.kinds || {};
    const esTags = res.es_media || CAT_ES_TAGS;
    const shown = {};
    Object.keys(allKinds).forEach(k => { if (esTags.includes(k)) shown[k] = allKinds[k]; });
    // what the details may show (a screenshot too) is kept apart: downloads get only what ES shows
    // a saved catalog: what is new and what changed since it was opened last time
    const seenNew = new Set((res.seen && res.seen.new) || []), seenChg = new Set((res.seen && res.seen.changed) || []);
    res.games.forEach(g => {
        g.isNew = seenNew.has(g.path);
        g.isChg = seenChg.has(g.path);
    });
    res.games.forEach(g => {
        g.look = {};
        Object.keys(g.media).forEach(k => {
            if (CAT_GALLERY.includes(k) || k === 'video') g.look[k] = g.media[k];
            if (!esTags.includes(k)) delete g.media[k];
        });
    });
    const kinds = Object.keys(shown);
    const on = new Set(kinds.filter(k => saved && saved[k] !== undefined ? saved[k] : !CAT_KIND_OFF.includes(k)));
    const sizes = {};
    res.games.forEach(g => [g.media, g.look].forEach(m => Object.keys(m || {}).forEach(k => { sizes[m[k][0]] = m[k][1] || 0; })));
    catState = { dir: res.dir, title: res.title, system: res.system, games: res.games, kinds: shown, sizes: sizes, cached: !!res.cached, coverRetry: {},
                 on: on, sel: new Set(), open: null, pics: {}, pending: {}, failed: {}, view: {}, local: {}, devReady: {}, devInfo: {}, source: {}, sid: res.sid || '', cover: {}, coverVis: new Set(), devCovers: {}, replaceMedia: false, replaceDesc: false, limit: CAT_PAGE, syncMedia: 'false',
                 recalbox: !!res.es_media };
    // the system folder is picked automatically when it exists (on the device or in the cloud)
    linkFillDests();
    apiFetch('/config').then(cfg => { if (catState && cfg) { catState.syncMedia = cfg.ROMS_SYNC_MEDIA || 'false'; catSummary(); } });
    if (prev) {
        // the checked list replaces the saved one: what was chosen on it stays
        const at = {};
        res.games.forEach((g, i) => { at[g.path] = i; });
        prev.sel.forEach(p => { if (p in at) catState.sel.add(p); });
        if (prev.open !== null && prev.games[prev.open] && prev.games[prev.open].path in at) catState.open = at[prev.games[prev.open].path];
        Object.keys(prev.cover).forEach(i => { const g = prev.games[i]; if (g && g.path in at && prev.cover[i]) catState.cover[at[g.path]] = prev.cover[i]; });
        ['pics', 'local', 'devReady', 'devInfo', 'devCovers'].forEach(k => { catState[k] = prev[k]; });
        catState.replaceMedia = prev.replaceMedia;
        catState.replaceDesc = prev.replaceDesc;
        catState.limit = prev.limit;
        const keep = {};
        ['catGenre', 'catPlayers', 'catSort'].forEach(id => { keep[id] = document.getElementById(id).value; });
        const hide = document.getElementById('catHideHave').checked;
        catFillFilters();
        Object.keys(keep).forEach(id => { const el = document.getElementById(id); if (Array.from(el.options).some(o => o.value === keep[id])) el.value = keep[id]; });
        document.getElementById('catHideHave').checked = hide;
    } else {
        document.getElementById('catSearch').value = '';
        catFillFilters();
    }
    const lst = document.getElementById('catList');
    if (!lst.dataset.zoom) {
        lst.dataset.zoom = '1';
        lst.addEventListener('click', e => {
            const im = e.target.closest('.cat-pic-main img');
            const pic = im && im.closest('.cat-pic');
            if (pic) catZoom(parseInt(pic.id.slice(6)), im.getAttribute('src'));
        });
    }
    catShow(true);
    catRenderKinds();
    catRender();
    linkSavedRender();
}

function catClose() {
    catState = null;
    catShow(false);
    linkRender();
    linkSavedRender();
}

function catRenderKinds() {
    const box = document.getElementById('catKinds');
    const kinds = Object.keys(catState.kinds).sort((a, b) => {
        const ia = CAT_KIND_ORDER.indexOf(a), ib = CAT_KIND_ORDER.indexOf(b);
        return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || a.localeCompare(b);
    });
    const replace = '<div class="cat-replace" title="' + escapeHtml(CAT_T.replaceHint) + '">' +
        '<label><input type="checkbox" id="catReplaceMedia"' + (catState.replaceMedia ? ' checked' : '') + '>' + escapeHtml(CAT_T.replaceMedia) + '</label>' +
        '<label><input type="checkbox" id="catReplaceDesc"' + (catState.replaceDesc ? ' checked' : '') + '>' + escapeHtml(CAT_T.replaceDesc) + '</label></div>';
    if (!kinds.length) {
        box.innerHTML = replace;
    } else {
        box.innerHTML = '<span>' + escapeHtml(CAT_T.media) + '</span>' + kinds.map(k =>
            '<label><input type="checkbox" data-kind="' + escapeHtml(k) + '"' + (catState.on.has(k) ? ' checked' : '') + '>' +
            escapeHtml((CAT_T.kinds[k] || k) + ' · ' + formatBytes(catState.kinds[k].size)) + '</label>').join('') + replace;
    }
    document.getElementById('catReplaceMedia').onchange = e => { catState.replaceMedia = e.target.checked; catSummary(); };
    document.getElementById('catReplaceDesc').onchange = e => { catState.replaceDesc = e.target.checked; catSummary(); };
    box.querySelectorAll('input[data-kind]').forEach(cb => cb.onchange = () => {
        if (cb.checked) catState.on.add(cb.dataset.kind); else catState.on.delete(cb.dataset.kind);
        try {
            const keep = {};
            Object.keys(catState.kinds).forEach(k => { keep[k] = catState.on.has(k); });
            localStorage.setItem('ss_cat_kinds2', JSON.stringify(keep));
        } catch (e) { /* private window */ }
        catSummary();
    });
}

// ---- filters, sorting, "selected only"
const CAT_SORTS = ['col', 'name', 'yearAsc', 'yearDesc', 'sizeAsc', 'sizeDesc'];
let catSort = 'col';
try { const v = localStorage.getItem('ss_cat_sort'); if (CAT_SORTS.includes(v)) catSort = v; } catch (e) { /* private window */ }

// "Platform / Shooter Scrolling" -> ['Platform', 'Shooter Scrolling']
function catGenres(g) {
    let parts = [g.genre || ''];
    ['/', ',', ';'].forEach(c => { parts = [].concat(...parts.map(x => x.split(c))); });
    return parts.map(x => x.trim()).filter(Boolean);
}

// "1-4" -> 4
function catMaxPlayers(g) {
    const m = String(g.players || '').match(/[0-9]+/g);
    return m ? Math.max(...m.map(Number)) : 0;
}

function catFillFilters() {
    const st = catState;
    const opt = (v, text, on) => '<option value="' + escapeHtml(v) + '"' + (on ? ' selected' : '') + '>' + escapeHtml(text) + '</option>';
    const genres = {};
    st.games.forEach(g => catGenres(g).forEach(x => { genres[x] = (genres[x] || 0) + 1; }));
    const names = Object.keys(genres).sort((a, b) => a.localeCompare(b));
    const gs = document.getElementById('catGenre');
    gs.innerHTML = opt('', CAT_T.allGenres) + names.map(x => opt(x, x + ' (' + genres[x] + ')')).join('');
    gs.style.display = names.length ? '' : 'none';
    const maxes = st.games.map(catMaxPlayers);
    const pl = [];
    if (maxes.some(m => m === 1)) pl.push(opt('1', CAT_T.players1));
    [2, 3, 4].forEach(n => { if (maxes.some(m => m >= n)) pl.push(opt(String(n), linkFmt(CAT_T.playersN, { n: n }))); });
    const ps = document.getElementById('catPlayers');
    ps.innerHTML = opt('', CAT_T.anyPlayers) + pl.join('');
    ps.style.display = pl.length > 1 ? '' : 'none';
    document.getElementById('catSort').innerHTML = CAT_SORTS.map(k => opt(k, CAT_T.sorts[k], k === catSort)).join('');
    document.getElementById('catHideText').textContent = CAT_T.hideHave;
    const fresh = st.games.filter(g => g.isNew || g.isChg).length;
    document.getElementById('catNewText').textContent = linkFmt(CAT_T.onlyNew, { n: fresh });
    document.getElementById('catNewRow').style.display = fresh ? '' : 'none';
    document.getElementById('catOnlyNew').checked = false;
    document.getElementById('catHideHave').checked = false;
}

function catSortChanged() {
    catSort = document.getElementById('catSort').value;
    try { localStorage.setItem('ss_cat_sort', catSort); } catch (e) { /* private window */ }
    catRender();
}

// "Selected": only the ticked games, whatever the search and the filters
function catToggleSel() {
    catState.onlySel = !catState.onlySel;
    catState.limit = CAT_PAGE;
    catRender();
}

function catShown() {
    const st = catState;
    const out = [];
    const busy = !!st.onlySel;
    ['catSearch', 'catGenre', 'catPlayers', 'catHideHave', 'catOnlyNew'].forEach(id => { document.getElementById(id).disabled = busy; });
    document.getElementById('catHideRow').style.display = st.games.some(g => g.have) ? '' : 'none';
    if (busy) {
        st.games.forEach((g, i) => { if (st.sel.has(g.path)) out.push(i); });
    } else {
        const q = (document.getElementById('catSearch').value || '').trim().toLowerCase();
        const genre = document.getElementById('catGenre').value;
        const pl = document.getElementById('catPlayers').value;
        const hide = document.getElementById('catHideHave').checked;
        const onlyNew = document.getElementById('catOnlyNew').checked;
        st.games.forEach((g, i) => {
            if (q && !g.name.toLowerCase().includes(q) && !(g.file || '').toLowerCase().includes(q)) return;
            if (hide && g.have) return;
            if (onlyNew && !g.isNew && !g.isChg) return;
            if (genre && !catGenres(g).includes(genre)) return;
            if (pl) {
                const m = catMaxPlayers(g);
                if (pl === '1' ? m !== 1 : m < parseInt(pl)) return;
            }
            out.push(i);
        });
    }
    if (catSort !== 'col') {
        const G = st.games;
        const cmp = {
            name: (a, b) => G[a].name.localeCompare(G[b].name, undefined, { numeric: true, sensitivity: 'base' }),
            yearAsc: (a, b) => (G[a].year || '9999').localeCompare(G[b].year || '9999'),
            yearDesc: (a, b) => (G[b].year || '0000').localeCompare(G[a].year || '0000'),
            sizeAsc: (a, b) => (G[a].size || 0) - (G[b].size || 0),
            sizeDesc: (a, b) => (G[b].size || 0) - (G[a].size || 0)
        }[catSort];
        out.sort((a, b) => cmp(a, b) || a - b);
    }
    return out;
}

// The pictures of a game on the whole screen: arrows, a swipe or the arrow keys go through
// them (those of the source chosen in the details); a tap or Esc closes it. The details
// show the picture last seen.
function catZoom(i, src) {
    const st = catState;
    const g = st.games[i];
    const all = catShots(g, catSource(g, i));
    const items = all.filter(x => x.kind !== 'video');
    if (!items.length) return;
    let cur = Math.max(0, items.findIndex(x => (x.url || st.pics[x.key]) === src));
    const box = document.createElement('div');
    box.className = 'cat-zoom';
    const img = document.createElement('img');
    img.alt = '';
    const cap = document.createElement('div');
    cap.className = 'cat-zoom-cap';
    // until a picture is there (or when it does not load) a message is shown in its place,
    // not an empty frame of the browser
    const msg = document.createElement('div');
    msg.className = 'cat-zoom-msg';
    img.style.display = 'none';
    img.onload = () => { img.style.display = ''; msg.textContent = ''; };
    img.onerror = () => { img.style.display = 'none'; msg.textContent = CAT_T.picFailed; };
    const put = src => {
        if (img.getAttribute('src') === src && img.complete && img.naturalWidth) { img.style.display = ''; msg.textContent = ''; }
        else img.src = src;
    };
    box.appendChild(img);
    box.appendChild(msg);
    box.appendChild(cap);
    const label = x => CAT_T.shot[x.kind] || CAT_T.kinds[x.kind] || x.kind;
    const show = async n => {
        cur = (n + items.length) % items.length;
        const x = items[cur], at = cur;
        const pos = items.length > 1 ? ' · ' + (cur + 1) + ' / ' + items.length : '';
        cap.textContent = label(x) + pos;
        if (catState === st && st.open === i) catShot(i, all.indexOf(x));    // the details follow
        img.style.display = 'none';
        msg.textContent = CAT_T.loadingPic;
        if (x.url || st.pics[x.key]) { put(x.url || st.pics[x.key]); return; }
        img.removeAttribute('src');
        const res = await catFetchPic(x.key);
        if (at !== cur || !box.isConnected) return;
        if (res && res.data) put(res.data);
        else msg.textContent = CAT_T.picFailed;
    };
    // the page under it does not scroll while it is open
    document.documentElement.classList.add('cat-zoom-open');
    box.addEventListener('wheel', e => e.preventDefault(), { passive: false });
    box.addEventListener('touchmove', e => e.preventDefault(), { passive: false });
    const close = () => {
        box.remove();
        document.removeEventListener('keydown', key);
        document.documentElement.classList.remove('cat-zoom-open');
    };
    const key = e => {
        if (e.key === 'Escape') close();
        else if (e.key === 'ArrowLeft' && items.length > 1) show(cur - 1);
        else if (e.key === 'ArrowRight' && items.length > 1) show(cur + 1);
    };
    if (items.length > 1) {
        box.classList.add('nav');
        [['cat-zoom-prev', '‹', -1], ['cat-zoom-next', '›', 1]].forEach(([cls, ch, d]) => {
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'cat-zoom-nav ' + cls;
            b.textContent = ch;
            b.onclick = e => { e.stopPropagation(); show(cur + d); };
            box.appendChild(b);
        });
        let x0 = null;
        box.addEventListener('touchstart', e => { x0 = e.touches.length === 1 ? e.touches[0].clientX : null; }, { passive: true });
        box.addEventListener('touchend', e => {
            if (x0 === null) return;
            const dx = e.changedTouches[0].clientX - x0;
            x0 = null;
            if (Math.abs(dx) > 50) { e.preventDefault(); show(cur + (dx < 0 ? 1 : -1)); }
        });
    }
    box.onclick = close;
    document.addEventListener('keydown', key);
    document.body.appendChild(box);
    show(cur);
}

function catRender() {
    if (!catState) return;
    const shown = catShown();
    // the name of the collection and, small, the number of games (it does not break the name)
    document.getElementById('catTitle').innerHTML = '<span class="cat-name">' + escapeHtml(catState.title) + '</span> <span class="cat-count">' + escapeHtml(linkFmt(CAT_T.count, { n: catState.games.length })) + '</span>';
    const list = document.getElementById('catList');
    const view = catView;
    list.className = 'link-list cat-list' + (view === 'list' ? '' : ' cat-' + view);
    document.querySelectorAll('#catViews button').forEach(b => b.classList.toggle('on', b.dataset.view === view));
    const parts = [], rows = [];
    const allOn = shown.length > 0 && shown.every(i => catState.sel.has(catState.games[i].path));
    parts.push('<label class="link-row"><input type="checkbox" id="catAll"' + (allOn ? ' checked' : '') + '><span class="link-name" style="color:var(--text-secondary)">' +
               escapeHtml(linkFmt(CAT_T.selectShown, { n: shown.length })) + '</span></label>');
    if (!shown.length) parts.push('<div class="link-row"><span class="link-name" style="color:var(--text-muted)">' + escapeHtml(CAT_T.noGames) + '</span></div>');
    shown.slice(0, catState.limit).forEach(i => {
        const g = catState.games[i];
        const meta = [g.year, formatBytes(g.size)].filter(Boolean).join(' · ');
        const mark = g.isNew ? '<span class="cat-mark">' + escapeHtml(CAT_T.markNew) + '</span> ' :
                     g.isChg ? '<span class="cat-mark chg">' + escapeHtml(CAT_T.markChanged) + '</span> ' : '';
        const box = '<input type="checkbox" data-gi="' + i + '"' + (catState.sel.has(g.path) ? ' checked' : '') + '>';
        if (view === 'grid') {
            rows.push('<div class="cat-tile cat-go' + (catState.open === i ? ' open' : '') + '" data-go="' + i + '">' + catCoverHtml(g, i) + box +
                (g.have ? '<span class="cat-tile-have" title="' + escapeHtml(CAT_T.have) + '">✓</span>' : '') +
                '<div class="cat-tile-name" title="' + escapeHtml(g.file || g.name) + '">' + escapeHtml(g.name) + '</div>' +
                '<div class="cat-tile-meta">' + mark + escapeHtml(meta) + '</div></div>');
        } else {
            const text = '<span class="link-name dir" title="' + escapeHtml(g.file || g.name) + '">' + escapeHtml(g.name) + '</span>' +
                '<span class="link-meta">' + mark + (g.have ? '<span class="cat-have">' + escapeHtml(CAT_T.have) + '</span> · ' : '') + escapeHtml(meta) + '</span>';
            if (view === 'covers') {
                const d = catRowData(g);
                const info = [d.year, formatBytes(g.size), d.genre, d.players ? CAT_T.players + ': ' + d.players : ''].filter(Boolean).join(' · ');
                rows.push('<div class="link-row cat-go' + (catState.open === i ? ' cat-open' : '') + '" data-go="' + i + '">' + box + catCoverHtml(g, i) + '<div class="cat-rt">' +
                    '<span class="link-name dir" title="' + escapeHtml(g.file || g.name) + '">' + escapeHtml(g.name) + '</span>' +
                    '<div class="cat-rt-meta">' + mark + (g.have ? '<span class="cat-have">' + escapeHtml(CAT_T.have) + '</span> · ' : '') + escapeHtml(info) + '</div>' +
                    (d.desc ? '<div class="cat-rt-desc">' + escapeHtml(d.desc) + '</div>' : '') + '</div></div>');
            } else {
                rows.push('<div class="link-row cat-go' + (catState.open === i ? ' cat-open' : '') + '" data-go="' + i + '">' + box + text + '</div>');
            }
        }
        // in the lists the line under a game goes under its details
        if (catState.open === i) rows.push(view === 'grid' ? catDetailHtml(g, i) : '<div class="cat-detail-wrap">' + catDetailHtml(g, i) + '</div>');
    });
    parts.push(view === 'grid' ? '<div class="cat-tiles">' + rows.join('') + '</div>' : rows.join(''));
    if (shown.length > catState.limit) {
        parts.push('<div class="cat-more"><button class="btn" id="catMore">' + escapeHtml(linkFmt(CAT_T.more, { n: shown.length - catState.limit })) + '</button></div>');
    }
    list.innerHTML = parts.join('');
    const all = document.getElementById('catAll');
    if (all) all.onchange = () => {
        shown.forEach(i => { const p = catState.games[i].path; if (all.checked) catState.sel.add(p); else catState.sel.delete(p); });
        catRender();
    };
    list.querySelectorAll('input[data-gi]').forEach(cb => cb.onchange = () => {
        const p = catState.games[parseInt(cb.dataset.gi)].path;
        if (cb.checked) catState.sel.add(p); else catState.sel.delete(p);
        const a = document.getElementById('catAll');
        if (a) a.checked = shown.length > 0 && shown.every(i => catState.sel.has(catState.games[i].path));
        catSummary();
    });
    list.querySelectorAll('[data-go]').forEach(el => el.onclick = e => {
        if (e.target.closest('input')) return;             // the checkbox only ticks the game
        const i = parseInt(el.dataset.go);
        catState.open = catState.open === i ? null : i;
        catRender();
        if (catState.open === i) catLoadPic(i);
    });
    const more = document.getElementById('catMore');
    if (more) more.onclick = () => { catState.limit += CAT_PAGE; catRender(); };
    catObserve(list);
    catSummary();
}

// ---- views: List / With covers / Tiles. A cover is asked only when it scrolls into view
// (a coloured placeholder until then); at most two at a time, like the pictures of the details.
let catView = 'list';
try { const v = localStorage.getItem('ss_cat_view'); if (['list', 'covers', 'grid'].includes(v)) catView = v; } catch (e) { /* private window */ }

function catSetView(v) {
    catView = v;
    try { localStorage.setItem('ss_cat_view', v); } catch (e) { /* private window */ }
    catRender();
}

function catTint(name) {
    let h = 2166136261;
    for (let k = 0; k < name.length; k++) h = Math.imul(h ^ name.charCodeAt(k), 16777619);
    h = Math.imul(h ^ (h >>> 15), 2246822507);
    h = ((h ^ (h >>> 13)) >>> 0) % 360;
    return 'linear-gradient(160deg,hsl(' + h + ',42%,62%),hsl(' + h + ',30%,34%))';
}

function catCoverHtml(g, i) {
    const url = catState.cover[i];
    return '<div class="cat-cov" id="catCov' + i + '" data-ci="' + i + '"' +
        (url ? '>' + '<img src="' + url + '" alt="">' : ' style="background:' + catTint(g.name) + '">') + '</div>';
}

let catCoverObs = null;
function catObserve(list) {
    if (catCoverObs) { catCoverObs.disconnect(); catCoverObs = null; }
    const st = catState;
    st.coverVis = new Set();
    if (catView === 'list') return;
    const els = [];
    list.querySelectorAll('.cat-cov[data-ci]').forEach(el => { if (st.cover[el.dataset.ci] === undefined) els.push(el); });
    if (!els.length) return;
    if (!('IntersectionObserver' in window)) {
        els.forEach(el => st.coverVis.add(parseInt(el.dataset.ci)));
        catCoverPump();
        return;
    }
    catCoverObs = new IntersectionObserver(entries => {
        entries.forEach(en => {
            const i = parseInt(en.target.dataset.ci);
            if (en.isIntersecting) st.coverVis.add(i); else st.coverVis.delete(i);
        });
        catCoverPump();
    }, { root: list, rootMargin: '200px 0px' });
    els.forEach(el => catCoverObs.observe(el));
}

// with the size in the link the browser keeps a picture for a month (a changed one gets another link)
function catCoverUrl(st, pic) {
    return API + '/link/catalog_cover?sid=' + encodeURIComponent(st.sid) + '&dir=' + encodeURIComponent(st.dir) + '&path=' + encodeURIComponent(pic) + '&s=' + (st.sizes[pic] || 0);
}

function catPicUrl(st, pic) {
    return API + '/link/catalog_pic?sid=' + encodeURIComponent(st.sid) + '&dir=' + encodeURIComponent(st.dir) + '&path=' + encodeURIComponent(pic) + '&s=' + (st.sizes[pic] || 0);
}

function catImgLoad(url) {
    return new Promise(done => {
        const im = new Image();
        im.onload = () => done(true);
        im.onerror = () => done(false);
        im.src = url;
    });
}

// a catalog left alone for 10 minutes is closed on the device: opened again for a picture
let catRevivePromise = null;
function catRevive() {
    if (!catRevivePromise) {
        catRevivePromise = apiFetch('/link/catalog_touch', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: linkState.url, password: linkState.password })
        });
        catRevivePromise.then(() => setTimeout(() => { catRevivePromise = null; }, 5000));
    }
    return catRevivePromise;
}

// covers of the games already on the device: one request for the whole list (null while it runs)
function catDevCovers(st, dir) {
    if (!dir) return {};
    const c = st.devCovers[dir];
    if (c) return c.map || null;
    const paths = st.games.filter(g => g.have).map(g => g.path);
    if (!paths.length) return {};
    st.devCovers[dir] = {};
    apiFetch('/link/catalog_device_covers', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ dir: dir, paths: paths })
    }).then(res => {
        const map = {}, m = (res && res.covers) || {};
        Object.keys(m).forEach(p => { map[p] = catLocalUrl(dir, m[p]); });
        st.devCovers[dir].map = map;
        st.devCovers[dir].info = (res && res.info) || {};
        if (catState !== st) return;
        // the rows of the games on the device now show the device's data
        if (catView === 'covers' && Object.keys(st.devCovers[dir].info).length) catRender(); else catCoverPump();
    });
    return null;
}

// the data of a row: a game on the device shows its entry in the device's gamelist.xml
// (missing fields come from the collection)
function catRowData(g) {
    if (!g.have) return g;
    const c = catState.devCovers[catLocalDir()];
    const dev = c && c.info && c.info[g.path];
    if (!dev) return g;
    const d = Object.assign({}, g);
    Object.keys(dev).forEach(k => { d[k] = dev[k]; });
    return d;
}

function catCoverPump() {
    const st = catState;
    if (!st || catView === 'list') return;
    let dev;
    for (const i of Array.from(st.coverVis)) {
        if (st.cover[i] !== undefined) continue;
        const g = st.games[i];
        if (g.have) {
            if (dev === undefined) dev = catDevCovers(st, catLocalDir());
            if (dev === null) continue;                    // asked; the pump runs again with the answer
            if (dev[g.path]) { catCoverLoad(st, i, dev[g.path], true); continue; }
        }
        if (catPicActive >= CAT_PIC_PARALLEL) continue;
        const pic = catPicPath(g);
        if (!pic) { st.cover[i] = null; continue; }
        catCoverLoad(st, i, catCoverUrl(st, pic), false);
    }
}

function catCoverLoad(st, i, url, local) {
    st.cover[i] = '';                                      // loading
    if (!local) catPicActive++;                            // a file on the device takes no slot
    const img = new Image();
    const done = ok => {
        if (!local) catPicFree();
        // the catalog may have been closed on the device: opened again, the cover asked once more
        if (!ok && !local && catState === st && !st.coverRetry[i]) {
            st.coverRetry[i] = true;
            st.cover[i] = undefined;
            catRevive().then(() => catCoverPump());
            return;
        }
        if (catState === st) {
            st.cover[i] = ok ? url : null;                 // a failed one keeps its placeholder
            st.coverVis.delete(i);
            const el = document.getElementById('catCov' + i);
            if (el && ok) { el.style.background = ''; el.innerHTML = '<img src="' + url + '" alt="">'; }
            if (el && catCoverObs) catCoverObs.unobserve(el);
        }
        catCoverPump();
    };
    img.onload = () => done(true);
    img.onerror = () => done(false);
    img.src = url;
}

function catPicPath(g) {
    for (const k of CAT_PIC_ORDER) {
        const m = g.media[k];
        if (m && /[.](png|jpe?g|gif|webp|bmp)$/i.test(m[0])) return m[0];
    }
    return null;
}

// The details of a game show its pictures (buttons under the picture) and its video. For a game
// already on the device they come from its entry in the device's gamelist.xml ("From the
// device"); "From the collection" shows those of the link.
function catLocalDir() {
    const sel = document.getElementById('linkDest');
    return (linkState.target !== 'cloud' && sel && sel.value) || catState.system || '';
}

function catLocalUrl(dir, rel) {
    return API + '/link/catalog_local?dir=' + encodeURIComponent(dir) + '&path=' + encodeURIComponent(rel);
}

// {tag: url} of the game on the device (cached; {} when it has none)
function catDevice(g) {
    const st = catState;
    const dir = catLocalDir();
    if (!g || !g.have || !dir) return Promise.resolve({});
    const key = dir + '|' + g.path;
    if (!st.local[key]) {
        st.local[key] = apiFetch('/link/catalog_device_media', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ dir: dir, path: g.path })
        }).then(res => {
            const out = {};
            const m = (res && res.media) || {};
            Object.keys(m).forEach(t => { out[t] = catLocalUrl(dir, m[t]); });
            // the game's entry on the device: its description (null when it has no entry)
            st.devInfo[key] = (res && res.info) || null;
            st.devReady[key] = out;
            return out;
        });
    }
    return st.local[key];
}

function catDevReady(g) {
    return catState.devReady[catLocalDir() + '|' + g.path];
}

function catDevInfo(g) {
    return catState.devInfo[catLocalDir() + '|' + g.path] || null;
}

// the device has an entry for the game (pictures, video or a description)
function catDevHas(g) {
    const dev = catDevReady(g);
    return !!dev && (Object.keys(dev).length > 0 || !!catDevInfo(g));
}

// 'device' or 'link': what the device has is shown first
function catSource(g, i) {
    if (!catDevHas(g)) return 'link';
    return catState.source[i] || 'device';
}

const CAT_IS_PIC = p => /[.](png|jpe?g|gif|webp|bmp)$/i.test(p);
const CAT_IS_VIDEO = p => /[.](mp4|m4v|webm)$/i.test(p);

// buttons of a game: {kind, key, url?, size?}. key: what is shown (a link path or a device url)
function catShots(g, src) {
    const out = [], kinds = new Set();
    const group = k => (k === 'boxart' ? 'thumbnail' : k);
    if (src === 'device') {
        const dev = catDevReady(g) || {};
        const first = CAT_PIC_ORDER.find(k => dev[k] && CAT_IS_PIC(dev[k].split('path=')[1] || dev[k]));
        if (first) { out.push({ kind: first, key: dev[first], url: dev[first] }); kinds.add(group(first)); }
        CAT_GALLERY.forEach(k => {
            if (dev[k] && !kinds.has(group(k)) && !out.some(s => s.key === dev[k])) {
                out.push({ kind: k, key: dev[k], url: dev[k] }); kinds.add(group(k));
            }
        });
        if (dev.video) out.push({ kind: 'video', key: dev.video, url: dev.video, size: 0 });
        if (!out.some(x => x.kind !== 'video')) {              // no pictures on the device: the collection's
            catShots(g, 'link').forEach(x => { if (x.kind !== 'video' || !dev.video) out.push(x); });
        }
        return out;
    }
    const seen = new Set();
    const main = catPicPath(g);
    if (main) { const k = catKindOf(g, main); out.push({ kind: k, key: main }); seen.add(main); kinds.add(group(k)); }
    const look = g.look || g.media;
    CAT_GALLERY.forEach(k => {
        const m = look[k];
        if (m && !seen.has(m[0]) && !kinds.has(group(k)) && CAT_IS_PIC(m[0])) {
            out.push({ kind: k, key: m[0] }); seen.add(m[0]); kinds.add(group(k));
        }
    });
    const v = look.video;
    if (v && CAT_IS_VIDEO(v[0])) out.push({ kind: 'video', key: v[0], size: v[1] || 0 });
    return out;
}

function catKindOf(g, path) {
    return Object.keys(g.media).find(k => g.media[k][0] === path) || '';
}

function catShotsHtml(g, i) {
    const src = catSource(g, i);
    const shots = catShots(g, src);
    const both = catDevHas(g);
    let html = '';
    if (both) {
        html += '<div class="cat-src">' +
            '<button type="button" class="' + (src === 'device' ? 'on' : '') + '" onclick="catSetSource(' + i + ',' + "'device'" + ')">' + escapeHtml(CAT_T.fromDevice) + '</button>' +
            '<button type="button" class="' + (src === 'link' ? 'on' : '') + '" onclick="catSetSource(' + i + ',' + "'link'" + ')">' + escapeHtml(CAT_T.fromLink) + '</button></div>';
    }
    if (shots.length < 2) return html;
    const cur = catState.view[i] || (shots[0] && shots[0].key);
    return html + '<div class="cat-shots">' + shots.map((s, n) => {
        const label = s.kind === 'video'
            ? (s.size ? linkFmt(CAT_T.video, { size: formatBytes(s.size) }) : '▶ ' + (CAT_T.kinds.video || 'Video'))
            : (CAT_T.shot[s.kind] || CAT_T.kinds[s.kind] || s.kind);
        return '<button type="button" class="' + (s.key === cur ? 'on' : '') + '" onclick="catShot(' + i + ',' + n + ')">' + escapeHtml(label) + '</button>';
    }).join('') + '</div>';
}

function catSetSource(i, src) {
    catState.source[i] = src;
    delete catState.view[i];
    catRender();
    catLoadPic(i);
}

function catVideoHtml(url) {
    return '<video src="' + url + '" controls autoplay playsinline preload="auto"></video>';
}

async function catShot(i, n) {
    const st = catState;
    const g = st.games[i];
    const src = catSource(g, i);
    const s = catShots(g, src)[n];
    if (!s) return;
    st.view[i] = s.key;
    const detail = document.getElementById('catPic' + i);
    if (!detail) return;
    const box = detail.querySelector('.cat-pic-main');
    detail.querySelectorAll('.cat-shots button').forEach((b, j) => b.classList.toggle('on', j === n));
    if (s.url) {                                           // on the device: shown at once
        box.innerHTML = s.kind === 'video' ? catVideoHtml(s.url) : '<img src="' + s.url + '" alt="">';
        return;
    }
    if (s.kind === 'video') {
        box.textContent = CAT_T.loadingVideo;
        const res = await apiFetch('/link/catalog_video', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: linkState.url, password: linkState.password, dir: st.dir, path: s.key })
        });
        if (catState !== st || st.view[i] !== s.key) return;
        if (res && res.src) box.innerHTML = catVideoHtml(API + res.src.replace(/^[/]api/, ''));
        else box.textContent = (res && res.error) || CAT_T.noVideo;
        return;
    }
    if (st.pics[s.key]) { box.innerHTML = '<img src="' + st.pics[s.key] + '" alt="">'; return; }
    box.textContent = CAT_T.loadingPic;
    const res = await catFetchPic(s.key);
    if (catState !== st || st.view[i] !== s.key) return;
    if (res && res.data) box.innerHTML = '<img src="' + res.data + '" alt="">';
    else box.textContent = CAT_T.picFailed;
}

function catDetailHtml(g, i) {
    const info = [];
    // the description of the chosen source: the device's entry or the collection's
    const waiting = g.have && catDevReady(g) === undefined;
    const d = !waiting && catSource(g, i) === 'device' ? (catDevInfo(g) || {}) : g;
    ['genre', 'players', 'developer', 'publisher', 'lang', 'region'].forEach(k => {
        if (d[k]) info.push('<div>' + escapeHtml(CAT_T[k] + ': ' + d[k]) + '</div>');
    });
    info.push('<div>' + escapeHtml(CAT_T.file + ': ' + (g.file || g.path)) + '</div>');
    let picHtml;
    if (g.have && catDevReady(g) === undefined) {
        picHtml = escapeHtml(CAT_T.loadingPic);                 // the device is asked first
    } else {
        const src = catSource(g, i);
        const shots = catShots(g, src);
        // the picture chosen with the buttons stays when the details are opened again (a video starts over)
        let s = shots.find(x => x.key === catState.view[i] && x.kind !== 'video') || shots.find(x => x.kind !== 'video');
        if (!s) picHtml = escapeHtml(CAT_T.noPic);
        else if (s.url) picHtml = '<img src="' + s.url + '" alt="">';
        else picHtml = catState.pics[s.key] ? '<img src="' + catState.pics[s.key] + '" alt="">' : escapeHtml(CAT_T.loadingPic);
        if (catState.view[i] && (!s || s.key !== catState.view[i])) delete catState.view[i];
    }
    return '<div class="cat-detail"><div class="cat-pic" id="catPic' + i + '"><div class="cat-pic-main">' + picHtml + '</div>' +
        (g.have && catDevReady(g) === undefined ? '' : catShotsHtml(g, i)) + '</div><div class="cat-info">' +
        info.join('') + (d.desc ? '<div class="cat-desc">' + escapeHtml(d.desc) + '</div>' : '') + '</div></div>';
}

// At most two pictures of the catalog are asked at a time: a picture the service does not
// give must not take up the browser's connections to the device (status, logs, buttons).
const CAT_PIC_PARALLEL = 2;
let catPicActive = 0;
const catPicQueue = [];
function catPicSlot() {
    if (catPicActive < CAT_PIC_PARALLEL) { catPicActive++; return Promise.resolve(); }
    return new Promise(r => catPicQueue.push(r));
}
function catPicFree() {
    const next = catPicQueue.shift();
    if (next) next(); else catPicActive--;
}

function catFetchPic(pic, prefetch) {
    const st = catState;
    if (st.pending[pic]) return st.pending[pic];
    // the next games are loaded ahead only into a free slot, and not after a failure
    if (prefetch && (catPicActive >= CAT_PIC_PARALLEL || st.failed[pic])) return null;
    const url = catPicUrl(st, pic);
    const p = catPicSlot().then(() => catImgLoad(url))
        .then(ok => ok ? true : catRevive().then(() => catImgLoad(url)))
        .then(ok => {
            catPicFree();
            if (ok) { st.pics[pic] = url; delete st.failed[pic]; return { data: url }; }
            delete st.pending[pic]; st.failed[pic] = true;                 // tried again when opened again
            return { error: 'failed' };
        });
    st.pending[pic] = p;
    return p;
}

async function catLoadPic(i) {
    const st = catState;
    const g = st.games[i];
    if (g.have && catDevReady(g) === undefined) {
        await catDevice(g);                                // quick: a file on the device
        if (catState !== st) return;
        if (st.open === i) catRender();
    }
    const src = catSource(g, i);
    const first = catShots(g, src).find(x => x.kind !== 'video');
    const pic = first && !first.url && !st.view[i] ? first.key : null;
    // the picture of the opened game is asked first, so it never waits behind the others
    const own = pic && !st.pics[pic] ? catFetchPic(pic) : null;
    // the next games of the list are loaded meanwhile (not those on the device: shown from it)
    const shown = catShown();
    const at = shown.indexOf(i);
    shown.slice(at + 1, at + 4).forEach(j => {
        const gj = st.games[j];
        const p = catPicPath(gj);
        if (p && !gj.have && !st.pics[p]) catFetchPic(p, true);
    });
    if (!own) return;
    const res = await own;
    if (catState !== st || st.view[i] || catSource(g, i) !== src) return;
    const detail = document.getElementById('catPic' + i);
    const box = detail && detail.querySelector('.cat-pic-main');
    if (res && res.data) {
        if (box) box.innerHTML = '<img src="' + res.data + '" alt="">';
    } else if (box) {
        box.textContent = CAT_T.picFailed;
    }
}

function catTotals() {
    let roms = 0, media = 0, n = 0;
    catState.games.forEach(g => {
        if (!catState.sel.has(g.path)) return;
        n++;
        roms += g.size || 0;
        Object.keys(g.media).forEach(k => { if (catState.on.has(k)) media += g.media[k][1] || 0; });
    });
    return { n: n, roms: roms, media: media };
}

function catSummary() {
    if (!catState) return;
    document.getElementById('linkStartBtn').classList.toggle('cat-wait', !!catState.cached);
    const ob = document.getElementById('catOnlySel');
    if (ob) {
        ob.textContent = linkFmt(CAT_T.onlySel, { n: catState.sel.size });
        ob.classList.toggle('on', !!catState.onlySel);
        ob.disabled = !catState.onlySel && !catState.sel.size;
    }
    linkGuessDest();
    const t = catTotals();
    const lines = [];
    if (!t.n) {
        lines.push({ text: CAT_T.nothingSel });
    } else {
        lines.push({ text: linkFmt(CAT_T.selected, { n: t.n, roms: formatBytes(t.roms), media: formatBytes(t.media), total: formatBytes(t.roms + t.media) }) });
        const dest = document.getElementById('linkDest').value;
        const cloud = linkState.target === 'cloud';
        lines.push({ text: !dest ? CAT_T.destNone : cloud ? linkFmt(CAT_T.destCloud, { dest: linkFmt(LINK_T.cloudLabel, { sys: dest }) })
                                                       : linkFmt(CAT_T.dest, { dest: dest }), warn: !dest });
        if (Object.keys(catState.kinds).length && !catState.on.size) lines.push({ text: CAT_T.noMedia });
        // games already on the device: what happens to their own media and description
        if (catState.games.some(g => g.have && catState.sel.has(g.path))) {
            const what = [];
            if (catState.replaceMedia) what.push(CAT_T.whatMedia);
            if (catState.replaceDesc) what.push(CAT_T.whatDesc);
            lines.push({ text: what.length ? linkFmt(CAT_T.replaceNote, { what: what.join(', ') }) : CAT_T.keepNote });
        }
        if (cloud && catState.on.size && catState.syncMedia === 'false') lines.push({ text: CAT_T.cloudMedia });
        else if (cloud && catState.on.has('video') && catState.syncMedia !== 'video') lines.push({ text: CAT_T.cloudVideo });
        const d = linkState.dests[linkState.target] || {};
        if (d.free !== null && d.free !== undefined) {
            const warn = t.roms + t.media > d.free;
            lines.push({ text: (warn ? LINK_T.noSpace + ' — ' : '') + linkFmt(cloud ? LINK_T.freeCloud : LINK_T.free, { free: formatBytes(d.free) }), warn: warn });
        }
        if (cloud) lines.push({ text: LINK_T.cloudNote });
        else if (catState.recalbox) lines.push({ text: CAT_T.recalboxNote });
    }
    document.getElementById('linkSummary').innerHTML =
        lines.map(l => '<div' + (l.warn ? ' class="warn"' : '') + '>' + escapeHtml(l.text) + '</div>').join('');
}

function catDownload() {
    if (catState.cached) { showToast(CAT_T.waitCheck, 'error'); return; }
    const dest = document.getElementById('linkDest').value;
    if (!dest) { showToast(CAT_T.destNone, 'error'); return; }
    const games = catState.games.filter(g => catState.sel.has(g.path)).map(g => g.path);
    if (!games.length) { showToast(CAT_T.nothingSel, 'error'); return; }
    const media = Object.keys(catState.kinds).filter(k => catState.on.has(k));
    const bar = document.getElementById('syncProgressLink');
    runSyncWithProgress('link_download', async () => {
        return await apiFetch('/link/catalog_get', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ url: linkState.url, password: linkState.password, dir: catState.dir,
                                   dest: dest, games: games, media: media, target: linkState.target,
                                   replace_media: catState.replaceMedia, replace_desc: catState.replaceDesc })
        });
    });
    setTimeout(() => { if (bar) bar.scrollIntoView({ behavior: 'smooth', block: 'center' }); }, 100);
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

// ---- sections of the web interface (Settings -> Sections)
let SECTIONS = { roms: true, link: true };

function applySections() {
    document.getElementById('romsSection').style.display = SECTIONS.roms ? '' : 'none';
    document.getElementById('linkSection').style.display = SECTIONS.link ? '' : 'none';
    // without the ROMs the link section is the first one: no gap above it
    document.querySelector('#linkSection > .section-title').style.marginTop = SECTIONS.roms ? '20px' : '0';
    document.getElementById('secRoms').checked = SECTIONS.roms;
    document.getElementById('secLink').checked = SECTIONS.link;
    // both hidden: the tab itself goes away
    const tab = document.querySelector('.tab[data-tab="roms"]');
    const none = !SECTIONS.roms && !SECTIONS.link;
    tab.style.display = none ? 'none' : '';
    if (none && tab.classList.contains('active')) document.querySelector('.tab[data-tab="saves"]').click();
}

async function loadSections() {
    const res = await apiFetch('/sections');
    if (res && typeof res.roms === 'boolean' && typeof res.link === 'boolean') {
        SECTIONS = { roms: res.roms, link: res.link };
    }
    applySections();
}

// the "IMPORTANT" notes: folded to one line (what deletes), a tap on the title opens them
['noteSaves', 'noteRoms'].forEach(id => {
    const note = document.getElementById(id);
    note.querySelector('p').addEventListener('click', () => note.classList.toggle('folded'));
});

async function saveSections() {
    SECTIONS.roms = document.getElementById('secRoms').checked;
    SECTIONS.link = document.getElementById('secLink').checked;
    applySections();
    postSections();
}

async function postSections() {
    const res = await apiFetch('/sections', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(SECTIONS)
    });
    if (!res || res.error) showToast((res && res.error) || 'Error', 'error');
}

// ---- export / import of the settings
const CFG_T = {"title": "Moving the settings", "export": "Export", "import": "Import", "hint": "Export downloads this device's settings file (sync.conf); import takes from such a file only what you choose. The cloud connection is not in it.", "choose": "What to take from “{name}”:", "apply": "Import", "cancel": "Cancel", "groups": {"links": "Saved links ({n}): added to the ones here", "sync": "Sync: interval, retries, conflict copies, notifications, after a game", "excluded": "Exclusions", "roms": "ROM systems and media", "web": "Web interface sections"}, "notFile": "This is not a Save Sync settings file", "done": "Imported: settings {s}, new links {l}", "nothing": "Choose what to import"};
const CFG_GROUPS = { links: ['WEB_LINKS'], sync: ['SYNC_INTERVAL', 'MAX_RETRIES', 'CONFLICT_KEEP_DAYS', 'NOTIFICATIONS', 'SYNC_MODE', 'MIN_FREE_KB'],
                     excluded: ['EXCLUDED_SYSTEMS'], roms: ['ROMS_SYNC_DIRS', 'ROMS_SYNC_MEDIA'], web: ['WEB_SHOW_ROMS', 'WEB_SHOW_LINK'] };
// device dependent groups are not ticked at first
const CFG_ON = ['links', 'sync'];
let cfgText = '';

function cfgExport() {
    const a = document.createElement('a');
    a.href = API + '/config/export';
    a.download = '';
    document.body.appendChild(a);
    a.click();
    a.remove();
}

function cfgPick(input) {
    const file = input.files && input.files[0];
    input.value = '';
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => cfgShow(String(reader.result || ''), file.name);
    reader.readAsText(file);
}

function cfgShow(text, name) {
    const keys = {};
    text.split(String.fromCharCode(10)).forEach(line => {
        const m = line.match(/^ *([A-Z_]+) *= *"?(.*?)"? *$/);
        if (m && !line.trim().startsWith('#')) keys[m[1]] = m[2];
    });
    const box = document.getElementById('cfgImport');
    if (!Object.keys(keys).some(k => CFG_GROUPS.sync.includes(k) || k === 'WEB_LINKS')) {
        box.style.display = 'none';
        showToast(CFG_T.notFile, 'error');
        return;
    }
    cfgText = text;
    const links = (keys.WEB_LINKS || '').split(' ').filter(Boolean).length;
    box.innerHTML = '<div>' + escapeHtml(CFG_T.choose.replace('{name}', name)) + '</div>' + Object.keys(CFG_GROUPS).map(g => {
        const has = g === 'links' ? links > 0 : CFG_GROUPS[g].some(k => k in keys);
        const label = CFG_T.groups[g].replace('{n}', links);
        return '<label class="' + (has ? '' : 'off') + '"><input type="checkbox" data-cfg="' + g + '"' +
            (has && CFG_ON.includes(g) ? ' checked' : '') + (has ? '' : ' disabled') + '><span>' + escapeHtml(label) + '</span></label>';
    }).join('') + '<div class="cfg-actions"><button class="btn btn-primary" onclick="cfgApply()">' + escapeHtml(CFG_T.apply) + '</button>' +
        '<button class="btn" onclick="cfgCancel()">' + escapeHtml(CFG_T.cancel) + '</button></div>';
    box.style.display = '';
}

function cfgCancel() {
    cfgText = '';
    document.getElementById('cfgImport').style.display = 'none';
}

async function cfgApply() {
    const groups = Array.from(document.querySelectorAll('#cfgImport input[data-cfg]:checked')).map(x => x.dataset.cfg);
    if (!groups.length) { showToast(CFG_T.nothing, 'error'); return; }
    const res = await apiFetch('/config/import', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: cfgText, groups: groups })
    });
    if (!res || !res.success) { showToast((res && res.error) || 'Error', 'error'); return; }
    showToast(CFG_T.done.replace('{s}', res.settings).replace('{l}', res.links));
    cfgCancel();
    loadSettings();
    loadSections();
    linkSavedLoad();
    if (typeof loadSystems === 'function') loadSystems();
}

loadSections();
linkInit();
linkSavedLoad();
setInterval(refreshStatus, 10000);
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
    
    print(f"\n✅ Save Sync Web UI v1.5.0 started")
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
        -e "s|__SS_BASE__|$DATA_DIR|g" \
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
    echo " Save Sync Diagnostics v1.5.0"
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
    CLOUD_ABOUT=$(cloud_about)
    CLOUD_USED=$(printf '%s\n' "$CLOUD_ABOUT" | grep -i "^used" | awk '{print $2, $3}')
    CLOUD_TOTAL=$(printf '%s\n' "$CLOUD_ABOUT" | grep -i "^total" | awk '{print $2, $3}')
    CLOUD_FREE=$(printf '%s\n' "$CLOUD_ABOUT" | grep -i "^free" | awk '{print $2, $3}')
    print_2col "Used" "${CLOUD_USED:-$(cloud_free_unknown)}"
    print_2col "Total" "${CLOUD_TOTAL:-$(cloud_free_unknown)}"
    print_2col "Free" "${CLOUD_FREE:-$(cloud_free_unknown)}"
    
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
    if grep -qF "$DOWNLOAD_SCRIPT" "$BASE/custom.sh" 2>/dev/null; then
        print_2col "Autostart" "✅ configured (custom.sh)"
        AUTOLOAD_FOUND=true
    fi
fi
if [ -f "$BASE/services/custom_service" ]; then
    if grep -qF "$DOWNLOAD_SCRIPT" "$BASE/services/custom_service" 2>/dev/null; then
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
        print_2col "Notifications" "$(notify_label)"
        print_2col "After a game" "$(sync_mode_label)"
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
    case "$ROMS_SYNC_MEDIA" in
        true)  print_2col "Media copying" "✅ no videos" ;;
        video) print_2col "Media copying" "✅ with videos" ;;
        *)     print_2col "Media copying" "❌ disabled" ;;
    esac
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

############################################
# Own folder (1.5.0): moving the files of an older version, uninstalling
############################################

SS_FILES="download_sync.sh upload_sync.sh download_roms.sh upload_roms.sh link_download.py sync_engine.py sync.conf .sync_state .sync_base.json roms_filter_sync"
SS_DIRS=".sync_manifests .catalog_cache"

stop_web_server() {
    if [ -f "/tmp/save_sync_web.pid" ]; then
        PID=$(cat /tmp/save_sync_web.pid 2>/dev/null)
        [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
        rm -f /tmp/save_sync_web.pid
    fi
    pkill -f "python3.*server.py" 2>/dev/null
    WEB_STOPPED=true
}

other_jobs_busy() {
    pgrep -f "link_download\.py|download_roms\.sh|upload_roms\.sh" >/dev/null 2>&1
}

# the connection of Save Sync is the [cloud] section of the old shared rclone config
# ($HOME/.config/rclone on Batocera and KNULLI, the default config of any rclone)
drop_old_rclone_conf() {
    local OLD_CONF="$BASE/.config/rclone/rclone.conf"
    rm -f "$OLD_CONF.bak"
    [ -f "$OLD_CONF" ] || return 0
    if grep '^\[' "$OLD_CONF" | grep -qv '^\[cloud\][[:space:]]*$'; then
        awk '/^\[/{s=($0 ~ /^\[cloud\][[:space:]]*$/)} !s' "$OLD_CONF" > "$OLD_CONF.tmp" && cat "$OLD_CONF.tmp" > "$OLD_CONF"
        rm -f "$OLD_CONF.tmp"
        echo "ℹ️  .config/rclone/rclone.conf has connections of other programs - they are left as they were"
    else
        rm -f "$OLD_CONF"
        rmdir "$BASE/.config/rclone" 2>/dev/null
    fi
}

remove_legacy_files() {
    local f d
    for f in $SS_FILES; do rm -f "$BASE/$f"; done
    for d in $SS_DIRS; do rm -rf "${BASE:?}/$d"; done
    rm -rf "$BASE"/.ss_tmp* 2>/dev/null
    rm -f "$BASE/bin/rclone"
    rmdir "$BASE/bin" 2>/dev/null
    drop_old_rclone_conf
}

# copies the files of an older version into APP_DIR; the old ones are removed by
# finish_migration once the scripts, the hook and the autostart point to the new place.
# Anything wrong -> the copy is dropped and everything stays as it was.
migrate_to_app_dir() {
    [ "$LEGACY_LAYOUT" = true ] || return 0
    echo "📁 Moving the Save Sync files into $APP_DIR"
    if sync_busy || other_jobs_busy; then
        echo "⏳ A sync or a download is running - waiting up to 2 minutes..."
        for i in $(seq 1 120); do
            sync_busy || other_jobs_busy || break
            sleep 1
        done
        if sync_busy || other_jobs_busy; then
            echo "❌ A sync or a download is still running. Nothing was changed - run the update later."
            return 1
        fi
    fi
    stop_web_server
    local ok=true f d
    rm -rf "${APP_DIR:?}"
    mkdir -p "$APP_DIR/bin" || ok=false
    for f in sync.conf .sync_state .sync_base.json roms_filter_sync; do
        if [ "$ok" = true ] && [ -f "$BASE/$f" ]; then cp -p "$BASE/$f" "$APP_DIR/$f" || ok=false; fi
    done
    for d in $SS_DIRS; do
        if [ "$ok" = true ] && [ -d "$BASE/$d" ]; then cp -rp "$BASE/$d" "$APP_DIR/" || ok=false; fi
    done
    if [ "$ok" = true ] && [ -f "$BASE/bin/rclone" ]; then
        cp -p "$BASE/bin/rclone" "$APP_DIR/bin/rclone" || ok=false
    fi
    local OLD_CONF="$BASE/.config/rclone/rclone.conf"
    if [ "$ok" = true ] && [ -f "$OLD_CONF" ]; then
        awk '/^\[/{s=($0 ~ /^\[cloud\][[:space:]]*$/)} s' "$OLD_CONF" > "$APP_DIR/rclone.conf" || ok=false
        [ -s "$APP_DIR/rclone.conf" ] || ok=false
        chmod 600 "$APP_DIR/rclone.conf" 2>/dev/null
    fi
    if [ "$ok" = true ] && [ -f "$OLD_CONF.bak" ]; then
        cp -p "$OLD_CONF.bak" "$APP_DIR/rclone.conf.bak" || ok=false
    fi
    if [ "$ok" != true ]; then
        rm -rf "${APP_DIR:?}"
        echo "❌ The files could not be moved (no free space?). Nothing was changed, Save Sync works as before."
        [ "$WEB_STOPPED" = true ] && bash "$0" --web > /dev/null 2>&1 &
        return 1
    fi
    LEGACY_LAYOUT=false
    set_paths
    ensure_rclone_executable
    MIGRATED=true
    echo "✅ Settings, sync state and rclone moved"
}

# the autostart line starts download_sync.sh by its full path: it is pointed to where it is now
fix_autostart_paths() {
    local AF
    for AF in "$BASE/custom.sh" "$BASE/services/custom_service"; do
        [ -f "$AF" ] || continue
        sed -i "s#/[^ \"']*/download_sync\.sh#$DOWNLOAD_SCRIPT#g" "$AF" 2>/dev/null
    done
}

finish_migration() {
    [ "$MIGRATED" = true ] || return 0
    fix_autostart_paths
    remove_legacy_files
    MIGRATED=false
    echo "✅ The Save Sync files are now in $APP_DIR"
}

remove_autostart() {
    local AF
    for AF in "$BASE/custom.sh" "$BASE/services/custom_service"; do
        [ -f "$AF" ] || continue
        awk '
            /^# (Запуск веб-интерфейса Save Sync|Start the Save Sync web interface)[[:space:]]*$/ { skip = 1; next }
            skip { if ($0 ~ /^\) &[[:space:]]*$/) skip = 0; next }
            /download_sync\.sh/ { next }
            /install_sync\.sh --web/ { next }
            { print }' "$AF" > "$AF.tmp" && cat "$AF.tmp" > "$AF"
        rm -f "$AF.tmp"
    done
}

uninstall_save_sync() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " 🗑  Uninstalling Save Sync"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo "Removed: the Save Sync scripts and settings, rclone, the cloud connection,"
    echo "the game-exit hook, the autostart lines and the log."
    echo "Left alone: the saves and ROMs on the device and everything in the cloud."
    echo ""
    read -p "Type yes to confirm: " UNINSTALL_OK
    case "$UNINSTALL_OK" in
        yes|Yes|YES) ;;
        *) echo "Cancelled. Nothing was removed."; return 1 ;;
    esac
    read -p "Keep sync.conf (exclusions, saved links, modes) for a later install? (y/n): " KEEP_CONF
    echo ""
    echo "⏹  Stopping the web interface, the sync and the downloads..."
    stop_web_server
    stop_sync >/dev/null 2>&1
    pkill -f "link_download\.py|download_roms\.sh|upload_roms\.sh" 2>/dev/null
    rm -f "$SCRIPT_DIR/save-sync.sh" "/recalbox/share/userscripts/save-sync[endgame].sh" 2>/dev/null
    remove_autostart
    local KEEP_FILE=""
    if { [ "$KEEP_CONF" = "y" ] || [ "$KEEP_CONF" = "Y" ]; } && [ -f "$CONFIG_FILE" ]; then
        KEEP_FILE="/tmp/ss_keep_sync.conf"
        cp -p "$CONFIG_FILE" "$KEEP_FILE"
    fi
    rm -rf "${APP_DIR:?}"
    remove_legacy_files >/dev/null
    rm -f "$LOG_FILE" "$LOG_FILE".* 2>/dev/null
    rm -rf /tmp/save_sync_* 2>/dev/null
    if [ -n "$KEEP_FILE" ]; then
        mkdir -p "$APP_DIR" && mv -f "$KEEP_FILE" "$APP_DIR/sync.conf"
        echo "📄 The settings file is kept: $APP_DIR/sync.conf"
    fi
    echo "✅ Save Sync is uninstalled."
    echo "   The installer $0 is left: delete it if you do not need it, or run it again to install."
    return 0
}

if [ "$1" = "--config" ]; then
    show_control_panel
    exit 0
fi

if [ "$1" = "--uninstall" ]; then
    uninstall_save_sync
    exit $?
fi

############################################
# Check: already installed?
############################################

if [ -f "$RCLONE_CONF" ] && [ -f "$DOWNLOAD_SCRIPT" ] && [ -f "$UPLOAD_SCRIPT" ]; then
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " Save Sync is already installed ($SYSTEM)"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo " 1 - Update to v1.5.0"
    echo " 2 - Reinstall from scratch"
    echo " 3 - Uninstall"
    echo " 4 - Exit"
    echo ""
    read -p "Choose an option (1-4): " REINSTALL_CHOICE
    case "$REINSTALL_CHOICE" in
    1)
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo " 📦 Updating to v1.5.0"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        migrate_to_app_dir || exit 1

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
        
        # Create the file if it doesn't exist
        if [ ! -f "$AUTOLOAD_FILE" ]; then
            echo '#!/bin/bash' > "$AUTOLOAD_FILE"
            chmod +x "$AUTOLOAD_FILE"
            echo "✅ Created $(basename $AUTOLOAD_FILE)"
        fi
        
        # Add download_sync.sh if missing (path taken from $DOWNLOAD_SCRIPT,
        # so it works correctly on Recalbox, not just Batocera/KNULLI)
        if ! grep -q "download_sync.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
            sed -i "/^#!/a [ \"\$1\" = \"stop\" ] || bash $DOWNLOAD_SCRIPT \&" "$AUTOLOAD_FILE"
            echo "✅ Save download added to $(basename $AUTOLOAD_FILE)"
        fi
        
        # Autostart lines from older versions also ran at shutdown:
        # the system calls this file with "start" at boot and "stop" at shutdown.
        # both autostart files (KNULLI can have both), and the old line format without bash
        for AF in "$BASE/custom.sh" "$BASE/services/custom_service"; do
            [ -f "$AF" ] || continue
            sed -i -e 's#^\([[:space:]]*\)\(bash \)\{0,1\}\(/[^ ]*download_sync\.sh\) &$#\1[ "$1" = "stop" ] || \2\3 \&#' \
                   -e 's#^\([[:space:]]*\)\(bash \)\{0,1\}\(/[^ ]*install_sync\.sh --web\) &$#\1[ "$1" = "stop" ] || \2\3 \&#' "$AF" 2>/dev/null
        done
        finish_migration

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
    [ "\$1" = "stop" ] || bash $BASE/install_sync.sh --web &
) &
EOF
            echo "✅ Web interface added to $(basename $AUTOLOAD_FILE)"
        fi
        
        echo ""
        echo "✅ Update to v1.5.0 complete!"

        log_msg "Update to v1.5.0 complete"

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
        migrate_to_app_dir || exit 1
        rm -f "$DOWNLOAD_SCRIPT" "$UPLOAD_SCRIPT" "$DOWNLOAD_ROMS" "$UPLOAD_ROMS" "$LINK_SCRIPT" 2>/dev/null
        rm -f "$SCRIPT_DIR/save-sync.sh" 2>/dev/null
        rm -f "/recalbox/share/userscripts/save-sync[endgame].sh" 2>/dev/null
        echo "✅ Old files removed"
        echo ""
        echo "Starting installation..."
        # Proceed to installation
        ;;
    3)
        uninstall_save_sync
        exit $?
        ;;
    4)
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
echo " Save Sync v1.5.0 - Installation"
echo " $SYSTEM"
echo "══════════════════════════════════════════════════════════"
echo ""

migrate_to_app_dir || exit 1
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

ask_cloud_config "$RCLONE_CONF" || exit 1

echo "Checking connection..."
if cloud_check "$RCLONE_CONF"; then
    echo "✅ Connection successful."
else
    echo "❌ Connection failed."
    [ -n "$CLOUD_ERR" ] && echo "   Reason: $CLOUD_ERR"
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
if ! grep -q "download_sync.sh" "$AUTOLOAD_FILE" 2>/dev/null; then
    sed -i "/^#!/a [ \"\$1\" = \"stop\" ] || bash $DOWNLOAD_SCRIPT \&" "$AUTOLOAD_FILE"
    echo "✅ Save download added to $(basename $AUTOLOAD_FILE)"
fi

# Autostart lines from older versions also ran at shutdown:
# the system calls this file with "start" at boot and "stop" at shutdown.
# both autostart files (KNULLI can have both), and the old line format without bash
for AF in "$BASE/custom.sh" "$BASE/services/custom_service"; do
    [ -f "$AF" ] || continue
    sed -i -e 's#^\([[:space:]]*\)\(bash \)\{0,1\}\(/[^ ]*download_sync\.sh\) &$#\1[ "$1" = "stop" ] || \2\3 \&#' \
           -e 's#^\([[:space:]]*\)\(bash \)\{0,1\}\(/[^ ]*install_sync\.sh --web\) &$#\1[ "$1" = "stop" ] || \2\3 \&#' "$AF" 2>/dev/null
done
finish_migration
[ "$WEB_STOPPED" = true ] && restart_web_after_update

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
    [ "\$1" = "stop" ] || bash $BASE/install_sync.sh --web &
) &
EOF
    echo "✅ Web interface added to $(basename $AUTOLOAD_FILE)"
else
    echo "✅ Web interface already present in $(basename $AUTOLOAD_FILE)"
fi

SYSTEM_VERSION=$(get_system_version)

log_msg "Save Sync v1.5.0 | $SYSTEM ($SYSTEM_VERSION) | rclone v${NEW_VER:-unknown}"
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