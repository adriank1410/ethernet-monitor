#!/bin/zsh
#
# ethernet-monitor — auto-recovery daemon for USB Ethernet (RTL8153)
#
# Watches the en6 interface. When the adapter is plugged in but the
# Ethernet link drops, attempts recovery:
#   1. Wait for self-heal (10s)
#   2. ifconfig down/up
#   3. Notify user to physically replug (then stop retrying)
#
# Install:   sudo ./install.sh
# Uninstall: sudo ./uninstall.sh
#
# Installed to /Library/PrivilegedHelperTools/ethernet-monitor (root-only directory).

setopt nounset  # error on undefined variables

_has_zsh_datetime=false
if zmodload zsh/datetime 2>/dev/null; then
    _has_zsh_datetime=true
else
    typeset -g EPOCHSECONDS
    EPOCHSECONDS=$(/bin/date +%s 2>/dev/null || echo 0)
fi

# In fallback mode, EPOCHSECONDS doesn't auto-update — call this before reading it.
# No-op when zsh/datetime is loaded (EPOCHSECONDS auto-updates).
refresh_epoch() {
    if [[ "$_has_zsh_datetime" == false ]]; then
        EPOCHSECONDS=$(/bin/date +%s 2>/dev/null || echo 0)
    fi
}

# Get wall-clock epoch from /bin/date (immune to EPOCHSECONDS staleness
# after DarkWake). Falls back to EPOCHSECONDS if /bin/date fails.
fresh_epoch() {
    /bin/date +%s 2>/dev/null || { refresh_epoch; echo "$EPOCHSECONDS"; }
}

# --- Config ----------------------------------------------------------------
readonly IFACE="en6"
readonly LOG="${ETHMON_LOG:-/var/log/ethernet-monitor.log}"
readonly CHECK_INTERVAL=3          # seconds between polls
readonly SELF_HEAL_WAIT=10         # seconds to wait before intervening
readonly RECOVERY_COOLDOWN=30      # min seconds between recovery attempts
readonly MAX_RECOVERY_ATTEMPTS=2   # give up after this many failed recoveries
readonly MAX_LOG_BYTES=1048576     # rotate log at 1 MB
readonly ROTATION_CHECK_INTERVAL=100  # check log size every N iterations (~5 min)
readonly WAKE_THRESHOLD=60            # time gap (s) that indicates system was sleeping
readonly BOOT_GRACE=120               # suppress first link-up notification for a never-seen adapter until uptime exceeds this (s)
readonly WAKE_SETTLE=120              # suppress notifications + recovery after wake (s); must exceed max DarkWake duration
readonly USER_WAKE_RESET_COOLDOWN=600 # min seconds between HID-wake recovery retries from gave-up state
readonly HID_IDLE_AWAY_THRESHOLD=60   # prev HID idle must exceed this (s) to treat next activity as a "return"
readonly HID_IDLE_BACK_THRESHOLD=10   # current HID idle must be under this (s) to treat as "user is back"
readonly HID_POLL_MIN_INTERVAL=30     # min seconds between ioreg HID polls in gave-up state (save CPU)

export PATH="/usr/sbin:/sbin:/usr/bin:/bin"

# --- Localization (PL/EN) ---------------------------------------------------
# Override with ETHMON_LANG=pl or ETHMON_LANG=en in the plist EnvironmentVariables,
# otherwise auto-detect from console user's system language.
if [[ -z "${ETHMON_LANG:-}" ]]; then
    # Same awk pattern as get_console_uid() — defined later, can't call yet at parse time
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
    readonly MSG_GAVE_UP="Ethernet nie wrócił — wyjmij i włóż przejściówkę"
    readonly MSG_CONNECTED="Ethernet podłączony"
else
    readonly MSG_LINK_DOWN="Ethernet link dropped — attempting auto-recovery..."
    readonly MSG_SELF_HEALED="Ethernet recovered on its own"
    readonly MSG_RECOVERED_IFCONFIG="Ethernet restored (ifconfig reset)"
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
wake_settle_until=0
link_ever_active=false
appeared_via_wake=false
pending_notify_msg=""
pending_notify_sound=""
pending_is_good_news=true
prev_hid_idle=0
last_user_wake_reset_at=0
last_hid_poll_at=0
boot_sec=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*{ sec = \([0-9]*\).*/\1/p') || boot_sec=0
# Ensure boot_sec is numeric; default to 0 if empty/non-numeric
if [[ -z "$boot_sec" || ! "$boot_sec" =~ '^[0-9]+$' ]]; then
    boot_sec=0
fi

# --- Helpers ----------------------------------------------------------------
log_msg() {
    local ts
    ts=$(/bin/date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || ts="UNKNOWN_TIME"
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

get_console_uid() {
    scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null \
        | awk '/CGSSessionUniqueSessionUUID/ { next } /^[[:space:]]*UID[[:space:]]*:/ { print $3 }'
}

# Returns 0 if the display is currently powered on, 1 if off.
# IODisplayWrangler CurrentPowerState: 4 = on.
# If ioreg fails or class not found, assumes display is on (don't suppress).
is_display_on() {
    local ioreg_out power_state
    ioreg_out=$(ioreg -r -d 1 -w 0 -c IODisplayWrangler 2>/dev/null)
    [[ -z "$ioreg_out" ]] && return 0
    power_state=$(echo "$ioreg_out" | sed -n 's/.*"CurrentPowerState" = \([0-9]*\).*/\1/p')
    # If we can't determine the power state, assume display is on
    [[ -z "$power_state" ]] && return 0
    (( power_state == 4 ))
}

# Seconds since the last HID (keyboard/mouse/trackpad) event.
# Used to detect real user presence — distinct from DarkWake, which can occur
# without any human interaction. Prints empty string on failure; callers must
# tolerate it (treat as "unknown — don't act").
get_hid_idle_seconds() {
    ioreg -c IOHIDSystem -d 0 -w 0 2>/dev/null \
        | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'
}

# Decide whether to retry recovery from the gave-up state after detecting that
# a user just returned to the machine. A "return" is defined as: HID was idle
# for more than HID_IDLE_AWAY_THRESHOLD seconds, and EITHER current HID idle is
# under HID_IDLE_BACK_THRESHOLD seconds OR an HID event occurred since the
# previous poll (cur_idle < cur_time - prev_poll_at). The since-poll check
# matters because HID polling is throttled to HID_POLL_MIN_INTERVAL — without
# it, a user who clicked mid-window and went idle again before the next poll
# would be missed permanently (cur_idle would exceed HID_IDLE_BACK_THRESHOLD
# and prev_hid_idle would never reach AWAY again). Additionally,
# USER_WAKE_RESET_COOLDOWN must have elapsed since the previous retry.
#
# Arguments: $1 = current HID idle seconds (may be empty), $2 = current epoch,
# $3 = previous HID poll epoch (optional; 0 disables the since-poll check).
# Reads globals: prev_hid_idle, last_user_wake_reset_at, HID_IDLE_*, USER_WAKE_*
# Returns 0 (true) if retry should happen, 1 (false) otherwise.
should_retry_after_user_wake() {
    local cur_idle="$1" cur_time="$2" prev_poll_at="${3:-0}"
    [[ -z "$cur_idle" ]] && return 1
    (( prev_hid_idle > HID_IDLE_AWAY_THRESHOLD )) || return 1
    (( cur_time - last_user_wake_reset_at > USER_WAKE_RESET_COOLDOWN )) || return 1
    (( cur_idle < HID_IDLE_BACK_THRESHOLD )) && return 0
    if (( prev_poll_at > 0 )); then
        local since_prev=$(( cur_time - prev_poll_at ))
        (( since_prev > 0 && cur_idle < since_prev )) && return 0
    fi
    return 1
}

# Check if the pending notification contradicts current iface state.
# Uses globals: iface_output, pending_is_good_news. Returns 0 if stale.
_pending_is_stale() {
    if [[ "$iface_output" == *"status: active"* ]]; then
        # Link is up — bad-news pending is stale
        [[ "$pending_is_good_news" == false ]]
    else
        # Link is down — good-news pending is stale
        [[ "$pending_is_good_news" == true ]]
    fi
}

_deliver_notify() {
    local msg="$1" sound="${2:-Glass}"
    local console_uid
    console_uid=$(get_console_uid) || return
    [[ -z "$console_uid" || "$console_uid" == "0" ]] && return

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

notify() {
    local msg="$1" sound="${2:-Glass}"
    # Classify: link_down and gave_up are bad news, everything else is good
    local is_good=true
    [[ "$msg" == "$MSG_LINK_DOWN" || "$msg" == "$MSG_GAVE_UP" ]] && is_good=false
    # Suppress during wake settle (link stabilization after wake)
    local notify_now
    notify_now=$(fresh_epoch)
    if (( wake_settle_until > 0 && notify_now < wake_settle_until )); then
        log_msg "[SUPPRESSED] $msg"
        pending_notify_msg="$msg"
        pending_notify_sound="$sound"
        pending_is_good_news=$is_good
        return
    fi
    # Suppress when display is off (DarkWake, display sleep, lid closed)
    if ! is_display_on; then
        log_msg "[SUPPRESSED] $msg (display off)"
        pending_notify_msg="$msg"
        pending_notify_sound="$sound"
        pending_is_good_news=$is_good
        return
    fi
    pending_notify_msg=""
    pending_notify_sound=""
    _deliver_notify "$msg" "$sound"
}

get_iface_status() {
    ifconfig "$IFACE" 2>/dev/null
}

# sleep that can be interrupted by SIGTERM
interruptible_sleep() {
    sleep "$1" &
    wait $!
}

# Detect system sleep that occurred during an interruptible_sleep.
# Compares wall-clock time against now_poll (set at loop top).
# Returns 0 if wake detected (caller should restart main loop or abort).
check_mid_loop_wake() {
    local real_now
    real_now=$(fresh_epoch)
    if (( real_now > 0 && now_poll > 0 && real_now - now_poll > WAKE_THRESHOLD )); then
        log_msg "[WAKE] System resumed after $(( real_now - now_poll ))s (mid-loop)"
        adapter_was_present=false
        link_was_active=false
        wake_settle_until=$(( real_now + WAKE_SETTLE ))
        last_poll_at=$real_now
        now_poll=$real_now
        pending_notify_msg=""
        pending_notify_sound=""
        return 0
    fi
    return 1
}

# --- Recovery ---------------------------------------------------------------
attempt_recovery() {
    local now
    now=$(fresh_epoch)

    # Respect cooldown to prevent recovery loops
    if (( now > 0 && last_recovery_at > 0 && now - last_recovery_at < RECOVERY_COOLDOWN )); then
        log_msg "[COOLDOWN] Recovery skipped (${RECOVERY_COOLDOWN}s cooldown)"
        return 1
    fi
    last_recovery_at=$now

    log_msg "[RECOVERY] ifconfig $IFACE down/up"
    local err
    err=$(ifconfig "$IFACE" down 2>&1) || log_msg "[WARN] ifconfig down: $err"
    interruptible_sleep 2
    err=$(ifconfig "$IFACE" up 2>&1) || log_msg "[WARN] ifconfig up: $err"
    interruptible_sleep 5
    if check_mid_loop_wake; then return 1; fi

    local status_output
    status_output=$(get_iface_status)
    if [[ "$status_output" == *"status: active"* ]]; then
        log_msg "[RECOVERED] ifconfig reset worked"
        notify "$MSG_RECOVERED_IFCONFIG" "Glass"
        recovery_failures=0
        return 0
    fi

    (( recovery_failures++ ))
    if (( recovery_failures >= MAX_RECOVERY_ATTEMPTS )); then
        log_msg "[GAVE UP] Auto-recovery failed ${MAX_RECOVERY_ATTEMPTS}x — stopping retries until link, adapter, or user wake"
        notify "$MSG_GAVE_UP" "Basso"
        prev_hid_idle=0
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

# --- Main loop iteration ----------------------------------------------------
# Single iteration of the polling logic. Returns 0 always; each early "skip"
# (what used to be `continue` in the while loop) is now `return 0`. Extracted
# so integration tests can drive the state machine directly by calling this
# function with mocked external-command wrappers.
run_iteration() {
    if (( ++rotation_counter >= ROTATION_CHECK_INTERVAL )); then
        rotation_counter=0
        rotate_log
    fi

    # Detect wake from sleep via timestamp gap
    now_poll=$(fresh_epoch)
    if (( now_poll > 0 && last_poll_at > 0 && now_poll - last_poll_at > WAKE_THRESHOLD )); then
        log_msg "[WAKE] System resumed after $(( now_poll - last_poll_at ))s sleep"
        adapter_was_present=false
        link_was_active=false
        # Don't reset recovery_failures — let gave-up state carry across DarkWakes
        # to prevent repeated "nie wrócił" notifications. Reset only on LINK UP or real replug.
        wake_settle_until=$(( now_poll + WAKE_SETTLE ))
        pending_notify_msg=""
        pending_notify_sound=""
    fi
    last_poll_at=$now_poll

    # Clear expired settle. Don't reset recovery_failures here — gave-up state
    # is sticky until a positive signal (LINK UP or real adapter replug).
    if (( wake_settle_until > 0 && now_poll >= wake_settle_until )); then
        wake_settle_until=0
    fi

    iface_output=$(get_iface_status)

    if [[ -z "$iface_output" ]]; then
        # Adapter not plugged in — reset state, no action
        if [[ "$adapter_was_present" == true ]]; then
            log_msg "[ADAPTER] $IFACE disappeared"
            adapter_was_present=false
            link_was_active=false
            recovery_failures=0
            link_ever_active=false
            appeared_via_wake=false
            first_link_up=false
            pending_notify_msg=""
            pending_notify_sound=""
            prev_hid_idle=0
        elif (( now_poll > 0 && boot_sec > 0 && now_poll - boot_sec > BOOT_GRACE )); then
            # System uptime beyond BOOT_GRACE without ever seeing adapter — not early boot
            first_link_up=false
        fi
        sleep "$CHECK_INTERVAL"
        return 0
    fi

    # --- Adapter is present ---

    # Deliver pending notification now that current state is known.
    # Only deliver "bad news" (link_down, gave_up) — good news is informational
    # and the user will see ethernet working without a notification.
    if [[ -n "$pending_notify_msg" ]]; then
        pending_now=$(fresh_epoch)
        if (( wake_settle_until == 0 || pending_now >= wake_settle_until )); then
            if is_display_on; then
                if [[ "$pending_is_good_news" == true ]]; then
                    log_msg "[DROPPED] Good-news pending not needed: $pending_notify_msg"
                elif _pending_is_stale; then
                    log_msg "[STALE] Skipping outdated: $pending_notify_msg"
                else
                    log_msg "[DEFERRED] Delivering: $pending_notify_msg"
                    _deliver_notify "$pending_notify_msg" "$pending_notify_sound"
                fi
                pending_notify_msg=""
                pending_notify_sound=""
            fi
        fi
    fi

    if [[ "$adapter_was_present" == false ]]; then
        adapter_was_present=true
        link_was_active=false
        # Track whether this appearance is a wake re-enumeration (not a physical plug-in).
        # Wake detection sets adapter_was_present=false; real replugs go through "disappeared".
        if (( wake_settle_until > 0 )); then
            appeared_via_wake=true
        fi
        if [[ "$appeared_via_wake" == true && "$link_ever_active" == false ]]; then
            log_msg "[ADAPTER] $IFACE appeared (wake, no link history — passive)"
        else
            log_msg "[ADAPTER] $IFACE appeared, waiting ${SELF_HEAL_WAIT}s for link negotiation..."
        fi
        interruptible_sleep "$SELF_HEAL_WAIT"
        if check_mid_loop_wake; then return 0; fi

        iface_output=$(get_iface_status)
        if [[ -z "$iface_output" ]]; then
            adapter_was_present=false
            return 0
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
            link_ever_active=true
            appeared_via_wake=false
            recovery_failures=0
            prev_hid_idle=0
        fi
        sleep "$CHECK_INTERVAL"
        return 0
    fi

    # --- Link is down, adapter is present ---

    # During wake settle, skip all link-down handling — just poll
    if (( now_poll > 0 && now_poll < wake_settle_until )); then
        sleep "$CHECK_INTERVAL"
        return 0
    fi

    # Already gave up — wait for state change (adapter replug or link return).
    # Exception: if the user was idle for a while and just became active again,
    # assume they physically woke the laptop or returned to it. Give recovery
    # one more shot — the earlier failures may have been during clamshell or
    # DarkWake, and a fresh banner now will actually be visible.
    if (( recovery_failures >= MAX_RECOVERY_ATTEMPTS )); then
        if (( now_poll - last_hid_poll_at < HID_POLL_MIN_INTERVAL )); then
            sleep "$CHECK_INTERVAL"
            return 0
        fi
        local prev_hid_poll_at=$last_hid_poll_at
        last_hid_poll_at=$now_poll
        local hid_idle
        hid_idle=$(get_hid_idle_seconds)
        if should_retry_after_user_wake "$hid_idle" "$now_poll" "$prev_hid_poll_at"; then
            log_msg "[USER WAKE] HID idle ${hid_idle}s (prev ${prev_hid_idle}s) — retrying recovery from gave-up state"
            recovery_failures=0
            last_recovery_at=0
            last_user_wake_reset_at=$now_poll
            prev_hid_idle=$hid_idle
            # fall through to the normal link-down handling below
        else
            # If hid_idle is unknown (ioreg failed), reset prev_hid_idle to 0
            # so a later valid sample can't be paired with a stale away value
            # — preserves the "unknown → don't act" contract of
            # should_retry_after_user_wake even across transient ioreg errors.
            if [[ -n "$hid_idle" ]]; then
                prev_hid_idle=$hid_idle
            else
                prev_hid_idle=0
            fi
            sleep "$CHECK_INTERVAL"
            return 0
        fi
    fi

    # Adapter re-appeared after wake but link was never active in this adapter
    # session — likely no cable connected. Stay passive instead of running
    # recovery that will always fail and produce a spurious notification.
    if [[ "$appeared_via_wake" == true && "$link_ever_active" == false ]]; then
        sleep "$CHECK_INTERVAL"
        return 0
    fi

    if [[ "$link_was_active" == true ]]; then
        # Fresh drop — wait for self-heal first
        log_msg "[LINK DOWN] $IFACE inactive (waiting ${SELF_HEAL_WAIT}s for self-heal)"
        notify "$MSG_LINK_DOWN" "Purr"
        link_was_active=false

        interruptible_sleep "$SELF_HEAL_WAIT"
        if check_mid_loop_wake; then return 0; fi

        iface_output=$(get_iface_status)
        if [[ -z "$iface_output" ]]; then
            # Adapter disappeared during self-heal wait — let next iteration handle it
            return 0
        fi
        if [[ "$iface_output" == *"status: active"* ]]; then
            log_msg "[SELF-HEALED] Link recovered on its own after ${SELF_HEAL_WAIT}s"
            notify "$MSG_SELF_HEALED" "Glass"
            link_was_active=true
            recovery_failures=0
            return 0
        fi
    fi

    # Still down, adapter still present — attempt recovery (cooldown-protected)
    # Skip recovery when display is off (DarkWake, lid closed) — nobody benefits,
    # and ifconfig calls during DarkWake cannot succeed.
    if ! is_display_on; then
        sleep "$CHECK_INTERVAL"
        return 0
    fi
    if attempt_recovery; then
        link_was_active=true
    fi

    sleep "$CHECK_INTERVAL"
    return 0
}

# --- Startup validation -----------------------------------------------------
# When the script is sourced from a test with ETHMON_NO_MAIN=1, bail out before
# installing signal traps or starting the main loop so the test can exercise
# individual functions (run_iteration, should_retry_after_user_wake). Sourcing
# still performs the setup above (setopt, globals, PATH); this guard only skips
# traps and the monitor loop. We only honour the env var when the file is
# actually being sourced (ZSH_EVAL_CONTEXT contains "file") — otherwise, treat
# an accidental production env var as a footgun and log a warning instead of
# silently disabling monitoring.
if [[ "${ETHMON_NO_MAIN:-0}" == "1" ]]; then
    if [[ "${ZSH_EVAL_CONTEXT:-}" == *file* ]]; then
        return 0
    fi
    log_msg "[WARN] ETHMON_NO_MAIN=1 ignored during normal execution; continuing startup"
fi

trap cleanup SIGTERM SIGINT
log_msg "Monitor started (PID $$, interface $IFACE, poll ${CHECK_INTERVAL}s)"

# --- Main loop --------------------------------------------------------------
while true; do
    run_iteration
done
