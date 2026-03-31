#!/bin/zsh
#
# Install ethernet-monitor as a LaunchDaemon.
# Usage: sudo ./install.sh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DEST_BIN="/usr/local/bin/ethernet-monitor"
DEST_PLIST="/Library/LaunchDaemons/com.local.ethernet-monitor.plist"
LABEL="com.local.ethernet-monitor"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./install.sh"
    exit 1
fi

# Stop existing daemon if running (try both APIs)
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl unload "$DEST_PLIST" 2>/dev/null || true

# Install files
cp "$SCRIPT_DIR/ethernet-monitor.sh" "$DEST_BIN"
chmod +x "$DEST_BIN"
cp "$SCRIPT_DIR/com.local.ethernet-monitor.plist" "$DEST_PLIST"
chmod 644 "$DEST_PLIST"
chown root:wheel "$DEST_PLIST"

# Start daemon (try modern API first, fall back to legacy)
bootstrap_err=""
load_err=""
if ! bootstrap_err=$(launchctl bootstrap system "$DEST_PLIST" 2>&1); then
    if ! load_err=$(launchctl load "$DEST_PLIST" 2>&1); then
        echo "WARNING: launchctl bootstrap failed: $bootstrap_err"
        echo "WARNING: launchctl load failed: $load_err"
    fi
fi

# Verify
sleep 2
if launchctl print "system/$LABEL" >/dev/null 2>&1 || launchctl list "$LABEL" >/dev/null 2>&1; then
    echo "Installed and started."
    echo "  Script: $DEST_BIN"
    echo "  Plist:  $DEST_PLIST"
    echo "  Log:    /var/log/ethernet-monitor.log"
    echo ""
    echo "Commands:"
    echo "  tail -f /var/log/ethernet-monitor.log   # watch log"
    echo "  sudo ./uninstall.sh                     # remove"
else
    echo "WARNING: Daemon failed to start. Check: sudo launchctl list $LABEL"
    exit 1
fi
