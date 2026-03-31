#!/bin/zsh
#
# Install ethernet-monitor as a LaunchDaemon.
# Usage: sudo ./install.sh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DEST_BIN="/Library/PrivilegedHelperTools/ethernet-monitor"
OLD_BIN="/usr/local/bin/ethernet-monitor"
DEST_PLIST="/Library/LaunchDaemons/com.local.ethernet-monitor.plist"
DEST_NEWSYSLOG="/etc/newsyslog.d/com.local.ethernet-monitor.conf"
LABEL="com.local.ethernet-monitor"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./install.sh"
    exit 1
fi

# Stop existing daemon if running (try both APIs independently)
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl unload "$DEST_PLIST" 2>/dev/null || true

# Clean up old install location if present
if [[ -f "$OLD_BIN" ]]; then
    rm -f "$OLD_BIN"
fi

# Ensure target directories exist
mkdir -p "$(dirname "$DEST_BIN")" "$(dirname "$DEST_NEWSYSLOG")"

# Install to root-only directory (not user-writable /usr/local/bin)
cp "$SCRIPT_DIR/ethernet-monitor.sh" "$DEST_BIN"
chown root:wheel "$DEST_BIN"
chmod 755 "$DEST_BIN"
cp "$SCRIPT_DIR/com.local.ethernet-monitor.plist" "$DEST_PLIST"
chown root:wheel "$DEST_PLIST"
chmod 644 "$DEST_PLIST"
cp "$SCRIPT_DIR/com.local.ethernet-monitor.newsyslog.conf" "$DEST_NEWSYSLOG"
chown root:wheel "$DEST_NEWSYSLOG"
chmod 644 "$DEST_NEWSYSLOG"

# Start daemon (try modern API first, fall back to legacy)
bootstrap_err=""
load_err=""
if ! bootstrap_err=$(launchctl bootstrap system "$DEST_PLIST" 2>&1); then
    if ! load_err=$(launchctl load "$DEST_PLIST" 2>&1); then
        echo "WARNING: launchctl bootstrap failed: $bootstrap_err"
        echo "WARNING: launchctl load failed: $load_err"
    fi
fi

# Verify — check that the daemon is actually running (not just registered)
sleep 2
# Try modern API first, fall back to legacy for older macOS
daemon_pid=$( (launchctl print "system/$LABEL" 2>/dev/null || true) | awk '/pid =/ { print $3 }')
if [[ -z "$daemon_pid" || "$daemon_pid" == "0" ]]; then
    # Fallback: launchctl list LABEL returns a dict with "PID" = NNN;
    daemon_pid=$( (launchctl list "$LABEL" 2>/dev/null || true) | sed -n 's/.*"PID" = \([0-9]*\).*/\1/p')
fi
if [[ -n "$daemon_pid" && "$daemon_pid" != "0" && "$daemon_pid" != "-" ]]; then
    echo "Installed and started (PID $daemon_pid)."
    echo "  Script: $DEST_BIN"
    echo "  Plist:  $DEST_PLIST"
    echo "  Log:    /var/log/ethernet-monitor.log"
    echo ""
    echo "Commands:"
    echo "  tail -f /var/log/ethernet-monitor.log   # watch log"
    echo "  sudo ./uninstall.sh                     # remove"
else
    echo "WARNING: Daemon failed to start."
    echo "  Debug: sudo launchctl print system/$LABEL"
    echo "  Legacy: sudo launchctl list | grep $LABEL"
    exit 1
fi
