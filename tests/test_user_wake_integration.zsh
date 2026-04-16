#!/usr/bin/env zsh
#
# Integration test: reproduce the 2026-04-15 incident sequence end-to-end by
# driving run_iteration() with the real attempt_recovery() backed by a PATH-
# shimmed ifconfig, and asserting the resulting log. Covers the regression
# described in the PR ("daemon enters gave-up during sleep, never notifies
# the user after they return") plus the HID-throttling follow-up fix (user
# returning between HID polls must still trigger a retry) and wake-event
# detection via fresh_epoch jumps.
#
# Design notes:
#   - attempt_recovery() is NOT mocked. ifconfig is replaced by a shim on
#     PATH so the real recovery function runs unmodified, including the
#     prev_hid_idle=0 reset that lives inside it. Previously the test
#     duplicated that reset, which defeated its purpose as a regression
#     guard.
#   - check_mid_loop_wake() is NOT mocked. With fresh_epoch() stable within
#     a single run_iteration() call (MOCK_TIME does not change mid-iter) and
#     interruptible_sleep() a no-op, the real function naturally returns 1.
#   - get_iface_status() reads link state from a file the ifconfig shim can
#     rewrite mid-iteration. An in-process counter was tried first but fails:
#     get_iface_status runs inside command substitution, so any state written
#     in the subshell is dropped. The file sidesteps that by making the state
#     visible to every subshell.
#
# Run: zsh tests/test_user_wake_integration.zsh

set -e

script_dir=${0:A:h}
repo_root=${script_dir:h}
log_file=$(mktemp -t ethmon-int.XXXXXX)
shim_dir=$(mktemp -d -t ethmon-shim.XXXXXX)
trap 'rm -rf "$log_file" "$shim_dir"' EXIT

# Fake ifconfig on PATH. The get_iface_status mock reads link state from a
# test-managed file (see below). When a "flip_pending" sentinel exists and
# the shim is invoked with "up", it rewrites the state file to "status:
# active" — simulating a successful recovery. This mirrors how production
# ifconfig brings an interface up, so subsequent status checks observe the
# change. Shell variable scope blocks using in-process counters here
# because get_iface_status is invoked via command substitution, and any
# state written in a subshell is dropped.
iface_state_file="$shim_dir/iface_status"
flip_sentinel="$shim_dir/flip_pending"

cat > "$shim_dir/ifconfig" <<SHIM
#!/usr/bin/env zsh
if [[ "\$2" == "up" && -f "$flip_sentinel" ]]; then
    printf 'status: active\n' > "$iface_state_file"
    rm -f "$flip_sentinel"
fi
exit 0
SHIM
chmod +x "$shim_dir/ifconfig"

ETHMON_NO_MAIN=1 ETHMON_LOG="$log_file" source "$repo_root/ethernet-monitor.sh"
unsetopt nounset

# ethernet-monitor.sh rewrites PATH on source; prepend the shim afterwards so
# attempt_recovery() finds our fake ifconfig first.
export PATH="$shim_dir:$PATH"

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
        (( ++failures ))
    fi
}

assert_log_not_contains() {
    local label="$1" pattern="$2"
    if grep -qF -- "$pattern" "$log_file"; then
        print -- "FAIL  $label — log unexpectedly contains: $pattern"
        (( ++failures ))
    else
        print -- "PASS  $label"
    fi
}

# --- Mocked external commands ---------------------------------------------
MOCK_HID_IDLE=1
MOCK_DISPLAY_ON=true
MOCK_TIME=1000

# Link state lives in $iface_state_file (file-backed so the ifconfig shim
# can flip it mid-iteration, and so command-substitution subshells see a
# consistent value). set_iface_status overwrites it; arm_recovery_success
# arms the shim to flip it to "active" on the next `ifconfig up`.
set_iface_status() {
    printf '%s\n' "$1" > "$iface_state_file"
}

arm_recovery_success() {
    touch "$flip_sentinel"
}

get_iface_status() {
    cat "$iface_state_file" 2>/dev/null
}

get_hid_idle_seconds() { echo "$MOCK_HID_IDLE"; }
is_display_on()        { [[ "$MOCK_DISPLAY_ON" == true ]]; }
fresh_epoch()          { echo "$MOCK_TIME"; }
refresh_epoch()        { :; }
sleep()                { :; }
interruptible_sleep()  { :; }
rotate_log()           { :; }
_deliver_notify()      { log_msg "[NOTIFY-DELIVERED] $1"; }

# --- Scenario: reproduce 2026-04-15 incident sequence ---------------------
#
# Phases 1–3 follow the production recovery path into gave-up (prev_hid_idle
# is reset inside the real attempt_recovery, not by the test).
# Phase 4 simulates idle iterations while the user stays away.
# Phase 5 is the Point 1 regression: user returns BETWEEN HID polls so the
# next poll sees cur_idle=25 (above HID_IDLE_BACK_THRESHOLD=10 but below the
# 35s poll delta). Before the fix this was missed — the test now proves the
# since-poll path fires and recovery succeeds.
# Phase 6 exercises real wake detection via a MOCK_TIME jump > WAKE_THRESHOLD.

# --- Phase 1: healthy link, user active ---
set_iface_status "status: active"
MOCK_HID_IDLE=1
MOCK_TIME=1000
first_link_up=false
run_iteration
assert_log_contains "phase 1 — healthy link logs [LINK UP]" "[LINK UP] en6 active"

# --- Phase 2: link drops → fresh drop path → recovery attempt 1 fails ---
set_iface_status "status: inactive"
MOCK_HID_IDLE=20
MOCK_TIME=1010
run_iteration
assert_log_contains "phase 2 — fresh drop logs [LINK DOWN]" "[LINK DOWN] en6 inactive"
assert_log_contains "phase 2 — first recovery attempt logged" "[RECOVERY]"
assert_log_contains "phase 2 — first recovery fails" "[FAILED] Recovery attempt 1/2 failed"

# --- Phase 3: past cooldown → recovery attempt 2 fails → GAVE UP ---
# The real attempt_recovery sets prev_hid_idle=0 on reaching GAVE UP; the
# test no longer duplicates that reset.
MOCK_TIME=1045
MOCK_HID_IDLE=55
run_iteration
assert_log_contains "phase 3 — second recovery fails, GAVE UP" "[GAVE UP]"
assert_log_contains "phase 3 — GAVE UP notification delivered" "[NOTIFY-DELIVERED]"
if (( prev_hid_idle == 0 )); then
    print -- "PASS  phase 3 — prev_hid_idle reset to 0 by real attempt_recovery"
else
    print -- "FAIL  phase 3 — expected prev_hid_idle=0, got $prev_hid_idle"
    (( ++failures ))
fi

# --- Phase 4: user still absent, no retry during idle iterations ---
# HID_POLL_MIN_INTERVAL=30s throttles ioreg calls, so time deltas must be
# ≥30s (staying <WAKE_THRESHOLD=60s to avoid false wake detection). While
# the user stays away (current HID high), no trigger.
MOCK_TIME=1080; MOCK_HID_IDLE=80;  run_iteration  # prev_hid_idle 0 → 80
MOCK_TIME=1115; MOCK_HID_IDLE=100; run_iteration  # prev 80 → 100
MOCK_TIME=1150; MOCK_HID_IDLE=150; run_iteration  # prev 100 → 150
assert_log_not_contains "phase 4 — no premature [USER WAKE] while away" "[USER WAKE]"

# --- Phase 5: user returns BETWEEN polls → since-poll retry succeeds ------
# This is the Point 1 regression test. At MOCK_TIME=1185 the user-reported
# scenario is: previous HID poll at 1150, user clicked ~t=1160, HID idle at
# 1185 is 25s. Without the since-poll check, should_retry_after_user_wake
# would fail (25 !< HID_IDLE_BACK_THRESHOLD=10) and the user's return would
# be lost until they actively typed during a poll — the very gap the PR is
# supposed to close. arm_recovery_success schedules the shim to flip the
# state file to "active" during the real attempt_recovery call.
arm_recovery_success
MOCK_TIME=1185
MOCK_HID_IDLE=25
run_iteration
assert_log_contains "phase 5 — between-poll return triggers [USER WAKE]" \
    "[USER WAKE] HID idle 25s (prev 150s)"
assert_log_contains "phase 5 — retry attempt logged after reset" "[RECOVERY]"
assert_log_contains "phase 5 — retry succeeds" "[RECOVERED] ifconfig reset worked"

# --- Phase 6: real wake detection via MOCK_TIME jump ---------------------
# After phase 5 the link is restored (state file flipped to "active"). Advance
# MOCK_TIME by 150s (> WAKE_THRESHOLD=60) to simulate a system sleep. The
# real run_iteration must log [WAKE], arm wake_settle_until, and clear
# adapter_was_present — proving the wake path works without a mocked
# check_mid_loop_wake.
MOCK_TIME=1335
MOCK_HID_IDLE=1
run_iteration
assert_log_contains "phase 6 — MOCK_TIME jump triggers real [WAKE]" \
    "[WAKE] System resumed after 150s sleep"
if (( wake_settle_until > MOCK_TIME )); then
    print -- "PASS  phase 6 — wake_settle_until armed after wake detection"
else
    print -- "FAIL  phase 6 — expected wake_settle_until > $MOCK_TIME, got $wake_settle_until"
    (( ++failures ))
fi

# --- Regression counts ----------------------------------------------------
# The whole point of the fix: the gap between GAVE UP and a physical replug
# (18h in the real incident) now contains a recovery retry path. Before,
# there was no [USER WAKE] in this sequence. The since-poll fix keeps that
# guarantee even when the user returns mid-throttle-window.
retry_count=$(grep -c "\[RECOVERY\]" "$log_file" || true)
if (( retry_count >= 3 )); then
    print -- "PASS  regression — recovery was attempted $retry_count times total (≥3)"
else
    print -- "FAIL  regression — expected ≥3 [RECOVERY] entries, got $retry_count"
    (( ++failures ))
fi

gave_up_count=$(grep -c "\[GAVE UP\]" "$log_file" || true)
user_wake_count=$(grep -c "\[USER WAKE\]" "$log_file" || true)
if (( gave_up_count == 1 && user_wake_count == 1 )); then
    print -- "PASS  regression — exactly one [GAVE UP] followed by one [USER WAKE]"
else
    print -- "FAIL  regression — counts off: GAVE UP=$gave_up_count USER WAKE=$user_wake_count"
    (( ++failures ))
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
