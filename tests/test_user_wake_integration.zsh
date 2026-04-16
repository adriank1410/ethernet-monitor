#!/usr/bin/env zsh
#
# Integration test: reproduce the 2026-04-15 incident sequence end-to-end by
# driving run_iteration() with mocked external commands and asserting the
# resulting log. This directly tests the regression described in the PR:
# "daemon enters gave-up during sleep, never notifies the user after they
# return, link stays down all day". Under the fix, a user-wake is detected,
# recovery is retried, and the log records [USER WAKE] followed by recovery.
#
# Run: zsh tests/test_user_wake_integration.zsh

set -e

script_dir=${0:A:h}
repo_root=${script_dir:h}
log_file=$(mktemp -t ethmon-int.XXXXXX)
trap 'rm -f "$log_file"' EXIT

ETHMON_NO_MAIN=1 ETHMON_LOG="$log_file" source "$repo_root/ethernet-monitor.sh"
unsetopt nounset

failures=0

assert_log_contains() {
    local label="$1" pattern="$2"
    if grep -qF -- "$pattern" "$log_file"; then
        print -- "PASS  $label"
    else
        print -- "FAIL  $label — log missing: $pattern"
        print -- "  ---- log so far ----"
        sed 's/^/  /' "$log_file"
        print -- "  ---- end ----"
        (( failures++ ))
    fi
}

assert_log_not_contains() {
    local label="$1" pattern="$2"
    if grep -qF -- "$pattern" "$log_file"; then
        print -- "FAIL  $label — log unexpectedly contains: $pattern"
        (( failures++ ))
    else
        print -- "PASS  $label"
    fi
}

# --- Mocked external commands ---------------------------------------------
MOCK_IFACE_STATUS="status: active"
MOCK_HID_IDLE=1
MOCK_DISPLAY_ON=true
MOCK_TIME=1000
MOCK_RECOVERY_RESULT=fail

get_iface_status()     { echo "$MOCK_IFACE_STATUS"; }
get_hid_idle_seconds() { echo "$MOCK_HID_IDLE"; }
is_display_on()        { [[ "$MOCK_DISPLAY_ON" == true ]]; }
fresh_epoch()          { echo "$MOCK_TIME"; }
refresh_epoch()        { :; }
sleep()                { :; }
interruptible_sleep()  { :; }
check_mid_loop_wake()  { return 1; }
rotate_log()           { :; }
_deliver_notify()      { log_msg "[NOTIFY-DELIVERED] $1"; }

attempt_recovery() {
    local now
    now=$(fresh_epoch)
    if (( last_recovery_at > 0 && now - last_recovery_at < RECOVERY_COOLDOWN )); then
        log_msg "[COOLDOWN] Recovery skipped (${RECOVERY_COOLDOWN}s cooldown)"
        return 1
    fi
    last_recovery_at=$now
    log_msg "[RECOVERY] ifconfig $IFACE down/up (mock)"
    if [[ "$MOCK_RECOVERY_RESULT" == success ]]; then
        log_msg "[RECOVERED] ifconfig reset worked"
        notify "$MSG_RECOVERED_IFCONFIG" "Glass"
        recovery_failures=0
        return 0
    fi
    (( recovery_failures++ ))
    if (( recovery_failures >= MAX_RECOVERY_ATTEMPTS )); then
        log_msg "[GAVE UP] Auto-recovery failed ${MAX_RECOVERY_ATTEMPTS}x — stopping retries until link or adapter changes"
        notify "$MSG_GAVE_UP" "Basso"
        prev_hid_idle=0
    else
        log_msg "[FAILED] Recovery attempt $recovery_failures/$MAX_RECOVERY_ATTEMPTS failed"
    fi
    return 1
}

# --- Scenario: reproduce 2026-04-15 incident sequence ---------------------
#
# Timestamps stay within WAKE_THRESHOLD (60s) of each other so the daemon
# never triggers its wake-detection path — we are simulating a continuous
# poll sequence, not a sleep/wake cycle. HID idle, however, grows freely to
# model the user stepping away and later returning.
#
# 1. Daemon sees a healthy link while the user is active.         (iter 1)
# 2. Link drops mid-poll → fresh drop → recovery attempt 1 fails. (iter 2)
# 3. Past recovery cooldown → recovery attempt 2 fails → GAVE UP. (iter 3)
# 4. Daemon sits idle; user still absent, no retry.               (iter 4-6)
# 5. User returns, types → [USER WAKE] → retry succeeds.          (iter 7)

# --- Phase 1: healthy link, user active ---
MOCK_IFACE_STATUS="status: active"
MOCK_HID_IDLE=1
MOCK_TIME=1000
first_link_up=false
run_iteration
assert_log_contains "phase 1 — healthy link logs [LINK UP]" "[LINK UP] en6 active"

# --- Phase 2: link drops → fresh drop path → recovery attempt 1 fails ---
MOCK_IFACE_STATUS="status: inactive"
MOCK_HID_IDLE=20
MOCK_TIME=1010
run_iteration
assert_log_contains "phase 2 — fresh drop logs [LINK DOWN]" "[LINK DOWN] en6 inactive"
assert_log_contains "phase 2 — first recovery attempt logged" "[RECOVERY]"
assert_log_contains "phase 2 — first recovery fails" "[FAILED] Recovery attempt 1/2 failed"

# --- Phase 3: past cooldown → recovery attempt 2 fails → GAVE UP ---
MOCK_TIME=1045   # 35s after last_recovery_at=1010 (> RECOVERY_COOLDOWN=30)
MOCK_HID_IDLE=55
run_iteration
assert_log_contains "phase 3 — second recovery fails, GAVE UP" "[GAVE UP]"
assert_log_contains "phase 3 — GAVE UP notification attempted" "[NOTIFY-DELIVERED]"

# --- Phase 4: user still absent, no retry during idle iterations ---
# prev_hid_idle was reset to 0 by the GAVE UP handler. Each HID poll in the
# gave-up block updates it. HID_POLL_MIN_INTERVAL=30s throttles ioreg calls,
# so time deltas must be ≥30s (while staying <WAKE_THRESHOLD=60s to avoid
# false wake detection). While user stays away (current HID high), no trigger.
MOCK_TIME=1080; MOCK_HID_IDLE=80;  run_iteration  # prev=0→80
MOCK_TIME=1115; MOCK_HID_IDLE=100; run_iteration  # prev=80→100
MOCK_TIME=1150; MOCK_HID_IDLE=150; run_iteration  # prev=100→150
assert_log_not_contains "phase 4 — no premature [USER WAKE] while away" "[USER WAKE]"

# --- Phase 5: user returns and types → [USER WAKE] + successful retry ---
# prev_hid_idle is now 150 (from phase 4), current drops to 1 → trigger.
# Cooldown check: USER_WAKE_RESET_COOLDOWN=600, last_user_wake_reset_at=0,
# now=1185 → 1185-0=1185 > 600 → cooldown OK. Delta from phase 4 is 35s:
# above HID_POLL_MIN_INTERVAL (30), below WAKE_THRESHOLD (60).
MOCK_TIME=1185
MOCK_HID_IDLE=1
MOCK_RECOVERY_RESULT=success
run_iteration
assert_log_contains "phase 5 — user return triggers [USER WAKE]" "[USER WAKE] HID idle 1s (prev 150s)"
assert_log_contains "phase 5 — retry attempt logged after reset" "[RECOVERY]"
assert_log_contains "phase 5 — retry succeeds" "[RECOVERED] ifconfig reset worked"

# --- Regression check: before the fix this sequence had no [USER WAKE] ---
# The whole point of the fix: the gap between GAVE UP and physical replug
# (18h in the real incident) now contains a recovery retry path.
retry_count=$(grep -c "\[RECOVERY\]" "$log_file" || true)
if (( retry_count >= 3 )); then
    print -- "PASS  regression — recovery was attempted $retry_count times total (≥3)"
else
    print -- "FAIL  regression — expected ≥3 [RECOVERY] entries, got $retry_count"
    (( failures++ ))
fi

gave_up_count=$(grep -c "\[GAVE UP\]" "$log_file" || true)
user_wake_count=$(grep -c "\[USER WAKE\]" "$log_file" || true)
if (( gave_up_count == 1 && user_wake_count == 1 )); then
    print -- "PASS  regression — exactly one [GAVE UP] followed by one [USER WAKE]"
else
    print -- "FAIL  regression — counts off: GAVE UP=$gave_up_count USER WAKE=$user_wake_count"
    (( failures++ ))
fi

print -- ""
print -- "--- Final log dump ---"
sed 's/^/  /' "$log_file"
print -- "--- End dump ---"
print -- ""
if (( failures > 0 )); then
    print -- "$failures test(s) FAILED"
    exit 1
fi
print -- "All integration tests PASSED"
