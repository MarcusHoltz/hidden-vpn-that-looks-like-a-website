#!/usr/bin/env bash
# =============================================================================
# xray.sh  —  XRAY VLESS + WebSocket + TLS  |  Server Setup + Client Guide
#
# This single script handles the full lifecycle on the server:
#   1. Install:  Nginx, certbot, XRAY, decoy website, TLS certificate
#   2. Manage:   clients, WS path, branding, status, cert renewal, uninstall
#   3. Guide:    walks any user through connecting any device to this server
#
# After installation completes the script flows directly into the client guide
# so the admin never has to leave the terminal to share access with devices.
#
# Architecture
#   - Nginx on port 443  →  decoy website at /  +  XRAY WS at hidden path
#   - XRAY on 127.0.0.1 only  →  never directly reachable from outside
#   - ISP sees: TLS to a domain on 443. Paths and content are encrypted.
#
# Supported:  Ubuntu 20.04 / 22.04 / 24.04  |  Debian 11 / 12
# Requires:   root, ports 80+443 open, DNS A record pointing here
#
# Usage:      sudo bash xray.sh
# =============================================================================
set -euo pipefail

# =============================================================================
# SECTION 1: Constants
# =============================================================================
readonly STATE_DIR="/etc/xray-setup"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly XRAY_CONF="/usr/local/etc/xray/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"
# XRAY releases — downloaded directly; the official installer requires systemd
# which is not present in Docker containers.
readonly XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/latest/download"
readonly XRAY_DAT_DIR="/usr/local/share/xray"
readonly NGINX_SITES_AVAIL="/etc/nginx/sites-available"
readonly NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"

# =============================================================================
# SECTION 2: Logging
# =============================================================================
log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[x] $*" >&2; exit 1; }

# =============================================================================
# SECTION 3: Root + OS detection
# =============================================================================
require_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root.  Try:  sudo bash $0"
}

PKG_MGR=""
detect_os() {
    [[ -f /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) PKG_MGR="apt-get" ;;
        *) die "Unsupported OS '${ID:-unknown}'. Debian or Ubuntu required." ;;
    esac
}

# =============================================================================
# SECTION 3b: Service management abstraction
# =============================================================================
# systemctl does not work inside Docker/LXC containers where systemd is not
# PID 1. These wrappers detect the init system and fall back to the `service`
# command (SysV/OpenRC compatible) so the script works on bare metal, VMs,
# and containers alike.
#
# Detection: /run/systemd/system exists only when systemd is the running init.
# The directory is created by systemd itself at boot and is never present in
# containers that use a stub or no init.

_has_systemd() { [[ -d /run/systemd/system ]]; }

# svc_enable NAME   — mark service to start on boot (best-effort in containers)
svc_enable() {
    local name="$1"
    if _has_systemd; then
        systemctl enable "${name}" --quiet 2>/dev/null || true
    fi
    # No-op in containers: services are started manually; boot persistence
    # is handled by the container restart policy.
}

# svc_start NAME   — start a service if not already running
svc_start() {
    local name="$1"
    if _has_systemd; then
        systemctl start "${name}"
    else
        service "${name}" start 2>/dev/null || _svc_direct_start "${name}"
    fi
}

# svc_restart NAME   — start or restart a service
svc_restart() {
    local name="$1"
    if _has_systemd; then
        systemctl restart "${name}"
    else
        service "${name}" restart 2>/dev/null || _svc_direct_start "${name}"
    fi
}

# svc_reload NAME   — reload config without dropping connections
svc_reload() {
    local name="$1"
    if _has_systemd; then
        systemctl reload "${name}"
    else
        case "${name}" in
            # nginx -s reload sends SIGHUP to the master process — works
            # without systemd; gracefully reloads config with no dropped conns.
            nginx)  nginx -s reload 2>/dev/null || svc_restart "${name}" ;;
            *)      service "${name}" reload 2>/dev/null || svc_restart "${name}" ;;
        esac
    fi
}

# svc_stop NAME
svc_stop() {
    local name="$1"
    if _has_systemd; then
        systemctl stop "${name}" 2>/dev/null || true
    else
        # `service NAME stop` is a no-op in Docker (no init daemon).
        # Use process-level signals for known services.
        case "${name}" in
            nginx)  nginx -s quit 2>/dev/null || pkill -x nginx 2>/dev/null || true ;;
            xray)   pkill -x xray  2>/dev/null || true ;;
            *)      service "${name}" stop 2>/dev/null || true ;;
        esac
    fi
}

# svc_disable NAME
svc_disable() {
    local name="$1"
    if _has_systemd; then
        systemctl disable "${name}" 2>/dev/null || true
    fi
}

# svc_daemon_reload   — tell systemd to re-read unit files (no-op elsewhere)
svc_daemon_reload() {
    _has_systemd && systemctl daemon-reload || true
}

# svc_is_active NAME   — returns 0 if service is running, 1 otherwise
svc_is_active() {
    local name="$1"
    if _has_systemd; then
        systemctl is-active "${name}" > /dev/null 2>&1
    else
        # `service NAME status` is unreliable in Docker (no init daemon registers
        # services). Use pgrep to check whether the process is actually running.
        pgrep -x "${name}" > /dev/null 2>&1
    fi
}

# _svc_direct_start NAME   — last-resort direct invocation for known services
_svc_direct_start() {
    case "$1" in
        nginx)
               # Stop any running nginx before starting a new master process.
               # Without this, `nginx` fails with "bind: Address already in use"
               # when called as a restart inside a Docker container.
               nginx -s quit 2>/dev/null || pkill -x nginx 2>/dev/null || true
               sleep 1
               nginx ;;
        xray)
               # Kill any existing xray process before spawning a new one.
               pkill -x xray 2>/dev/null || true
               sleep 1
               mkdir -p /var/log/xray
               "${XRAY_BIN}" run -config "${XRAY_CONF}" >> /var/log/xray/xray.log 2>&1 &
               sleep 2 ;;
        *)     warn "No direct start handler for service: $1"; return 1 ;;
    esac
}


# =============================================================================
# SECTION 3d: DNS-01 certificate helpers
# =============================================================================

# _dns_plugin_pkg PROVIDER — apt package name for the certbot DNS plugin
_dns_plugin_pkg() {
    case "$1" in
        cloudflare)   echo "python3-certbot-dns-cloudflare" ;;
        digitalocean) echo "python3-certbot-dns-digitalocean" ;;
        linode)       echo "python3-certbot-dns-linode" ;;
        ovh)          echo "python3-certbot-dns-ovh" ;;
        route53)      echo "python3-certbot-dns-route53" ;;
        hetzner)      echo "" ;;   # pip only
        manual)       echo "" ;;   # no plugin
        *)            echo "" ;;
    esac
}

# _dns_plugin_pip PROVIDER — pip package name when no apt package exists
_dns_plugin_pip() {
    case "$1" in
        hetzner) echo "certbot-dns-hetzner" ;;
        *)       echo "" ;;
    esac
}

# install_dns_plugin PROVIDER — installs the certbot DNS plugin for PROVIDER
install_dns_plugin() {
    local provider="$1"
    local pkg; pkg=$(_dns_plugin_pkg "${provider}")
    local pip_pkg; pip_pkg=$(_dns_plugin_pip "${provider}")

    if [[ "${provider}" == "manual" ]]; then
        log "Manual DNS-01 selected — no plugin needed."
        return 0
    fi

    if [[ -n "${pkg}" ]]; then
        log "Installing certbot DNS plugin: ${pkg}..."
        $PKG_MGR install -y -qq "${pkg}" || \
            die "Failed to install ${pkg}. Check apt sources and try again."
    elif [[ -n "${pip_pkg}" ]]; then
        log "Installing certbot DNS plugin via pip: ${pip_pkg}..."
        # Try with --break-system-packages (required on Ubuntu 23.04+ / Debian 12+).
        # Falls back without the flag for older Ubuntu/Debian where pip doesn't know it.
        pip3 install --break-system-packages --quiet "${pip_pkg}" 2>/dev/null \
            || pip3 install --quiet "${pip_pkg}" \
            || die "Failed to install ${pip_pkg} via pip. Try manually: pip3 install ${pip_pkg}"
    else
        die "No plugin handler for DNS provider '${provider}'."
    fi
}

# write_dns_credentials PROVIDER TOKEN [TOKEN2]
# Writes provider credentials to STATE_DIR/dns_credentials.ini (chmod 600).
# Sets DNS_CREDS_FILE as a side-effect.
write_dns_credentials() {
    local provider="$1"
    local token="$2"
    local creds_file="${STATE_DIR}/dns_credentials.ini"

    mkdir -p "${STATE_DIR}"; chmod 700 "${STATE_DIR}"

    case "${provider}" in
        cloudflare)
            cat > "${creds_file}" <<EOF
# Cloudflare API credentials for certbot
dns_cloudflare_api_token = ${token}
EOF
            ;;
        digitalocean)
            cat > "${creds_file}" <<EOF
# DigitalOcean API credentials for certbot
dns_digitalocean_token = ${token}
EOF
            ;;
        linode)
            cat > "${creds_file}" <<EOF
# Linode API credentials for certbot
dns_linode_key = ${token}
dns_linode_version = 4
EOF
            ;;
        ovh)
            # token = "endpoint:app_key:app_secret:consumer_key"
            local endpoint app_key app_secret consumer_key
            IFS=':' read -r endpoint app_key app_secret consumer_key <<< "${token}"
            cat > "${creds_file}" <<EOF
# OVH API credentials for certbot
dns_ovh_endpoint = ${endpoint}
dns_ovh_application_key = ${app_key}
dns_ovh_application_secret = ${app_secret}
dns_ovh_consumer_key = ${consumer_key}
EOF
            ;;
        hetzner)
            cat > "${creds_file}" <<EOF
# Hetzner DNS API credentials for certbot
dns_hetzner_api_token = ${token}
EOF
            ;;
        route53)
            # Route53 reads standard AWS credentials — no .ini file needed.
            DNS_CREDS_FILE=""
            return 0
            ;;
        manual)
            DNS_CREDS_FILE=""
            return 0
            ;;
    esac

    chmod 600 "${creds_file}"
    DNS_CREDS_FILE="${creds_file}"
}

# run_certbot_dns DOMAIN EMAIL — obtains cert via DNS-01 using DNS_PROVIDER/DNS_CREDS_FILE
run_certbot_dns() {
    local domain="$1" email="$2"

    if [[ "${DNS_PROVIDER}" == "manual" ]]; then
        log "Running certbot DNS-01 in MANUAL mode."
        log "You will be asked to add a TXT record. Follow the prompts."
        certbot certonly \
            --manual \
            --preferred-challenges dns \
            --manual-public-ip-logging-ok \
            -d "${domain}" \
            --agree-tos \
            -m "${email}"
        return $?
    fi

    local certbot_args=(
        certonly
        "--dns-${DNS_PROVIDER}"
        "--dns-${DNS_PROVIDER}-propagation-seconds" "60"
        -d "${domain}"
        --non-interactive
        --agree-tos
        -m "${email}"
    )
    [[ -n "${DNS_CREDS_FILE}" ]] && \
        certbot_args+=( "--dns-${DNS_PROVIDER}-credentials" "${DNS_CREDS_FILE}" )

    log "Running: certbot ${certbot_args[*]}"
    certbot "${certbot_args[@]}"
}

# wizard_dns_provider — interactive DNS provider + credentials wizard.
# Sets DNS_PROVIDER and DNS_CREDS_FILE as side-effects.
wizard_dns_provider() {
    local provider
    provider=$(wt_menu "TLS Certificate — DNS-01 Provider" \
        "Choose your DNS provider. DNS-01 requires no open ports." \
        "cloudflare"   "Cloudflare       (API token)" \
        "digitalocean" "DigitalOcean     (API token)" \
        "route53"      "AWS Route53      (IAM credentials)" \
        "linode"       "Linode / Akamai  (API key)" \
        "hetzner"      "Hetzner DNS      (API token)" \
        "ovh"          "OVH              (4-part credentials)" \
        "manual"       "Manual           (add TXT record yourself — interactive)") \
        || return 1

    DNS_PROVIDER="${provider}"

    case "${provider}" in
        cloudflare)
            wt_msg "Cloudflare — API Token" \
"Create a scoped API token (not a Global API Key):

  Cloudflare Dashboard -> My Profile -> API Tokens
  -> Create Token -> Use template: Edit zone DNS
  -> Zone Resources: Include -> Specific zone -> your domain
  -> Create Token -> copy the token string"
            local token
            token=$(wt_input "Cloudflare API Token" "Paste your Cloudflare API token:" "") || return 1
            [[ -z "${token}" ]] && { wt_msg "Error" "Token cannot be empty."; return 1; }
            write_dns_credentials cloudflare "${token}"
            ;;

        digitalocean)
            wt_msg "DigitalOcean — API Token" \
"Create a personal access token with Write scope:

  DigitalOcean Control Panel -> API -> Tokens/Keys
  -> Generate New Token -> enable Write
  -> copy the token string"
            local token
            token=$(wt_input "DigitalOcean API Token" "Paste your DigitalOcean API token:" "") || return 1
            [[ -z "${token}" ]] && { wt_msg "Error" "Token cannot be empty."; return 1; }
            write_dns_credentials digitalocean "${token}"
            ;;

        route53)
            wt_msg "AWS Route53 — IAM Credentials" \
"certbot-dns-route53 reads standard AWS credentials.
No credentials file is written by this script.

The IAM user/role needs:
  route53:ListHostedZones
  route53:GetChange
  route53:ChangeResourceRecordSets

Configure credentials BEFORE continuing via ONE of:
  A) Environment variables:
       export AWS_ACCESS_KEY_ID=...
       export AWS_SECRET_ACCESS_KEY=...
  B) ~/.aws/credentials  (aws configure)
  C) IAM instance role (if on EC2)

Press OK when AWS credentials are in place."
            write_dns_credentials route53 ""
            ;;

        linode)
            wt_msg "Linode / Akamai — API Key" \
"Create a Personal Access Token with DNS Read/Write:

  Linode Cloud Manager -> Profile -> API Tokens
  -> Add a Personal Access Token -> Domains: Read/Write
  -> copy the token"
            local token
            token=$(wt_input "Linode API Key" "Paste your Linode API key:" "") || return 1
            [[ -z "${token}" ]] && { wt_msg "Error" "Key cannot be empty."; return 1; }
            write_dns_credentials linode "${token}"
            ;;

        hetzner)
            wt_msg "Hetzner DNS — API Token" \
"Create a DNS API token:

  Hetzner DNS Console -> DNS -> API Tokens
  -> Create API token -> copy the token"
            local token
            token=$(wt_input "Hetzner DNS API Token" "Paste your Hetzner DNS API token:" "") || return 1
            [[ -z "${token}" ]] && { wt_msg "Error" "Token cannot be empty."; return 1; }
            write_dns_credentials hetzner "${token}"
            ;;

        ovh)
            wt_msg "OVH — Application Credentials" \
"You need four values from https://api.ovh.com/createToken/

  Required rights: GET/PUT/POST/DELETE /domain/zone/*

  You will be asked for:
    1. Endpoint    (e.g. ovh-eu, ovh-us, kimsufi-eu)
    2. App Key
    3. App Secret
    4. Consumer Key"
            local endpoint app_key app_secret consumer_key
            endpoint=$(wt_input    "OVH — Endpoint"     "Endpoint (e.g. ovh-eu):" "ovh-eu") || return 1
            app_key=$(wt_input     "OVH — App Key"      "Application Key:"        "")        || return 1
            app_secret=$(wt_input  "OVH — App Secret"   "Application Secret:"     "")        || return 1
            consumer_key=$(wt_input "OVH — Consumer Key" "Consumer Key:"           "")        || return 1
            [[ -z "${app_key}" || -z "${app_secret}" || -z "${consumer_key}" ]] && \
                { wt_msg "Error" "All OVH fields are required."; return 1; }
            write_dns_credentials ovh "${endpoint}:${app_key}:${app_secret}:${consumer_key}"
            ;;

        manual)
            wt_msg "Manual DNS-01" \
"Manual mode: certbot will print the TXT record value
and wait while you add it to your DNS provider.

During installation you will see:

  Please deploy a DNS TXT record under:
  _acme-challenge.yourdomain.com
  with value: <token>

Add the record, wait 30-120s for propagation,
then press Enter to let certbot verify.

This is fully interactive — do not run unattended."
            write_dns_credentials manual ""
            ;;
    esac
}

# =============================================================================
# SECTION 4: Colors and native bash UI
# =============================================================================
# Pure bash UI — no whiptail/newt dependency. Works on any terminal and
# on serial consoles. Uses ANSI escape codes referenced by name.

# ANSI color references — use these names throughout the script.
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_FG_WHITE=$'\033[97m'   # bright white  — primary text
C_FG_GREY=$'\033[37m'    # grey          — secondary text / hints
C_FG_CYAN=$'\033[96m'    # cyan          — titles / borders
C_FG_YELLOW=$'\033[93m'  # yellow        — prompts / user input cues
C_FG_GREEN=$'\033[92m'   # green         — success markers
C_FG_RED=$'\033[91m'     # red           — error markers

# _ui_width: usable terminal width, capped 64-84
_ui_width() {
    local w; w=$(tput cols 2>/dev/null || echo 76)
    [[ $w -gt 84 ]] && w=84; [[ $w -lt 64 ]] && w=64; echo "$w"
}

# _ui_rule W CHAR — print W copies of CHAR then newline (no border math needed)
_ui_rule() {
    local w="$1" c="${2:--}"
    printf "${C_FG_CYAN}"
    printf "%${w}s" | tr ' ' "${c}"
    printf "${C_RESET}\n"
}

# _ui_box TITLE BODY
# Open-right design: full-width separator lines, left-aligned text.
# No right border means zero byte-vs-column alignment math.
_ui_box() {
    local title="$1" body="$2"
    local w; w=$(_ui_width)
    {
    clear
    echo
    _ui_rule "${w}" "="
    printf "${C_BOLD}${C_FG_WHITE}  %s${C_RESET}\n" "${title}"
    _ui_rule "${w}" "-"
    while IFS= read -r line; do
        printf "  ${C_FG_WHITE}%s${C_RESET}\n" "${line}"
    done <<< "$(echo -e "${body}")"
    _ui_rule "${w}" "-"
    echo
    } >&2
}

# wt_msg TITLE BODY — informational, press Enter to continue
wt_msg() {
    _ui_box "$1" "$2"
    printf "${C_FG_YELLOW}  Press Enter to continue...${C_RESET}" >&2
    local _; read -r _ </dev/tty
    echo >&2
}

# wt_yesno TITLE QUESTION — returns 0=yes 1=no
wt_yesno() {
    _ui_box "$1" "$2"
    while true; do
        printf "${C_FG_YELLOW}  [y/n]: ${C_RESET}" >&2
        local ans; read -r ans </dev/tty
        case "${ans,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) printf "${C_FG_GREY}  Enter y or n.\n${C_RESET}" >&2 ;;
        esac
    done
}

# wt_input TITLE PROMPT DEFAULT — prints value to stdout; returns 1 if empty with no default
wt_input() {
    local title="$1" prompt="$2" default="$3"
    _ui_box "${title}" "${prompt}"
    local hint=""
    [[ -n "${default}" ]] && hint=" ${C_DIM}[${default}]${C_RESET}"
    printf "${C_FG_YELLOW}  >%s ${C_RESET}" "${hint}" >&2
    local val; read -r val </dev/tty
    [[ -z "${val}" && -n "${default}" ]] && val="${default}"
    if [[ -z "${val}" ]]; then
        printf "${C_FG_GREY}  (cancelled)\n${C_RESET}" >&2
        return 1
    fi
    echo "${val}"
}

# wt_menu TITLE PROMPT key desc key desc ... — prints selected key; returns 1 on cancel
wt_menu() {
    local title="$1" prompt="$2"; shift 2
    local -a _keys=() _descs=()
    while [[ $# -ge 2 ]]; do _keys+=("$1"); _descs+=("$2"); shift 2; done
    _ui_box "${title}" "${prompt}"
    local i
    for (( i=0; i<${#_keys[@]}; i++ )); do
        printf "  ${C_FG_CYAN}%2d)${C_RESET} ${C_FG_WHITE}%-22s${C_RESET} ${C_FG_GREY}%s${C_RESET}\n" \
            $((i+1)) "${_keys[$i]}" "${_descs[$i]}" >&2
    done
    echo >&2
    while true; do
        printf "${C_FG_YELLOW}  Choose [1-${#_keys[@]}] or q to cancel: ${C_RESET}" >&2
        local ans; read -r ans </dev/tty
        [[ "${ans,,}" == "q" ]] && return 1
        if [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#_keys[@]} )); then
            echo "${_keys[$((ans-1))]}"
            return 0
        fi
        printf "${C_FG_GREY}  Enter a number 1-%d.\n${C_RESET}" "${#_keys[@]}" >&2
    done
}

# wt_checklist TITLE PROMPT key desc on/off ... — prints selected keys space-separated; returns 1 on cancel
wt_checklist() {
    local title="$1" prompt="$2"; shift 2
    local -a _keys=() _descs=() _states=()
    while [[ $# -ge 3 ]]; do
        _keys+=("$1"); _descs+=("$2")
        [[ "${3,,}" == "on" ]] && _states+=(1) || _states+=(0)
        shift 3
    done
    _ui_box "${title}" "${prompt}"
    # Nested function: defined here to access _keys/_descs/_states from caller's local scope.
    _checklist_draw() {
        local i
        for (( i=0; i<${#_keys[@]}; i++ )); do
            local mark=" "; [[ ${_states[$i]} -eq 1 ]] && mark="x"
            printf "  ${C_FG_CYAN}%2d)${C_RESET} [%s] ${C_FG_WHITE}%s${C_RESET}\n" \
                $((i+1)) "${mark}" "${_descs[$i]}" >&2
        done
        echo >&2
    }
    _checklist_draw
    printf "${C_FG_GREY}  Type numbers to toggle, Enter to confirm, q to cancel:\n${C_RESET}" >&2
    while true; do
        printf "${C_FG_YELLOW}  > ${C_RESET}" >&2
        local ans; read -r ans </dev/tty
        [[ "${ans,,}" == "q" ]] && return 1
        if [[ -z "${ans}" ]]; then
            local selected=()
            local i; for (( i=0; i<${#_keys[@]}; i++ )); do
                [[ ${_states[$i]} -eq 1 ]] && selected+=("${_keys[$i]}")
            done
            echo "${selected[*]}"
            return 0
        fi
        local tok
        for tok in ${ans}; do
            if [[ "${tok}" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#_keys[@]} )); then
                local idx=$(( tok - 1 ))
                [[ ${_states[$idx]} -eq 0 ]] && _states[$idx]=1 || _states[$idx]=0
            fi
        done
        _checklist_draw
        printf "${C_FG_GREY}  Toggle more or Enter to confirm, q to cancel:\n${C_RESET}" >&2
    done
}


# =============================================================================
# SECTION 5: Terminal print helpers
# =============================================================================
# These print directly to the terminal so the user can select and copy freely.
# Never put links or commands inside wt_msg boxes — they trap text.

BAR="============================================================================"

# print_link "label" "vless://..."
# Displays a single VLESS link full-width in the terminal for copying.
print_link() {
    local label="$1" link="$2"
    clear
    echo ""
    echo "  ${BAR}"
    echo "  VLESS Import Link  —  ${label}"
    echo "  ${BAR}"
    echo ""
    echo "  ${link}"
    echo ""
    echo "  ${BAR}"
    echo ""
    echo "  Select the link above and copy it."
    echo "  The initial client link is saved at ${STATE_DIR}/client1.txt"
    echo ""
    read -r -p "  Press Enter to continue..." </dev/tty
}

# print_block "title" "content (multi-line ok)"
# Displays any block of text (commands, YAML, etc.) for copying.
print_block() {
    local title="$1" content="$2"
    clear
    echo ""
    echo "  ${BAR}"
    echo "  ${title}"
    echo "  ${BAR}"
    echo ""
    while IFS= read -r line; do echo "  ${line}"; done <<< "${content}"
    echo ""
    echo "  ${BAR}"
    echo ""
    echo "  Select the text above and copy it."
    echo ""
    read -r -p "  Press Enter to continue..." </dev/tty
}

# print_qr "vless://..."
# Renders a QR code of the link in the terminal using qrencode.
print_qr() {
    local link="$1" label="${2:-}"
    clear
    echo ""
    echo "  ${BAR}"
    echo "  QR Code${label:+  —  ${label}}"
    echo "  Scan with v2rayNG (Android) or Shadowrocket (iOS)"
    echo "  ${BAR}"
    echo ""
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 -m 2 "${link}"
    else
        echo "  qrencode is not installed. It should have been installed by the setup script."
        echo "  Install it manually:  sudo apt install qrencode"
        echo "  Then re-run this menu option."
        echo ""
        echo "  Alternatively use https://qr-code-generator.com"
        echo "  and paste the vless:// link manually."
        echo ""
        echo "  Link:  ${link}"
    fi
    echo ""
    echo "  ${BAR}"
    echo ""
    read -r -p "  Press Enter to continue..." </dev/tty
}

# =============================================================================
# SECTION 5b: vless:// link parser
# =============================================================================
# Used by the Linux auto-config wizard and the Clash YAML generator.
# Parses a vless:// link into C_* globals so server state vars are not clobbered.
# C_ prefix = "Client" to distinguish from server-side DOMAIN, WS_PATH, etc.
C_UUID="" C_SERVER="" C_PORT="" C_SECURITY="" C_NETWORK="" C_SNI="" C_PATH="" C_NAME=""

parse_vless_link() {
    local link="$1"
    [[ "${link}" == vless://* ]] || { wt_msg "Parse Error" "Not a vless:// link.\n\nMust start with  vless://"; return 1; }

    local rest="${link#vless://}"

    # Fragment (label after #)
    if [[ "${rest}" == *"#"* ]]; then C_NAME="${rest##*#}"; rest="${rest%#*}"; else C_NAME="xray"; fi

    C_UUID="${rest%@*}"
    [[ -z "${C_UUID}" ]] && { wt_msg "Parse Error" "Could not extract UUID from link."; return 1; }

    local addr_part="${rest#*@}"
    C_SERVER="${addr_part%%:*}"
    local port_query="${addr_part#*:}"
    C_PORT="${port_query%%\?*}"
    local query=""; [[ "${port_query}" == *"?"* ]] && query="${port_query#*\?}"

    C_SECURITY=$(echo "${query}" | grep -oP '(?<=security=)[^&]*' || true)
    C_NETWORK=$(echo  "${query}" | grep -oP '(?<=type=)[^&]*'     || true)
    C_SNI=$(echo      "${query}" | grep -oP '(?<=sni=)[^&]*'      || true)
    local raw_path; raw_path=$(echo "${query}" | grep -oP '(?<=path=)[^&]*' || true)
    C_PATH=$(python3 -c \
        "import urllib.parse, sys; print(urllib.parse.unquote(sys.argv[1]))" \
        "${raw_path}" 2>/dev/null || echo "${raw_path}")

    [[ -z "${C_SECURITY}" ]] && C_SECURITY="none"
    [[ -z "${C_NETWORK}"  ]] && C_NETWORK="tcp"
    [[ -z "${C_SNI}"      ]] && C_SNI="${C_SERVER}"
    [[ -z "${C_PATH}"     ]] && C_PATH="/"

    [[ -z "${C_SERVER}" ]] && { wt_msg "Parse Error" "Could not extract server address."; return 1; }
    [[ -z "${C_PORT}"   ]] && { wt_msg "Parse Error" "Could not extract port."; return 1; }
    [[ "${C_UUID}" =~ ^[0-9a-f-]{36}$ ]] \
        || { wt_msg "Parse Error" "UUID does not look valid:\n${C_UUID}"; return 1; }
}

# prompt_vless_link: asks the user to paste a link, strips whitespace, parses it.
# On success all C_* globals are populated. Returns 1 on cancel or parse failure.
prompt_vless_link() {
    local raw
    raw=$(wt_input "Paste vless:// Link" \
        "Paste the complete vless:// link for this client.\n\nGet it from: Clients -> List (it prints to the terminal).\n\nThe full link must start with  vless://" \
        "") || return 1
    # Strip leading/trailing whitespace
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    [[ -z "${raw}" ]] && { wt_msg "Error" "Nothing was entered."; return 1; }
    parse_vless_link "${raw}" || return 1

    wt_yesno "Confirm Parsed Link" \
"Verify these details before generating the config:

  Server    : ${C_SERVER}
  Port      : ${C_PORT}
  UUID      : ${C_UUID}
  Transport : ${C_NETWORK}
  TLS       : ${C_SECURITY}
  SNI       : ${C_SNI}
  WS Path   : ${C_PATH}
  Label     : ${C_NAME}

Look correct?" || return 1
}

# =============================================================================
# SECTION 6: Server state  (all install variables persisted between runs)
# =============================================================================
DOMAIN=""
EMAIL=""
SERVER_PORT="443"
XRAY_INTERNAL_PORT="10001"
WS_PATH=""
COMPANY_NAME="Meridian"
COMPANY_TAGLINE="Infrastructure for the modern web. Deploy, scale, and monitor with confidence"
COMPANY_COLOR="#3b82f6"
WEBROOT=""
# ── Reverse proxy mode ────────────────────────────────────────────────────────
# SETUP_MODE="standalone" : this server owns TLS (certbot, port 443)
# SETUP_MODE="reverse_proxy": an upstream RP owns TLS; this Nginx speaks plain HTTP
SETUP_MODE="standalone"
RP_DOMAIN=""       # the domain the external RP serves — used in vless:// links
RP_PORT="443"      # the port clients connect to at the RP
LISTEN_PORT="8080" # plain HTTP port this Nginx listens on in RP mode
# ── Client guide display helpers (set by client_guide_menu) ──────────────────
# In RP mode, clients connect to RP_DOMAIN:RP_PORT, not DOMAIN:SERVER_PORT.
# These vars let guide sub-functions show the correct connection details
# without each one branching on SETUP_MODE independently.
GUIDE_DOMAIN=""  # effective domain clients connect to
GUIDE_PORT=""    # effective port  clients connect to
# ── Certificate challenge mode ─────────────────────────────────────────────
ACME_METHOD="http01" # "http01" = webroot (default) | "dns01" = DNS challenge
DNS_PROVIDER=""      # cloudflare | digitalocean | route53 | linode | hetzner | ovh | manual
DNS_CREDS_FILE=""    # path to provider credentials .ini (empty for route53/manual)

is_installed() { [[ -f "${STATE_FILE}" ]]; }

save_state() {
    mkdir -p "${STATE_DIR}"; chmod 700 "${STATE_DIR}"
    cat > "${STATE_FILE}" <<EOF
DOMAIN="${DOMAIN}"
EMAIL="${EMAIL}"
SERVER_PORT="${SERVER_PORT}"
XRAY_INTERNAL_PORT="${XRAY_INTERNAL_PORT}"
WS_PATH="${WS_PATH}"
COMPANY_NAME="${COMPANY_NAME}"
COMPANY_TAGLINE="${COMPANY_TAGLINE}"
COMPANY_COLOR="${COMPANY_COLOR}"
WEBROOT="${WEBROOT}"
SETUP_MODE="${SETUP_MODE}"
RP_DOMAIN="${RP_DOMAIN}"
RP_PORT="${RP_PORT}"
LISTEN_PORT="${LISTEN_PORT}"
ACME_METHOD="${ACME_METHOD}"
DNS_PROVIDER="${DNS_PROVIDER}"
DNS_CREDS_FILE="${DNS_CREDS_FILE}"
INSTALL_DATE="$(date -Iseconds)"
EOF
    chmod 600 "${STATE_FILE}"
}

load_state() {
    [[ -f "${STATE_FILE}" ]] || die "No state file at ${STATE_FILE}. Run the installer first."
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
}

# =============================================================================
# SECTION 7: VLESS link builder
# =============================================================================
build_vless_link() {
    # $1 = client UUID   $2 = human label (optional)
    local uuid="$1" label="${2:-}"
    local enc_path
    # Pass WS_PATH as an argument so no shell quoting in the Python string is needed.
    enc_path=$(python3 -c \
        "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe='/'))" \
        "${WS_PATH}")

    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        # Client connects to the external reverse proxy which owns TLS.
        # RP_DOMAIN and RP_PORT are what clients dial; DOMAIN is only used
        # internally for the nginx site file name.
        local lbl="${label:-client@${RP_DOMAIN}}"
        echo "vless://${uuid}@${RP_DOMAIN}:${RP_PORT}?encryption=none&security=tls&sni=${RP_DOMAIN}&type=ws&path=${enc_path}#${lbl}"
    else
        local lbl="${label:-${DOMAIN}}"
        echo "vless://${uuid}@${DOMAIN}:${SERVER_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&path=${enc_path}#${lbl}"
    fi
}

# =============================================================================
# SECTION 8: Decoy website generator
# =============================================================================
generate_decoy_site() {
    mkdir -p "${WEBROOT}"
    local year; year=$(date +%Y)
    cat > "${WEBROOT}/index.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${COMPANY_NAME} - Developer Platform</title>
  <style>
    :root{--a:${COMPANY_COLOR}}
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;background:#0f1117;color:#e2e8f0}
    nav{padding:1.2rem 2rem;border-bottom:1px solid #1e2535;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;background:#0f1117;z-index:10}
    .logo{font-size:1.25rem;font-weight:700;color:var(--a)}
    nav a{color:#94a3b8;text-decoration:none;margin-left:1.5rem;font-size:.875rem}
    nav a:hover{color:#f1f5f9}
    .hero{max-width:800px;margin:5rem auto 0;padding:0 2rem;text-align:center}
    .badge{display:inline-block;background:#1e2535;border:1px solid #2d3748;border-radius:999px;padding:.3rem 1rem;font-size:.75rem;color:#94a3b8;margin-bottom:1.25rem;letter-spacing:.05em;text-transform:uppercase}
    h1{font-size:2.75rem;font-weight:800;line-height:1.15;color:#f8fafc;margin-bottom:1.25rem}
    h1 span{color:var(--a)}
    .hero p{color:#94a3b8;font-size:1.05rem;line-height:1.75;max-width:600px;margin:0 auto 2rem}
    .cta{display:flex;gap:.75rem;justify-content:center;flex-wrap:wrap}
    .btn{padding:.7rem 1.75rem;border-radius:8px;font-size:.95rem;font-weight:600;text-decoration:none}
    .btn-p{background:var(--a);color:#fff}
    .btn-s{border:1px solid #334155;color:#cbd5e1;background:transparent}
    .stats{display:flex;gap:3rem;justify-content:center;padding:3rem 2rem;border-top:1px solid #1e2535;border-bottom:1px solid #1e2535;margin:4rem 0}
    .stat{text-align:center}
    .stat strong{display:block;font-size:1.75rem;font-weight:800;color:var(--a)}
    .stat span{color:#64748b;font-size:.85rem}
    .features{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:1.25rem;max-width:900px;margin:0 auto 4rem;padding:0 2rem}
    .card{background:#161b26;border:1px solid #1e2535;border-radius:10px;padding:1.5rem}
    .card h3{color:#f1f5f9;font-size:1rem;margin-bottom:.5rem}
    .card p{color:#64748b;font-size:.875rem;line-height:1.65}
    footer{text-align:center;padding:2.5rem;color:#475569;font-size:.8rem;border-top:1px solid #1e2535}
    footer a{color:#475569;text-decoration:none}
    @media(max-width:640px){h1{font-size:2rem}.stats{gap:1.5rem}}
  </style>
</head>
<body>
  <nav>
    <span class="logo">${COMPANY_NAME}</span>
    <div><a href="#">Products</a><a href="#">Developers</a><a href="#">Pricing</a><a href="#">Blog</a><a href="#">Sign in</a></div>
  </nav>
  <div class="hero">
    <div class="badge">Generally Available</div>
    <h1>The platform built for <span>what's next</span></h1>
    <p>${COMPANY_TAGLINE}. Trusted by engineering teams at companies of every size.</p>
    <div class="cta">
      <a class="btn btn-p" href="#">Get started free</a>
      <a class="btn btn-s" href="#">Read the docs</a>
    </div>
  </div>
  <div class="stats">
    <div class="stat"><strong>40+</strong><span>Global regions</span></div>
    <div class="stat"><strong>99.99%</strong><span>Uptime SLA</span></div>
    <div class="stat"><strong>10B+</strong><span>Requests / day</span></div>
    <div class="stat"><strong>&lt;5ms</strong><span>P95 latency</span></div>
  </div>
  <div class="features">
    <div class="card"><h3>Edge Network</h3><p>40+ PoPs with anycast routing. Your users connect to the nearest node every time.</p></div>
    <div class="card"><h3>Versioned API</h3><p>Every platform capability over a stable REST and gRPC API. Stream, automate, integrate.</p></div>
    <div class="card"><h3>Zero-trust Security</h3><p>Short-lived tokens, mTLS enforcement, fine-grained RBAC. SOC 2 Type II certified.</p></div>
    <div class="card"><h3>Observability</h3><p>Real-time metrics, distributed tracing, structured log ingestion. Works with Grafana and Datadog.</p></div>
    <div class="card"><h3>Instant Deploy</h3><p>Git-push deploys with atomic rollbacks and preview environments out of the box.</p></div>
    <div class="card"><h3>Webhooks &amp; Events</h3><p>Subscribe to any platform event. Guaranteed delivery with exponential backoff.</p></div>
  </div>
  <footer>
    &copy; ${year} ${COMPANY_NAME}, Inc.
    &nbsp;&middot;&nbsp;<a href="#">Privacy</a>
    &nbsp;&middot;&nbsp;<a href="#">Terms</a>
    &nbsp;&middot;&nbsp;<a href="#">Security</a>
    &nbsp;&middot;&nbsp;<a href="#">Status</a>
  </footer>
</body>
</html>
HTMLEOF
}

# =============================================================================
# SECTION 9: XRAY server config writer
# =============================================================================
FIRST_UUID=""   # set as side-effect on fresh install

write_xray_config() {
    # $1 (optional) — pre-built JSON array of client objects
    local clients_json="${1:-}"

    if [[ -z "${clients_json}" ]]; then
        FIRST_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
        clients_json=$(jq -n \
            --arg id    "${FIRST_UUID}" \
            --arg email "client@${DOMAIN}" \
            '[{"id": $id, "level": 0, "email": $email}]')
    fi

    mkdir -p "$(dirname "${XRAY_CONF}")"
    # Write to a temp file first so a jq failure never leaves a 0-byte config.
    local _tmp; _tmp=$(mktemp)
    jq -n \
        --argjson clients "${clients_json}" \
        --arg     path    "${WS_PATH}" \
        --argjson port    "${XRAY_INTERNAL_PORT}" \
        '{
          "log": {"loglevel": "warning"},
          "inbounds": [{
            "port": $port, "listen": "127.0.0.1",
            "protocol": "vless",
            "settings": {"clients": $clients, "decryption": "none"},
            "streamSettings": {
              "network": "ws",
              "wsSettings": {"path": $path}
            }
          }],
          "outbounds": [
            {"protocol": "freedom",   "settings": {}, "tag": "direct"},
            {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
          ],
          "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
              {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}
            ]
          }
        }' > "${_tmp}" || { rm -f "${_tmp}"; die "write_xray_config: jq failed to render config."; }
    mv "${_tmp}" "${XRAY_CONF}"
    chmod 644 "${XRAY_CONF}"
}

# =============================================================================
# SECTION 10: Nginx config writer
# =============================================================================
write_nginx_config() {
    local cert_path="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    local key_path="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    local chain_path="/etc/letsencrypt/live/${DOMAIN}/chain.pem"
    local conf="${NGINX_SITES_AVAIL}/${DOMAIN}"

    # nginx < 1.25.1 : http2 is a parameter on the listen directive
    # nginx >= 1.25.1: listen...http2 was deprecated; use standalone "http2 on;"
    # nginx >= 1.27.x: listen...http2 was removed entirely — causes fatal error
    local _ver _maj _min
    _ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "1.18.0")
    _maj=$(cut -d. -f1 <<< "${_ver}")
    _min=$(cut -d. -f2 <<< "${_ver}")
    local h2_listen=" http2" h2_directive=""
    if [[ "${_maj}" -gt 1 ]] || { [[ "${_maj}" -eq 1 ]] && [[ "${_min}" -ge 25 ]]; }; then
        h2_listen=""
        h2_directive="http2 on;"  # heredoc indents this 4 spaces; no leading spaces here
    fi

    cat > "${conf}" <<NGINXEOF
# Managed by xray.sh — do not edit by hand.

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${SERVER_PORT} ssl${h2_listen};
    listen [::]:${SERVER_PORT} ssl${h2_listen};
    ${h2_directive}
    server_name ${DOMAIN};

    ssl_certificate        ${cert_path};
    ssl_certificate_key    ${key_path};
    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers            ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache      shared:SSL:10m;
    ssl_session_timeout    1d;
    ssl_stapling           on;
    ssl_stapling_verify    on;
    ssl_trusted_certificate ${chain_path};
    resolver               1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout       5s;
    add_header             Strict-Transport-Security "max-age=63072000" always;

    root  ${WEBROOT};
    index index.html;

    # Decoy: any browser visitor sees a convincing product site.
    location / {
        try_files \$uri \$uri/ =404;
    }

    # XRAY WebSocket endpoint.
    # A plain HTTP GET to this path returns 400 — not an error page,
    # so it does not hint that anything special is running here.
    location ${WS_PATH} {
        if (\$http_upgrade != "websocket") { return 400; }
        proxy_pass          http://127.0.0.1:${XRAY_INTERNAL_PORT};
        proxy_http_version  1.1;
        proxy_set_header    Upgrade         \$http_upgrade;
        proxy_set_header    Connection      "upgrade";
        proxy_set_header    Host            \$host;
        proxy_set_header    X-Real-IP       \$remote_addr;
        proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
    }
}
NGINXEOF

    ln -sf "${conf}" "${NGINX_SITES_ENABLED}/${DOMAIN}"
}

# =============================================================================
# SECTION 10b: Nginx config writer — reverse proxy mode (plain HTTP)
# =============================================================================
# The upstream reverse proxy terminates TLS. This Nginx speaks plain HTTP on
# LISTEN_PORT. Trusted only because the RP is on the same host or private net.
# DOMAIN is used only as a stable site-file name (set to "xray-rp" by wizard).
write_nginx_config_rp() {
    local conf="${NGINX_SITES_AVAIL}/${DOMAIN}"

    cat > "${conf}" <<NGINXEOF
# Managed by xray.sh (reverse proxy mode) — do not edit by hand.
# TLS is terminated by the upstream reverse proxy.
# This server speaks plain HTTP on ${LISTEN_PORT}.

server {
    listen ${LISTEN_PORT};
    listen [::]:${LISTEN_PORT};
    server_name _;

    root  ${WEBROOT};
    index index.html;

    # Decoy: any visitor sees a convincing product site.
    location / {
        try_files \$uri \$uri/ =404;
    }

    # XRAY WebSocket endpoint.
    # A plain HTTP GET to this path returns 400.
    location ${WS_PATH} {
        if (\$http_upgrade != "websocket") { return 400; }
        proxy_pass          http://127.0.0.1:${XRAY_INTERNAL_PORT};
        proxy_http_version  1.1;
        proxy_set_header    Upgrade         \$http_upgrade;
        proxy_set_header    Connection      "upgrade";
        proxy_set_header    Host            \$host;
        proxy_set_header    X-Real-IP       \$remote_addr;
        proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
    }
}
NGINXEOF

    ln -sf "${conf}" "${NGINX_SITES_ENABLED}/${DOMAIN}"
}

# =============================================================================
# SECTION 11: Industry presets
# =============================================================================
apply_preset() {
    case "$1" in
        cloud)     COMPANY_NAME="Meridian"; COMPANY_TAGLINE="Infrastructure for the modern web. Deploy, scale, and monitor with confidence";    COMPANY_COLOR="#3b82f6" ;;
        api)       COMPANY_NAME="Nexus";    COMPANY_TAGLINE="Connect your services, effortlessly. The API gateway built for scale";             COMPANY_COLOR="#8b5cf6" ;;
        security)  COMPANY_NAME="Vault";    COMPANY_TAGLINE="Zero-trust security for distributed teams. Access without exposure";               COMPANY_COLOR="#10b981" ;;
        analytics) COMPANY_NAME="Prism";    COMPANY_TAGLINE="Turn your data into decisions. Real-time analytics at any scale";                  COMPANY_COLOR="#f59e0b" ;;
        devtools)  COMPANY_NAME="Forge";    COMPANY_TAGLINE="Ship faster with the right tools. CI/CD, previews, and rollbacks built in";        COMPANY_COLOR="#e11d48" ;;
        cdn)       COMPANY_NAME="Strata";   COMPANY_TAGLINE="Global content delivery with edge compute. Fast, everywhere, always";              COMPANY_COLOR="#06b6d4" ;;
    esac
}

# =============================================================================
# SECTION 12b: Install wizard — reverse proxy mode
# =============================================================================
# Shorter wizard: no domain DNS check, no certbot, no email.
# Collects: listen port, RP domain+port (for vless links), WS path, branding.
wizard_install_rp() {
    wt_msg "XRAY Setup — Reverse Proxy Mode" \
"In this mode:

  - Nginx listens on a plain HTTP port you choose
    (e.g. 8080, 8443, or anything free)
  - Your external reverse proxy handles TLS and forwards
    to this server's IP:PORT
  - No certbot or Let's Encrypt is involved

What you need to configure on your reverse proxy:
  - A domain with a TLS certificate
  - A proxy rule forwarding to  <this IP>:<listen port>
  - WebSocket passthrough enabled for the hidden path

The vless:// links generated for clients will use the
domain and port served by your reverse proxy, not this
server's IP.

Press OK to continue." || return 1

    local val

    # ── RP domain and port (what clients will actually connect to) ────────────
    wt_msg "Reverse Proxy Mode — Step 1 of 4: External Domain" \
"This is the domain your reverse proxy serves and the port
clients connect to. It is used in the vless:// link so
clients know where to connect.

It does NOT need to be reachable from this machine.
You can add the DNS entry and RP rule after setup.

  Example domain : cdn.example.com
  Example port   : 443  (standard HTTPS)"

    val=$(wt_input "Step 1 of 4 — RP Domain" \
        "Domain your reverse proxy serves:\n(used in vless:// links, e.g.  cdn.example.com)" \
        "") || return 1
    [[ -z "${val}" ]] && { wt_msg "Error" "Domain cannot be empty."; return 1; }
    RP_DOMAIN="${val}"

    val=$(wt_input "Step 1 of 4 — RP Port" \
        "Port clients connect to at your reverse proxy:" \
        "${RP_PORT}") || return 1
    [[ "${val}" =~ ^[0-9]+$ ]] && RP_PORT="${val}"

    # ── Local listen port ────────────────────────────────────────────────────
    wt_msg "Reverse Proxy Mode — Step 2 of 4: Listen Port" \
"This is the plain HTTP port Nginx will listen on locally.
Your reverse proxy must forward to this port on this machine.

  Default: 8080
  Use any available port above 1024 that nothing else is using.

Check what is already in use:
  ss -tlnp | grep LISTEN"

    val=$(wt_input "Step 2 of 4 — Local Listen Port" \
        "Port this Nginx listens on  (reverse proxy points here):" \
        "${LISTEN_PORT}") || return 1
    [[ "${val}" =~ ^[0-9]+$ ]] && LISTEN_PORT="${val}"

    # XRAY internal port
    val=$(wt_input "Step 2 of 4 — XRAY Internal Port" \
        "Internal port XRAY listens on  (127.0.0.1 only, never exposed):" \
        "${XRAY_INTERNAL_PORT}") || return 1
    [[ "${val}" =~ ^[0-9]+$ ]] && XRAY_INTERNAL_PORT="${val}"

    # Use a fixed site-file name so the rest of the code works unchanged.
    # This is not a real hostname — just a stable key for nginx site files.
    DOMAIN="xray-rp"
    WEBROOT="/var/www/xray-rp"

    # ── WebSocket path ────────────────────────────────────────────────────────
    local rand_ver rand_hex
    rand_ver=$(shuf -i 1-4 -n 1)
    rand_hex=$(tr -d '-' < /proc/sys/kernel/random/uuid | head -c 8)
    local default_path="/api/v${rand_ver}/${rand_hex}"

    wt_msg "Reverse Proxy Mode — Step 3 of 4: WebSocket Path" \
"This is the secret path where XRAY accepts WebSocket connections.

Your reverse proxy must pass WebSocket upgrades to this path
through to this server. Most reverse proxies do this automatically
once you enable WebSocket support on the proxy rule.

A random path is pre-filled. Change it to something that fits
your site's look if you prefer.

  Examples:  /api/v2/stream   /ws/data   /gateway/connect"

    val=$(wt_input "Step 3 of 4 — WebSocket Path" \
        "Secret WebSocket path (must start with /):" "${default_path}") || return 1
    [[ -z "${val}" ]] && val="${default_path}"
    [[ "${val}" != /* ]] && val="/${val}"
    WS_PATH="${val}"

    # ── Decoy branding ────────────────────────────────────────────────────────
    wt_msg "Reverse Proxy Mode — Step 4 of 4: Decoy Website" \
"The server still needs to look like a real company's site
in case anyone probes the listen port directly.

Choose an industry template. All fields are editable after."

    local preset
    preset=$(wt_menu "Step 4 of 4 — Industry Preset" \
        "Choose a starting template  (all fields editable after):" \
        "cloud"     "Cloud Platform      (blue)    Meridian" \
        "api"       "API Gateway         (purple)  Nexus" \
        "security"  "Security Platform   (green)   Vault" \
        "analytics" "Analytics           (amber)   Prism" \
        "devtools"  "Developer Tools     (red)     Forge" \
        "cdn"       "CDN / Edge Network  (cyan)    Strata" \
        "custom"    "Custom              (enter everything yourself)") || return 1
    [[ "${preset}" != "custom" ]] && apply_preset "${preset}"

    val=$(wt_input "Step 4 of 4 — Company Name" \
        "Company name:" "${COMPANY_NAME}") || return 1
    [[ -n "${val}" ]] && COMPANY_NAME="${val}"

    val=$(wt_input "Step 4 of 4 — Tagline" \
        "One-sentence company description:" "${COMPANY_TAGLINE}") || return 1
    [[ -n "${val}" ]] && COMPANY_TAGLINE="${val}"

    val=$(wt_input "Step 4 of 4 — Accent Color" \
        "CSS hex color  (e.g.  #3b82f6):" "${COMPANY_COLOR}") || return 1
    [[ -n "${val}" ]] && COMPANY_COLOR="${val}"

    # ── Confirm ───────────────────────────────────────────────────────────────
    wt_yesno "Reverse Proxy Mode — Confirm" \
"Review before installation:

  Mode             Reverse proxy  (no certbot)
  RP domain        ${RP_DOMAIN}
  RP port          ${RP_PORT}
  Listen port      ${LISTEN_PORT}  (Nginx plain HTTP)
  XRAY int. port   ${XRAY_INTERNAL_PORT}
  WebSocket path   ${WS_PATH}

  Company name     ${COMPANY_NAME}
  Accent color     ${COMPANY_COLOR}

Reverse proxy rule needed after setup:
  Forward  ${RP_DOMAIN}  ->  <this IP>:${LISTEN_PORT}
  WebSocket passthrough: enabled
  Path prefix: ${WS_PATH}  (or all paths)

Proceed?" || return 1
}


# =============================================================================
# SECTION 12: Install wizard
# =============================================================================
wizard_install() {
    # ── Mode selection ────────────────────────────────────────────────────────
    local mode
    mode=$(wt_menu "XRAY Setup — Choose Mode" \
        "How will TLS be handled for this installation?" \
        "standalone"     "Standalone  —  this server owns TLS (certbot + Let's Encrypt)" \
        "reverse_proxy"  "Reverse Proxy  —  upstream RP owns TLS, Nginx serves plain HTTP") \
        || return 1

    SETUP_MODE="${mode}"

    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        wizard_install_rp
        return $?
    fi

    # ── Standalone mode ───────────────────────────────────────────────────────
    # ── Step 1: Domain & email ────────────────────────────────────────────────
    wt_msg "XRAY Setup Wizard — Standalone" \
"This wizard configures:

  - Nginx serving HTTPS on your domain
  - A decoy tech-company website at /
  - XRAY (VLESS over WebSocket) at a hidden path
  - Auto-renewing TLS certificate via Let's Encrypt

Your domain's A record must already point to this server.

Press OK to begin." || return 1

    local val
    val=$(wt_input "Step 1 of 5 - Domain" \
        "Domain name pointing to this server:\n(e.g.  cdn.example.com)" "") || return 1
    [[ -z "${val}" ]] && { wt_msg "Error" "Domain cannot be empty."; return 1; }
    DOMAIN="${val}"

    val=$(wt_input "Step 1 of 5 - Email" \
        "Email address (for Let's Encrypt expiry notices):" "") || return 1
    [[ -z "${val}" ]] && { wt_msg "Error" "Email cannot be empty."; return 1; }
    EMAIL="${val}"

    # ── Step 1b: ACME challenge method ────────────────────────────────────────
    local acme_choice
    acme_choice=$(wt_menu "Step 1 of 5 - Certificate Method" \
        "How should Let's Encrypt verify domain ownership?" \
        "http01" "HTTP-01   (default)  — port 80 must be open, no API key needed" \
        "dns01"  "DNS-01   (advanced) — no open ports, works behind CDN/firewall") \
        || return 1
    ACME_METHOD="${acme_choice}"

    if [[ "${ACME_METHOD}" == "dns01" ]]; then
        wizard_dns_provider || return 1
    fi

    # ── Step 2: Ports ─────────────────────────────────────────────────────────
    wt_msg "Step 2 of 5 - Port Settings" \
"Defaults work for almost every setup.

  HTTPS Port (443):     The port clients connect to. Changing
                        this from 443 makes traffic stand out.

  XRAY Internal Port:   Where XRAY listens on 127.0.0.1 only.
                        Never exposed externally. Change only
                        if something else is using that port."

    val=$(wt_input "Step 2 of 5 - HTTPS Port" \
        "Port Nginx listens on (clients connect here):" "${SERVER_PORT}") || return 1
    [[ "${val}" =~ ^[0-9]+$ ]] && SERVER_PORT="${val}"

    val=$(wt_input "Step 2 of 5 - XRAY Internal Port" \
        "Internal port XRAY listens on (127.0.0.1 only):" "${XRAY_INTERNAL_PORT}") || return 1
    [[ "${val}" =~ ^[0-9]+$ ]] && XRAY_INTERNAL_PORT="${val}"

    # ── Step 3: WebSocket path ────────────────────────────────────────────────
    local rand_ver rand_hex
    rand_ver=$(shuf -i 1-4 -n 1)
    rand_hex=$(tr -d '-' < /proc/sys/kernel/random/uuid | head -c 8)
    local default_path="/api/v${rand_ver}/${rand_hex}"

    wt_msg "Step 3 of 5 - WebSocket Path" \
"This is the secret URL path where XRAY accepts connections.
It should look like a plausible API endpoint.

A random path is pre-filled. Change it to match your decoy
company's style if you want.

  Examples:  /api/v2/stream   /ws/upload   /gateway/sync

A plain HTTP GET to this path returns 400 Bad Request —
not an error banner — so it does not reveal XRAY is here."

    val=$(wt_input "Step 3 of 5 - WebSocket Path" \
        "Secret WebSocket path (must start with /):" "${default_path}") || return 1
    [[ -z "${val}" ]] && val="${default_path}"
    [[ "${val}" != /* ]] && val="/${val}"
    WS_PATH="${val}"

    # ── Step 4: Decoy website ─────────────────────────────────────────────────
    wt_msg "Step 4 of 5 - Decoy Website" \
"The server needs to look like a real company's site so any
casual visitor or security scanner sees a tech firm.

Choose an industry template. The company name, tagline, and
accent color are all editable after you select a preset."

    local preset
    preset=$(wt_menu "Step 4 of 5 - Industry Preset" \
        "Choose a starting template  (all fields editable after):" \
        "cloud"     "Cloud Platform      (blue)    Meridian" \
        "api"       "API Gateway         (purple)  Nexus" \
        "security"  "Security Platform   (green)   Vault" \
        "analytics" "Analytics           (amber)   Prism" \
        "devtools"  "Developer Tools     (red)     Forge" \
        "cdn"       "CDN / Edge Network  (cyan)    Strata" \
        "custom"    "Custom              (enter everything yourself)") || return 1
    [[ "${preset}" != "custom" ]] && apply_preset "${preset}"

    val=$(wt_input "Step 4 of 5 - Company Name" \
        "Company name shown in the nav bar and footer:" "${COMPANY_NAME}") || return 1
    [[ -n "${val}" ]] && COMPANY_NAME="${val}"

    val=$(wt_input "Step 4 of 5 - Tagline" \
        "One-sentence company description (hero section):" "${COMPANY_TAGLINE}") || return 1
    [[ -n "${val}" ]] && COMPANY_TAGLINE="${val}"

    val=$(wt_input "Step 4 of 5 - Accent Color" \
        "CSS hex color for buttons and logo:\n(e.g.  #3b82f6  #8b5cf6  #10b981  #e11d48)" \
        "${COMPANY_COLOR}") || return 1
    [[ -n "${val}" ]] && COMPANY_COLOR="${val}"

    WEBROOT="/var/www/${DOMAIN}"

    # ── Step 5: Confirm ───────────────────────────────────────────────────────
    local _acme_display="${ACME_METHOD}"
    [[ "${ACME_METHOD}" == "dns01" ]] && _acme_display="DNS-01 (${DNS_PROVIDER})"
    [[ "${ACME_METHOD}" == "http01" ]] && _acme_display="HTTP-01 (port 80)"

    wt_yesno "Step 5 of 5 - Confirm" \
"Review before installation:

  Domain           ${DOMAIN}
  Email            ${EMAIL}
  Cert method      ${_acme_display}
  HTTPS port       ${SERVER_PORT}
  XRAY int. port   ${XRAY_INTERNAL_PORT}
  WebSocket path   ${WS_PATH}

  Company name     ${COMPANY_NAME}
  Tagline          ${COMPANY_TAGLINE}
  Accent color     ${COMPANY_COLOR}
  Web root         /var/www/${DOMAIN}

Proceed?" || return 1
}

# install_xray_binary — downloads and installs the XRAY binary directly
# from the XTLS GitHub release zip without invoking the official installer
# script, which requires systemd and therefore fails inside Docker containers.
#
# What this does (mirrors what the official installer does, minus systemd):
#   1. Detect CPU architecture and map it to the release zip name
#   2. Download Xray-linux-<arch>.zip from the latest GitHub release
#   3. Extract the xray binary to /usr/local/bin/xray
#   4. Extract geoip.dat and geosite.dat to /usr/local/share/xray/
#   5. Set permissions
#
# The systemd service unit is intentionally NOT created. In Docker the
# entrypoint manages xray directly; on bare-metal/VM the svc_* wrappers
# fall back to _svc_direct_start which runs the binary as a background job.
install_xray_binary() {
    log "Installing XRAY binary from GitHub releases..."

    # -- Resolve architecture --------------------------------------------------
    local _arch; _arch=$(uname -m)
    local _zip_name
    case "${_arch}" in
        x86_64)          _zip_name="Xray-linux-64.zip" ;;
        aarch64|arm64)   _zip_name="Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7)    _zip_name="Xray-linux-arm32-v7a.zip" ;;
        armv6l)          _zip_name="Xray-linux-arm32-v6.zip" ;;
        *) die "install_xray_binary: unsupported architecture '${_arch}'." ;;
    esac

    local _url="${XRAY_RELEASE_BASE}/${_zip_name}"
    local _tmp_zip; _tmp_zip=$(mktemp --suffix=.zip)
    local _tmp_dir; _tmp_dir=$(mktemp -d)

    log "Downloading ${_url}..."
    curl -fsSL --retry 3 -o "${_tmp_zip}" "${_url}" \
        || { rm -f "${_tmp_zip}"; rm -rf "${_tmp_dir}"; die "Failed to download XRAY release zip from GitHub."; }

    # -- Extract ---------------------------------------------------------------
    # unzip is not installed by default on Debian slim; use python3 which is.
    python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "${_tmp_zip}" "${_tmp_dir}" \
        || { rm -f "${_tmp_zip}"; rm -rf "${_tmp_dir}"; die "Failed to extract XRAY zip."; }

    rm -f "${_tmp_zip}"

    # -- Install binary --------------------------------------------------------
    [[ -f "${_tmp_dir}/xray" ]] \
        || die "xray binary not found in release zip. Unexpected archive layout."
    install -m 755 "${_tmp_dir}/xray" "${XRAY_BIN}"
    log "XRAY binary installed at ${XRAY_BIN}."

    # -- Install geo data files ------------------------------------------------
    mkdir -p "${XRAY_DAT_DIR}"
    for _dat in geoip.dat geosite.dat; do
        if [[ -f "${_tmp_dir}/${_dat}" ]]; then
            install -m 644 "${_tmp_dir}/${_dat}" "${XRAY_DAT_DIR}/${_dat}"
            log "${_dat} installed at ${XRAY_DAT_DIR}/${_dat}."
        else
            warn "${_dat} not found in release zip — skipping."
        fi
    done

    rm -rf "${_tmp_dir}"
    log "XRAY installation complete  ($(${XRAY_BIN} version 2>/dev/null | head -1 || echo 'version unknown'))"
}

# remove_xray_binary — reverses install_xray_binary
remove_xray_binary() {
    pkill -x xray 2>/dev/null || true
    rm -f  "${XRAY_BIN}"
    rm -rf "${XRAY_DAT_DIR}"
    rm -rf /usr/local/etc/xray
    log "XRAY binary and data files removed."
}

# =============================================================================
# SECTION 13: Install execution
# =============================================================================
install_base_deps() {
    log "Updating package lists..."
    $PKG_MGR update -qq -y
    log "Installing packages: nginx, certbot, jq, uuid-runtime, qrencode, psmisc..."
    $PKG_MGR install -y -qq \
        nginx certbot \
        curl uuid-runtime python3 jq qrencode psmisc
    # apt post-install may have tried to start nginx and failed, or started
    # another web server (apache2). Stop and disable apache2 if present so
    # it does not hold ports 80/443 when we start nginx.
    if command -v apache2 &>/dev/null || (_has_systemd && systemctl list-units --type=service 2>/dev/null | grep -q apache2); then
        log "apache2 detected — stopping and disabling it..."
        svc_stop apache2 2>/dev/null || true
        svc_disable apache2 2>/dev/null || true
    fi
}

# clear_port PORT
# Kills any process holding PORT so nginx can bind. Uses fuser when available,
# falls back to ss + kill. Logs what it kills so the user has an audit trail.
clear_port() {
    local port="$1"
    local pids
    if command -v fuser &>/dev/null; then
        pids=$(fuser "${port}/tcp" 2>/dev/null || true)
        if [[ -n "${pids}" ]]; then
            log "Port ${port} occupied by PID(s): ${pids} — stopping them..."
            fuser -k "${port}/tcp" 2>/dev/null || true
            sleep 1
        fi
    elif command -v ss &>/dev/null; then
        pids=$(ss -tlnp "sport = :${port}" 2>/dev/null \
            | grep -oP 'pid=\K[0-9]+' || true)
        for pid in ${pids}; do
            log "Port ${port} occupied by PID ${pid} — killing..."
            kill "${pid}" 2>/dev/null || true
        done
        [[ -n "${pids}" ]] && sleep 1
    fi
}

# check_port_free PORT
# Dies with a clear message if anything is still bound to PORT after
# clear_port has already run. Prevents nginx from failing to bind silently.
check_port_free() {
    local port="$1"
    local bound=""  # initialize so set -u does not fire if neither ss nor netstat found
    if command -v ss &>/dev/null; then
        bound=$(ss -tlnH "sport = :${port}" 2>/dev/null | head -1)
    elif command -v netstat &>/dev/null; then
        bound=$(netstat -tlnp 2>/dev/null | awk -v p=":${port} " '$4 ~ p' | head -1)
    fi
    if [[ -n "${bound}" ]]; then
        die "Port ${port} is still in use after attempting to clear it.\n  Check: ss -tlnp | grep ':${port}'\n  Then re-run this script."
    fi
}

do_install() {
    clear
    log "Starting installation  (mode: ${SETUP_MODE})..."

    # ── Free ports before nginx starts ────────────────────────────────────────
    svc_stop nginx  2>/dev/null || true
    svc_stop apache2 2>/dev/null || true
    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        clear_port "${LISTEN_PORT}"
        check_port_free "${LISTEN_PORT}"
    else
        clear_port 80
        check_port_free 80
        clear_port 443
        check_port_free 443
    fi

    # ── Open firewall ports ───────────────────────────────────────────────────
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
            log "ufw active — opening ${LISTEN_PORT} (plain HTTP for RP mode)..."
            ufw allow "${LISTEN_PORT}/tcp" > /dev/null
        else
            log "ufw active — opening 80 and 443..."
            ufw allow 80/tcp  > /dev/null
            ufw allow 443/tcp > /dev/null
        fi
    fi

    rm -f "${NGINX_SITES_ENABLED}/default" 2>/dev/null || true
    mkdir -p "${WEBROOT}"

    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        # ── Reverse proxy install path: no certbot ────────────────────────────
        log "Writing Nginx config (plain HTTP on port ${LISTEN_PORT})..."
        write_nginx_config_rp; nginx -t
        svc_enable nginx; svc_restart nginx

        log "Installing XRAY..."
        install_xray_binary

        log "Writing XRAY config..."
        FIRST_UUID=""
        write_xray_config

        log "Generating decoy website..."
        generate_decoy_site

        nginx -t; svc_reload nginx

    else
        # ── Standalone install path ────────────────────────────────────────────
        if [[ "${ACME_METHOD}" == "dns01" ]]; then
            # ── DNS-01 path: no port 80 required ─────────────────────────────
            # Install the certbot DNS plugin for the chosen provider, then
            # obtain the cert. Nginx is not involved in cert issuance at all.
            install_dns_plugin "${DNS_PROVIDER}"

            log "Obtaining TLS certificate via DNS-01 (provider: ${DNS_PROVIDER})..."
            run_certbot_dns "${DOMAIN}" "${EMAIL}" \
                || die "certbot DNS-01 failed. See output above.
Common causes:
  - API token/key is wrong or lacks DNS write permission
  - DNS record did not propagate within 60s (try again)
  - Manual mode: TXT record was not added in time"

            [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] \
                || die "Certificate files missing after certbot. Check /var/log/letsencrypt/letsencrypt.log"

        else
            # ── HTTP-01 path (default): webroot via port 80 ───────────────────
            #
            # We use certbot certonly --webroot (NOT --nginx).
            # certbot --nginx modifies nginx config in place; on re-run its
            # baked-in HTTPS redirects break the HTTP-01 challenge. --webroot
            # only drops a file under WEBROOT and never touches nginx config.

            log "Configuring nginx for ACME HTTP-01 challenge (plain HTTP)..."
            mkdir -p "${WEBROOT}/.well-known/acme-challenge"
            cat > "${NGINX_SITES_AVAIL}/${DOMAIN}" <<EOF
# Plain HTTP — used only for Let's Encrypt ACME challenge.
# Replaced with the full TLS config after certbot succeeds.
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEBROOT};
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
EOF
            ln -sf "${NGINX_SITES_AVAIL}/${DOMAIN}" "${NGINX_SITES_ENABLED}/${DOMAIN}"
            nginx -t
            svc_enable nginx
            svc_start nginx

            # Verify port 80 is externally reachable before certbot runs.
            # Set SKIP_PORT_CHECK=true to bypass (use when running in Docker
            # or behind a NAT that does not support hairpin loopback).
            if [[ "${SKIP_PORT_CHECK:-false}" == "true" ]]; then
                warn "SKIP_PORT_CHECK=true — skipping external port-80 check."
                warn "Ensure port 80 on ${DOMAIN} is publicly reachable before certbot runs."
            else
                log "Verifying port 80 is reachable from the internet..."
                local _token="xray-probe-$$"
                echo "${_token}" > "${WEBROOT}/.well-known/acme-challenge/${_token}"
                local _got
                _got=$(curl -fsS --max-time 10 "http://${DOMAIN}/.well-known/acme-challenge/${_token}" 2>/dev/null || true)
                rm -f "${WEBROOT}/.well-known/acme-challenge/${_token}"
                if [[ "${_got}" != "${_token}" ]]; then
                    die "Port 80 on ${DOMAIN} is not reachable from the internet.
  Let's Encrypt cannot complete the HTTP-01 challenge.
  Ensure DNS points to this server and port 80 is open in your firewall."
                fi
                log "Port 80 reachability confirmed."
            fi

            log "Requesting TLS certificate from Let's Encrypt (HTTP-01)..."
            certbot certonly \
                --webroot \
                --webroot-path "${WEBROOT}" \
                -d "${DOMAIN}" \
                --non-interactive \
                --agree-tos \
                -m "${EMAIL}"

            [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] \
                || die "Certificate not found after certbot. Check DNS and that port 80 is reachable."
        fi

        log "Installing XRAY..."
        install_xray_binary

        log "Writing XRAY config..."
        FIRST_UUID=""
        write_xray_config

        log "Generating decoy website..."
        generate_decoy_site

        # Write the full TLS nginx config now that the certificate exists.
        log "Writing final Nginx config (TLS)..."
        write_nginx_config
        nginx -t
        svc_enable nginx
        svc_restart nginx

        # certbot systemd timer for auto-renewal (systemd only, no-op in containers)
        if _has_systemd; then
            systemctl enable certbot.timer 2>/dev/null \
                && systemctl start certbot.timer 2>/dev/null || true
        fi
    fi

    # ── Start XRAY (same for both modes) ─────────────────────────────────────
    log "Starting XRAY..."
    svc_daemon_reload
    svc_enable xray
    svc_restart xray
    sleep 2

    svc_is_active xray  || die "XRAY failed to start.
  systemd:     journalctl -u xray -n 50
  non-systemd: ${XRAY_BIN} run -config ${XRAY_CONF}"
    svc_is_active nginx || die "Nginx not running. Check: journalctl -u nginx -n 50"

    save_state

    # Save first client link to a file
    local first_link; first_link=$(build_vless_link "${FIRST_UUID}")
    echo "${first_link}" > "${STATE_DIR}/client1.txt"
    chmod 600 "${STATE_DIR}/client1.txt"

    # ── Post-install summary ──────────────────────────────────────────────────
    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        wt_msg "Installation Complete — Reverse Proxy Mode" \
"XRAY is running and ready.

  Mode            : Reverse proxy  (no certbot)
  RP domain       : ${RP_DOMAIN}
  RP port         : ${RP_PORT}
  Nginx listens   : 0.0.0.0:${LISTEN_PORT}  (plain HTTP)
  XRAY internal   : 127.0.0.1:${XRAY_INTERNAL_PORT}
  WebSocket path  : ${WS_PATH}
  UUID (client 1) : ${FIRST_UUID}

Next step — configure your reverse proxy:
  Forward domain  : ${RP_DOMAIN}
  Upstream target : <this server IP>:${LISTEN_PORT}
  WebSocket       : enabled / upgrade headers required

The connection link will be shown on the next screen."
    else
        wt_msg "Installation Complete — Standalone" \
"XRAY is running and ready.

  Domain    : ${DOMAIN}
  Port      : ${SERVER_PORT}
  Protocol  : VLESS / WebSocket / TLS
  Path      : ${WS_PATH}
  UUID      : ${FIRST_UUID}

The connection link will be shown on the next screen so you
can select and copy it before doing anything else.

After that, the client guide will walk you through connecting
your first device — phone, laptop, or anything else."
    fi

    print_link "Client 1  —  client@${DOMAIN}" "${first_link}"

    wt_msg "What's Next: Connecting a Device" \
"The server is running. Now you need a client app on the
device you want to route through it.

The next section is a built-in guide covering every platform:

  - Linux  (config generator — paste your link, get config.json)
  - Clash Verge  (GUI for Linux, Windows, macOS — YAML generator)
  - Windows  (v2rayN, Hiddify)
  - macOS  (Clash Verge, V2Box, Hiddify)
  - Android  (v2rayNG — full walkthrough + QR scan)
  - iOS  (Shadowrocket, V2Box, Hiddify)

You can return to this guide at any time from:
  Main menu  ->  Connect a Device"

    client_guide_menu
}

# =============================================================================
# SECTION 14: Server management — clients
# =============================================================================
mgmt_client_list() {
    if [[ ! -f "${XRAY_CONF}" ]]; then
        wt_msg "Error" "XRAY config not found at ${XRAY_CONF}.\nRun a fresh install first."
        return 1
    fi

    local clients_json count
    clients_json=$(jq '.inbounds[0].settings.clients' "${XRAY_CONF}" 2>/dev/null) || {
        wt_msg "Error" "Could not read XRAY config.\nThe file may be corrupted.\n\nCheck: cat ${XRAY_CONF}"
        return 1
    }
    if [[ "${clients_json}" == "null" || -z "${clients_json}" ]]; then
        wt_msg "No Clients" "No clients found in the XRAY config."
        return 0
    fi
    count=$(echo "${clients_json}" | jq 'length')

    wt_msg "Clients — ${count} active" \
"Each client's link will be shown in the terminal one at a
time so you can select and copy it.

Press Enter after each link to advance to the next one.

You can also generate a QR code from the client guide:
  Main menu -> Connect a Device -> Show QR Code"

    local i=0
    while read -r _; do
        local uuid email link
        uuid=$(echo  "${clients_json}" | jq -r ".[${i}].id")
        email=$(echo "${clients_json}" | jq -r ".[${i}].email")
        link=$(build_vless_link "${uuid}" "${email}")
        print_link "Client $((i+1)) of ${count}  —  ${email}" "${link}"
        (( i++ )) || true
    done < <(echo "${clients_json}" | jq -c '.[]')
    # Explicit pause after all clients so the last link isn't swept away
    # when the management menu redraws.
    echo ""
    read -r -p "  All ${count} client(s) shown. Press Enter to return to menu..." </dev/tty
}

mgmt_client_add() {
    local label
    label=$(wt_input "Add Client — Label" \
        "Enter a label for this client.\n\nThis is for your reference only — not visible in TLS traffic.\nExamples:  phone  alice  work-laptop  tablet" \
        "user$(date +%s | tail -c 4)") || return 0
    [[ -z "${label}" ]] && label="client$(date +%s | tail -c 4)"
    # Sanitize: keep only alphanumerics, dots, underscores, hyphens.
    # The label is used as the email field in XRAY config and as a
    # key for removal, so spaces or @ signs would corrupt that logic.
    label="${label//[^a-zA-Z0-9._-]/-}"

    local new_uuid; new_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local tmp; tmp=$(mktemp)
    jq --arg id    "${new_uuid}" \
       --arg email "${label}@${DOMAIN}" \
       '.inbounds[0].settings.clients += [{"id": $id, "level": 0, "email": $email}]' \
       "${XRAY_CONF}" > "${tmp}" \
       || { rm -f "${tmp}"; die "Failed to update XRAY config. Check: jq . ${XRAY_CONF}"; }
    mv "${tmp}" "${XRAY_CONF}"
    chmod 644 "${XRAY_CONF}"

    svc_restart xray; sleep 1

    local link; link=$(build_vless_link "${new_uuid}" "${label}@${DOMAIN}")
    wt_msg "Client Added" \
"New client created and XRAY restarted.

  Label : ${label}@${DOMAIN}
  UUID  : ${new_uuid}

The link will be shown on the next screen.
Use the client guide to share it with a device:
  Main menu -> Connect a Device"

    print_link "${label}@${DOMAIN}" "${link}"
}

mgmt_client_remove() {
    local clients_json count
    clients_json=$(jq '.inbounds[0].settings.clients' "${XRAY_CONF}")
    count=$(echo "${clients_json}" | jq 'length')

    if [[ "${count}" -le 1 ]]; then
        wt_msg "Cannot Remove" \
"There is only one client and it cannot be removed.

Add a replacement client first, then remove this one."
        return 0
    fi

    local items=() i=0
    while read -r _; do
        local email; email=$(echo "${clients_json}" | jq -r ".[${i}].email")
        items+=( "${email}" "${email}" "OFF" )
        (( i++ )) || true
    done < <(echo "${clients_json}" | jq -c '.[]')

    local selected
    selected=$(wt_checklist "Remove Clients" \
        "Choose which clients to remove. Type a number to toggle, Enter to confirm:" "${items[@]}") || return 0
    [[ -z "${selected}" ]] && { wt_msg "Nothing Selected" "No changes made."; return 0; }

    wt_yesno "Confirm Removal" \
"Remove the selected client(s)?\n\n${selected}\n\nThis immediately revokes their access." || return 0

    local to_remove; to_remove=$(echo "${selected}" | tr -d '"')
    for email in ${to_remove}; do
        local tmp; tmp=$(mktemp)
        jq --arg e "${email}" \
           '.inbounds[0].settings.clients = [.inbounds[0].settings.clients[] | select(.email != $e)]' \
           "${XRAY_CONF}" > "${tmp}" \
           || { rm -f "${tmp}"; die "Failed to update XRAY config while removing ${email}."; }
        mv "${tmp}" "${XRAY_CONF}"
        chmod 644 "${XRAY_CONF}"
    done

    svc_restart xray; sleep 1
    wt_msg "Removed" "Removed: ${to_remove}\n\nXRAY restarted. Those clients can no longer connect."
}

mgmt_clients() {
    while true; do
        local choice
        choice=$(wt_menu "Manage Clients" \
            "Each client has a unique UUID and its own vless:// link." \
            "list"   "List all clients and show their connection links" \
            "add"    "Add a new client" \
            "remove" "Remove client(s) — revokes access immediately" \
            "back"   "Back") || return 0
        case "${choice}" in
            list)   mgmt_client_list ;;
            add)    mgmt_client_add  ;;
            remove) mgmt_client_remove ;;
            back)   return 0 ;;
        esac
    done
}

# =============================================================================
# SECTION 15: Server management — change WebSocket path
# =============================================================================
mgmt_change_path() {
    local rand_ver rand_hex suggest
    rand_ver=$(shuf -i 1-4 -n 1)
    rand_hex=$(tr -d '-' < /proc/sys/kernel/random/uuid | head -c 8)
    suggest="/api/v${rand_ver}/${rand_hex}"

    local new_path
    new_path=$(wt_input "Change WebSocket Path" \
        "Current path: ${WS_PATH}\n\nA new random path is pre-filled. Type your own if preferred.\nAll existing clients break until they import the new link." \
        "${suggest}") || return 0
    [[ -z "${new_path}" ]] && { wt_msg "Error" "Path cannot be empty."; return 0; }
    [[ "${new_path}" != /* ]] && new_path="/${new_path}"

    wt_yesno "Confirm Path Change" \
"Change the WebSocket path?

  Old : ${WS_PATH}
  New : ${new_path}

ALL active clients will be broken until they update their
import links. New links will be shown after the change." || return 0

    local tmp; tmp=$(mktemp)
    jq --arg p "${new_path}" \
       '.inbounds[0].streamSettings.wsSettings.path = $p' \
       "${XRAY_CONF}" > "${tmp}" \
       || { rm -f "${tmp}"; die "Failed to update XRAY config with new path."; }
    mv "${tmp}" "${XRAY_CONF}"
    chmod 644 "${XRAY_CONF}"

    WS_PATH="${new_path}"
    save_state
    # Write the correct nginx config for the current mode before testing.
    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        write_nginx_config_rp
    else
        write_nginx_config
    fi
    nginx -t
    svc_reload nginx
    svc_restart xray; sleep 1

    local clients_json; clients_json=$(jq '.inbounds[0].settings.clients' "${XRAY_CONF}")
    local count; count=$(echo "${clients_json}" | jq 'length')

    wt_msg "Path Changed" \
"Path updated to: ${new_path}

${count} client link(s) will be shown in the terminal so you
can copy and redistribute them to affected clients."

    local i=0
    while read -r _; do
        local uuid email link
        uuid=$(echo  "${clients_json}" | jq -r ".[${i}].id")
        email=$(echo "${clients_json}" | jq -r ".[${i}].email")
        link=$(build_vless_link "${uuid}" "${email}")
        print_link "Client $((i+1)) of ${count}  —  ${email}  (NEW PATH)" "${link}"
        (( i++ )) || true
    done < <(echo "${clients_json}" | jq -c '.[]')
}

# =============================================================================
# SECTION 16: Server management — branding
# =============================================================================
mgmt_branding() {
    # Compute the URL used to verify the decoy site after branding changes.
    # In RP mode DOMAIN is "xray-rp" (internal key), so use the real RP domain.
    local _brand_url
    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        _brand_url="https://${RP_DOMAIN}"
    else
        _brand_url="https://${DOMAIN}"
    fi
    while true; do
        local choice
        choice=$(wt_menu "Update Website Branding" \
            "Current: \"${COMPANY_NAME}\" | ${COMPANY_COLOR}" \
            "name"    "Change company name" \
            "tagline" "Change tagline / description" \
            "color"   "Change accent color (CSS hex)" \
            "preset"  "Apply a new industry preset" \
            "all"     "Edit name, tagline, and color together" \
            "preview" "Show current values" \
            "back"    "Save and go back") || break

        local val
        case "${choice}" in
            name)
                val=$(wt_input "Company Name" "New company name:" "${COMPANY_NAME}") || continue
                [[ -n "${val}" ]] && COMPANY_NAME="${val}" ;;
            tagline)
                val=$(wt_input "Tagline" "New one-line company description:" "${COMPANY_TAGLINE}") || continue
                [[ -n "${val}" ]] && COMPANY_TAGLINE="${val}" ;;
            color)
                val=$(wt_input "Accent Color" \
                    "CSS hex color for buttons and logo:\n(e.g.  #3b82f6  #8b5cf6  #10b981  #e11d48)" \
                    "${COMPANY_COLOR}") || continue
                [[ -n "${val}" ]] && COMPANY_COLOR="${val}" ;;
            preset)
                local p
                p=$(wt_menu "Apply Preset" "Choose a new industry preset:" \
                    "cloud"     "Cloud Platform    (blue)    Meridian" \
                    "api"       "API Gateway       (purple)  Nexus" \
                    "security"  "Security          (green)   Vault" \
                    "analytics" "Analytics         (amber)   Prism" \
                    "devtools"  "Developer Tools   (red)     Forge" \
                    "cdn"       "CDN / Edge        (cyan)    Strata") || continue
                apply_preset "${p}" ;;
            all)
                val=$(wt_input "Branding - Name"    "Company name:"  "${COMPANY_NAME}")    || continue
                [[ -n "${val}" ]] && COMPANY_NAME="${val}"
                val=$(wt_input "Branding - Tagline" "Tagline:"       "${COMPANY_TAGLINE}") || continue
                [[ -n "${val}" ]] && COMPANY_TAGLINE="${val}"
                val=$(wt_input "Branding - Color"   "CSS hex color:" "${COMPANY_COLOR}")   || continue
                [[ -n "${val}" ]] && COMPANY_COLOR="${val}" ;;
            preview)
                wt_msg "Current Branding" \
"  Name    : ${COMPANY_NAME}
  Tagline : ${COMPANY_TAGLINE}
  Color   : ${COMPANY_COLOR}
  URL     : ${_brand_url}"
                continue ;;
            back) break ;;
        esac

        if [[ "${choice}" != "preview" && "${choice}" != "back" ]]; then
            generate_decoy_site; save_state; svc_reload nginx
            wt_msg "Branding Updated" "Website regenerated.\n\nVisit ${_brand_url} to verify."
        fi
    done
}

# =============================================================================
# SECTION 17: Server management — status
# =============================================================================
mgmt_status() {
    local xray_st nginx_st client_count

    xray_st=$(svc_is_active xray  && echo "active" || echo "inactive")
    nginx_st=$(svc_is_active nginx && echo "active" || echo "inactive")
    client_count=$(jq '.inbounds[0].settings.clients | length' "${XRAY_CONF}" 2>/dev/null || echo "?")

    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        wt_msg "Server Status — Reverse Proxy Mode" \
"Services
  XRAY   : ${xray_st}
  Nginx  : ${nginx_st}

Mode: Reverse proxy  (TLS handled upstream)
  RP domain       : ${RP_DOMAIN}
  RP port         : ${RP_PORT}
  Nginx listens   : 0.0.0.0:${LISTEN_PORT}  (plain HTTP)

XRAY
  Clients       : ${client_count}
  WS path       : ${WS_PATH}
  Internal port : ${XRAY_INTERNAL_PORT}

Config paths
  XRAY   : ${XRAY_CONF}
  Nginx  : ${NGINX_SITES_AVAIL}/${DOMAIN}
  State  : ${STATE_FILE}

Logs (run in terminal)
  journalctl -u xray  -f
  journalctl -u nginx -f"
    else
        local cert_expiry
        local cert_file="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        if [[ -f "${cert_file}" ]]; then
            cert_expiry=$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null \
                | sed 's/notAfter=//' || echo "unknown")
        else
            cert_expiry="certificate not found"
        fi

        wt_msg "Server Status — Standalone" \
"Services
  XRAY   : ${xray_st}
  Nginx  : ${nginx_st}

TLS Certificate
  Domain  : ${DOMAIN}
  Expires : ${cert_expiry}

XRAY
  Clients       : ${client_count}
  WS path       : ${WS_PATH}
  Internal port : ${XRAY_INTERNAL_PORT}

Config paths
  XRAY   : ${XRAY_CONF}
  Nginx  : ${NGINX_SITES_AVAIL}/${DOMAIN}
  State  : ${STATE_FILE}

Logs (run in terminal)
  journalctl -u xray  -f
  journalctl -u nginx -f"
    fi
}

# =============================================================================
# SECTION 18: Server management — cert renewal
# =============================================================================
mgmt_renew_cert() {
    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        wt_msg "Renew TLS — Not Applicable" \
"This installation runs in reverse proxy mode.

TLS certificates are managed by your upstream reverse proxy,
not by this server. Renew the certificate there.

This option does nothing in reverse proxy mode."
        return 0
    fi

    wt_yesno "Renew Certificate" \
"Force-renew the TLS certificate for ${DOMAIN}?

Certificates auto-renew via the certbot systemd timer
(systemd hosts only — check with: systemctl list-timers | grep certbot).
Only force-renew if auto-renewal is not working." || return 0

    clear
    log "Running: certbot renew --force-renewal --cert-name ${DOMAIN}"
    certbot renew --force-renewal --cert-name "${DOMAIN}" || true
    svc_reload nginx
    wt_msg "Renewal Attempted" \
"Check the terminal output above for results.

Note: certbot exits 0 even when renewal was skipped
because the cert was not near expiry yet."
}

# =============================================================================
# SECTION 19: Server management — uninstall
# =============================================================================
mgmt_uninstall() {
    local cert_note
    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        cert_note="  - TLS certificate  (managed by your reverse proxy, not here)"
    else
        cert_note="  - TLS certificate  (stays in /etc/letsencrypt)"
    fi

    wt_yesno "Uninstall — Step 1 of 2" \
"The following will be PERMANENTLY removed:
  - XRAY binary, config, and systemd service
  - Nginx site config for ${DOMAIN}
  - Website files at ${WEBROOT}
  - Setup state at ${STATE_DIR}

NOT removed:
  - Nginx itself (may serve other sites)
${cert_note}

This cannot be undone." || return 0

    wt_yesno "Uninstall — Step 2 of 2" \
"Last chance. Permanently remove XRAY?" || return 0

    clear
    log "Stopping XRAY..."
    svc_stop xray; svc_disable xray

    log "Removing XRAY binary and data files..."
    remove_xray_binary

    log "Removing Nginx site config..."
    rm -f "${NGINX_SITES_ENABLED}/${DOMAIN}" 2>/dev/null || true
    rm -f "${NGINX_SITES_AVAIL}/${DOMAIN}"   2>/dev/null || true
    svc_reload nginx 2>/dev/null || true

    log "Removing web root..."; rm -rf "${WEBROOT}" 2>/dev/null || true
    log "Removing state...";    rm -rf "${STATE_DIR}" 2>/dev/null || true

    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        wt_msg "Uninstalled" \
"XRAY has been removed.

Remember to remove or update the reverse proxy rule that
was forwarding traffic to this server on port ${LISTEN_PORT}.

Nginx is still running. Remove if no longer needed:
  apt remove nginx"
    else
        wt_msg "Uninstalled" \
"XRAY has been removed.

TLS certificate remains at /etc/letsencrypt/live/${DOMAIN}/
Nginx is still running. Remove if no longer needed:
  apt remove nginx"
    fi
}

# =============================================================================
# SECTION 20: Client guide — wiki / how it all works
# =============================================================================
# These screens are shown when the user asks "how does this work?" or before
# they connect their first device. They explain everything from first principles.
guide_wiki() {
    wt_msg "How It Works — Overview" \
"XRAY is a proxy. When a client app runs on your device, it
tunnels your internet traffic through a server you control
instead of going directly from your device to websites.

Why use it?
  - Websites see your server's IP, not yours
  - Traffic is encrypted even on hostile networks
  - Bypasses network-level filters and blocks

What makes this setup unusual?
  Most VPN protocols announce themselves. Their packets
  look obviously like VPN traffic to any network observer.

  This setup looks like a normal HTTPS request to a website.
  The proxy traffic is hidden inside a WebSocket connection
  on a path that resembles an ordinary API endpoint.
  From the outside: just HTTPS. Nothing stands out."

    wt_msg "How It Works — Connection Path" \
"Your device  →  ${GUIDE_DOMAIN}:${GUIDE_PORT}  →  Nginx  →  XRAY  →  Internet

Step by step:
  1. Your client app dials ${GUIDE_DOMAIN}:${GUIDE_PORT} over TLS
  2. It sends a WebSocket upgrade to the hidden path:
     ${WS_PATH}
     (this path is inside the TLS tunnel, not visible to ISP)
  3. Nginx sees the WS upgrade and proxies it to XRAY
     running on 127.0.0.1:${XRAY_INTERNAL_PORT}
  4. XRAY authenticates your UUID and tunnels your traffic

What a passive observer (ISP) sees:
  TLS connection to ${GUIDE_DOMAIN} on port ${GUIDE_PORT}
  Standard SNI in the TLS handshake.
  Nothing else.

What they do NOT see:
  The WebSocket path  (encrypted inside TLS)
  Your UUID           (encrypted inside TLS)
  Your traffic        (encrypted inside TLS)"

    wt_msg "How It Works — On the Client Device" \
"When the XRAY client app runs on a device, it opens a local
proxy port. Apps on that device send traffic to:

  SOCKS5  127.0.0.1:1080   (most apps, browsers)
  HTTP    127.0.0.1:1081   (curl, wget, git, pip...)

The XRAY client encrypts each request and sends it through
the tunnel to this server. The server fetches the content
and returns it through the tunnel.

Options for routing:
  Per-browser:   configure proxy in browser settings only
  Terminal-only: export https_proxy=http://127.0.0.1:1081
  System-wide:   set OS network proxy (all apps use it)
  Full tunnel:   Tun/VPN mode in GUI apps (every packet)"

    wt_msg "The vless:// Link Explained" \
"Your link encodes all connection details in one string:
  vless://UUID@server:port?params#label

  UUID      Your unique authentication key. Anyone with
            this can connect to this server as a client.
            Treat it like a password.

  server    ${GUIDE_DOMAIN}

  port      ${GUIDE_PORT}

  security  tls  —  connection uses TLS. This is what
            makes it look like normal HTTPS traffic.

  type      ws  —  WebSocket transport. The connection
            starts as HTTPS then upgrades to WebSocket.

  sni       ${GUIDE_DOMAIN}  —  the server name sent in TLS
            ClientHello. Must match the certificate.

  path      ${WS_PATH}
            The hidden endpoint Nginx forwards to XRAY.
            Any other path serves the decoy website.

  #label    Human-readable name. Not part of protocol."

    wt_msg "Troubleshooting — Quick Reference" \
"Connection not working? Check in order:

  1. Is XRAY running on the server?
       systemctl status xray

  2. Can you reach the decoy site?
       curl -I https://${GUIDE_DOMAIN}
       (expect: 200 OK with HTML)

  3. Does the WS path return 400?
       curl -I https://${GUIDE_DOMAIN}${WS_PATH}
       (expect: 400 Bad Request — that is correct)

  4. Check XRAY logs for errors:
       journalctl -u xray -n 50

  5. Wrong UUID?
       Compare client UUID to the one in ${XRAY_CONF}

  6. Clock skew?
       XRAY rejects connections if server/client clocks
       differ by more than 90 seconds.
       Run: date  on both machines to compare.

  7. Firewall?
       Port ${GUIDE_PORT} must be open:
       ufw allow ${GUIDE_PORT}/tcp"
}

# =============================================================================
# SECTION 21: Client guide — QR code picker
# =============================================================================
guide_show_qr() {
    # Let the user pick which client's QR to show
    local clients_json count
    clients_json=$(jq '.inbounds[0].settings.clients' "${XRAY_CONF}")
    count=$(echo "${clients_json}" | jq 'length')

    if [[ "${count}" -eq 1 ]]; then
        # Only one client — skip the picker
        local uuid email link
        uuid=$(echo  "${clients_json}" | jq -r '.[0].id')
        email=$(echo "${clients_json}" | jq -r '.[0].email')
        link=$(build_vless_link "${uuid}" "${email}")
        print_qr "${link}" "${email}"
        return 0
    fi

    # Build menu items from client list — use email as key so wt_menu handles numbering
    local items=() i=0
    while read -r _; do
        local email; email=$(echo "${clients_json}" | jq -r ".[${i}].email")
        items+=( "${email}" "${email}" )
        (( i++ )) || true
    done < <(echo "${clients_json}" | jq -c '.[]')

    local choice
    choice=$(wt_menu "Show QR Code" \
        "Choose which client's QR code to display:" \
        "${items[@]}") || return 0

    # Look up UUID by email
    local uuid link
    uuid=$(echo "${clients_json}" | jq -r --arg e "${choice}" '.[] | select(.email == $e) | .id')
    link=$(build_vless_link "${uuid}" "${choice}")
    print_qr "${link}" "${choice}"
}

# =============================================================================
# SECTION 22: Client guide — platform flows
# =============================================================================
# All flows are instructional. They run on the server and explain how to
# configure a REMOTE device. No config files are written to this machine.
# Server state (DOMAIN, SERVER_PORT, WS_PATH, etc.) is used directly.

# ── Linux terminal ────────────────────────────────────────────────────────────
guide_linux() {
    wt_msg "Linux — How It Works on the Client" \
"On the client Linux machine:
  - XRAY binary runs as a local proxy service
  - It opens SOCKS5 on 127.0.0.1:1080 and HTTP on 127.0.0.1:1081
  - You point your browser or terminal at those ports
  - XRAY tunnels the traffic to this server

The official XTLS installer handles the binary and systemd
service. Config is a single JSON file.

This guide will ask you to paste the client's vless:// link
so it can generate a ready-to-use config.json with the real
UUID already filled in."

    wt_msg "Linux — Step 1: Install XRAY Binary" \
"Run this on the CLIENT Linux machine (requires root):

  sudo bash <(curl -fsSL \\
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

This installs:
  Binary   ->  /usr/local/bin/xray
  Config   ->  /usr/local/etc/xray/config.json
  Service  ->  /etc/systemd/system/xray.service

Verify after install:
  xray version"

    # Ask for the client's vless:// link so the config can be generated
    # with the real UUID — no placeholder for the user to remember to replace.
    wt_msg "Linux — Step 2: Paste the Client Link" \
"The next screen asks for the vless:// link for this client.

Where to find it:
  Main menu -> Clients -> List all clients
  The link is printed to the terminal (not inside a dialog
  box) so you can select and copy it.

The link contains the UUID. This script will use it to
generate a complete, ready-to-use config.json."

    prompt_vless_link || return 0
    # C_UUID, C_SERVER, C_PORT, C_SNI, C_PATH, C_NETWORK, C_SECURITY are now set.

    # Generate the config JSON with real values — no placeholder.
    local config_json
    config_json=$(jq -n \
        --arg     uuid     "${C_UUID}" \
        --arg     server   "${C_SERVER}" \
        --arg     port     "${C_PORT}" \
        --arg     network  "${C_NETWORK}" \
        --arg     security "${C_SECURITY}" \
        --arg     sni      "${C_SNI}" \
        --arg     path     "${C_PATH}" \
        '{
          "log": {"loglevel": "warning"},
          "inbounds": [
            {
              "port": 1080, "listen": "127.0.0.1",
              "protocol": "socks",
              "settings": {"udp": true, "auth": "noauth"},
              "tag": "socks-in"
            },
            {
              "port": 1081, "listen": "127.0.0.1",
              "protocol": "http",
              "tag": "http-in"
            }
          ],
          "outbounds": [
            {
              "protocol": "vless",
              "settings": {
                "vnext": [{
                  "address": $server,
                  "port":    ($port | tonumber),
                  "users":   [{"id": $uuid, "encryption": "none"}]
                }]
              },
              "streamSettings": {
                "network":     $network,
                "security":    $security,
                "tlsSettings": {"serverName": $sni},
                "wsSettings":  {"path": $path}
              },
              "tag": "proxy"
            },
            {"protocol": "freedom", "settings": {}, "tag": "direct"}
          ],
          "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
              {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}
            ]
          }
        }')

    wt_msg "Linux — Step 3: Write the Config File" \
"The next screen shows the complete config.json.
Copy the entire block and write it to the client machine:

  /usr/local/etc/xray/config.json

This is the path the XTLS system service reads on startup.
The UUID is already filled in — no manual editing needed."

    print_block "config.json — copy to /usr/local/etc/xray/config.json on the client machine" \
        "${config_json}"

    wt_msg "Linux — Step 4: Start and Test" \
"On the client machine, restart the service:

  sudo systemctl restart xray
  sudo systemctl status  xray

Test immediately:
  curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
  (should return this server's IP, not the client's IP)

Run manually instead of the service (useful for debugging):
  xray run -config /usr/local/etc/xray/config.json

View live logs:
  sudo journalctl -u xray -f"

    wt_msg "Linux — Step 5: Using the Proxy" \
"Browser — Firefox (recommended, per-browser):
  Settings -> Network Settings -> Manual proxy
  SOCKS Host : 127.0.0.1   Port : 1080
  SOCKS v5   : selected
  Proxy DNS  : checked  (prevents DNS leaks)

Terminal — route all commands through the proxy:
  export http_proxy=http://127.0.0.1:1081
  export https_proxy=http://127.0.0.1:1081
  export ALL_PROXY=socks5://127.0.0.1:1080

Per-command:
  curl --socks5-hostname 127.0.0.1:1080 https://example.com
  git config --global http.proxy http://127.0.0.1:1081
  sudo https_proxy=http://127.0.0.1:1081 apt-get update"
}

# ── Clash Verge (Linux / Windows / macOS desktop GUI) ────────────────────────
# Generates a ready-to-use Clash YAML from a pasted vless:// link.
guide_clash_yaml() {
    wt_msg "Clash Verge — What It Is" \
"Clash Verge is a cross-platform desktop GUI that supports VLESS.
It uses YAML profiles and shows live traffic/speed graphs.

Platforms: Linux, Windows, macOS
Cost:      Free, open source
Download:  https://github.com/Clash-Verge-rev/clash-verge-rev/releases

When running, it creates a local proxy (HTTP port 7890,
SOCKS port 7891) and optionally sets it as the system proxy
so all apps use it without individual configuration.

Tun mode routes every packet system-wide — including apps
that do not respect system proxy settings."

    wt_msg "Clash Verge — Paste the Client Link" \
"The next screen asks for the vless:// link for this client.

Where to find it:
  Main menu -> Clients -> List all clients
  The link is printed to the terminal for copying.

This script will generate a complete, ready-to-import
YAML profile with all connection details filled in."

    prompt_vless_link || return 0
    # C_* globals are now populated from the parsed link.

    local tls_bool; [[ "${C_SECURITY}" == "tls" ]] && tls_bool="true" || tls_bool="false"

    local ws_opts_block=""
    if [[ "${C_NETWORK}" == "ws" ]]; then
        ws_opts_block="    ws-opts:
      path: \"${C_PATH}\"
      headers:
        Host: \"${C_SNI}\""
    fi

    local yaml_content
    yaml_content="# Generated by xray.sh
# Server: ${C_NAME}
proxies:
  - name: \"${C_NAME}\"
    type: vless
    server: ${C_SERVER}
    port: ${C_PORT}
    uuid: ${C_UUID}
    network: ${C_NETWORK}
    tls: ${tls_bool}
    servername: ${C_SNI}
    udp: true
    skip-cert-verify: false
${ws_opts_block}

proxy-groups:
  - name: \"PROXY\"
    type: select
    proxies:
      - \"${C_NAME}\"
      - DIRECT

rules:
  - GEOIP,private,DIRECT,no-resolve
  - MATCH,PROXY"

    print_block "Clash Verge YAML profile — copy the entire block" "${yaml_content}"

    wt_msg "Clash Verge — Import Steps" \
"Import the YAML into Clash Verge:

  1. Open Clash Verge on your desktop
  2. Click 'Profiles' in the left sidebar
  3. Click the + button -> 'New profile' -> 'Manual'
  4. Paste the YAML you just copied
  5. Click Save
  6. Click the profile to activate it
  7. Go to 'Proxies' -> select PROXY -> '${C_NAME}'
  8. On the home screen: enable 'System Proxy'

Test:
  Open a browser -> https://ifconfig.me
  Should show this server's IP, not your local IP.

Clash Verge proxy ports (defaults):
  HTTP  : 127.0.0.1:7890
  SOCKS : 127.0.0.1:7891"

    wt_msg "Clash Verge — Tun Mode (Routes Everything)" \
"Tun mode captures all traffic at the OS level.
It routes every packet including apps that ignore system proxy.

Enable Tun mode:
  Settings -> Tun Mode -> Enable
  Approve the admin/root permission prompt.

Rule-based routing is already in the generated YAML:
  - Private/LAN IP ranges go DIRECT
  - Everything else goes through PROXY

To route only some traffic, add DOMAIN or IP rules above
the MATCH,PROXY line in the YAML before importing."
}

# ── Windows ───────────────────────────────────────────────────────────────────
guide_windows() {
    wt_msg "Windows — Recommended Apps" \
"Two recommended Windows clients:

  v2rayN  (lightweight, tray icon, VLESS native)
    https://github.com/2dust/v2rayN/releases
    Download: v2rayN-With-Core.zip
    The -With-Core version includes the XRAY binary.

  Hiddify  (easiest for first-time users, modern UI)
    https://github.com/hiddify/hiddify-app/releases
    Download: Hiddify-Windows-Setup.exe

Both are free and open source."

    wt_msg "Windows — v2rayN Setup" \
"Step by step:

  1. Download v2rayN-With-Core.zip from GitHub releases
  2. Extract to a folder, e.g.  C:\\v2rayN
  3. Run v2rayN.exe  (approve firewall prompt if shown)
  4. The v2rayN icon appears in the system tray
  5. Right-click the tray icon -> Servers
     -> Import bulk URL from clipboard
  6. Paste the vless:// link
  7. Right-click the server in the list
     -> Set as active server
  8. In the bottom bar: choose System Proxy mode

v2rayN proxy ports (defaults):
  HTTP  : 127.0.0.1:10809
  SOCKS : 127.0.0.1:10808

Test:
  Open a browser -> visit https://ifconfig.me
  Should show this server's IP: not your local IP."

    wt_msg "Windows — Hiddify Setup" \
"Easiest option for new users:

  1. Download and run Hiddify-Windows-Setup.exe
  2. Open Hiddify
  3. Click + -> Add profile -> Add from URL or text
  4. Paste the vless:// link
  5. Flip the main switch to ON

VPN mode: routes ALL Windows traffic through the tunnel.
System Proxy mode: routes browser/system-proxy-aware apps.

Toggle between modes in Hiddify's settings panel."
}

# ── macOS ─────────────────────────────────────────────────────────────────────
guide_macos() {
    wt_msg "macOS — Recommended Apps" \
"Clash Verge Rev  (free, open source)
  https://github.com/Clash-Verge-rev/clash-verge-rev/releases
  Apple Silicon: aarch64.dmg  |  Intel: x64.dmg
  Full-featured, supports rule-based routing.

V2Box  (free, App Store, easiest option)
  https://apps.apple.com/app/v2box-v2ray-client/id6446814690
  Paste vless:// link directly. No YAML needed.

Hiddify  (free, open source, very easy)
  https://github.com/hiddify/hiddify-app/releases
  Download: Hiddify-MacOS.dmg"

    wt_msg "macOS — V2Box Setup (Easiest)" \
"V2Box accepts the vless:// link directly:

  1. Install V2Box from the App Store (free)
  2. Open V2Box
  3. Tap the + button
  4. Select 'Import from URL / clipboard'
  5. Paste the vless:// link
  6. Tap the server to select it
  7. Toggle ON at the top to connect
  8. Accept the VPN configuration permission

V2Box creates a system VPN so all macOS apps route through
the server — no individual browser configuration needed."

    wt_msg "macOS — Clash Verge Setup" \
"Clash Verge on macOS:

  1. Download the .dmg for your Mac architecture
  2. Drag Clash Verge to Applications
  3. First launch — macOS will block it (unsigned app):
     System Settings -> Privacy & Security -> Open Anyway
  4. Open Clash Verge
  5. Profiles -> + -> Manual -> paste the YAML profile
     Generate the YAML from:
       Connect a Device -> Clash Verge
     in this script's main menu.
  6. Activate the profile
  7. Enable System Proxy

Alternatively, use V2Box or Hiddify which accept the
vless:// link directly — no YAML generation needed."
}

# ── Android ───────────────────────────────────────────────────────────────────
guide_android() {
    wt_msg "Android — Overview" \
"Recommended app: v2rayNG  (free, most widely used)

This guide covers:
  1. Installing v2rayNG
  2. Getting the vless:// link onto your phone
     (QR scan is the easiest method)
  3. Connecting and what the VPN toggle does
  4. Per-app routing  (split tunneling)
  5. Testing and troubleshooting

Alternative apps:
  Hiddify       — easiest UI, great for beginners
  NekoBox       — advanced users, more protocols
  ClashMeta     — Clash-style profiles"

    wt_msg "Android — Getting the Link to Your Phone" \
"Option 1: QR Code  (recommended — no typing needed)
  - On this screen: go back -> 'Show QR Code'
  - Open v2rayNG on your phone
  - Tap the scan icon (top right)
  - Point the camera at the QR code on this screen

Option 2: Clipboard sync app
  KDE Connect, Syncthing Clipboard, or built-in
  clipboard sync if you use Samsung DeX / MIUI.
  Copy the link on your computer, it appears on phone.

Option 3: Message to yourself
  Paste the link into Signal/Telegram/WhatsApp
  to yourself, open on phone, long-press, copy.

Option 4: Online QR generator  (no app needed)
  Visit https://qr-code-generator.com on your computer,
  paste the link, scan the generated QR with your phone.

Option 5: Type manually  (last resort)
  v2rayNG: + -> Type manually -> VLESS
  Fill in each field individually."

    wt_msg "Android — v2rayNG Setup" \
"Installing v2rayNG:
  - Google Play: search 'v2rayNG' (by 2dust)
  - GitHub: https://github.com/2dust/v2rayNG/releases
    (use the APK if Play Store is unavailable)

Importing the link:
  1. Open v2rayNG
  2. Tap + (top right) -> From clipboard
     (or: Scan QR code if using the QR method above)
  3. The server appears in the list with its label

Connecting:
  1. Tap the server to select it (checkmark appears)
  2. Tap the large round V button at the bottom
  3. Accept the VPN permission dialog
  4. The V button turns green — you are connected

What happens:
  Android routes ALL traffic through v2rayNG's VPN
  adapter. Every app uses the tunnel until you disconnect."

    wt_msg "Android — Per-App Routing (Split Tunneling)" \
"Route only specific apps, or everything except specific apps:

  1. Open v2rayNG
  2. Three-dot menu (top right) -> Settings
  3. Scroll to 'App whitelist' or 'Per-app proxy'
  4. Choose:
       All apps through proxy  (default — everything)
       Only selected apps      (whitelist mode)
       All except selected     (blacklist mode)

What to EXCLUDE (send direct, not through proxy):
  - Banking apps  (many reject VPN connections)
  - Local delivery / maps  (need local IP for accuracy)

What to KEEP in the tunnel:
  - Browser, social media, streaming
  - Any app blocked on your current network"

    wt_msg "Android — Testing and Troubleshooting" \
"Test the connection:
  Browser -> https://ifconfig.me
  The IP should be this server's IP, not your phone's.

Check traffic stats in v2rayNG:
  Three-dot menu -> Statistics
  Sent/received bytes should increase as you browse.

Test latency:
  Long-press a server in the list -> Test latency
  Under 200ms is good for most uses.

Troubleshooting:
  Three-dot menu -> Log -> View log

Common errors:
  'TLS handshake failed'
    Server domain or SNI does not match. Check link.

  'WebSocket connection failed'
    Wrong path in the link. Check ${WS_PATH}.

  Timeout / no connection
    Port ${GUIDE_PORT} may be blocked on your current network.
    Try a different network to test."
}

# ── iOS ───────────────────────────────────────────────────────────────────────
guide_ios() {
    wt_msg "iOS — Recommended Apps" \
"Shadowrocket  (\$2.99 one-time — best VLESS support)
  App Store: search 'Shadowrocket'
  Note: requires a non-CN App Store account.
  US App Store accounts work everywhere.

V2Box  (free, App Store)
  https://apps.apple.com/app/v2box-v2ray-client/id6446814690
  Good free option. Paste vless:// link directly.

Hiddify  (free, App Store)
  https://apps.apple.com/app/hiddify-proxy-vpn/id6596777532
  Easiest UI. Highly recommended for first-time users.

Streisand  (free, App Store)
  https://apps.apple.com/app/streisand/id6450534064"

    wt_msg "iOS — Getting the Link to Your iPhone" \
"Option 1: QR Code  (easiest)
  - On this screen: go back -> 'Show QR Code'
  - Open Shadowrocket -> Scan button (top right)
  - Point camera at the QR code on this screen

Option 2: AirDrop or iMessage to yourself
  Copy the link on your Mac, AirDrop to iPhone,
  or iMessage to yourself, long-press to copy,
  paste into the app.

Option 3: Universal Clipboard (Handoff)
  If Handoff is enabled, copy on Mac and paste on iPhone
  automatically through iCloud Clipboard.

Option 4: Paste in Shadowrocket
  + -> URL -> paste the vless:// link directly."

    wt_msg "iOS — Shadowrocket Setup" \
"1. Install Shadowrocket from App Store
2. Tap + (top right) -> URL
3. Paste the vless:// link -> Done
4. The server appears in the list
5. Tap the server to select it (checkmark)
6. Tap the main Connect toggle at the top
7. Allow the VPN configuration prompt

iOS routes all traffic through a VPN tunnel when
Shadowrocket is active.

Testing:
  Safari -> https://ifconfig.me
  Should show this server's IP.

Split tunneling in Shadowrocket:
  Config tab -> Rules -> Add rules
  Use DOMAIN or IP rules with DIRECT policy
  for services you want to bypass the proxy."

    wt_msg "iOS — Hiddify Setup (Free Alternative)" \
"1. Install Hiddify from App Store  (free)
2. Open Hiddify
3. Tap + -> Add profile -> Add from URL or text
4. Paste the vless:// link
5. Tap Add
6. Flip the main switch to ON
7. Allow VPN permission

Hiddify also accepts subscription URLs if you want to
manage multiple servers from one profile URL."
}

# =============================================================================
# SECTION 23: Client guide — top-level menu
# =============================================================================
# This is the main entry point for anything client-facing.
# Accessible from: post-install handoff, and management menu -> Connect a Device.
client_guide_menu() {
    load_state 2>/dev/null || true   # graceful — state may already be loaded

    # Set display variables for all guide sub-functions.
    # In RP mode, clients connect to RP_DOMAIN:RP_PORT, not this server's DOMAIN:SERVER_PORT.
    if [[ "${SETUP_MODE}" == "reverse_proxy" ]]; then
        GUIDE_DOMAIN="${RP_DOMAIN}"
        GUIDE_PORT="${RP_PORT}"
    else
        GUIDE_DOMAIN="${DOMAIN}"
        GUIDE_PORT="${SERVER_PORT}"
    fi

    while true; do
        local choice
        choice=$(wt_menu "Connect a Device  —  ${DOMAIN}" \
            "Choose a topic or platform to get started:" \
            "how"     "How it works         understand the system" \
            "qr"      "Show QR Code         scan with phone (Android / iOS)" \
            "linux"   "Linux                terminal setup + config generator" \
            "clash"   "Clash Verge          GUI for Linux, Windows, macOS" \
            "windows" "Windows              v2rayN or Hiddify" \
            "macos"   "macOS                Clash Verge, V2Box, or Hiddify" \
            "android" "Android              v2rayNG  (full walkthrough)" \
            "ios"     "iOS                  Shadowrocket, V2Box, or Hiddify" \
            "back"    "Back to main menu") || break

        case "${choice}" in
            how)     guide_wiki       ;;
            qr)      guide_show_qr   ;;
            linux)   guide_linux     ;;
            clash)   guide_clash_yaml ;;
            windows) guide_windows   ;;
            macos)   guide_macos     ;;
            android) guide_android   ;;
            ios)     guide_ios       ;;
            back)    break           ;;
        esac
    done
}

# =============================================================================
# SECTION 24: Main management menu
# =============================================================================
menu_manage() {
    load_state
    while true; do
        local xray_st; xray_st=$(svc_is_active xray && echo "active" || echo "inactive")
        local choice
        choice=$(wt_menu "XRAY Manager  —  ${DOMAIN}" \
            "Server: ${xray_st}  |  Path: ${WS_PATH}" \
            "device"    "Connect a Device    share access / client guide" \
            "clients"   "Clients             add / remove / list links" \
            "path"      "Path                change the hidden WebSocket path" \
            "branding"  "Branding            company name, tagline, color" \
            "status"    "Status              services, cert, config paths" \
            "renew"     "Renew TLS           force-renew the certificate" \
            "uninstall" "Uninstall           remove everything" \
            "exit"      "Exit") || break

        case "${choice}" in
            device)    client_guide_menu ;;
            clients)   mgmt_clients      ;;
            path)      mgmt_change_path  ;;
            branding)  mgmt_branding     ;;
            status)    mgmt_status       ;;
            renew)     mgmt_renew_cert   ;;
            uninstall) mgmt_uninstall; is_installed || break ;;
            exit)      break ;;
        esac
    done
}

# =============================================================================
# SECTION 25: Entry point
# =============================================================================
main() {
    require_root
    detect_os

    if is_installed; then
        source "${STATE_FILE}" 2>/dev/null || true

        local choice
        choice=$(wt_menu "XRAY  —  ${DOMAIN}" \
            "Installation detected. What would you like to do?" \
            "manage"    "Manage server" \
            "reinstall" "Reinstall (overwrites current config)" \
            "exit"      "Exit") || exit 0

        case "${choice}" in
            manage)
                menu_manage
                ;;
            reinstall)
                wt_yesno "Confirm Reinstall" \
"Overwrite the current installation for ${DOMAIN}?

All client UUIDs will be replaced. The TLS certificate
will be kept. The decoy site will be regenerated." \
                && { install_base_deps; wizard_install && do_install; } || true
                ;;
            exit) exit 0 ;;
        esac
    else
        local choice
        choice=$(wt_menu "XRAY Setup" \
            "No existing installation found on this server." \
            "install" "Install XRAY + Nginx  (fresh setup)" \
            "exit"    "Exit") || exit 0

        case "${choice}" in
            install)
                install_base_deps
                wizard_install && do_install
                # do_install ends with client_guide_menu.
                # After the user exits the guide, land them in the management menu.
                is_installed && menu_manage || true
                ;;
            exit) exit 0 ;;
        esac
    fi
}

main "$@"
