                 # VANISH

**Leave No Trace. Become Invisible.**

A comprehensive Bash script that hardens the network privacy of your Kali machine when online: it can route **all** traffic through Tor (transparent, system-wide), spoof MAC addresses, lock down DNS, disable leaky services, and clean up — with persistent backups and automatic restoration on exit.

```

▄▄▄▄  ▄▄▄▄   ▄▄▄▄   ▄▄▄    ▄▄▄ ▄▄▄▄▄  ▄▄▄▄▄▄▄ ▄▄▄   ▄▄▄ 
▀███  ███▀ ▄██▀▀██▄ ████▄  ███  ███  █████▀▀▀ ███   ███ 
 ███  ███  ███  ███ ███▀██▄███  ███   ▀████▄  █████████ 
 ███▄▄███  ███▀▀███ ███  ▀████  ███     ▀████ ███▀▀▀███ 
  ▀████▀   ███  ███ ███    ███ ▄███▄ ███████▀ ███   ███ 

```

## Quick Start

```bash
# Interactive menu
sudo ~/Projects/vanish/vanish.sh

# Quick mode (no prompts, full setup, safe defaults)
sudo ~/Projects/vanish/vanish.sh --quick

# Load saved profile
sudo ~/Projects/vanish/vanish.sh --profile my-profile
```

**Press Ctrl+C** at any time to restore the original configuration.

## What VANISH Does

### Core Features
1. **Transparent Tor Routing** — routes **all** outbound traffic through Tor system-wide (not just per-command), with leak protection
2. **MAC Address Spoofing** — randomizes network MAC addresses (won't strand your SSH session)
3. **DNS Privacy** — routes DNS through Tor (transparent mode) or a privacy-focused resolver
4. **IPv6 Disabling** — eliminates an IPv6 leak/fingerprinting vector
5. **Service Disabling** — stops leaky services (Bluetooth, Avahi, CUPS, etc.)
6. **Log Clearing** — erases shell history and truncates system logs (guarded, opt-in)
7. **Connection Tracking** — flushes netfilter conntrack tables
8. **Firewall Rules** — privacy-first iptables configuration

### Highlights
- **System-wide Tor** — everything exits through Tor; no need for `proxychains`/`torsocks`
- **Leak-proof** — default-DROP OUTPUT policy blocks any traffic trying to bypass Tor
- **Fail-closed** — if Tor isn't up, traffic is blocked rather than leaked in the clear
- **Safe MAC spoofing** — detects and skips the interface carrying your SSH session; waits for the link to recover
- **Guarded destructive actions** — irreversible wipes require explicit confirmation
- **Persistent backups** — saved to `~/.vanish/` (not `/tmp`)
- **Automatic recovery** — detects incomplete sessions and offers to restore
- **Profile management** — save configs for reuse

## Modes

### 1. Interactive Mode (Default)
```bash
sudo ~/Projects/vanish/vanish.sh
```
Banner + main menu: configure features one by one, choose DNS provider, select services, pick interfaces, **choose the Tor routing mode (transparent vs. SOCKS-only)**, set the SOCKS port, and optionally save a profile.

### 2. Quick Mode
```bash
sudo ~/Projects/vanish/vanish.sh --quick
```
Full vanish with all defaults, no interaction. For safety, quick mode **skips irreversible wipes** (log/temp clearing) unless you also pass `--force`.

### 3. Profile Mode
```bash
sudo ~/Projects/vanish/vanish.sh --profile pentest
```
Load a saved profile, review the config, confirm, then run.

## Tor: Transparent vs. SOCKS-only

**Transparent (default)** — VANISH configures Tor with a `TransPort` and `DNSPort`, then uses the iptables **nat** table to redirect *all* outbound TCP and *all* DNS through Tor. The **filter** table is set to default-DROP on OUTPUT, allowing only Tor's own daemon, loopback, and LAN — so nothing can leak around Tor.

- All apps are anonymized automatically; no wrappers needed.
- LAN (RFC1918) and localhost stay reachable.
- `.onion` addresses resolve via Tor's `AutomapHostsOnResolve`.

**SOCKS-only** — opt out of system-wide routing with the `--socks-only` flag, or by choosing it in interactive mode's Tor Configuration prompt. Tor only opens a SOCKS port, and you anonymize individual commands yourself:
```bash
proxychains4 curl https://ifconfig.me
torsocks ssh user@host
```

## Command-line Flags

```bash
sudo vanish.sh                 # interactive menu
sudo vanish.sh --quick         # full vanish, defaults, no prompts
sudo vanish.sh --profile NAME  # load a saved profile
sudo vanish.sh --dry-run       # show resolved config, change nothing
sudo vanish.sh --socks-only    # per-command Tor instead of system-wide
sudo vanish.sh --wipe-tmp      # also delete /tmp and /var/tmp (destructive)
sudo vanish.sh --force         # skip destructive-action confirmations
sudo vanish.sh --help          # show help
```

## How It Works

### Startup
1. Shows the banner
2. Checks for an incomplete prior session (recovery mode)
3. Presents the interactive menu (or applies quick/profile mode)
4. Creates a persistent backup in `~/.vanish/backups/`
5. Applies the enabled modules
6. Shows status and stays resident

### Exit (Ctrl+C)
1. Flushes Tor routing and **reopens the OUTPUT policy first** (so a failed restore can't lock you out)
2. Restores DNS, torrc, IPv6, services, and firewall from backup
3. Removes recovery state and confirms restoration

## DNS Providers (SOCKS-only mode)

In transparent mode DNS always goes through Tor. In `--socks-only` mode you can pick a resolver:

```
1) Cloudflare (1.1.1.1)   - Fast, global
2) Quad9 (9.9.9.9)        - Privacy-focused, blocks malware
3) AdGuard (94.140.14.14) - Ad & tracker blocking
4) Mullvad (194.242.2.2)  - Privacy-first, no logging
5) NextDNS (45.90.28.0)   - Customizable filtering
```

## MAC Spoofing Behavior

- Spoofs all non-loopback interfaces (or a list you specify).
- **Skips the interface carrying your SSH session** (detected via `SSH_CONNECTION`) so you aren't disconnected.
- Uses `macchanger` when installed, otherwise `ip link`.
- Reassociates NetworkManager-managed interfaces and **waits up to 20s** for the link and IP to return, warning if they don't.

## Destructive Actions (Guarded)

Log clearing is **irreversible and not covered by backup/restore**, so it is gated:

- Clearing shell history + truncating `auth.log`/`syslog`/`wtmp`/`btmp` and vacuuming the journal requires typing `yes` to confirm.
- Deleting `/tmp` and `/var/tmp` is **off by default** — enable with `--wipe-tmp` (it gets its own extra confirmation, since it can crash apps relying on those paths).
- `--force` skips the prompts. `--quick` without `--force` **skips** these wipes entirely.

## Profiles

### Save
After interactive configuration, choose to save; give it a name.

### List / Load
```bash
ls ~/Projects/vanish/.profiles/
sudo ~/Projects/vanish/vanish.sh --profile my-config
```

### Edit
```bash
nano ~/Projects/vanish/.profiles/my-config.conf
```

Profile format:
```bash
FEATURE_MAC_SPOOF=true
FEATURE_DNS_PRIVACY=true
FEATURE_TOR=true
TOR_TRANSPARENT=true
DNS_PROVIDER="cloudflare"
TOR_SOCKS_PORT=9050
TOR_TRANS_PORT=9040
TOR_DNS_PORT=5353
SERVICES_TO_DISABLE=("cups" "avahi-daemon" "bluetooth")
INTERFACES_TO_SPOOF=""   # empty = all
```

## Testing Anonymity

After vanishing (transparent mode):

```bash
# Confirm your exit is a Tor node (no proxychains needed)
curl https://check.torproject.org/api/ip
# -> {"IsTor":true, ...}

# Check exit IP
curl https://icanhazip.com

# Check MAC spoofing
ip link show

# Current network state
ip addr show
```

In `--socks-only` mode, prefix commands with `proxychains4` / `torsocks` instead.

## Requirements

**Essential:**
- root access (sudo)
- iproute2 (`ip`)
- iptables (with `xt_owner` for `--uid-owner` matching — standard on Kali)
- openssl (MAC generation fallback)
- tor
- bash 4+

**Recommended:**
```bash
sudo apt install tor macchanger proxychains4 torsocks curl
```

## Configuration & Logs

```bash
cat ~/.vanish/vanish.log        # activity log
ls ~/.vanish/backups/           # persistent backups
cat ~/.vanish/.recovery         # recovery metadata
```

## Recovery Mode

If a session crashes or doesn't restore properly, the next startup detects it:

```
Recovery Detected
Attempt recovery? (y/n) y
✓ Recovery completed
```

Recovery restores DNS, re-enables IPv6, restarts services, flushes Tor routing, reopens the firewall, and cleans up.

## Troubleshooting

### No network after starting (transparent Tor)
This is expected if Tor hasn't bootstrapped — routing is **fail-closed**. Check Tor:
```bash
sudo systemctl status tor
sudo journalctl -u tor -f
```
If it won't recover, press Ctrl+C to restore, or manually reopen:
```bash
sudo iptables -t nat -F
sudo iptables -F OUTPUT
sudo iptables -P OUTPUT ACCEPT
```

### Tor won't connect
```bash
sudo systemctl restart tor
sudo journalctl -u tor -f
```

### DNS not resolving
In transparent mode `/etc/resolv.conf` is set to `127.0.0.1` (DNS is redirected to Tor). NetworkManager/DHCP may overwrite it — re-run, or restore:
```bash
sudo cp /etc/resolv.conf.orig /etc/resolv.conf
```

### MAC change dropped my connection
The active SSH interface is skipped automatically. For local (non-SSH) interfaces, wait up to ~20s for reassociation, or `sudo nmcli device reconnect <iface>`.

### Firewall locked me out
```bash
sudo iptables -t nat -F
sudo iptables -F OUTPUT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -P INPUT ACCEPT
```

## ⚠️ Testing Advice

`bash -n` only validates syntax. The iptables / MAC / Tor behavior must be validated **running as root**, ideally **in a VM snapshot** — a bad rule set combined with a remote session can lock you out. The SSH-skip logic mitigates this, but test in a disposable environment first.

## Legal Notice

VANISH is for authorized use only:
- ✅ Authorized penetration testing
- ✅ Security research on your own systems
- ✅ CTF competitions
- ✅ Privacy protection during legitimate work

Do not use it for unauthorized access, evading law enforcement, or any unlawful purpose. You are responsible for your actions.

## File Structure

```
vanish/
├── vanish.sh              # main script
├── README.md              # this file
└── .profiles/             # saved profiles

~/.vanish/                 # user data
├── vanish.log             # activity log
├── .recovery              # recovery metadata
└── backups/               # persistent backups
```

---

🖤⚫ Leave No Trace. Become Invisible. ⚫🖤
