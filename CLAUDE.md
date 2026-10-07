# VANISH

Operational-security helper for Kali Linux. A single Bash script that hardens
network privacy on demand: routes **all** traffic through Tor (transparent,
system-wide), spoofs MAC addresses, locks down DNS, disables leaky services,
and cleans up — with persistent backups and automatic restoration on exit.

**Authorized/defensive use only** (personal privacy, pentest engagements, CTFs).
It is not a tool for evading detection during unauthorized activity.

## Layout

| Path | Purpose |
|------|---------|
| `vanish.sh` | The entire tool (~1050 lines, single Bash file). |
| `README.md` | User-facing docs. Keep in sync with `vanish.sh` behavior. |
| `TESTING.md` | VM test checklist — run changes here before a real machine. |
| `.profiles/` | Saved user configs (git-ignored). |
| `~/.vanish/` | Runtime home: `backups/`, `vanish.log`, `.pid`, `.recovery` (outside the repo). |

## Running it

Always as root. Press **Ctrl+C** at any time to trigger restore.

```bash
sudo ./vanish.sh                 # interactive menu (default)
sudo ./vanish.sh --quick         # full vanish, defaults, no prompts
sudo ./vanish.sh --profile NAME  # load a saved profile
sudo ./vanish.sh --dry-run       # resolve + print config, change nothing
sudo ./vanish.sh --socks-only    # per-command Tor instead of system-wide
sudo ./vanish.sh --wipe-tmp      # also delete /tmp + /var/tmp (destructive)
sudo ./vanish.sh --force         # skip destructive-action confirmations
```

## How it works (key internals)

- `main` → `parse_args` → mode dispatch (`main_menu` / quick / profile). Entry at bottom of file.
- `check_root` gates everything; `check_recovery` offers to restore an interrupted prior run from `~/.vanish/.recovery`.
- A `trap cleanup_on_exit INT TERM` ensures the original config is restored on Ctrl+C / kill. `restore_config` reverses every applied change from the backup.
- Feature flags (`FEATURE_*`) and Tor settings are declared at the top of the script; the interactive menu toggles them.
- **Transparent Tor** (`TOR_TRANSPARENT=true`, default): iptables redirects all TCP to `TOR_TRANS_PORT` (9040) and DNS to `TOR_DNS_PORT` (5353), with a default-DROP OUTPUT policy so nothing leaks. Tor runs as system user `debian-tor`. `--socks-only` opts out to proxychains/torsocks on `TOR_SOCKS_PORT` (9050).
- `NON_TOR_NETS` keeps loopback + RFC1918 (LAN) reachable.
- MAC spoofing detects and **skips the interface carrying the active SSH session** so it won't strand a remote login.

## Working on this code — conventions

- **Fail-closed is the whole point.** Any change to the Tor/iptables path must keep the invariant: if Tor is down, traffic is *blocked*, never sent in the clear. Don't add a rule that could leak on error.
- **Everything reversible.** Any new system change must be backed up before applying and undone in `restore_config`. Nothing should survive a clean exit.
- **Destructive actions stay guarded.** Log/temp wipes require explicit confirmation unless `--force`; keep them opt-in.
- Script uses `set -euo pipefail` — preserve it; quote expansions.
- Test with `--dry-run` first, then in a VM per `TESTING.md`. Never test destructive paths on this host.
- When you change flags, modes, or behavior, **update `README.md` and `usage()` together** — they're expected to match.
- Backups and logs live in `~/.vanish/`, never `/tmp`.

## Environment

- Target OS: **Kali / Debian** (uses `debian-tor` user, `systemctl`, `macchanger`, `iptables`).
- Originally developed on macOS, now run on this Linux host — watch for GNU vs BSD tool differences if porting snippets.
