#!/bin/zsh
#
# Uninstall ethernet-monitor.
# Usage: sudo ./uninstall.sh

set -euo pipefail

DEST_BIN="/usr/local/bin/ethernet-monitor"
DEST_PLIST="/Library/LaunchDaemons/com.local.ethernet-monitor.plist"
LABEL="com.local.ethernet-monitor"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./uninstall.sh"
    exit 1
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "$DEST_BIN" "$DEST_PLIST"

echo "Uninstalled. Log files remain in /var/log/ethernet-monitor.*"
