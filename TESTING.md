# VANISH — VM Test Checklist

Validate `vanish.sh` end-to-end in a disposable VM before ever running it on a
machine you care about. The script switches Tor to **fail-closed** and rewrites
iptables, so a bad run can cut all network access — a VM snapshot makes that a
non-event.

Work top to bottom. Each step says **what to do**, **what you should see**, and
**how to bail out**.

---

## 0. Build the test VM

- [ ] Fresh Kali VM (VirtualBox/VMware/QEMU), updated: `sudo apt update && sudo apt full-upgrade`
- [ ] Install deps: `sudo apt install tor macchanger proxychains4 torsocks curl`
- [ ] Confirm Tor runs at all: `sudo systemctl start tor && systemctl is-active tor`
- [ ] Copy the `vanish/` folder into the VM (shared folder, `scp`, or git)
- [ ] **Use the VM console, NOT SSH, for the first run.** If Tor misbehaves, SSH may drop and you'll want console access. (The SSH-skip logic protects the MAC step, but fail-closed Tor can still cut an SSH session.)

### Snapshot
- [ ] Take a snapshot named **`clean`** while networking works and before any run.
- [ ] Know how to restore it. This is your undo button for every test below.

### Baseline (record "normal" so you can compare later)
```bash
ip -br addr                              # interfaces + IPs
ip link show | grep link/ether          # current MACs
curl -s https://icanhazip.com            # your REAL exit IP (write it down)
cat /etc/resolv.conf                     # current DNS
sudo iptables -S; sudo iptables -t nat -S
```
- [ ] Baseline captured.

---

## 1. Dry run (no changes)

```bash
sudo ./vanish.sh --dry-run
sudo ./vanish.sh --dry-run --socks-only
```
- [ ] Config table prints; "no changes were made".
- [ ] `--dry-run` shows **Tor Routing: TRANSPARENT (system-wide)**, ports `9040 / 5353`.
- [ ] `--socks-only` shows **Tor Routing: SOCKS-only (per-command)**.
- [ ] Afterward, `iptables -S` is unchanged from baseline (dry run really changed nothing).

---

## 2. First live run — transparent Tor (the big one)

Run from the **VM console**:
```bash
sudo ./vanish.sh --quick
```
Watch the module output. Expected highlights:
- [ ] Backup created under `~/.vanish/backups/backup-<timestamp>/`
- [ ] MAC addresses spoofed (or interface(s) skipped with a reason)
- [ ] "Transparent Tor enabled — firewall is managed by the Tor module"
- [ ] Tor bootstraps within ~60s: **"Tor circuit established"**
- [ ] **"Transparent Tor active — all traffic exits through Tor"**
- [ ] Status screen shows **Transparent Tor ON**; script stays resident

### Verify anonymity (in a second console, script still running)
```bash
curl -s https://check.torproject.org/api/ip      # -> {"IsTor":true,...}
curl -s https://icanhazip.com                     # must DIFFER from baseline IP
```
- [ ] `IsTor` is `true`
- [ ] Exit IP is **not** your baseline IP

### Leak checks (the part that actually matters)
```bash
# DNS must resolve through Tor, not your ISP:
nslookup example.com 2>&1 | head -5               # should use 127.0.0.1
cat /etc/resolv.conf                              # -> nameserver 127.0.0.1

# Raw IP connection that bypasses DNS should still be forced through Tor:
curl -s https://1.1.1.1 --max-time 15 >/dev/null && echo "TCP reachable (via Tor)"

# A non-Tor UDP path should be BLOCKED (leak protection), not silently sent:
# QUIC/UDP 443 to a public host should fail/timeout:
timeout 5 bash -c 'cat < /dev/null > /dev/udp/8.8.8.8/443' 2>&1 || echo "UDP blocked (good)"

# IPv6 should be down (no v6 leak):
ip -6 addr show | grep -q "inet6 .* scope global" && echo "WARN: global IPv6 present" || echo "No global IPv6 (good)"

# LAN still reachable (gateway ping), localhost still works:
ping -c1 -W2 "$(ip route | awk '/default/{print $3; exit}')" >/dev/null && echo "LAN ok"
```
- [ ] DNS goes to `127.0.0.1`
- [ ] Direct-IP TCP works (proves transparent redirect, not just DNS)
- [ ] Non-Tor UDP is blocked
- [ ] No global IPv6 address
- [ ] LAN gateway still reachable

### Restore
- [ ] Press **Ctrl+C** in the script console.
- [ ] See: OUTPUT policy reopened first, then DNS / torrc / IPv6 / services / firewall restored, then "You are visible again."
- [ ] Confirm the world is back to normal:
```bash
curl -s https://icanhazip.com      # == baseline IP again
cat /etc/resolv.conf               # back to original
sudo iptables -S | tail            # OUTPUT policy ACCEPT, no DROP/REJECT leftovers
sudo iptables -t nat -S            # nat OUTPUT flushed
ip -6 addr show                    # IPv6 back
systemctl is-active tor            # stopped (per restore)
```
- [ ] Everything matches baseline. **Restore snapshot `clean` before the next test** to guarantee a known start.

---

## 3. Failure & safety drills (do NOT skip these)

Restore the `clean` snapshot before each drill.

### 3a. Tor can't start → fail-closed, then clean recovery
```bash
sudo mv /usr/bin/tor /usr/bin/tor.bak      # simulate broken Tor
sudo ./vanish.sh --quick                   # should warn Tor not confirmed
```
- [ ] Script warns Tor didn't come up (routing may be fail-closed = no internet — expected)
- [ ] `curl https://icanhazip.com` times out (confirms it fails CLOSED, not leaking)
- [ ] **Ctrl+C restores** network fully
- [ ] `sudo mv /usr/bin/tor.bak /usr/bin/tor` to undo

### 3b. Lockout recovery by hand (practice the escape hatch)
While a transparent run is active, in another console pretend the script is gone:
```bash
sudo iptables -t nat -F
sudo iptables -F OUTPUT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -P INPUT ACCEPT
```
- [ ] Network returns. (This is the manual unlock from the README — know it by heart.)

### 3c. Crash recovery (incomplete session)
```bash
sudo ./vanish.sh --quick
# kill it hard instead of Ctrl+C:  sudo pkill -9 -f vanish.sh
sudo ./vanish.sh                 # next launch should offer "Recovery Detected"
```
- [ ] Recovery prompt appears; answering `y` restores DNS/IPv6/services/firewall
- [ ] `~/.vanish/.recovery` is removed afterward

### 3d. Destructive-wipe guards
```bash
sudo ./vanish.sh                 # interactive, pick custom/start, let it reach log clearing
```
- [ ] Log clearing asks you to type `yes` (not just y/n)
- [ ] Declining it logs "skipped" and continues
```bash
sudo ./vanish.sh --quick         # quick, no --force
```
- [ ] Quick mode **skips** the log wipe automatically (warns, does not prompt)
```bash
sudo ./vanish.sh --quick --force --wipe-tmp   # ONLY in the throwaway VM
```
- [ ] With `--force` the wipe runs unattended; `--wipe-tmp` clears /tmp (verify VM still usable, then restore snapshot)

---

## 4. MAC-spoof safety (if testing over SSH at all)

On a VM you can reach by SSH (optional, advanced):
```bash
ssh user@vm
sudo ./vanish.sh --quick
```
- [ ] Output shows the SSH-carrying interface is **skipped** with a warning
- [ ] Your SSH session stays alive
- [ ] Other (non-SSH) interfaces get new MACs and recover within ~20s

---

## 5. Profiles

```bash
sudo ./vanish.sh                 # custom config -> save as "test-profile"
sudo ./vanish.sh --dry-run --profile test-profile
sudo ./vanish.sh --profile test-profile
```
- [ ] Profile saved under `./.profiles/test-profile.conf`
- [ ] Dry run previews the saved settings
- [ ] Loading + confirming runs with those settings

---

## Sign-off

- [ ] Transparent Tor verified (IsTor true, IP changed, no DNS/UDP/IPv6 leaks)
- [ ] Clean restore verified (iptables, DNS, IPv6, services back to baseline)
- [ ] Fail-closed confirmed (broken Tor = no leak, not open internet)
- [ ] Manual unlock commands memorized
- [ ] Recovery mode works
- [ ] Destructive guards behave (prompt / quick-skip / force)
- [ ] MAC spoof doesn't strand the session

Only after all boxes are checked should you consider running it outside a VM —
and even then, make sure you have **console access** and the manual-unlock
commands on hand.
