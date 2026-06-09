#!/bin/bash
#==============================================================================
# OpenList Nginx + Let's Encrypt SSL — standalone (run before main deploy)
# Usage: bash deploy_arguo_ssl.sh  (root user)
#
# Run this FIRST to obtain SSL certificates, then snapshot your VM.
# Once snapshot is taken, run deploy_arguo_core.sh for everything else.
#
# CLI args override defaults:
#   --domain <domain>        OpenList domain
#   --qbit-domain <domain>   qBittorrent domain
#   --email <email>          Let's Encrypt notification email
#   -y, --non-interactive    Skip confirmation
#   -h, --help               Show help
#==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# ---- Configurable defaults ----
DOMAIN="${DOMAIN:-pan.arguo.org}"
QBIT_DOMAIN="${QBIT_DOMAIN:-qb.arguo.org}"
EMAIL="${EMAIL:-i@arguo.org}"
NON_INTERACTIVE=true

# ---- Helpers ----
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
step_header() { echo ""; echo -e "${BOLD}━━━━━━ $1 ━━━━━━${NC}"; }

# ---- CLI argument parsing ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)        DOMAIN="$2"; shift 2 ;;
        --qbit-domain)   QBIT_DOMAIN="$2"; shift 2 ;;
        --email)         EMAIL="$2"; shift 2 ;;
        -y|--non-interactive) NON_INTERACTIVE=true; shift ;;
        -h|--help)
            echo "Usage: bash deploy_arguo_ssl.sh [options]"
            echo ""
            echo "Options:"
            echo "  --domain <domain>        OpenList domain"
            echo "  --qbit-domain <domain>   qBittorrent domain"
            echo "  --email <email>          Let's Encrypt email"
            echo "  -y, --non-interactive    Skip confirmation"
            echo "  -h, --help               Show this help"
            exit 0 ;;
        *)
            echo "Unknown option: $1, use -h for help"; exit 1 ;;
    esac
done

# ---- Pre-flight ----
if [ "$(id -u)" -ne 0 ]; then
    err "Must run as root"; exit 1
fi

echo ""
echo -e "${BOLD}══════════ Nginx + SSL Certificate Setup ══════════${NC}"
echo ""
echo -e "  OpenList domain:    ${GREEN}${DOMAIN}${NC}"
echo -e "  qBittorrent domain: ${GREEN}${QBIT_DOMAIN:-<none>}${NC}"
echo -e "  Email:              ${GREEN}${EMAIL}${NC}"
echo ""

if [ "$NON_INTERACTIVE" != "true" ]; then
    read -p "  Confirm? [Y/n] " CONFIRM
    case "$CONFIRM" in [Nn]*) exit 0 ;; esac
fi

# ---- Install Nginx + Certbot ----
step_header "Nginx + Certbot Installation"
apt update -qq && apt install -y -qq nginx certbot python3-certbot-nginx
systemctl enable nginx --quiet && systemctl start nginx
if systemctl is-active --quiet nginx; then
    echo -e "${GREEN}  ✓ Nginx and Certbot installed and running${NC}"
else
    err "Nginx failed to start"; exit 1
fi

# ---- Nginx Config: OpenList ----
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
echo -e "${GREEN}  ✓ OpenList Nginx config generated${NC}"

# ---- Nginx Config: qBittorrent ----
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

# Disable default site
if [ -f /etc/nginx/sites-enabled/default ]; then
    warn "Disabling default Nginx site"
    rm -f /etc/nginx/sites-enabled/default
fi

# ---- Nginx Syntax Check ----
echo ""
if nginx -t 2>&1; then
    systemctl reload nginx
    echo -e "${GREEN}  ✓ Nginx config valid and reloaded${NC}"
else
    err "Nginx config syntax error, aborting"; exit 1
fi

# ---- SSL Certificate: OpenList ----
step_header "SSL Certificate — $DOMAIN"
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}  ✓ SSL certificate issued for $DOMAIN${NC}"
else
    err "SSL certificate request failed for $DOMAIN"
    err "Check: DNS resolves to this server? dig +short $DOMAIN"
    exit 1
fi

# ---- SSL Certificate: qBittorrent ----
if [ -n "$QBIT_DOMAIN" ]; then
    step_header "SSL Certificate — $QBIT_DOMAIN"
    certbot --nginx -d "$QBIT_DOMAIN" --non-interactive --agree-tos -m "$EMAIL" 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}  ✓ SSL certificate issued for $QBIT_DOMAIN${NC}"
    else
        warn "SSL certificate request failed for $QBIT_DOMAIN (non-fatal)"
        warn "Manual: certbot --nginx -d $QBIT_DOMAIN"
    fi
fi

# ---- Auto-Renewal ----
step_header "Certificate Auto-Renewal Check"
if certbot renew --dry-run 2>&1 | grep -qE "Congratulations|success|not yet due"; then
    echo -e "${GREEN}  ✓ Certificate auto-renewal OK${NC}"
else
    warn "Renewal dry-run had warnings (check manually: certbot renew --dry-run)"
fi

# ---- Summary ----
echo ""
echo -e "${BOLD}══════════ SSL Setup Complete ══════════${NC}"
echo ""
echo -e "  ${GREEN}https://${DOMAIN}${NC}"
[ -n "$QBIT_DOMAIN" ] && echo -e "  ${GREEN}https://${QBIT_DOMAIN}${NC}"
echo ""
echo "  Certificate expiry:"
openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" 2>/dev/null || true
echo ""
echo -e "${YELLOW}► Next: take a VM snapshot, then run deploy_arguo_core.sh${NC}"
