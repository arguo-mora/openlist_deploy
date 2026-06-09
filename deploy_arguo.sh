#!/bin/bash
#==============================================================================
# OpenList + qBittorrent + Aria2 One-Click Deploy Script (Debian 12 / Ubuntu)
# Usage: bash deploy.sh  (root user)
#
# CLI arguments (optional; interactive prompts if not provided):
#   --domain <domain>        OpenList domain
#   --qbit-domain <domain>   qBittorrent domain
#   --email <email>          Let's Encrypt notification email
#   --base-dir <path>        Deployment root directory       [default: /opt/openlist]
#   --bt-port <port>         BT/PT listen port               [default: 62973]
#   --aria2                  Install Aria2
#   --no-aria2               Do not install Aria2
#   --aria2-bt-port <port>   Aria2 BT port                   [default: 62974]
#   --timezone <tz>          Timezone                        [default: Asia/Shanghai]
#   --puid <uid>             Container UID                   [default: 1001]
#   --pgid <gid>             Container GID                   [default: 1001]
#   -y, --non-interactive    Skip confirmation, run directly
#   -h, --help               Show help
#==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# Pipe safety: if stdin is not a terminal (curl|bash), override read
# to read user input from /dev/tty instead.
# We cannot use exec < /dev/tty because bash still needs to read
# the rest of the script body from the pipe.
if [ ! -t 0 ]; then
    read() { builtin read "$@" < /dev/tty; }
fi

# ---- Configurable defaults ----
TZ="${TZ:-Asia/Shanghai}"
PUID="${PUID:-1001}"
PGID="${PGID:-1001}"
DOMAIN="${DOMAIN:-pan.arguo.org}"
HAS_DOMAIN="${HAS_DOMAIN:-yes}"
QBIT_DOMAIN="${QBIT_DOMAIN:-qb.arguo.org}"
EMAIL="${EMAIL:-i@arguo.org}"
INSTALL_ARIA2="${INSTALL_ARIA2:-yes}"
NON_INTERACTIVE=true

# ---- CLI argument parsing ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)        DOMAIN="$2"; HAS_DOMAIN="yes"; shift 2 ;;
        --qbit-domain)   QBIT_DOMAIN="$2"; shift 2 ;;
        --email)         EMAIL="$2"; shift 2 ;;
        --base-dir)      BASE_DIR="$2"; shift 2 ;;
        --bt-port)       BT_PORT="$2"; shift 2 ;;
        --aria2)         INSTALL_ARIA2="yes"; shift ;;
        --no-aria2)      INSTALL_ARIA2="no"; shift ;;
        --aria2-bt-port) ARIA2_BT_PORT="$2"; shift 2 ;;
        --timezone)      TZ="$2"; shift 2 ;;
        --puid)          PUID="$2"; shift 2 ;;
        --pgid)          PGID="$2"; shift 2 ;;
        -y|--non-interactive) NON_INTERACTIVE=true; shift ;;
        -h|--help)
            echo "Usage: bash deploy.sh [options]"
            echo ""
            echo "Options:"
            echo "  --domain <domain>        OpenList domain"
            echo "  --qbit-domain <domain>   qBittorrent domain"
            echo "  --email <email>          Let's Encrypt notification email"
            echo "  --base-dir <path>        Deployment root dir     [default: /opt/openlist]"
            echo "  --bt-port <port>         BT/PT listen port       [default: 62973]"
            echo "  --aria2                  Install Aria2"
            echo "  --no-aria2               Do not install Aria2"
            echo "  --aria2-bt-port <port>   Aria2 BT port           [default: 62974]"
            echo "  --timezone <tz>          Timezone                [default: Asia/Shanghai]"
            echo "  --puid <uid>             Container UID           [default: 1001]"
            echo "  --pgid <gid>             Container GID           [default: 1001]"
            echo "  -y, --non-interactive    Skip confirmation, run directly"
            echo "  -h, --help               Show this help"
            echo ""
            echo "Examples:"
            echo "  bash deploy.sh"
            echo "  bash deploy.sh --domain example.com --email a@b.com -y"
            echo "  bash deploy.sh --domain example.com --aria2 --timezone America/New_York"
            exit 0 ;;
        *)
            echo "Unknown option: $1, use -h for help"; exit 1 ;;
    esac
done

declare -a STEP_RESULTS
CRITICAL_FAILURE=0
START_TIME=$(date +%s)
declare -a DEFERRED_INFO
defer_info() { DEFERRED_INFO+=("${1}|${2}"); }

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

record_step() { STEP_RESULTS+=("${1}|${2}|${3:-}"); }
step_header() { echo ""; echo -e "${BOLD}━━━━━━ $1 ━━━━━━${NC}"; }

check_cmd() {
    local name="$1" level="$2" cmd="$3" ok_msg="${4:-}" fail_msg="${5:-}"
    step_header "$name"
    local output exit_code=0
    echo -n "  Running..."
    if output=$(eval "$cmd" 2>&1); then
        echo -e "\r  ${GREEN}✓${NC} ${ok_msg}"
        [ -n "$output" ] && echo "$output" | tail -15
        record_step "$name" "OK" ""
        return 0
    else
        exit_code=$?
        echo -e "\r  ${YELLOW}⚠${NC} ${fail_msg} (exit code: $exit_code)"
        [ -n "$output" ] && echo "$output" | tail -15
        record_step "$name" "$([ "$level" = "critical" ] && echo "FAIL" || echo "WARN")" \
            "Exit: $exit_code | $(echo "$output" | tail -3 | tr '\n' ' ')"
        if [ "$level" = "critical" ]; then
            CRITICAL_FAILURE=1
            echo -e "${RED}  → Critical step failed, aborting deployment${NC}"
            print_final_report
        fi
        return $exit_code
    fi
}

print_suggestion() {
    case "$1" in
        "System Dependencies")
            echo "    Suggestion: check network, run apt update for details" ;;
        "Docker Installation")
            echo "    Suggestion: verify access to download.docker.com" ;;
        "Docker Service Check")
            echo "    Suggestion: systemctl status docker --no-pager" ;;
        "Directory & Permissions")
            echo "    Suggestion: check disk space df -h /opt" ;;
        "docker-compose.yml Generation")
            echo "    Suggestion: check if deployment directory is writable" ;;
        "Docker Compose Syntax Check")
            echo "    Suggestion: cd $BASE_DIR && docker compose config for details" ;;
        "Container Startup")
            echo "    Suggestion: cd $BASE_DIR && docker compose ps"
            echo "    Logs: docker compose logs openlist  /  docker compose logs qbittorrent  /  docker compose logs aria2" ;;
        "qBittorrent Config Preset")
            echo "    Suggestion: check directory permissions: ls -la $BASE_DIR/config/qbittorrent/qBittorrent/" ;;
        "Aria2 RPC Secret Generation")
            echo "    Suggestion: check if $BASE_DIR/config/aria2/aria2.conf exists" ;;
        "Aria2 Config Preset")
            echo "    Suggestion: check directory permissions: ls -la $BASE_DIR/config/aria2/" ;;
        "OpenList Password Retrieval")
            echo "    Suggestion: docker logs openlist 2>&1 | grep -i password" ;;
        "qBittorrent Password Retrieval")
            echo "    Suggestion: docker logs qbittorrent 2>&1 | grep -i password" ;;
        "Aria2 RPC Secret Retrieval")
            echo "    Suggestion: docker logs aria2 2>&1 | grep -i 'rpc.secret'"
            echo "    Or check: cat $BASE_DIR/config/aria2/aria2.conf | grep rpc-secret" ;;
        "Nginx + Certbot Installation")
            echo "    Suggestion: apt update && apt install -y nginx certbot" ;;
        "Nginx Syntax Check & Reload")
            echo "    Suggestion: nginx -t for detailed error output" ;;
        "SSL Certificate Request")
            echo "    Suggestion: verify that the domain DNS resolves to this server's IP"
            echo "    Verify: dig +short $DOMAIN"
            echo "    Manual: certbot --nginx -d $DOMAIN" ;;
        "qBittorrent SSL Certificate Request")
            echo "    Suggestion: verify DNS resolution; manual: certbot --nginx -d $QBIT_DOMAIN" ;;
        "Certificate Auto-Renewal Check")
            echo "    Suggestion: certbot renew --dry-run for detailed output" ;;
        "Key Directory Owner Check")
            echo "    Suggestion: chown -R ${PUID}:${PGID} $BASE_DIR" ;;
        "qBittorrent Config Owner Check")
            echo "    Suggestion: chown ${PUID}:${PGID} $BASE_DIR/config/qbittorrent/qBittorrent/qBittorrent.conf" ;;
        "Shared Dir Writable Check (qBittorrent)"|"Shared Dir Writable Check (Aria2)")
            echo "    Suggestion: This is the #1 reason downloads succeed but files don't appear!"
            echo "    Fix: chown -R ${PUID}:${PGID} $BASE_DIR/temp/qBittorrent && chmod -R 755 $BASE_DIR/temp/qBittorrent"
            [ "$INSTALL_ARIA2" = "yes" ] && echo "         chown -R ${PUID}:${PGID} $BASE_DIR/temp/aria2 && chmod -R 755 $BASE_DIR/temp/aria2"
            echo "    Important: local storage directories mounted in OpenList must also have owner=${PUID}" ;;
        *)  echo "    Suggestion: inspect the command output above for error details" ;;
    esac
}

write_config_json() {
    local config_file="$BASE_DIR/config/openlist/config.json"
    local site_url="$1" force_https="${2:-false}"
    local jwt_secret
    jwt_secret=$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')

    if [ ! -f "$config_file" ]; then
        step_header "OpenList Config Generation"
        cat > "$config_file" <<CONFJSON
{
  "force": false,
  "site_url": "$site_url",
  "cdn": "",
  "jwt_secret": "$jwt_secret",
  "token_expires_in": 48,
  "scheme": {
    "address": "0.0.0.0",
    "http_port": 5244,
    "https_port": -1,
    "force_https": $force_https,
    "cert_file": "",
    "key_file": "",
    "unix_file": "",
    "unix_file_perm": "",
    "enable_h2c": false
  },
  "temp_dir": "data/temp",
  "bleve_dir": "data/bleve",
  "dist_dir": "",
  "delayed_start": 0,
  "max_connections": 0,
  "max_concurrency": 64,
  "tls_insecure_skip_verify": true
}
CONFJSON
        chown ${PUID}:${PGID} "$config_file" 2>/dev/null || true
        echo -e "${GREEN}  ✓ Config file generated: $config_file${NC}"
        echo -e "     site_url=${site_url}, jwt_secret=${jwt_secret}"
        record_step "OpenList Config Generation" "OK" "site_url=$site_url"
    else
        # Existing config: only update site_url and force_https, leave other fields untouched
        sed -i "s|\"site_url\": \"[^\"]*\"|\"site_url\": \"$site_url\"|" "$config_file"
        sed -i "s|\"force_https\": [a-z]*|\"force_https\": $force_https|" "$config_file"
        if grep -q '"jwt_secret": "random_generated"' "$config_file" 2>/dev/null; then
            sed -i "s|\"jwt_secret\": \"random_generated\"|\"jwt_secret\": \"$jwt_secret\"|" "$config_file"
        fi
        echo -e "${GREEN}  ✓ Config file updated: site_url=${site_url}${NC}"
        record_step "OpenList Config Generation" "OK" "Already exists, updated site_url=$site_url"
    fi
}

print_final_report() {
    local end_time=$(date +%s) elapsed=$((end_time - START_TIME))
    local ok_count=0 warn_count=0 fail_count=0
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                  Deployment Summary Report                   ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "║  Total time: %4d sec                                         ║\n" "$elapsed"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    for entry in "${STEP_RESULTS[@]}"; do
        local name="${entry%%|*}" rest="${entry#*|}" status="${rest%%|*}" detail="${rest#*|}"
        case "$status" in
            OK)    printf "║  ${GREEN}✓${NC} %-54s ║\n" "$name"; ((ok_count++)) ;;
            WARN)  printf "║  ${YELLOW}⚠${NC} %-54s ║\n" "$name"; ((warn_count++)) ;;
            FAIL)  printf "║  ${RED}✗${NC} %-54s ║\n" "$name"; ((fail_count++)) ;;
        esac
        [ -n "$detail" ] && echo -e "║     ${BLUE}→${NC} $(echo "$detail" | head -c 50)..."
    done
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "║  OK: %-2d  |  WARN: %-2d  |  FAIL: %-2d                              ║\n" "$ok_count" "$warn_count" "$fail_count"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

    if [ "$fail_count" -gt 0 ] || [ "$warn_count" -gt 0 ]; then
        echo ""; echo -e "${BOLD}━━━━━━━━━━━━ Troubleshooting Guide ━━━━━━━━━━━━${NC}"; echo ""
        for entry in "${STEP_RESULTS[@]}"; do
            local name="${entry%%|*}" rest="${entry#*|}" status="${rest%%|*}"
            if [ "$status" = "WARN" ] || [ "$status" = "FAIL" ]; then
                echo -e "  ${YELLOW}▸${NC} ${name}"; print_suggestion "$name"; echo ""
            fi
        done
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi

    if [ "$CRITICAL_FAILURE" -eq 1 ]; then
        echo ""; echo -e "${RED}A critical step failed. Deployment incomplete. Fix the issue and re-run the script.${NC}"
        echo -e "${YELLOW}The script is safe to re-run — completed steps will be skipped automatically.${NC}"
    else
        echo ""; echo -e "${GREEN}All critical steps passed.${NC}"
        [ "$warn_count" -gt 0 ] && echo -e "${YELLOW}${warn_count} warning(s) — review the suggestions above.${NC}"
    fi

    # Key info: show as long as any step completed (even if later steps failed)
    if [ -n "$OPENLIST_PWD" ] || [ -n "$QBIT_PWD" ] || [ -n "$ARIA2_RPC_SECRET" ] || [ "$CRITICAL_FAILURE" -eq 0 ]; then
        echo ""; echo -e "${BOLD}━━━━━━━━━━ Key Info Summary ━━━━━━━━━━${NC}"; echo ""

        # ── Access URLs ──
        echo -e "${BOLD}Access URLs${NC}"
        if [ "$HAS_DOMAIN" = "yes" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            echo -e "  OpenList:      ${GREEN}https://$DOMAIN${NC}"
        elif [ "$HAS_DOMAIN" = "yes" ]; then
            echo -e "  OpenList:      http://$DOMAIN ${YELLOW}(HTTPS not yet active, retry: certbot --nginx)${NC}"
        else
            echo -e "  OpenList:      http://$(curl -s --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null || echo 'SERVER_IP'):5244"
        fi
        if [ -n "$QBIT_DOMAIN" ] && [ -f "/etc/letsencrypt/live/$QBIT_DOMAIN/fullchain.pem" ]; then
            echo -e "  qBittorrent:   ${GREEN}https://$QBIT_DOMAIN${NC}"
        elif [ -n "$QBIT_DOMAIN" ]; then
            echo -e "  qBittorrent:   http://$QBIT_DOMAIN ${YELLOW}(HTTPS not yet active)${NC}"
        fi
        echo ""

        # ── Ports ──
        echo -e "${BOLD}Ports${NC}"
        echo "  OpenList:          5244"
        echo "  qBittorrent WebUI: 8080"
        echo "  BT/PT:             ${BT_PORT}"
        if [ "$INSTALL_ARIA2" = "yes" ]; then
            echo "  Aria2 RPC:         6800"
            echo "  Aria2 BT:          ${ARIA2_BT_PORT}"
        fi
        echo -e "  ${BLUE}─────────────────────────────${NC}"
        echo -e "  ${BLUE}Optional service ports (disabled by default; enable in docker-compose & firewall):${NC}"
        echo "  S3:               5246"
        echo "  FTP:              5221"
        echo "  SFTP:             5222"
        echo ""

        # ── Credentials ──
        echo -e "${BOLD}Credentials${NC}"
        if [ -n "$OPENLIST_PWD" ]; then
            echo -e "  OpenList initial password: ${GREEN}${OPENLIST_PWD}${NC}"
        else
            echo -e "  OpenList initial password: ${YELLOW}Failed to auto-retrieve${NC}"
        fi
        if [ -n "$QBIT_PWD" ]; then
            echo -e "  qBittorrent temporary password: ${GREEN}${QBIT_PWD}${NC}"
        else
            echo -e "  qBittorrent temporary password: ${YELLOW}Failed to auto-retrieve${NC}"
        fi
        if [ "$INSTALL_ARIA2" = "yes" ]; then
            if [ -n "$ARIA2_SECRET_FROM_LOG" ] && [ "${#ARIA2_SECRET_FROM_LOG}" -gt 4 ]; then
                echo -e "  Aria2 RPC secret:       ${GREEN}${ARIA2_SECRET_FROM_LOG}${NC}"
            else
                echo -e "  Aria2 RPC secret:       ${GREEN}${ARIA2_RPC_SECRET}${NC}"
            fi
        fi
        echo -e "  ${YELLOW}─────────────────────────────────────────${NC}"
        echo -e "  ${YELLOW}Manual retrieval commands (use if above is empty):${NC}"
        echo "    docker logs openlist 2>&1 | grep -i password"
        echo "    docker logs qbittorrent 2>&1 | grep -i password"
        [ "$INSTALL_ARIA2" = "yes" ] && echo "    docker logs aria2 2>&1 | grep -i 'rpc.secret'"
        echo ""

        # ── OpenList backend config ──
        echo -e "${BOLD}OpenList Backend Configuration${NC}"
        echo "  1. Settings → qBittorrent → URL:"
        echo "     http://admin:<qBit_password>@qbittorrent:8080/"
        echo ""
        if [ "$INSTALL_ARIA2" = "yes" ]; then
            echo "  2. Settings → Others → Aria2:"
            echo "     http://aria2:6800/jsonrpc"
            echo "     RPC Secret: use the Aria2 key from the Credentials section above"
            echo ""
        fi
        echo "  3. Bottom-right corner → Offline Download → choose qBittorrent or Aria2"
        echo ""

        # SSL certificate expiry
        if [ "$HAS_DOMAIN" = "yes" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            echo -e "${BOLD}SSL Certificate${NC}"
            echo "  $(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" 2>/dev/null)"
            echo ""
        fi
        echo -e "${BOLD}Note${NC}"
        echo "  OpenList defaults to tls_insecure_skip_verify=true"
        echo "  If mounting storage backends with self-signed certificates, this avoids TLS errors."
        echo "  Backends using proper CA certificates do not need this option."
        echo ""
    fi
    exit ${CRITICAL_FAILURE}
}

# ====================================================================
#                       Interactive Configuration
# ====================================================================

echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  OpenList + qBittorrent + Aria2 One-Click Deploy (Debian 12 / Ubuntu) ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$NON_INTERACTIVE" = true ]; then
    echo -e "${YELLOW}Non-interactive mode: using CLI args or defaults${NC}"; echo ""
else
    echo -e "${YELLOW}Answer the following (press Enter to accept defaults)${NC}"; echo ""
fi

# OpenList domain
if [ -z "$HAS_DOMAIN" ]; then
    echo -e "  ${BLUE}OpenList domain (optional; leave empty for direct IP access without HTTPS)${NC}"
    read -p "  OpenList domain: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        HAS_DOMAIN="no"
        echo -e "  ${GREEN}→ No domain configured; OpenList will expose port 5244 directly${NC}"
    else
        HAS_DOMAIN="yes"
    fi
else
    echo -e "  OpenList domain: ${DOMAIN:-(no domain, direct IP access)}"
fi

# qBittorrent domain
if [ -z "$QBIT_DOMAIN" ] && [ "$NON_INTERACTIVE" != true ]; then
    echo ""
    echo -e "  ${BLUE}qBittorrent domain (optional; leave empty to skip)${NC}"
    read -p "  qBittorrent domain: " QBIT_DOMAIN
    [ -z "$QBIT_DOMAIN" ] && echo -e "  ${GREEN}→ Skipping qBittorrent domain config${NC}"
elif [ -n "$QBIT_DOMAIN" ]; then
    echo "  qBittorrent domain: $QBIT_DOMAIN"
fi

# Email
if [ -z "$EMAIL" ]; then
    if [ "$HAS_DOMAIN" = "yes" ] || [ -n "$QBIT_DOMAIN" ]; then
        if [ "$NON_INTERACTIVE" = true ]; then
            err "Domain configured but --email not provided (required for SSL certificates)"; exit 1
        fi
        echo ""
        while true; do
            read -p "  Let's Encrypt notification email: " EMAIL
            [ -n "$EMAIL" ] && break
            echo -e "  ${RED}This field is required (needed for SSL certificate)${NC}"
        done
    else
        EMAIL=""
        echo -e "  ${GREEN}→ No domain configured, skipping email${NC}"
    fi
else
    echo "  Email:          $EMAIL"
fi

# Deployment root directory
if [ -z "$BASE_DIR" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        BASE_DIR="/opt/openlist"
    else
        echo ""
        read -p "  Deployment root dir [default: /opt/openlist]: " BASE_DIR
    fi
fi
BASE_DIR="${BASE_DIR:-/opt/openlist}"
# Path validation: spaces and special chars cause eval issues downstream
if [ "$BASE_DIR" != "$(printf '%s' "$BASE_DIR" | tr -d '[:space:]')" ]; then
    err "Deployment path must not contain spaces: $BASE_DIR"; exit 1
fi
if ! printf '%s' "$BASE_DIR" | grep -q '^/[a-zA-Z0-9/_.-]\+$'; then
    err "Deployment path contains invalid characters (allowed: letters, digits, / _ . -): $BASE_DIR"
    exit 1
fi

# BT port
if [ -z "$BT_PORT" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        BT_PORT="62973"
    else
        read -p "  BT/PT listen port [default: 62973]: " BT_PORT
    fi
fi
BT_PORT="${BT_PORT:-62973}"

# Aria2
if [ -z "$INSTALL_ARIA2" ]; then
    echo ""
    echo -e "  ${BLUE}Install Aria2 offline downloader? Supports HTTP/FTP/BT/magnet links${NC}"
    read -p "  Install Aria2? [Y/n]: " INSTALL_ARIA2
fi
INSTALL_ARIA2="${INSTALL_ARIA2:-Y}"
if [ "$INSTALL_ARIA2" = "n" ] || [ "$INSTALL_ARIA2" = "N" ] || [ "$INSTALL_ARIA2" = "no" ] || [ "$INSTALL_ARIA2" = "NO" ]; then
    INSTALL_ARIA2="no"
    echo -e "  ${GREEN}→ Skipping Aria2 installation${NC}"
else
    INSTALL_ARIA2="yes"
    if [ -z "$ARIA2_BT_PORT" ]; then
        if [ "$NON_INTERACTIVE" = true ]; then
            ARIA2_BT_PORT="62974"
        else
            read -p "  Aria2 BT listen port [default: 62974]: " ARIA2_BT_PORT
        fi
    fi
    ARIA2_BT_PORT="${ARIA2_BT_PORT:-62974}"
    if [ "$ARIA2_BT_PORT" = "$BT_PORT" ]; then
        ARIA2_BT_PORT=$((ARIA2_BT_PORT + 1))
        echo -e "  ${YELLOW}→ BT port conflict; Aria2 BT port auto-adjusted to: ${ARIA2_BT_PORT}${NC}"
    fi
fi

# Confirmation
echo ""
echo -e "${BOLD}━━━━━━━━━━ Configuration Summary ━━━━━━━━━━${NC}"
echo "  OpenList:       ${DOMAIN:-(no domain, direct IP access)}"
echo "  qBittorrent:    ${QBIT_DOMAIN:-(no dedicated domain)}"
echo "  Aria2:          ${INSTALL_ARIA2}"
if [ "$INSTALL_ARIA2" = "yes" ]; then
    echo "  Aria2 BT port:  ${ARIA2_BT_PORT}"
fi
echo "  Email:          ${EMAIL:-(not configured)}"
echo "  Deployment dir: $BASE_DIR"
echo "  BT port:        $BT_PORT"
echo "  Timezone:       $TZ"
echo "  UID/GID:        ${PUID}/${PGID}"
echo ""

if [ "$NON_INTERACTIVE" = true ]; then
    echo -e "${GREEN}→ Non-interactive mode, auto-confirmed${NC}"
else
    read -p "  Confirm the above? [Y/n] " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        echo "Cancelled. Re-run the script to try again."; exit 0
    fi
fi

# ====================================================================
#                       Pre-flight Checks
# ====================================================================
step_header "Pre-flight Checks"

if [ "$EUID" -ne 0 ]; then
    err "Please run this script as root"; exit 1
fi
echo -e "${GREEN}  ✓ root privileges${NC}"
echo -e "${GREEN}  ✓ OpenList: ${DOMAIN:-(no domain, direct IP access)}${NC}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ]; then
        echo -e "${GREEN}  ✓ OS: ${PRETTY_NAME}${NC}"
    else
        warn "Current OS is $ID; this script is designed for Debian/Ubuntu and may not be fully compatible"
        record_step "OS Compatibility" "WARN" "Current: $ID, script designed for Debian/Ubuntu"
    fi
fi

AVAIL_GB=$(df -BG "$(dirname "$BASE_DIR")" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
[ -z "$AVAIL_GB" ] && AVAIL_GB=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
SKIP_SWAP=0
if [ "$AVAIL_GB" -lt 3 ]; then
    err "Only ${AVAIL_GB}GB disk remaining, insufficient for deployment (need ~3GB for Docker images and base files)"
    record_step "Disk Space" "FAIL" "Remaining: ${AVAIL_GB}GB < 3GB, cannot deploy"
    echo -e "${RED}  → Free up disk space and re-run the script${NC}"
    exit 1
elif [ "$AVAIL_GB" -lt 5 ]; then
    warn "Only ${AVAIL_GB}GB disk remaining, tight (recommend ≥5GB). Skipping swap creation to save space"
    record_step "Disk Space" "WARN" "Remaining: ${AVAIL_GB}GB < 5GB, skipping swap"
    SKIP_SWAP=1
else
    echo -e "${GREEN}  ✓ Disk space: ${AVAIL_GB}GB${NC}"
fi

MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo -e "${GREEN}  ✓ Memory: ${MEM_MB}MB${NC}"
if [ "$MEM_MB" -lt 1500 ] && [ "$SKIP_SWAP" -eq 1 ]; then
    warn "Memory < 1.5GB and insufficient disk for swap; monitor memory usage after deployment"
elif [ "$MEM_MB" -lt 1500 ]; then
    warn "Memory < 1.5GB; swap will be created automatically"
fi

# ====================================================================
#                       Step Execution
# ====================================================================

check_cmd "System Dependencies" "critical" \
    'apt update -qq && apt install -y -qq curl wget vim git unzip net-tools gpg' \
    "System dependencies installed" \
    "Installation failed; check network"

check_cmd "Timezone Config" "optional" \
    "timedatectl set-timezone $TZ && timedatectl | grep 'Time zone'" \
    "Timezone set to $TZ" \
    "Timezone configuration failed"

step_header "Swap Creation"
if [ "$SKIP_SWAP" -eq 1 ]; then
    warn "Insufficient disk space, skipping swap creation"
    record_step "Swap Creation" "WARN" "Insufficient disk, skipped"
elif [ ! -f /swapfile ]; then
    check_cmd "Swap Creation" "optional" \
        'dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null && \
         chmod 600 /swapfile && mkswap /swapfile > /dev/null && swapon /swapfile && \
         ( grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab ) && \
         ( grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf ) && \
         sysctl -p > /dev/null 2>&1 && swapon --show | grep -q swapfile' \
        "2GB swap created successfully" \
        "Swap creation failed; check disk space"
else
    echo -e "${GREEN}  ✓ Swap already exists, skipping${NC}"
    record_step "Swap Creation" "OK" "Already exists, skipped"
fi
step_header "Docker Installation"
if command -v docker &> /dev/null; then
    echo -e "${GREEN}  ✓ Docker already installed: $(docker --version)${NC}"
    record_step "Docker Installation" "OK" "Already installed: $(docker --version)"
else
    check_cmd "Docker Installation" "critical" \
        'for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
             apt remove -y $pkg 2>/dev/null || true
         done && \
         install -m 0755 -d /etc/apt/keyrings && \
         curl -fsSL --connect-timeout 10 --max-time 60 https://download.docker.com/linux/$ID/gpg | \
             gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null && \
         chmod a+r /etc/apt/keyrings/docker.gpg && \
         . /etc/os-release && \
         echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
             https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
             > /etc/apt/sources.list.d/docker.list && \
         apt update -qq && \
         apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' \
        "Docker installed successfully" \
        "Docker installation failed; check network"
fi
# Always verify Docker service (new install or pre-existing)
check_cmd "Docker Service Check" "critical" \
    'systemctl is-active --quiet docker && docker version --format "{{.Server.Version}}" > /dev/null 2>&1 && echo "Docker $(docker --version)"' \
    "Docker service running normally" \
    "Docker service is not running"

check_cmd "Directory & Permissions" "critical" \
    'mkdir -p "$BASE_DIR"/config/{openlist,qbittorrent} && \
     mkdir -p "$BASE_DIR"/temp/qBittorrent && \
     chown -R ${PUID}:${PGID} "$BASE_DIR" && \
     chmod -R 755 "$BASE_DIR" && \
     test -d "$BASE_DIR/config/openlist" && test -d "$BASE_DIR/temp/qBittorrent"' \
    "Directory structure created: $BASE_DIR" \
    "Directory creation failed"

if [ "$INSTALL_ARIA2" = "yes" ]; then
    check_cmd "Aria2 Directory Creation" "critical" \
        'mkdir -p "$BASE_DIR"/config/aria2 && \
         mkdir -p "$BASE_DIR"/temp/aria2 && \
         chown -R ${PUID}:${PGID} "$BASE_DIR/config/aria2" "$BASE_DIR/temp/aria2" && \
         chmod -R 755 "$BASE_DIR/config/aria2" "$BASE_DIR/temp/aria2"' \
        "Aria2 directories created: $BASE_DIR/config/aria2, $BASE_DIR/temp/aria2" \
        "Aria2 directory creation failed"
fi

# Always write qBit config — these three settings are key to fixing Unauthorized errors
check_cmd "qBittorrent Config Preset" "critical" \
    'QBIT_CONF_DIR="$BASE_DIR/config/qbittorrent/qBittorrent"; \
     mkdir -p "$QBIT_CONF_DIR" && \
     cat > "$QBIT_CONF_DIR/qBittorrent.conf" <<CONFEOF
[Preferences]
WebUI\\HostHeaderValidation=false
WebUI\\CSRFProtection=false
WebUI\\LocalHostAuth=false

[BitTorrent]
Session\\Port=${BT_PORT}
CONFEOF
     chown -R ${PUID}:${PGID} "$BASE_DIR/config/qbittorrent" && \
     test -s "$QBIT_CONF_DIR/qBittorrent.conf" && \
     test "$(stat -c %u "$QBIT_CONF_DIR/qBittorrent.conf")" = "${PUID}"' \
    "qBittorrent config preset, owner=${PUID}" \
    "Config preset failed"

if [ "$INSTALL_ARIA2" = "yes" ]; then
    step_header "Aria2 RPC Secret Generation"
    ARIA2_RPC_SECRET=$(openssl rand -hex 16 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || echo "$(date +%s%N)$RANDOM" | md5sum | cut -d' ' -f1)
    echo -e "${GREEN}  ✓ Aria2 RPC secret generated (see summary below)${NC}"
    record_step "Aria2 RPC Secret Generation" "OK" "$ARIA2_RPC_SECRET"
fi

step_header "docker-compose.yml Generation"

if [ -f "$BASE_DIR/docker-compose.yml" ]; then
    # Check if existing compose includes all requested services
    if [ "$INSTALL_ARIA2" = "yes" ] && ! grep -q "container_name: aria2" "$BASE_DIR/docker-compose.yml" 2>/dev/null; then
        warn "docker-compose.yml exists but missing aria2 service definition"
        warn "To add aria2, remove the compose file and re-run the script:"
        warn "  rm -f $BASE_DIR/docker-compose.yml && bash deploy.sh"
        record_step "docker-compose.yml Generation" "WARN" "Exists but missing aria2; remove and re-run"
    else
        echo -e "${GREEN}  ✓ docker-compose.yml already exists, skipping${NC}"
        record_step "docker-compose.yml Generation" "OK" "Already exists, skipped"
    fi
else
    if [ "$HAS_DOMAIN" = "yes" ]; then
        OPENLIST_BIND="127.0.0.1:5244:5244"
        QBIT_BIND="127.0.0.1:8080:8080"
        ARIA2_RPC_BIND="127.0.0.1:6800:6800"
    else
        OPENLIST_BIND="0.0.0.0:5244:5244"
        QBIT_BIND="0.0.0.0:8080:8080"
        ARIA2_RPC_BIND="0.0.0.0:6800:6800"
    fi

    cat > "$BASE_DIR/docker-compose.yml" <<COMPOSE_EOF
services:
  openlist:
    image: ghcr.io/mora-smith/openlist:latest
    container_name: openlist
    volumes:
      - ${BASE_DIR}/config/openlist:/opt/openlist/data
      - ${BASE_DIR}/temp/qBittorrent:/opt/openlist/data/temp/qBittorrent
      - ${BASE_DIR}/temp/aria2:/opt/openlist/data/temp/aria2
    ports:
      - "${OPENLIST_BIND}"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - UMASK=022
    restart: unless-stopped
    mem_limit: 512m
    networks:
      openlist_net:
        aliases:
          - openlist

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - WEBUI_PORT=8080
      - BT_PORT=${BT_PORT}
      - TZ=${TZ}
    volumes:
      - ${BASE_DIR}/config/qbittorrent:/config
      - ${BASE_DIR}/temp/qBittorrent:/opt/openlist/data/temp/qBittorrent
    ports:
      - "${QBIT_BIND}"
      - "${BT_PORT}:${BT_PORT}"
      - "${BT_PORT}:${BT_PORT}/udp"
    restart: unless-stopped
    mem_limit: 1g
    networks:
      openlist_net:
        aliases:
          - qbittorrent
COMPOSE_EOF

        if [ "$INSTALL_ARIA2" = "yes" ]; then
            cat >> "$BASE_DIR/docker-compose.yml" <<COMPOSE_EOF

  aria2:
    image: p3terx/aria2-pro:latest
    container_name: aria2
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - UMASK_SET=022
      - RPC_SECRET=${ARIA2_RPC_SECRET}
      - RPC_PORT=6800
      - LISTEN_PORT=${ARIA2_BT_PORT}
      - TZ=${TZ}
      - DISK_CACHE=64M
      - UPDATE_TRACKERS=true
    volumes:
      - ${BASE_DIR}/config/aria2:/config
      - ${BASE_DIR}/temp/aria2:/opt/openlist/data/temp/aria2
      - ${BASE_DIR}/temp/aria2:/downloads
    ports:
      - "${ARIA2_RPC_BIND}"
      - "${ARIA2_BT_PORT}:${ARIA2_BT_PORT}"
      - "${ARIA2_BT_PORT}:${ARIA2_BT_PORT}/udp"
    restart: unless-stopped
    mem_limit: 512m
    networks:
      openlist_net:
        aliases:
          - aria2
COMPOSE_EOF
        fi

        cat >> "$BASE_DIR/docker-compose.yml" <<'COMPOSE_EOF'

networks:
  openlist_net:
    name: openlist_net
COMPOSE_EOF

    if [ -s "$BASE_DIR/docker-compose.yml" ]; then
        echo -e "${GREEN}  ✓ docker-compose.yml generated${NC}"
        record_step "docker-compose.yml Generation" "OK" ""
    else
        echo -e "${RED}  ✗ docker-compose.yml generation failed${NC}"
        record_step "docker-compose.yml Generation" "FAIL" "Empty file"
        CRITICAL_FAILURE=1; print_final_report
    fi
fi

check_cmd "Docker Compose Syntax Check" "critical" \
    'cd "$BASE_DIR" && docker compose config > /dev/null 2>&1' \
    "docker-compose.yml syntax valid" \
    "docker-compose.yml syntax error"

# Generate config.json before starting containers to ensure correct site_url etc.
if [ "$HAS_DOMAIN" = "yes" ]; then
    write_config_json "https://$DOMAIN" "false"
else
    write_config_json "http://$(curl -s --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null || echo 'SERVER_IP'):5244" "false"
fi

check_cmd "Container Startup" "critical" \
    'cd "$BASE_DIR" && \
     docker compose down --remove-orphans 2>/dev/null || true && \
     docker compose up -d 2>&1' \
    "Containers launched (image pull may take a few minutes)" \
    "Container startup failed; check docker compose logs"

# Wait for container initialization (non-critical; informational)
step_header "Waiting for Containers"
info "Waiting 10 seconds for container initialization..."
sleep 10
echo ""
info "Current container status (if not all containers are shown, images may still be pulling; wait and check manually):"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
echo ""
if [ "$INSTALL_ARIA2" = "yes" ]; then
    info "Expected 3 containers: openlist, qbittorrent, aria2"
else
    info "Expected 2 containers: openlist, qbittorrent"
fi
info "Manual check: cd $BASE_DIR && docker compose ps"
record_step "Container Ready Wait" "OK" "Waited 10 seconds"

step_header "Password Retrieval"

OPENLIST_PWD=$(docker logs openlist 2>&1 | grep -i "initial password" | tail -1 || true)
if [ -n "$OPENLIST_PWD" ]; then
    echo -e "${GREEN}  ✓ OpenList initial password retrieved${NC}"
    record_step "OpenList Password Retrieval" "OK" "$OPENLIST_PWD"
else
    OPENLIST_PWD=$(docker logs openlist 2>&1 | grep -i "password" | tail -3 || true)
    if [ -n "$OPENLIST_PWD" ]; then
        echo -e "${YELLOW}  ⚠ Could not precisely match initial password; see summary below${NC}"
        record_step "OpenList Password Retrieval" "WARN" "No precise match"
    else
        echo -e "${YELLOW}  ⚠ Failed to retrieve OpenList password; see summary below${NC}"
        record_step "OpenList Password Retrieval" "WARN" "Failed to extract"
    fi
fi

QBIT_PWD=$(docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1 || true)
if [ -n "$QBIT_PWD" ]; then
    echo -e "${GREEN}  ✓ qBittorrent temporary password retrieved${NC}"
    record_step "qBittorrent Password Retrieval" "OK" "$QBIT_PWD"
else
    QBIT_PWD=$(docker logs qbittorrent 2>&1 | grep -i "password" | tail -5 || true)
    if [ -n "$QBIT_PWD" ]; then
        echo -e "${YELLOW}  ⚠ Could not precisely match qBit temp password; see summary below${NC}"
        record_step "qBittorrent Password Retrieval" "WARN" "No precise match"
    else
        echo -e "${YELLOW}  ⚠ Failed to retrieve qBittorrent password; see summary below${NC}"
        record_step "qBittorrent Password Retrieval" "WARN" "Failed to extract"
    fi
fi

if [ "$INSTALL_ARIA2" = "yes" ]; then
    # p3terx/aria2-pro prints the RPC secret at startup; try to extract from logs
    ARIA2_SECRET_FROM_LOG=$(docker logs aria2 2>&1 | grep -i 'rpc.secret\|RPC secret' | tail -1 | sed -n 's/.*[Ss]ecret[=: ]*//p' | awk '{print $1}' || true)
    if [ -n "$ARIA2_SECRET_FROM_LOG" ] && [ "${#ARIA2_SECRET_FROM_LOG}" -gt 4 ]; then
        echo -e "${GREEN}  ✓ Aria2 RPC secret extracted from logs${NC}"
        record_step "Aria2 RPC Secret Retrieval" "OK" "$ARIA2_SECRET_FROM_LOG"
    else
        echo -e "${GREEN}  ✓ Aria2 RPC secret generated${NC}"
        record_step "Aria2 RPC Secret Retrieval" "OK" "Script-generated: $ARIA2_RPC_SECRET"
    fi
fi

if [ "$HAS_DOMAIN" = "yes" ]; then
    check_cmd "Nginx + Certbot Installation" "critical" \
        'apt install -y -qq nginx certbot python3-certbot-nginx && \
         systemctl enable nginx --quiet && systemctl start nginx && \
         systemctl is-active --quiet nginx' \
        "Nginx and Certbot installed and running" \
        "Nginx/Certbot installation failed"

    step_header "Nginx Reverse Proxy Config"
    cat > "/etc/nginx/sites-available/openlist" <<NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:5244;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 100m;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 60s;
    }
}
NGINX_EOF
    ln -sf /etc/nginx/sites-available/openlist /etc/nginx/sites-enabled/openlist
    # If default site exists, disable it (original file stays in sites-available)
    if [ -f /etc/nginx/sites-enabled/default ]; then
        warn "Detected Nginx default site; disabling it"
        rm -f /etc/nginx/sites-enabled/default
    fi

    if [ -f "/etc/nginx/sites-available/openlist" ]; then
        echo -e "${GREEN}  ✓ Nginx config generated${NC}"
        record_step "Nginx Config" "OK" ""
    else
        echo -e "${RED}  ✗ Nginx config generation failed${NC}"
        record_step "Nginx Config" "FAIL" "File write failed"
        CRITICAL_FAILURE=1; print_final_report
    fi

    if [ -n "$QBIT_DOMAIN" ]; then
        cat > "/etc/nginx/sites-available/qbittorrent" <<QBIT_NGINX_EOF
server {
    listen 80;
    server_name ${QBIT_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 100m;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 60s;
    }
}
QBIT_NGINX_EOF
        ln -sf /etc/nginx/sites-available/qbittorrent /etc/nginx/sites-enabled/qbittorrent
        echo -e "${GREEN}  ✓ qBittorrent Nginx config generated${NC}"
    fi

    check_cmd "Nginx Syntax Check & Reload" "critical" \
        'nginx -t 2>&1 && systemctl reload nginx' \
        "Nginx config valid, reloaded" \
        "Nginx config error"

    step_header "SSL Certificate Request"
    check_cmd "SSL Certificate Request" "optional" \
        'certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" 2>&1 | tail -10; [ ${PIPESTATUS[0]} -eq 0 ]' \
        "SSL certificate issued successfully" \
        "SSL certificate request failed (DNS may not be resolving)"

    if [ -n "$QBIT_DOMAIN" ]; then
        check_cmd "qBittorrent SSL Certificate Request" "optional" \
            'certbot --nginx -d "$QBIT_DOMAIN" --non-interactive --agree-tos -m "$EMAIL" 2>&1 | tail -10; [ ${PIPESTATUS[0]} -eq 0 ]' \
            "qBittorrent SSL certificate issued successfully" \
            "qBittorrent SSL certificate request failed"
    fi

    check_cmd "Certificate Auto-Renewal Check" "optional" \
        'certbot renew --dry-run 2>&1 | grep -qE "Congratulations|success|not yet due"; [ ${PIPESTATUS[0]} -eq 0 ]' \
        "Certificate renewal mechanism OK" \
        "Certificate renewal test did not pass"

    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        sed -i "s|\"site_url\": \"[^\"]*\"|\"site_url\": \"https://$DOMAIN\"|" "$BASE_DIR/config/openlist/config.json"
        sed -i 's|"force_https": false|"force_https": true|' "$BASE_DIR/config/openlist/config.json"
        info "config.json updated to HTTPS mode"
        docker restart openlist > /dev/null 2>&1 || true
        info "OpenList restarted to apply config changes"
    fi
else
    info "No domain configured; skipping Nginx and HTTPS setup"
    info "OpenList listening on port 5244, qBittorrent WebUI on port 8080"
    [ "$INSTALL_ARIA2" = "yes" ] && info "Aria2 RPC listening on port 6800"
fi
step_header "Final Verification"
# Display only; no hard judgment — image pull can be slow
info "Current container status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
echo ""
RUNNING_COUNT=$(docker ps --filter "status=running" --format "{{.Names}}" 2>/dev/null | wc -l)
if [ "$INSTALL_ARIA2" = "yes" ]; then
    if [ "$RUNNING_COUNT" -ge 3 ]; then
        echo -e "${GREEN}  ✓ All 3 containers running${NC}"
        record_step "Container Status" "OK" "3/3 running"
    else
        warn "${RUNNING_COUNT} container(s) running (expected 3); may still be pulling images"
        record_step "Container Status" "WARN" "${RUNNING_COUNT}/3 running"
    fi
else
    if [ "$RUNNING_COUNT" -ge 2 ]; then
        echo -e "${GREEN}  ✓ Both 2 containers running${NC}"
        record_step "Container Status" "OK" "2/2 running"
    else
        warn "${RUNNING_COUNT} container(s) running (expected 2); may still be pulling images"
        record_step "Container Status" "WARN" "${RUNNING_COUNT}/2 running"
    fi
fi

check_cmd "OpenList Port Check" "optional" \
    'ss -tlnp | grep -q "5244" && echo "Port 5244 listening"' \
    "OpenList port 5244 listening" \
    "Port 5244 not listening"

check_cmd "qBittorrent WebUI Port Check" "optional" \
    'ss -tlnp | grep -q "8080" && echo "Port 8080 listening"' \
    "WebUI port 8080 listening" \
    "Port 8080 not listening"

check_cmd "BT Port Check" "optional" \
    'ss -tlnp | grep -q "${BT_PORT}" && echo "TCP ${BT_PORT} listening"' \
    "BT port ${BT_PORT} TCP listening" \
    "Port ${BT_PORT} not listening"

if [ "$INSTALL_ARIA2" = "yes" ]; then
    check_cmd "Aria2 RPC Port Check" "optional" \
        'ss -tlnp | grep -q "6800" && echo "Port 6800 listening"' \
        "Aria2 RPC port 6800 listening" \
        "Port 6800 not listening"

    check_cmd "Aria2 BT Port Check" "optional" \
        'ss -tlnp | grep -q "${ARIA2_BT_PORT}" && echo "TCP ${ARIA2_BT_PORT} listening"' \
        "Aria2 BT port ${ARIA2_BT_PORT} TCP listening" \
        "Port ${ARIA2_BT_PORT} not listening"
fi
step_header "Permission Verification (UID ${PUID})"
# Build directory list outside eval to avoid nested quoting issues
_OWNER_CHECK_DIRS=("$BASE_DIR/config/openlist" "$BASE_DIR/temp/qBittorrent" "$BASE_DIR/config/qbittorrent")
if [ "$INSTALL_ARIA2" = "yes" ]; then
    _OWNER_CHECK_DIRS+=("$BASE_DIR/config/aria2" "$BASE_DIR/temp/aria2")
fi

_owner_errors=0
for _d in "${_OWNER_CHECK_DIRS[@]}"; do
    _owner=$(stat -c %u "$_d" 2>/dev/null)
    if [ "$_owner" != "${PUID}" ]; then
        echo -e "  ${RED}✗${NC} $_d → owner=$_owner (expected ${PUID})"
        ((_owner_errors++))
    else
        echo -e "  ${GREEN}✓${NC} $_d → owner=${PUID}"
    fi
done
if [ "$_owner_errors" -eq 0 ]; then
    echo -e "${GREEN}  ✓ All key directories owned by ${PUID}${NC}"
    record_step "Key Directory Owner Check" "OK" ""
else
    warn "Some directories have incorrect owners"
    record_step "Key Directory Owner Check" "WARN" "${_owner_errors} directory(ies) have wrong owner"
fi

check_cmd "qBittorrent Config Owner Check" "optional" \
    'QBIT_CONF="$BASE_DIR/config/qbittorrent/qBittorrent/qBittorrent.conf"; \
     if [ -f "$QBIT_CONF" ]; then \
         OWNER=$(stat -c %u "$QBIT_CONF"); \
         echo "  $QBIT_CONF → owner=$OWNER"; [ "$OWNER" = "${PUID}" ]; \
     else echo "  Config file not yet generated"; true; fi' \
    "qBittorrent.conf owner=${PUID}" \
    "Config file owner mismatch"

check_cmd "Shared Dir Writable Check (qBittorrent)" "optional" \
    'TESTFILE="$BASE_DIR/temp/qBittorrent/.perm_test_$$"; \
     OK=0; \
     touch "$TESTFILE" && chown ${PUID}:${PGID} "$TESTFILE" 2>/dev/null && \
     [ "$(stat -c %u "$TESTFILE")" = "${PUID}" ] && OK=1; \
     rm -f "$TESTFILE"; \
     [ "$OK" -eq 1 ] && echo "  qBittorrent shared directory writable"' \
    "UID ${PUID} can create and own files in qBittorrent temp directory" \
    "Directory permission issue — this directly causes download failures"

if [ "$INSTALL_ARIA2" = "yes" ]; then
    check_cmd "Shared Dir Writable Check (Aria2)" "optional" \
        'TESTFILE="$BASE_DIR/temp/aria2/.perm_test_$$"; \
         OK=0; \
         touch "$TESTFILE" && chown ${PUID}:${PGID} "$TESTFILE" 2>/dev/null && \
         [ "$(stat -c %u "$TESTFILE")" = "${PUID}" ] && OK=1; \
         rm -f "$TESTFILE"; \
         [ "$OK" -eq 1 ] && echo "  Aria2 shared directory writable"' \
        "UID ${PUID} can create and own files in Aria2 temp directory" \
        "Aria2 directory permission issue; downloads may not complete"
fi

if [ "$HAS_DOMAIN" = "yes" ]; then
    check_cmd "Nginx HTTP Check" "optional" \
        'HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:80/ --connect-timeout 5 2>/dev/null); \
         echo "HTTP status code: $HTTP_CODE"; [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 500 ]' \
        "Nginx HTTP response OK" \
        "Nginx HTTP response abnormal"

    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        check_cmd "Nginx HTTPS Check" "optional" \
            'CERT_EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/'"$DOMAIN"'/fullchain.pem" 2>/dev/null | cut -d= -f2); \
             echo "Certificate expires: $CERT_EXPIRY"' \
            "HTTPS certificate ready" \
            "HTTPS check failed"
    else
        info "SSL certificate not yet obtained; skipping HTTPS check"
        record_step "Nginx HTTPS Check" "WARN" "Certificate not present; ensure DNS resolves and re-request"
    fi
fi

print_final_report
