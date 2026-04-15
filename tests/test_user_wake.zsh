#!/usr/bin/env zsh
#
# Unit tests for should_retry_after_user_wake.
#
# Sources ethernet-monitor.sh with ETHMON_NO_MAIN=1 to skip the main loop,
# then exercises the decision function with controlled inputs. No ioreg or
# /var/log writes happen — mocks the HID idle seconds per test case.
#
# Run: zsh tests/test_user_wake.zsh

set -e

script_dir=${0:A:h}
repo_root=${script_dir:h}
tmp_log=$(mktemp -t ethmon-test.XXXXXX)
trap 'rm -f "$tmp_log"' EXIT

ETHMON_NO_MAIN=1 ETHMON_LOG="$tmp_log" source "$repo_root/ethernet-monitor.sh"

# nounset is inherited from the sourced script; relax it so tests can reset
# state freely without tripping over unset locals on first access.
unsetopt nounset

failures=0
pass() {
    local name="$1"; shift
    if "$@"; then
        print -- "PASS  $name"
    else
        print -- "FAIL  $name (expected success, got failure)"
        (( failures++ ))
    fi
}
fail() {
    local name="$1"; shift
    if "$@"; then
        print -- "FAIL  $name (expected failure, got success)"
        (( failures++ ))
    else
        print -- "PASS  $name"
    fi
}

# Constants come from the sourced script (readonly, can't be overridden):
#   HID_IDLE_AWAY_THRESHOLD=60
#   HID_IDLE_BACK_THRESHOLD=10
#   USER_WAKE_RESET_COOLDOWN=600
# Tests below are written against those exact values.

# --- Test 1: user was idle for an hour, just clicked a key ---
# Expected: retry fires.
prev_hid_idle=3600
last_user_wake_reset_at=0
pass "user returned from long idle" should_retry_after_user_wake 2 10000

# --- Test 2: user pressing keys non-stop, link just happened to fail ---
# Expected: no retry (prev never exceeded AWAY threshold).
prev_hid_idle=2
last_user_wake_reset_at=0
fail "user continuously active" should_retry_after_user_wake 1 10000

# --- Test 3: genuine return but cooldown still active ---
# Expected: no retry (cooldown not elapsed).
prev_hid_idle=3600
last_user_wake_reset_at=9500   # 500s before now, cooldown is 600s
fail "cooldown blocks repeat" should_retry_after_user_wake 2 10000

# --- Test 4: cooldown just elapsed (edge: > not >=) ---
# Expected: retry fires at 601s, not at 600s.
prev_hid_idle=3600
last_user_wake_reset_at=9400   # exactly 600s before now
fail "cooldown exact boundary (not yet)" should_retry_after_user_wake 2 10000
last_user_wake_reset_at=9399   # 601s before now
pass "cooldown just elapsed" should_retry_after_user_wake 2 10000

# --- Test 5: empty HID idle (ioreg failed) ---
# Expected: no retry (caller must treat unknown as "don't act").
prev_hid_idle=3600
last_user_wake_reset_at=0
fail "empty hid_idle yields no retry" should_retry_after_user_wake "" 10000

# --- Test 6: user opened lid but hasn't clicked yet (still idle) ---
# Expected: no retry (current idle > BACK threshold).
prev_hid_idle=3600
last_user_wake_reset_at=0
fail "lid opened but no click yet" should_retry_after_user_wake 30 10000

# --- Test 7: AWAY threshold is strict (>, not >=) ---
# Expected: prev=60 exactly should not trigger.
prev_hid_idle=60
last_user_wake_reset_at=0
fail "AWAY boundary exact (not yet)" should_retry_after_user_wake 2 10000
prev_hid_idle=61
pass "AWAY boundary +1" should_retry_after_user_wake 2 10000

# --- Test 8: BACK threshold is strict (<, not <=) ---
# Expected: current=10 exactly should not trigger.
prev_hid_idle=3600
last_user_wake_reset_at=0
fail "BACK boundary exact (not yet)" should_retry_after_user_wake 10 10000
pass "BACK boundary -1" should_retry_after_user_wake 9 10000

# --- Test 9: first-ever wake (last_user_wake_reset_at=0) ---
# Expected: cooldown treats 0 as "never reset" and allows retry as long as
# now_poll > USER_WAKE_RESET_COOLDOWN.
prev_hid_idle=3600
last_user_wake_reset_at=0
pass "first reset from zero" should_retry_after_user_wake 2 601

print -- ""
if (( failures > 0 )); then
    print -- "$failures test(s) FAILED"
    exit 1
fi
print -- "All tests PASSED"
