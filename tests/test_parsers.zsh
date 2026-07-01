#!/usr/bin/env zsh
#
# Unit tests for lightweight parsers used around expensive macOS commands.
#
# Run: zsh tests/test_parsers.zsh

set -e

script_dir=${0:A:h}
repo_root=${script_dir:h}
tmp_log=$(mktemp -t ethmon-parser.XXXXXX)
trap 'rm -f "$tmp_log"' EXIT

ETHMON_NO_MAIN=1 ETHMON_LOG="$tmp_log" source "$repo_root/ethernet-monitor.sh"
unsetopt nounset

failures=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        print -- "PASS  $name"
    else
        print -- "FAIL  $name — expected '$expected', got '$actual'"
        (( ++failures ))
    fi
}

assert_fails() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        print -- "FAIL  $name — expected failure"
        (( ++failures ))
    else
        print -- "PASS  $name"
    fi
}

display_compact='+-o IODisplayWrangler
    {
      "IOPowerManagement" = {"CurrentPowerState"=4}
    }'

display_spaced='+-o IODisplayWrangler
    {
      "CurrentPowerState" = 3
    }'

hid_sample='+-o IOHIDSystem
    {
      "HIDIdleTime" = 25000000000
    }'

console_sample='
  Name : adrian
  UID : 501
  CGSSessionUniqueSessionUUID : skipped
'

languages_sample='(
    "pl-PL",
    "en-US"
)'

boottime_sample='{ sec = 1782920000, usec = 123456 } Mon Jul  1 17:33:20 2026'

assert_eq "display power parser accepts compact ioreg dictionaries" \
    "4" "$(_extract_ioreg_int_property "$display_compact" "CurrentPowerState")"
assert_eq "display power parser accepts spaced ioreg dictionaries" \
    "3" "$(_extract_ioreg_int_property "$display_spaced" "CurrentPowerState")"
assert_eq "hid parser converts nanoseconds to seconds" \
    "25" "$(_extract_hid_idle_seconds "$hid_sample")"
assert_eq "console uid parser skips session uuid and returns UID" \
    "501" "$(_extract_console_uid "$console_sample")"
assert_eq "language parser returns first AppleLanguages entry" \
    "pl-PL" "$(_first_apple_language "$languages_sample")"
assert_eq "boot parser extracts kern.boottime seconds" \
    "1782920000" "$(_extract_boot_sec "$boottime_sample")"
assert_fails "missing property fails clearly" \
    _extract_ioreg_int_property "$display_compact" "NoSuchProperty"

print -- ""
if (( failures > 0 )); then
    print -- "$failures test(s) FAILED"
    exit 1
fi
print -- "All parser tests PASSED"
