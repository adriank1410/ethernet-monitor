# ethernet-monitor

Auto-recovery LaunchDaemon for USB Ethernet adapters on macOS.

Works with any USB Ethernet adapter that appears as a standard network interface **after configuring `IFACE`/`SERVICE` in `ethernet-monitor.sh`**. Created to solve random link drops on Realtek RTL8153 (common in USB-C docks/adapters), but compatible with any chipset — it monitors the interface, not the driver.

## Problem

MacBook + USB-C adapter with Ethernet — the link randomly drops while the adapter stays connected. The only fix is unplugging and replugging the adapter.

## What this does

A lightweight daemon (~1.5 MB RAM, 0% CPU) that polls the `en6` interface every 3 seconds and:

1. **Detects link drops** — adapter present but no Ethernet link (including intentional cable unplugs — the daemon assumes the cable should always be connected; it gives up after 2 failed recovery attempts)
2. **Waits 10s for self-heal** — transient blips resolve themselves
3. **Escalating recovery** — `ifconfig down/up`, then `networksetup` service toggle
4. **Gives up after 2 failures** — no notification spam, resets on adapter replug
5. **Detects sleep/wake** — waits for link negotiation instead of false-alarming
6. **macOS notifications** with sounds — localized to Polish or English based on system language

### Notifications

| Event | English | Polski | Sound |
|---|---|---|---|
| Link dropped | Ethernet link dropped — attempting auto-recovery... | Ethernet link padł — czekam na auto-recovery... | Purr |
| Self-healed | Ethernet recovered on its own | Ethernet wrócił sam | Glass |
| Recovery worked | Ethernet restored (ifconfig reset) | Ethernet wrócił (ifconfig reset) | Glass |
| Recovery failed | Ethernet not restored — replug the adapter | Ethernet nie wrócił — wyjmij i włóż przejściówkę | Basso |
| Link up after replug/wake | Ethernet connected | Ethernet podłączony | Glass |
| Adapter unplugged | *(silent)* | *(silent)* | — |
| System boot | *(silent)* | *(silent)* | — |

Language is auto-detected from the console user's system preferences. To force a language, set `ETHMON_LANG` in the plist (see [Configuration](#configuration)).

## Install

```bash
git clone https://github.com/adriank1410/ethernet-monitor.git
cd ethernet-monitor
sudo ./install.sh
```

## Uninstall

```bash
sudo ./uninstall.sh
```

## Usage

```bash
# Watch live log
tail -f /var/log/ethernet-monitor.log

# Check daemon status
sudo launchctl print system/com.local.ethernet-monitor

# Restart daemon after editing
sudo ./install.sh
```

## Configuration

Edit `ethernet-monitor.sh` — constants at the top:

| Variable | Default | Description |
|---|---|---|
| `IFACE` | `en6` | Network interface name |
| `SERVICE` | `USB 10/100/1000 LAN` | networksetup service name |
| `CHECK_INTERVAL` | `3` | Seconds between polls |
| `SELF_HEAL_WAIT` | `10` | Seconds to wait before recovery |
| `RECOVERY_COOLDOWN` | `30` | Min seconds between recovery attempts |
| `MAX_RECOVERY_ATTEMPTS` | `2` | Give up after N failed recoveries |
| `WAKE_THRESHOLD` | `60` | Time gap (s) that indicates system sleep |
| `BOOT_GRACE` | `120` | Suppress first notification if adapter never seen and uptime < this |

### Force notification language

By default, the daemon reads the console user's system language. To override, add an `EnvironmentVariables` key to the plist:

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>ETHMON_LANG</key>
    <string>en</string>  <!-- or "pl" -->
</dict>
```

Then reinstall with `sudo ./install.sh`.

## Files

| File | Installed to |
|---|---|
| `ethernet-monitor.sh` | `/Library/PrivilegedHelperTools/ethernet-monitor` |
| `com.local.ethernet-monitor.plist` | `/Library/LaunchDaemons/` |
| `com.local.ethernet-monitor.newsyslog.conf` | `/etc/newsyslog.d/com.local.ethernet-monitor.conf` |

The script is installed to `/Library/PrivilegedHelperTools/` (root-only, not user-writable) to prevent local privilege escalation.

Logs:
- `/var/log/ethernet-monitor.log` — main log (auto-rotated at 1 MB by the daemon)
- `/var/log/ethernet-monitor.err` — stderr (rotated by newsyslog at 1 MB, 1 backup)

## License

[MIT](LICENSE)
