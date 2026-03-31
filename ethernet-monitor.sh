#!/bin/zsh
#
# ethernet-monitor — auto-recovery daemon for USB Ethernet (RTL8153)
#
# Watches the en6 interface. When the adapter is plugged in but the
# Ethernet link drops, attempts escalating recovery:
#   1. Wait for self-heal (10s)
#   2. ifconfig down/up
#   3. networksetup service toggle
#   4. Notify user to physically replug (then stop retrying)
#
# Install:   sudo ./install.sh
# Uninstall: sudo ./uninstall.sh
#
# Installed to /Library/PrivilegedHelperTools/ethernet-monitor (root-only directory).

setopt nounset  # error on undefined variables

# --- Config ----------------------------------------------------------------
readonly IFACE="en6"
readonly SERVICE="USB 10/100/1000 LAN"
readonly LOG="/var/log/ethernet-monitor.log"
readonly CHECK_INTERVAL=3          # seconds between polls
readonly SELF_HEAL_WAIT=10         # seconds to wait before intervening
readonly RECOVERY_COOLDOWN=30      # min seconds between recovery attempts
readonly MAX_RECOVERY_ATTEMPTS=2   # give up after this many failed recoveries
readonly MAX_LOG_BYTES=1048576     # rotate log at 1 MB
readonly ROTATION_CHECK_INTERVAL=100  # check log size every N iterations (~5 min)
readonly WAKE_THRESHOLD=60            # time gap (s) that indicates system was sleeping
readonly BOOT_GRACE=120               # delay first link-up notification for never-seen adapter until uptime exceeds this (s)

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/bin"

# --- Localization (PL/EN) ---------------------------------------------------
# Override with ETHMON_LANG=pl or ETHMON_LANG=en in the plist EnvironmentVariables,
# otherwise auto-detect from console user's system language.
if [[ -z "${ETHMON_LANG:-}" ]]; then
    console_uid=$(scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null | awk '/CGSSessionUniqueSessionUUID/ { next } /^[[:space:]]*UID[[:space:]]*:/ { print $3 }' 2>/dev/null)
    ETHMON_LANG=""
    if [[ -n "${console_uid:-}" && "$console_uid" != "0" ]]; then
        ETHMON_LANG=$(launchctl asuser "$console_uid" defaults read -g AppleLanguages 2>/dev/null \
            | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)
    fi
    if [[ -z "${ETHMON_LANG:-}" ]]; then
        ETHMON_LANG=$(defaults read -g AppleLanguages 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)
    fi
fi
if [[ "$ETHMON_LANG" == pl* ]]; then
    readonly MSG_LINK_DOWN="Ethernet link padł — czekam na auto-recovery..."
    readonly MSG_SELF_HEALED="Ethernet wrócił sam"
    readonly MSG_RECOVERED_IFCONFIG="Ethernet wrócił (ifconfig reset)"
    readonly MSG_RECOVERED_NETSETUP="Ethernet wrócił (service reset)"
    readonly MSG_GAVE_UP="Ethernet nie wrócił — wyjmij i włóż przejściówkę"
    readonly MSG_CONNECTED="Ethernet podłączony"
else
    readonly MSG_LINK_DOWN="Ethernet link dropped — attempting auto-recovery..."
    readonly MSG_SELF_HEALED="Ethernet recovered on its own"
    readonly MSG_RECOVERED_IFCONFIG="Ethernet restored (ifconfig reset)"
    readonly MSG_RECOVERED_NETSETUP="Ethernet restored (service reset)"
    readonly MSG_GAVE_UP="Ethernet not restored — replug the adapter"
    readonly MSG_CONNECTED="Ethernet connected"
fi

# --- State ------------------------------------------------------------------
link_was_active=false
adapter_was_present=false
last_recovery_at=0
recovery_failures=0
rotation_counter=0
iface_output=""
last_poll_at=0
now_poll=0
first_link_up=true
boot_sec=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*{ sec = \([0-9]*\).*/\1/p') || boot_sec=0
# Ensure boot_sec is numeric; default to 0 if empty/non-numeric
if [[ -z "$boot_sec" || ! "$boot_sec" =~ '^[0-9]+$' ]]; then
    boot_sec=0
fi

# --- Helpers ----------------------------------------------------------------
log_msg() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || ts="UNKNOWN_TIME"
    if ! printf '%s  %s\n' "$ts" "$1" >> "$LOG" 2>/dev/null; then
        printf '%s  LOG_WRITE_FAILED: %s\n' "$ts" "$1" >&2
    fi
}

rotate_log() {
    local size
    size=$(stat -f%z "$LOG" 2>/dev/null) || return
    if (( size > MAX_LOG_BYTES )); then
        if mv -f "$LOG" "${LOG}.old" 2>/dev/null; then
            log_msg "Log rotated (previous log in ${LOG}.old)"
        else
            log_msg "[WARN] Log rotation failed"
        fi
    fi
}

get_console_user() {
    scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }' 2>/dev/null
}

notify() {
    local msg="$1" sound="${2:-Glass}"
    local console_user console_uid
    console_user=$(get_console_user) || return
    [[ -z "$console_user" || "$console_user" == "loginwindow" ]] && return
    console_uid=$(id -u "$console_user" 2>/dev/null) || return

    local output
    output=$(launchctl asuser "$console_uid" /usr/bin/osascript - "$msg" "$sound" <<'APPLESCRIPT' 2>&1
on run argv
    display notification (item 1 of argv) with title "Ethernet Monitor" sound name (item 2 of argv)
end run
APPLESCRIPT
    )
    if [[ $? -ne 0 ]]; then
        log_msg "[WARN] Notification failed: ${output:0:200}"
    fi
}

get_iface_status() {
    ifconfig "$IFACE" 2>/dev/null
}

# sleep that can be interrupted by SIGTERM
interruptible_sleep() {
    sleep "$1" &
    wait $!
}

# --- Recovery (escalating) --------------------------------------------------
attempt_recovery() {
    local now
    now=$(date +%s 2>/dev/null) || now=0

    # Respect cooldown to prevent recovery loops
    if (( now > 0 && last_recovery_at > 0 && now - last_recovery_at < RECOVERY_COOLDOWN )); then
        log_msg "[COOLDOWN] Recovery skipped (${RECOVERY_COOLDOWN}s cooldown)"
        return 1
    fi
    last_recovery_at=$now

    # Step 1: ifconfig down/up
    log_msg "[RECOVERY] Step 1/2: ifconfig $IFACE down/up"
    local err
    err=$(ifconfig "$IFACE" down 2>&1) || log_msg "[WARN] ifconfig down: $err"
    interruptible_sleep 2
    err=$(ifconfig "$IFACE" up 2>&1) || log_msg "[WARN] ifconfig up: $err"
    interruptible_sleep 5

    local status_output
    status_output=$(get_iface_status)
    if [[ "$status_output" == *"status: active"* ]]; then
        log_msg "[RECOVERED] ifconfig reset worked"
        notify "$MSG_RECOVERED_IFCONFIG" "Glass"
        recovery_failures=0
        return 0
    fi

    # Step 2: networksetup service toggle
    log_msg "[RECOVERY] Step 2/2: networksetup toggle \"$SERVICE\""
    err=$(networksetup -setnetworkserviceenabled "$SERVICE" off 2>&1) \
        || log_msg "[WARN] networksetup off: $err"
    interruptible_sleep 3
    err=$(networksetup -setnetworkserviceenabled "$SERVICE" on 2>&1) \
        || log_msg "[WARN] networksetup on: $err"
    interruptible_sleep 5

    status_output=$(get_iface_status)
    if [[ "$status_output" == *"status: active"* ]]; then
        log_msg "[RECOVERED] networksetup toggle worked"
        notify "$MSG_RECOVERED_NETSETUP" "Glass"
        recovery_failures=0
        return 0
    fi

    (( recovery_failures++ ))
    if (( recovery_failures >= MAX_RECOVERY_ATTEMPTS )); then
        log_msg "[GAVE UP] Auto-recovery failed ${MAX_RECOVERY_ATTEMPTS}x — stopping retries until link or adapter changes"
        notify "$MSG_GAVE_UP" "Basso"
    else
        log_msg "[FAILED] Recovery attempt $recovery_failures/$MAX_RECOVERY_ATTEMPTS failed"
    fi
    return 1
}

# --- Shutdown ---------------------------------------------------------------
cleanup() {
    log_msg "Monitor stopping (PID $$, signal received)"
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- Startup validation -----------------------------------------------------
log_msg "Monitor started (PID $$, interface $IFACE, poll ${CHECK_INTERVAL}s)"

if ! networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\* //' | grep -xqF "$SERVICE"; then
    log_msg "[ERROR] Network service '$SERVICE' not found. Recovery step 2 will fail."
    log_msg "[ERROR] Available: $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\* //' | tr '\n' ', ')"
fi

# --- Main loop --------------------------------------------------------------
while true; do
    if (( ++rotation_counter >= ROTATION_CHECK_INTERVAL )); then
        rotation_counter=0
        rotate_log
    fi

    # Detect wake from sleep via timestamp gap
    now_poll=$(date +%s 2>/dev/null) || now_poll=0
    if (( now_poll > 0 && last_poll_at > 0 && now_poll - last_poll_at > WAKE_THRESHOLD )); then
        log_msg "[WAKE] System resumed after $(( now_poll - last_poll_at ))s sleep"
        adapter_was_present=false
        link_was_active=false
        recovery_failures=0
    fi
    last_poll_at=$now_poll

    iface_output=$(get_iface_status)

    if [[ -z "$iface_output" ]]; then
        # Adapter not plugged in — reset state, no action
        if [[ "$adapter_was_present" == true ]]; then
            log_msg "[ADAPTER] $IFACE disappeared"
            adapter_was_present=false
            link_was_active=false
            recovery_failures=0
            first_link_up=false
        elif (( now_poll > 0 && boot_sec > 0 && now_poll - boot_sec > BOOT_GRACE )); then
            # System uptime beyond BOOT_GRACE without ever seeing adapter — not early boot
            first_link_up=false
        fi
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # --- Adapter is present ---

    if [[ "$adapter_was_present" == false ]]; then
        # Adapter just appeared — give it time to negotiate link
        log_msg "[ADAPTER] $IFACE appeared, waiting ${SELF_HEAL_WAIT}s for link negotiation..."
        adapter_was_present=true
        link_was_active=false
        recovery_failures=0
        interruptible_sleep "$SELF_HEAL_WAIT"

        iface_output=$(get_iface_status)
        if [[ -z "$iface_output" ]]; then
            adapter_was_present=false
            continue
        fi
    fi

    if [[ "$iface_output" == *"status: active"* ]]; then
        if [[ "$link_was_active" == false ]]; then
            log_msg "[LINK UP] $IFACE active"
            if [[ "$first_link_up" == true ]]; then
                first_link_up=false
            else
                notify "$MSG_CONNECTED" "Glass"
            fi
            link_was_active=true
            recovery_failures=0
        fi
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # --- Link is down, adapter is present ---

    # Already gave up — wait for state change (adapter replug or link return)
    if (( recovery_failures >= MAX_RECOVERY_ATTEMPTS )); then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if [[ "$link_was_active" == true ]]; then
        # Fresh drop — wait for self-heal first
        log_msg "[LINK DOWN] $IFACE inactive (waiting ${SELF_HEAL_WAIT}s for self-heal)"
        notify "$MSG_LINK_DOWN" "Purr"
        link_was_active=false

        interruptible_sleep "$SELF_HEAL_WAIT"

        iface_output=$(get_iface_status)
        if [[ -n "$iface_output" && "$iface_output" == *"status: active"* ]]; then
            log_msg "[SELF-HEALED] Link recovered on its own after ${SELF_HEAL_WAIT}s"
            notify "$MSG_SELF_HEALED" "Glass"
            link_was_active=true
            recovery_failures=0
            continue
        fi
    fi

    # Still down — attempt recovery (cooldown-protected)
    if attempt_recovery; then
        link_was_active=true
    fi

    sleep "$CHECK_INTERVAL"
done
