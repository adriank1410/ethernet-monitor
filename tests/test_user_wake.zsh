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
        (( ++failures ))
    fi
}
fail() {
    local name="$1"; shift
    if "$@"; then
        print -- "FAIL  $name (expected failure, got success)"
        (( ++failures ))
    else
        print -- "PASS  $name"
    fi
}

# Constants come from the sourced script (readonly, can't be overridden):
#   HID_IDLE_AWAY_THRESHOLD=60
#   HID_IDLE_BACK_THRESHOLD=10
#   USER_WAKE_RESET_COOLDOWN=600
# Tests below are written against those exact values.

# Each numbered test below runs a single assertion. Nineteen tests total,
# matching the count in the PR description.

# --- Test 1: user was idle for an hour, just clicked a key ---
# Expected: retry fires.
prev_hid_idle=3600
last_user_wake_reset_at=0
pass "1. user returned from long idle" should_retry_after_user_wake 2 10000

# --- Test 2: user pressing keys non-stop, link just happened to fail ---
# Expected: no retry (prev never exceeded AWAY threshold).
prev_hid_idle=2
last_user_wake_reset_at=0
fail "2. user continuously active" should_retry_after_user_wake 1 10000

# --- Test 3: genuine return but cooldown still active ---
# Expected: no retry (cooldown not elapsed).
prev_hid_idle=3600
last_user_wake_reset_at=9500   # 500s before now, cooldown is 600s
fail "3. cooldown blocks repeat" should_retry_after_user_wake 2 10000

# --- Test 4: cooldown exact boundary (edge: > not >=) ---
# Expected: retry does NOT fire at exactly 600s elapsed.
prev_hid_idle=3600
last_user_wake_reset_at=9400   # exactly 600s before now
fail "4. cooldown exact boundary (not yet)" should_retry_after_user_wake 2 10000

# --- Test 5: cooldown just elapsed ---
# Expected: retry fires at 601s.
prev_hid_idle=3600
last_user_wake_reset_at=9399   # 601s before now
pass "5. cooldown just elapsed" should_retry_after_user_wake 2 10000

# --- Test 6: empty HID idle (ioreg failed) ---
# Expected: no retry (caller must treat unknown as "don't act").
prev_hid_idle=3600
last_user_wake_reset_at=0
fail "6. empty hid_idle yields no retry" should_retry_after_user_wake "" 10000

# --- Test 7: user opened lid but hasn't clicked yet (still idle) ---
# Expected: no retry (current idle > BACK threshold).
prev_hid_idle=3600
last_user_wake_reset_at=0
fail "7. lid opened but no click yet" should_retry_after_user_wake 30 10000

# --- Test 8: AWAY threshold is strict (>, not >=) ---
# Expected: prev=60 exactly should not trigger.
prev_hid_idle=60
last_user_wake_reset_at=0
fail "8. AWAY boundary exact (not yet)" should_retry_after_user_wake 2 10000

# --- Test 9: AWAY threshold one past boundary ---
# Expected: prev=61 does trigger.
prev_hid_idle=61
last_user_wake_reset_at=0
pass "9. AWAY boundary +1" should_retry_after_user_wake 2 10000

# --- Test 10: BACK threshold is strict (<, not <=) ---
# Expected: current=10 exactly should not trigger.
prev_hid_idle=3600
last_user_wake_reset_at=0
fail "10. BACK boundary exact (not yet)" should_retry_after_user_wake 10 10000

# --- Test 11: BACK threshold one below boundary ---
# Expected: current=9 does trigger.
prev_hid_idle=3600
last_user_wake_reset_at=0
pass "11. BACK boundary -1" should_retry_after_user_wake 9 10000

# --- Test 12: first-ever reset (last_user_wake_reset_at=0) ---
# Expected: cooldown treats 0 as "never reset" and allows retry as long as
# now_poll > USER_WAKE_RESET_COOLDOWN.
prev_hid_idle=3600
last_user_wake_reset_at=0
pass "12. first reset from zero" should_retry_after_user_wake 2 601

# --- Test 13: prev_hid_idle=0 after GAVE UP reset prevents false trigger ---
# If prev_hid_idle is properly reset to 0 on entering gave-up, a user who was
# active the whole time (current idle=1) should NOT trigger — because prev (0)
# is not > AWAY (60). Without the reset, a stale prev from a prior gave-up
# session could cause a false positive.
prev_hid_idle=0
last_user_wake_reset_at=0
fail "13. fresh gave-up with reset prev=0" should_retry_after_user_wake 1 10000

# --- Test 14: HID event between polls (cur_idle >= BACK, but < poll delta) ---
# Scenario from the HID-throttling incident: poll at t=9970 saw user away
# (prev=3600), user clicked at t=9975, went idle. At t=10000 the next poll sees
# cur_idle=25 — above BACK threshold (10), but below the 30s poll delta. The
# old single-check (cur_idle < BACK) missed this; the since-poll path catches
# it. Expected: retry fires.
prev_hid_idle=3600
last_user_wake_reset_at=0
pass "14. activity since previous poll triggers retry" \
    should_retry_after_user_wake 25 10000 9970

# --- Test 15: since-poll boundary is strict (<, not <=) ---
# Activity exactly at prev_poll_at means HIDIdleTime == poll delta — not newer.
# Expected: no retry (without this, we'd retrigger on stale timing).
prev_hid_idle=3600
last_user_wake_reset_at=0
fail "15. since-poll boundary exact (not yet)" \
    should_retry_after_user_wake 30 10000 9970

# --- Test 16: since-poll trigger still respects cooldown ---
# Even with fresh activity since the last poll, USER_WAKE_RESET_COOLDOWN blocks
# retries within 600s of the previous one.
prev_hid_idle=3600
last_user_wake_reset_at=9500   # 500s ago, cooldown is 600s
fail "16. since-poll respects cooldown" \
    should_retry_after_user_wake 25 10000 9970

# --- Test 17: since-poll trigger still requires AWAY state ---
# If prev_hid_idle never crossed AWAY (user was continuously active), a fresh
# HID event between polls should not count as "returning".
prev_hid_idle=2
last_user_wake_reset_at=0
fail "17. since-poll requires prev AWAY" \
    should_retry_after_user_wake 25 10000 9970

# --- Test 18: prev_poll_at=0 disables the since-poll check ---
# First-ever poll in gave-up state has no prior timestamp. Passing 0 must not
# spuriously trigger — we must still see cur_idle < BACK.
prev_hid_idle=3600
last_user_wake_reset_at=0
fail "18. prev_poll_at=0 disables since-poll path" \
    should_retry_after_user_wake 25 10000 0

# --- Test 19: regression — the exact missed-wake scenario from review ---
# Reviewer's trace: poll at t=1000 (user away, idle=65), user activity at
# t=1005, next poll at t=1030 with idle=25 and prev_hid_idle=65. Before the
# fix, recovery_failures stayed at 2 because idle=25 failed the BACK check and
# prev kept drifting upward. Expected: retry fires via since-poll path.
prev_hid_idle=65
last_user_wake_reset_at=0
pass "19. reviewer's missed-wake trace now triggers" \
    should_retry_after_user_wake 25 1030 1000

print -- ""
if (( failures > 0 )); then
    print -- "$failures test(s) FAILED"
    exit 1
fi
print -- "All tests PASSED"
