#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VANISH_HOME="${HOME}/.vanish"
BACKUP_DIR="${VANISH_HOME}/backups/backup-$(date +%s)"
LOG_FILE="${VANISH_HOME}/vanish.log"
PID_FILE="${VANISH_HOME}/vanish.pid"
PROFILE_DIR="${SCRIPT_DIR}/.profiles"
RECOVERY_FILE="${VANISH_HOME}/.recovery"

# Create vanish home directory
mkdir -p "$VANISH_HOME/backups" "$PROFILE_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Default configuration
FEATURE_MAC_SPOOF=true
FEATURE_DNS_PRIVACY=true
FEATURE_IPV6_DISABLE=true
FEATURE_DISABLE_SERVICES=true
FEATURE_CLEAR_LOGS=true
FEATURE_CONNECTION_CLEANUP=true
FEATURE_FIREWALL_RULES=true
FEATURE_TOR=true

DNS_PROVIDER="cloudflare"
TOR_SOCKS_PORT=9050
TOR_ENABLED=true

# Transparent (system-wide) Tor routing
TOR_TRANSPARENT=true          # route ALL traffic through Tor, not just proxychains
TOR_TRANS_PORT=9040           # Tor TransPort for redirected TCP
TOR_DNS_PORT=5353             # Tor DNSPort for redirected DNS
TOR_USER="debian-tor"         # system user Tor runs as (Debian/Kali)

SERVICES_TO_DISABLE=("cups" "avahi-daemon" "bluetooth" "snapd" "systemd-resolved")
INTERFACES_TO_SPOOF=""
DRY_RUN=false

# Safety guards for destructive actions
FORCE=false                   # --force: skip destructive-action confirmations
WIPE_TMP=false                # --wipe-tmp: also rm -rf /tmp /var/tmp (off by default)

# RFC1918 / loopback ranges kept OFF Tor so LAN + localhost still work
NON_TOR_NETS=("127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "169.254.0.0/16")

show_banner() {
    clear
    cat << "EOF"

                                                        
▄▄▄▄  ▄▄▄▄   ▄▄▄▄   ▄▄▄    ▄▄▄ ▄▄▄▄▄  ▄▄▄▄▄▄▄ ▄▄▄   ▄▄▄ 
▀███  ███▀ ▄██▀▀██▄ ████▄  ███  ███  █████▀▀▀ ███   ███ 
 ███  ███  ███  ███ ███▀██▄███  ███   ▀████▄  █████████ 
 ███▄▄███  ███▀▀███ ███  ▀████  ███     ▀████ ███▀▀▀███ 
  ▀████▀   ███  ███ ███    ███ ▄███▄ ███████▀ ███   ███                                                         
                                                       
                    🕶️   OPERATIONAL SECURITY ASSISTANT  🕶️
                      Leave No Trace | Become Invisible

EOF
    echo ""
}

log() {
    echo -e "${BLUE}[vanish]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}✗${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

header() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Use: sudo $0"
        exit 1
    fi
}

check_recovery() {
    if [[ -f "$RECOVERY_FILE" ]]; then
        header "Recovery Detected"
        warn "A previous vanish session may not have completed restoration"

        read -p "Attempt recovery? (y/n) " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            source "$RECOVERY_FILE"
            restore_config
            rm "$RECOVERY_FILE"
            success "Recovery completed"
            exit 0
        fi
    fi
}

save_profile() {
    local profile_name="$1"
    local profile_file="${PROFILE_DIR}/${profile_name}.conf"

    cat > "$profile_file" <<PROFEOF
# Vanish Profile: $profile_name
# Created: $(date)

FEATURE_MAC_SPOOF=$FEATURE_MAC_SPOOF
FEATURE_DNS_PRIVACY=$FEATURE_DNS_PRIVACY
FEATURE_IPV6_DISABLE=$FEATURE_IPV6_DISABLE
FEATURE_DISABLE_SERVICES=$FEATURE_DISABLE_SERVICES
FEATURE_CLEAR_LOGS=$FEATURE_CLEAR_LOGS
FEATURE_CONNECTION_CLEANUP=$FEATURE_CONNECTION_CLEANUP
FEATURE_FIREWALL_RULES=$FEATURE_FIREWALL_RULES
FEATURE_TOR=$FEATURE_TOR

DNS_PROVIDER="$DNS_PROVIDER"
TOR_SOCKS_PORT=$TOR_SOCKS_PORT
TOR_ENABLED=$TOR_ENABLED
TOR_TRANSPARENT=$TOR_TRANSPARENT
TOR_TRANS_PORT=$TOR_TRANS_PORT
TOR_DNS_PORT=$TOR_DNS_PORT

SERVICES_TO_DISABLE=($(printf '%s ' "${SERVICES_TO_DISABLE[@]}"))
INTERFACES_TO_SPOOF="$INTERFACES_TO_SPOOF"
PROFEOF

    success "Profile saved: $profile_name"
}

load_profile() {
    local profile_name="$1"
    local profile_file="${PROFILE_DIR}/${profile_name}.conf"

    if [[ ! -f "$profile_file" ]]; then
        error "Profile not found: $profile_name"
        return 1
    fi

    source "$profile_file"
    success "Profile loaded: $profile_name"
}

list_profiles() {
    if [[ ! -d "$PROFILE_DIR" ]] || [[ -z "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ]]; then
        info "No saved profiles yet"
        return 0
    fi

    echo -e "${CYAN}Available profiles:${NC}"
    for profile in "$PROFILE_DIR"/*.conf; do
        if [[ -f "$profile" ]]; then
            local name=$(basename "$profile" .conf)
            echo "  • $name"
        fi
    done
}

show_config() {
    header "Current Configuration"

    echo -e "${YELLOW}Features Enabled:${NC}"
    echo "  MAC Spoofing:            $([ "$FEATURE_MAC_SPOOF" = true ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}")"
    echo "  DNS Privacy:             $([ "$FEATURE_DNS_PRIVACY" = true ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}")"
    echo "  IPv6 Disable:            $([ "$FEATURE_IPV6_DISABLE" = true ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}")"
    echo "  Disable Services:        $([ "$FEATURE_DISABLE_SERVICES" = true ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}")"
    echo "  Clear Logs:              $([ "$FEATURE_CLEAR_LOGS" = true ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}")"
    echo "  Connection Cleanup:      $([ "$FEATURE_CONNECTION_CLEANUP" = true ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}")"
    echo "  Firewall Rules:          $([ "$FEATURE_FIREWALL_RULES" = true ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}")"
    echo "  Tor:                     $([ "$FEATURE_TOR" = true ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}")"

    echo ""
    echo -e "${YELLOW}Settings:${NC}"
    echo "  DNS Provider:            $DNS_PROVIDER"
    echo "  Tor SOCKS Port:          $TOR_SOCKS_PORT"
    if [[ "$FEATURE_TOR" == true ]]; then
        if [[ "$TOR_TRANSPARENT" == true ]]; then
            echo -e "  Tor Routing:             ${GREEN}TRANSPARENT (system-wide)${NC}"
            echo "  Tor Trans/DNS Ports:     $TOR_TRANS_PORT / $TOR_DNS_PORT"
        else
            echo -e "  Tor Routing:             ${YELLOW}SOCKS-only (per-command)${NC}"
        fi
    fi

    if [[ ${#SERVICES_TO_DISABLE[@]} -gt 0 ]]; then
        echo "  Services to Disable:     ${SERVICES_TO_DISABLE[*]}"
    fi

    if [[ -n "$INTERFACES_TO_SPOOF" ]]; then
        echo "  Interfaces to Spoof:     $INTERFACES_TO_SPOOF"
    else
        echo "  Interfaces to Spoof:     All non-loopback"
    fi

    echo ""
}

interactive_features() {
    header "Feature Selection"

    echo -e "${CYAN}Choose which features to enable (y/n):${NC}"
    echo ""

    read -p "MAC Address Spoofing? (y/n, default: y) " -r
    [[ $REPLY =~ ^[Nn]$ ]] && FEATURE_MAC_SPOOF=false

    read -p "DNS Privacy Configuration? (y/n, default: y) " -r
    [[ $REPLY =~ ^[Nn]$ ]] && FEATURE_DNS_PRIVACY=false

    read -p "Disable IPv6? (y/n, default: y) " -r
    [[ $REPLY =~ ^[Nn]$ ]] && FEATURE_IPV6_DISABLE=false

    read -p "Disable Leaky Services? (y/n, default: y) " -r
    [[ $REPLY =~ ^[Nn]$ ]] && FEATURE_DISABLE_SERVICES=false

    read -p "Clear Logs & History? (y/n, default: y) " -r
    [[ $REPLY =~ ^[Nn]$ ]] && FEATURE_CLEAR_LOGS=false

    read -p "Connection Tracking Cleanup? (y/n, default: y) " -r
    [[ $REPLY =~ ^[Nn]$ ]] && FEATURE_CONNECTION_CLEANUP=false

    read -p "Apply Firewall Rules? (y/n, default: y) " -r
    [[ $REPLY =~ ^[Nn]$ ]] && FEATURE_FIREWALL_RULES=false

    read -p "Enable Tor? (y/n, default: y) " -r
    [[ $REPLY =~ ^[Nn]$ ]] && FEATURE_TOR=false

    echo ""
}

interactive_dns() {
    if [[ "$FEATURE_DNS_PRIVACY" != true ]]; then
        return 0
    fi

    header "DNS Provider Selection"

    echo -e "${CYAN}Choose a privacy-focused DNS provider:${NC}"
    echo ""
    echo "1) Cloudflare (1.1.1.1, 1.0.0.1) - Fast, global"
    echo "2) Quad9 (9.9.9.9, 149.112.112.112) - Privacy-focused, blocks malware"
    echo "3) AdGuard (94.140.14.14, 94.140.15.15) - Ad & tracker blocking"
    echo "4) Mullvad (194.242.2.2, 194.242.2.3) - Privacy-first, no logging"
    echo "5) NextDNS (45.90.28.0, 45.90.29.0) - Customizable filtering"
    echo ""

    read -p "Select DNS provider (1-5, default: 1) " -r

    case $REPLY in
        2) DNS_PROVIDER="quad9" ;;
        3) DNS_PROVIDER="adguard" ;;
        4) DNS_PROVIDER="mullvad" ;;
        5) DNS_PROVIDER="nextdns" ;;
        *) DNS_PROVIDER="cloudflare" ;;
    esac

    success "DNS Provider set to: $DNS_PROVIDER"
    echo ""
}

interactive_services() {
    if [[ "$FEATURE_DISABLE_SERVICES" != true ]]; then
        return 0
    fi

    header "Service Selection"

    echo -e "${CYAN}Select services to disable (space-separated, or press Enter for defaults):${NC}"
    echo "Default: cups avahi-daemon bluetooth snapd systemd-resolved"
    echo ""

    read -p "Services to disable (or press Enter for defaults) " -r

    if [[ -z "$REPLY" ]]; then
        SERVICES_TO_DISABLE=("cups" "avahi-daemon" "bluetooth" "snapd" "systemd-resolved")
    else
        IFS=' ' read -ra SERVICES_TO_DISABLE <<< "$REPLY"
    fi

    success "Services to disable: ${SERVICES_TO_DISABLE[*]}"
    echo ""
}

interactive_interfaces() {
    if [[ "$FEATURE_MAC_SPOOF" != true ]]; then
        return 0
    fi

    header "Network Interface Selection"

    echo -e "${CYAN}Available network interfaces:${NC}"
    ip link show | grep "^[0-9]:" | awk -F': ' '{print "  " $2}' | grep -v lo
    echo ""

    read -p "Spoof all interfaces? (y/n, default: y) " -r

    if [[ $REPLY =~ ^[Nn]$ ]]; then
        read -p "Enter interface names (space-separated, e.g., 'eth0 wlan0') " -r
        INTERFACES_TO_SPOOF="$REPLY"
    fi

    echo ""
}

interactive_tor() {
    if [[ "$FEATURE_TOR" != true ]]; then
        return 0
    fi

    header "Tor Configuration"

    echo -e "${CYAN}Routing mode:${NC}"
    echo "  1) Transparent (system-wide) - route ALL traffic through Tor, block leaks [default]"
    echo "  2) SOCKS-only (per-command)  - open SOCKS port; use proxychains/torsocks yourself"
    echo ""
    read -p "Select routing mode (1-2, default: 1) " -r
    case $REPLY in
        2) TOR_TRANSPARENT=false ;;
        *) TOR_TRANSPARENT=true ;;
    esac

    if [[ "$TOR_TRANSPARENT" == true ]]; then
        success "Tor routing: TRANSPARENT (system-wide)"
    else
        success "Tor routing: SOCKS-only (per-command)"
    fi
    echo ""

    read -p "SOCKS5 port (default: 9050) " -r
    if [[ -n "$REPLY" ]]; then
        TOR_SOCKS_PORT=$REPLY
    fi

    success "Tor SOCKS port set to: $TOR_SOCKS_PORT"
    echo ""
}

main_menu() {
    show_banner
    header "Main Menu"

    echo -e "${CYAN}What would you like to do?${NC}"
    echo ""
    echo "1) Quick Mode      - Full vanish with defaults"
    echo "2) Custom Mode     - Configure features interactively"
    echo "3) Load Profile    - Load a saved profile"
    echo "4) Show Config     - Display current configuration"
    echo "5) Start           - Begin vanish mode"
    echo "6) Exit            - Quit without starting"
    echo ""

    read -p "Select option (1-6) " -r

    case $REPLY in
        1)
            success "Quick Mode selected"
            DRY_RUN=false
            ;;
        2)
            interactive_features
            interactive_dns
            interactive_services
            interactive_interfaces
            interactive_tor
            show_config
            read -p "Save this configuration as a profile? (y/n) " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                read -p "Profile name (e.g., 'minimal', 'full-tor') " -r
                save_profile "$REPLY"
            fi
            ;;
        3)
            list_profiles
            read -p "Profile name to load " -r
            load_profile "$REPLY" || return 1
            show_config
            ;;
        4)
            show_config
            main_menu
            return 0
            ;;
        5)
            show_config
            read -p "Start vanish mode? (y/n) " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                main_menu
                return 0
            fi
            ;;
        6)
            info "Exiting"
            exit 0
            ;;
        *)
            error "Invalid option"
            main_menu
            return 0
            ;;
    esac
}

create_backup() {
    log "Creating backup of current network configuration..."
    mkdir -p "$BACKUP_DIR"

    if [[ -d /etc/network/interfaces.d ]]; then
        cp -r /etc/network/interfaces.d "$BACKUP_DIR/" 2>/dev/null || true
    fi
    cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    ip link show | grep -E "link/ether" > "$BACKUP_DIR/mac-addresses.bak" || true
    systemctl status systemd-resolved 2>/dev/null > "$BACKUP_DIR/dns-status.bak" || true
    systemctl list-units --type=service --state=running > "$BACKUP_DIR/services.bak" || true
    iptables-save > "$BACKUP_DIR/iptables.bak" 2>/dev/null || true
    sysctl -a > "$BACKUP_DIR/sysctl.bak" 2>/dev/null || true
    echo "${HISTFILE:-.bash_history}" > "$BACKUP_DIR/histfile.bak"

    # Save recovery info
    cat > "$RECOVERY_FILE" <<RECEOF
BACKUP_DIR="$BACKUP_DIR"
FEATURE_MAC_SPOOF=$FEATURE_MAC_SPOOF
FEATURE_DNS_PRIVACY=$FEATURE_DNS_PRIVACY
FEATURE_IPV6_DISABLE=$FEATURE_IPV6_DISABLE
FEATURE_DISABLE_SERVICES=$FEATURE_DISABLE_SERVICES
FEATURE_FIREWALL_RULES=$FEATURE_FIREWALL_RULES
SERVICES_TO_DISABLE=($(printf '%s ' "${SERVICES_TO_DISABLE[@]}"))
RECEOF

    success "Backup created in $BACKUP_DIR"
}

spoof_mac_addresses() {
    if [[ "$FEATURE_MAC_SPOOF" != true ]]; then
        return 0
    fi

    log "Spoofing MAC addresses..."

    local interfaces
    if [[ -n "$INTERFACES_TO_SPOOF" ]]; then
        interfaces="$INTERFACES_TO_SPOOF"
    else
        interfaces=$(ip link show | grep "^[0-9]:" | awk -F': ' '{print $2}' | sed 's/@.*//')
    fi

    # Figure out which interface we must NOT touch, so we don't strand the
    # session that's running this script.
    local protected_iface=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        # SSH_CONNECTION = "clientip clientport serverip serverport"
        local server_ip
        server_ip=$(awk '{print $3}' <<< "$SSH_CONNECTION")
        protected_iface=$(ip -o route get "$server_ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        [[ -n "$protected_iface" ]] && warn "SSH session detected on '$protected_iface' — it will be skipped to avoid disconnecting you"
    fi

    local changed=0
    for iface in $interfaces; do
        [[ "$iface" == "lo" ]] && continue

        if [[ "$iface" == "$protected_iface" ]]; then
            warn "  Skipping $iface (carries your SSH session)"
            continue
        fi

        # Is this interface managed by NetworkManager?
        local nm_managed=false
        if command -v nmcli &>/dev/null && nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q "^${iface}:"; then
            nm_managed=true
        fi

        local random_mac="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/:$//')"
        log "  Setting $iface -> $random_mac"

        if command -v macchanger &>/dev/null; then
            ip link set "$iface" down 2>/dev/null || true
            macchanger -r "$iface" &>/dev/null || warn "  macchanger failed on $iface"
        else
            ip link set "$iface" down 2>/dev/null || warn "  Could not bring down $iface"
            ip link set "$iface" address "$random_mac" 2>/dev/null || warn "  Could not set MAC on $iface"
        fi
        ip link set "$iface" up 2>/dev/null || warn "  Could not bring up $iface"

        # Reassociate so connectivity comes back, then wait for it.
        if [[ "$nm_managed" == true ]]; then
            nmcli device reconnect "$iface" &>/dev/null || warn "  NM reconnect failed on $iface"
        fi

        if wait_for_link "$iface" 20; then
            success "  $iface up with new MAC"
        else
            warn "  $iface did not regain connectivity within 20s"
        fi
        changed=$((changed + 1))
    done

    if [[ "$changed" -eq 0 ]]; then
        warn "No interfaces were spoofed"
    else
        success "MAC addresses spoofed ($changed interface(s))"
    fi
}

# Wait up to $2 seconds for interface $1 to have carrier + an IPv4 address.
wait_for_link() {
    local iface="$1" timeout="${2:-20}" waited=0
    while (( waited < timeout )); do
        if ip -4 addr show dev "$iface" 2>/dev/null | grep -q "inet "; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

setup_dns_privacy() {
    if [[ "$FEATURE_DNS_PRIVACY" != true ]]; then
        return 0
    fi

    log "Configuring DNS privacy ($DNS_PROVIDER)..."

    [[ -f /etc/resolv.conf ]] && cp /etc/resolv.conf /etc/resolv.conf.orig

    case $DNS_PROVIDER in
        quad9)
            cat > /etc/resolv.conf <<EOF
nameserver 9.9.9.9
nameserver 149.112.112.112
options timeout:2 attempts:3
EOF
            ;;
        adguard)
            cat > /etc/resolv.conf <<EOF
nameserver 94.140.14.14
nameserver 94.140.15.15
options timeout:2 attempts:3
EOF
            ;;
        mullvad)
            cat > /etc/resolv.conf <<EOF
nameserver 194.242.2.2
nameserver 194.242.2.3
options timeout:2 attempts:3
EOF
            ;;
        nextdns)
            cat > /etc/resolv.conf <<EOF
nameserver 45.90.28.0
nameserver 45.90.29.0
options timeout:2 attempts:3
EOF
            ;;
        *)
            cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
options timeout:2 attempts:3
EOF
            ;;
    esac

    if systemctl is-active --quiet systemd-resolved; then
        log "  Disabling systemd-resolved..."
        systemctl stop systemd-resolved 2>/dev/null || true
    fi

    success "DNS privacy configured"
}

disable_ipv6() {
    if [[ "$FEATURE_IPV6_DISABLE" != true ]]; then
        return 0
    fi

    log "Disabling IPv6..."

    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1

    for iface in $(ip link show | grep "^[0-9]:" | awk -F': ' '{print $2}' | grep -v lo); do
        sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=1" >/dev/null 2>&1 || true
    done

    success "IPv6 disabled"
}

disable_leaky_services() {
    if [[ "$FEATURE_DISABLE_SERVICES" != true ]]; then
        return 0
    fi

    log "Disabling services..."

    for service in "${SERVICES_TO_DISABLE[@]}"; do
        if systemctl is-enabled "$service" 2>/dev/null; then
            log "  Stopping $service..."
            systemctl stop "$service" 2>/dev/null || true
            systemctl disable "$service" 2>/dev/null || true
        fi
    done

    success "Services disabled"
}

clear_logs_and_history() {
    if [[ "$FEATURE_CLEAR_LOGS" != true ]]; then
        return 0
    fi

    # This is destructive and NOT covered by the backup/restore. Gate it.
    if ! confirm_destructive "Clear shell history and truncate system logs (auth.log, syslog, wtmp, btmp, journal). This is IRREVERSIBLE and will erase your own audit trail."; then
        warn "Log clearing skipped"
        return 0
    fi

    log "Clearing logs and history..."

    history -c
    > ~/.bash_history
    > /root/.bash_history 2>/dev/null || true
    [[ -f ~/.zsh_history ]] && > ~/.zsh_history
    export HISTFILE=/dev/null

    journalctl --rotate 2>/dev/null || true
    journalctl --vacuum=1s 2>/dev/null || true
    > /var/log/auth.log 2>/dev/null || true
    > /var/log/syslog 2>/dev/null || true
    > /var/log/wtmp 2>/dev/null || true
    > /var/log/btmp 2>/dev/null || true

    # rm -rf /tmp can break running apps that keep sockets/state there, so it
    # is opt-in via --wipe-tmp and gets its own extra confirmation.
    if [[ "$WIPE_TMP" == true ]]; then
        if confirm_destructive "Delete EVERYTHING in /tmp and /var/tmp. This can crash running apps relying on those paths."; then
            rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
            success "Temp directories wiped"
        else
            warn "Temp wipe skipped"
        fi
    fi

    success "Logs and history cleared"
}

# Ask before an irreversible action. Returns 0 to proceed, 1 to skip.
# --force bypasses the prompt; a non-interactive run without --force declines.
confirm_destructive() {
    local msg="$1"
    if [[ "$FORCE" == true ]]; then
        return 0
    fi
    # Quick mode is meant to be unattended — never auto-run an irreversible wipe.
    if [[ "${MODE:-}" == "quick" ]]; then
        warn "Quick mode without --force — skipping destructive action: $msg"
        return 1
    fi
    if [[ ! -t 0 ]]; then
        warn "Non-interactive run and --force not set — declining destructive action"
        return 1
    fi
    echo ""
    warn "$msg"
    read -p "$(echo -e "${RED}Proceed? Type 'yes' to confirm: ${NC}")" -r
    [[ "$REPLY" == "yes" ]]
}

setup_connection_cleanup() {
    if [[ "$FEATURE_CONNECTION_CLEANUP" != true ]]; then
        return 0
    fi

    log "Configuring connection tracking..."

    sysctl -w net.netfilter.nf_conntrack_max=100000 >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=300 >/dev/null 2>&1 || true
    conntrack -F 2>/dev/null || true

    success "Connection tracking configured"
}

setup_firewall_rules() {
    if [[ "$FEATURE_FIREWALL_RULES" != true ]]; then
        return 0
    fi

    # When transparent Tor is on, start_tor owns the full firewall (nat + filter)
    # to enforce leak-proof routing. Don't install conflicting generic rules.
    if [[ "$FEATURE_TOR" == true && "$TOR_TRANSPARENT" == true ]]; then
        info "Transparent Tor enabled — firewall is managed by the Tor module"
        return 0
    fi

    log "Setting up firewall rules..."

    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -P INPUT DROP 2>/dev/null || true
    iptables -P FORWARD DROP 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    success "Firewall rules applied"
}

start_tor() {
    if [[ "$FEATURE_TOR" != true ]]; then
        return 0
    fi

    log "Starting Tor..."

    if ! command -v tor &> /dev/null; then
        warn "Tor not installed. Skipping."
        return 1
    fi

    # Back up torrc once, then write our managed block (idempotent).
    [[ ! -f /etc/tor/torrc.backup ]] && cp /etc/tor/torrc /etc/tor/torrc.backup 2>/dev/null || true

    if ! grep -q "# >>> vanish managed" /etc/tor/torrc 2>/dev/null; then
        cat >> /etc/tor/torrc <<TORRC

# >>> vanish managed (do not edit by hand)
SocksPort $TOR_SOCKS_PORT
TORRC
        if [[ "$TOR_TRANSPARENT" == true ]]; then
            cat >> /etc/tor/torrc <<TORRC
TransPort $TOR_TRANS_PORT
DNSPort $TOR_DNS_PORT
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
TORRC
        fi
        echo "# <<< vanish managed" >> /etc/tor/torrc
    fi

    systemctl restart tor 2>/dev/null || warn "Could not restart Tor"

    log "  Waiting for Tor to bootstrap (up to 60s)..."
    local waited=0
    while (( waited < 60 )); do
        if timeout 5 curl -s -x socks5h://127.0.0.1:"$TOR_SOCKS_PORT" https://check.torproject.org/api/ip &>/dev/null; then
            success "Tor circuit established"
            break
        fi
        sleep 3
        waited=$((waited + 3))
    done
    (( waited >= 60 )) && warn "Tor not confirmed after 60s — check: journalctl -u tor -f"

    if [[ "$TOR_TRANSPARENT" == true ]]; then
        setup_tor_transparent
    fi
}

# Route ALL traffic through Tor via the nat table, and block anything that
# would leak around it via the filter table. Modeled on the kalitorify/Whonix
# transparent-proxy pattern.
setup_tor_transparent() {
    log "Applying system-wide (transparent) Tor routing..."

    local tor_uid
    tor_uid=$(id -u "$TOR_USER" 2>/dev/null || true)
    if [[ -z "$tor_uid" ]]; then
        error "Tor user '$TOR_USER' not found — cannot set transparent routing safely. Aborting Tor firewall."
        return 1
    fi

    # Point the resolver at localhost; DNS gets redirected to Tor's DNSPort.
    echo "nameserver 127.0.0.1" > /etc/resolv.conf

    # --- nat table: redirect outbound through Tor ---
    iptables -t nat -F
    # Tor's own traffic must go out untouched, or we create a loop.
    iptables -t nat -A OUTPUT -m owner --uid-owner "$tor_uid" -j RETURN
    # DNS (any destination) -> Tor DNSPort. Must come before the LAN RETURNs.
    iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$TOR_DNS_PORT"
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$TOR_DNS_PORT"
    # Tor's virtual range for .onion -> TransPort.
    iptables -t nat -A OUTPUT -d 10.192.0.0/10 -p tcp -j REDIRECT --to-ports "$TOR_TRANS_PORT"
    # Keep loopback + LAN direct.
    for net in "${NON_TOR_NETS[@]}"; do
        iptables -t nat -A OUTPUT -d "$net" -j RETURN
    done
    # Everything else (new TCP) -> TransPort.
    iptables -t nat -A OUTPUT -p tcp --syn -j REDIRECT --to-ports "$TOR_TRANS_PORT"

    # --- filter table: leak protection (default-deny OUTPUT) ---
    iptables -F OUTPUT
    iptables -P OUTPUT DROP
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$tor_uid" -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    for net in "${NON_TOR_NETS[@]}"; do
        iptables -A OUTPUT -d "$net" -j ACCEPT
    done
    # Allow the redirected packets to reach the local Tor ports.
    iptables -A OUTPUT -p tcp --dport "$TOR_TRANS_PORT" -j ACCEPT
    iptables -A OUTPUT -p udp --dport "$TOR_DNS_PORT" -j ACCEPT
    iptables -A OUTPUT -p tcp --dport "$TOR_DNS_PORT" -j ACCEPT
    # Anything else out is a leak -> reject.
    iptables -A OUTPUT -j REJECT

    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    # Verify the exit is actually a Tor node.
    if timeout 15 curl -s https://check.torproject.org/api/ip 2>/dev/null | grep -q '"IsTor":true'; then
        success "Transparent Tor active — all traffic exits through Tor"
    else
        warn "Transparent routing applied but Tor exit not yet confirmed (circuit may still be building)"
    fi
}

show_status() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}       🕶️  VANISH MODE ACTIVATED  🕶️        ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}     Leave No Trace. Become Invisible.     ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    echo ""

    show_config

    if [[ "$FEATURE_TOR" == true ]]; then
        if [[ "$TOR_TRANSPARENT" == true ]]; then
            echo -e "${GREEN}Transparent Tor ON — ALL traffic is routed through Tor.${NC}"
            echo "  Verify:  curl https://check.torproject.org/api/ip"
            echo "  (No proxychains/torsocks needed; LAN + localhost stay direct.)"
        else
            echo -e "${YELLOW}For anonymous traffic routing (per-command):${NC}"
            echo "  • proxychains4 <command>"
            echo "  • torsocks <command>"
        fi
        echo ""
    fi

    echo -e "${YELLOW}Current network state:${NC}"
    ip addr show | grep "inet " | head -5
    echo ""

    echo -e "${BLUE}Log file: $LOG_FILE${NC}"
    echo -e "${BLUE}Backup: $BACKUP_DIR${NC}"
    echo ""
    echo -e "${RED}Press Ctrl+C to EXIT and restore${NC}"
    echo ""
}

restore_config() {
    log "Restoring configuration..."

    if [[ ! -d "$BACKUP_DIR" ]]; then
        error "Backup not found at $BACKUP_DIR"
        return 1
    fi

    if [[ -f "$BACKUP_DIR/resolv.conf.bak" ]]; then
        cp "$BACKUP_DIR/resolv.conf.bak" /etc/resolv.conf
        success "DNS restored"
    fi

    if [[ -f /etc/tor/torrc.backup ]]; then
        cp /etc/tor/torrc.backup /etc/tor/torrc
        systemctl stop tor 2>/dev/null || true
        success "Tor restored"
    fi

    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
    systemctl start systemd-resolved 2>/dev/null || true
    systemctl start avahi-daemon 2>/dev/null || true
    systemctl start bluetooth 2>/dev/null || true

    # Tear down transparent-Tor rules FIRST and reopen OUTPUT, so a failed
    # restore below can never leave the machine with a default-DROP policy.
    iptables -t nat -F 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -F OUTPUT 2>/dev/null || true

    if [[ -f "$BACKUP_DIR/iptables.bak" ]]; then
        iptables-restore < "$BACKUP_DIR/iptables.bak" 2>/dev/null || true
        success "Firewall restored"
    fi

    success "Configuration restored"
    rm -f "$RECOVERY_FILE"
}

cleanup_on_exit() {
    local exit_code=$?
    echo ""
    header "Restoring System"
    log "Interrupt received — restoring original configuration..."

    # If the handler fires in a shell that lacks BACKUP_DIR (e.g. recovery),
    # pull the context back from the recovery file.
    if [[ -z "${BACKUP_DIR:-}" && -f "$RECOVERY_FILE" ]]; then
        source "$RECOVERY_FILE"
    fi

    restore_config || warn "Restore hit problems — check $LOG_FILE and the Troubleshooting section"

    rm -f "$PID_FILE" 2>/dev/null || true

    success "VANISH deactivated. You are visible again."
    exit "$exit_code"
}

run_vanish() {
    # Register the restore handler BEFORE changing anything, so any
    # interrupt from here on rolls the system back.
    trap cleanup_on_exit INT TERM

    echo "$$" > "$PID_FILE"

    header "Activating VANISH"

    create_backup
    spoof_mac_addresses
    setup_dns_privacy
    disable_ipv6
    disable_leaky_services
    clear_logs_and_history
    setup_connection_cleanup
    setup_firewall_rules
    start_tor

    show_status

    # Stay resident until the user hits Ctrl+C, which triggers cleanup_on_exit.
    while true; do
        sleep 1
    done
}

usage() {
    cat <<USAGE
VANISH — operational-security helper for Kali

Usage:
  sudo $0                      Interactive menu (default)
  sudo $0 --quick              Full vanish with all defaults, no prompts
  sudo $0 --profile <name>     Load a saved profile, confirm, then run
  sudo $0 --dry-run            Show the resolved config without changing anything
  sudo $0 --socks-only         Use per-command Tor (proxychains/torsocks) instead of system-wide
  sudo $0 --wipe-tmp           Also delete /tmp and /var/tmp (destructive; off by default)
  sudo $0 --force              Skip confirmation prompts for destructive actions
  sudo $0 --help               Show this help

Transparent Tor (default) routes ALL traffic through Tor and blocks leaks.
LAN and localhost stay reachable. Add --socks-only to opt out.

Profiles live in: $PROFILE_DIR
Logs and backups:  $VANISH_HOME
USAGE
}

parse_args() {
    MODE="interactive"
    PROFILE_NAME=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick)       MODE="quick" ;;
            --profile)     MODE="profile"; PROFILE_NAME="${2:-}"; shift ;;
            --dry-run)     DRY_RUN=true ;;
            --force)       FORCE=true ;;
            --wipe-tmp)    WIPE_TMP=true ;;
            --socks-only)  TOR_TRANSPARENT=false ;;
            -h|--help)     usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"
    check_root
    check_recovery

    # A dry run never prompts — just show the resolved config and exit.
    # Honor --profile so you can preview a saved profile's settings.
    if [[ "$DRY_RUN" == true ]]; then
        show_banner
        if [[ "$MODE" == "profile" && -n "${PROFILE_NAME:-}" ]]; then
            load_profile "$PROFILE_NAME" || exit 1
        fi
        header "Dry Run"
        show_config
        warn "Dry run: no changes were made."
        exit 0
    fi

    case "$MODE" in
        quick)
            show_banner
            info "Quick mode — applying all defaults"
            ;;
        profile)
            show_banner
            if [[ -z "$PROFILE_NAME" ]]; then
                error "--profile requires a name"
                list_profiles
                exit 1
            fi
            load_profile "$PROFILE_NAME" || exit 1
            show_config
            read -p "Start vanish with this profile? (y/n) " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                info "Aborted"
                exit 0
            fi
            ;;
        *)
            main_menu
            ;;
    esac

    run_vanish
}

main "$@"
