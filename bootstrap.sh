#!/usr/bin/env bash
# bootstrap.sh — Public VPS bootstrap for Loans Emporium Platform
# Part of ignite (PUBLIC repository)
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Loans-Emporium/platform-ignite/main/bootstrap.sh)
#
# This script:
#   1. Installs Docker, Git, curl, jq
#   2. Installs Tailscale (mesh networking)
#   3. Installs bws CLI (Bitwarden Secrets Manager)
#   4. Clones platform-core and triggers platform-bootstrap.sh

set -euo pipefail

# Configuration
GITHUB_ORG="${GITHUB_ORG:-Loans-Emporium}"
GITHUB_REPO="platform-core"
INSTALL_DIR="/opt/platform"

# Localization (Manageable via Env or hardcoded here)
VPS_HOSTNAME="${VPS_HOSTNAME:-loans-platform-vps-1}"
VPS_TZ="${VPS_TZ:-Asia/Kolkata}"

# F-01/F-21: Read VERSION dynamically if available
VERSION="11.0" # V11.0 Root Resilience
if [[ -f "$INSTALL_DIR/VERSION" ]]; then
    VERSION=$(cat "$INSTALL_DIR/VERSION")
fi

# ── Canonical CLI Versions ──────────────────────────────────────────────────
BWS_VERSION="1.0.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

verify_checksum() {
    local file="$1"
    local expected_sha="$2"
    echo "${expected_sha}  ${file}" | sha256sum --check --status || {
        log_error "Checksum verification failed for ${file}!"
        exit 1
    }
}

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Loans Emporium Platform - ignite Bootstrap V11.0       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────────
# PHASE 0: Pre-flight Checks
# ─────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    log_error "Please run as root: sudo bash bootstrap.sh"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 1: OS Update & Base Tools
# ─────────────────────────────────────────────────────────────────
log_info "Phase 1: Updating OS and installing base tools (Git, curl, jq, pg_dump 17)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq > /dev/null 2>&1

# V10.6.9: Install Postgres 17 Client for Neon/Cloud compatibility
if ! command -v pg_dump &>/dev/null || [[ $(pg_dump --version | grep -oE '[0-9]+' | head -1) -lt 17 ]]; then
    log_info "Adding official PostgreSQL repository for version 17 client..."
    install -d /usr/share/postgresql-common/pgdg
    curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
fi

apt-get update -qq && apt-get install -y -qq curl git jq unzip gpg wget postgresql-client-17 openssl > /dev/null 2>&1

# ─────────────────────────────────────────────────────────────────
# PHASE 2: Install Docker Engine
# ─────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_info "Phase 2: Installing Docker Engine..."
    curl -fsSL https://get.docker.com -o /tmp/install-docker.sh
    # Note: We rely on the official installer's integrity for the script itself, 
    # but we force the repo check during apt-get.
    bash /tmp/install-docker.sh > /dev/null 2>&1
    systemctl enable --now docker
    log_success "Docker installed and started."
else
    log_info "Phase 2: Docker already installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 3: Install Utility Binaries (Rclone, YQ)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 3: Installing Rclone & YQ..."
if ! command -v rclone &>/dev/null; then
    curl -fsSL https://rclone.org/install.sh -o /tmp/install-rclone.sh
    bash /tmp/install-rclone.sh > /dev/null 2>&1
fi
if ! command -v yq &>/dev/null; then
    YQ_VER="v4.44.3"
    YQ_SHA="887c956cc65860d5c074e6456075c75ed9f30e9d6d7aa9d1c1432f808759695d"
    wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VER}/yq_linux_amd64" -O /usr/local/bin/yq
    verify_checksum "/usr/local/bin/yq" "$YQ_SHA"
    chmod +x /usr/local/bin/yq
fi
log_success "Utilities installed."

# ─────────────────────────────────────────────────────────────────
# PHASE 4: Install Bitwarden Secrets Manager (bws)
# ─────────────────────────────────────────────────────────────────
INSTALLED_BWS=$(bws --version 2>/dev/null | awk '{print $2}' || echo "none")
if [[ "$INSTALLED_BWS" != "$BWS_VERSION" ]]; then
    log_info "Phase 4: Installing Bitwarden SDK CLI v${BWS_VERSION}..."
    curl -fsSL "https://github.com/bitwarden/sdk/releases/download/bws-v${BWS_VERSION}/bws-x86_64-unknown-linux-gnu-${BWS_VERSION}.zip" -o /tmp/bws.zip
    mkdir -p /tmp/bws_pkg && unzip -q /tmp/bws.zip -d /tmp/bws_pkg
    install -m 755 /tmp/bws_pkg/bws /usr/local/bin/bws
    rm -rf /tmp/bws.zip /tmp/bws_pkg
    log_success "bws CLI installed."
fi

# Helper for Bitwarden Fetching (bws v1.x compatibility)
get_bws_value() {
    local key="$1"
    # V11.0: Hardened to prevent pipefail crashes on empty bws output
    bws secret list --access-token "$BWS_TOKEN" -o json 2>/dev/null | \
        jq -r --arg k "$key" '.[] | select((.key | ascii_upcase) == ($k | ascii_upcase)) | .value' 2>/dev/null || echo ""
}

# ─────────────────────────────────────────────────────────────────
# PHASE 5: Security Challenge & Authentication
# ─────────────────────────────────────────────────────────────────
log_info "Phase 5: Security checks & BWS authentication..."
unset BWS_TOKEN
echo -n -e "${YELLOW}[PROMPT]${NC} Please enter your Bitwarden Secrets Manager Access Token: "
read -s BWS_TOKEN < /dev/tty
echo ""
export BWS_TOKEN

if [[ -z "$BWS_TOKEN" ]]; then
    log_error "BWS_TOKEN is required. Bootstrap aborted."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 6: Platform Inception (Source Clone)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 6: Cloning platform-core repository..."
GITHUB_TOKEN=$(get_bws_value "GITHUB_PAT")
if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "null" ]]; then
    log_error "Critical Secret Missing: GITHUB_PAT. Clone failed."
    exit 1
fi
rm -rf "$INSTALL_DIR"
git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${GITHUB_REPO}.git" "$INSTALL_DIR" > /dev/null 2>&1
unset GITHUB_TOKEN
log_success "Platform source cloned to $INSTALL_DIR."

# ─────────────────────────────────────────────────────────────────
# PHASE 7: Tailscale Join
# ─────────────────────────────────────────────────────────────────
log_info "Phase 7: Configuring Tailscale mesh networking..."

# Tailscale setup
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | bash > /dev/null 2>&1
fi
TS_KEY=$(get_bws_value "TAILSCALE_AUTH_KEY")
if [[ -n "$TS_KEY" && "$TS_KEY" != "null" ]]; then
    log_info "Attempting Tailscale mesh join..."
    tailscale up --authkey="$TS_KEY" --hostname="$VPS_HOSTNAME" --ssh || log_warn "Tailscale join failed. Continuing..."
    log_success "Tailscale mesh joined."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 8: Network Hardening (UFW) & Localization
# ─────────────────────────────────────────────────────────────────
log_info "Phase 8: Enforcing network lockdown (UFW) & Localization..."
apt-get install -y -qq ufw > /dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny 22/tcp
if ip addr show tailscale0 &>/dev/null; then
    ufw allow in on tailscale0
    log_success "Tailscale interface recognized. Firewall rules applied."
fi
ufw --force enable

# Hostname & TZ
timedatectl set-timezone "$VPS_TZ" || true
hostnamectl set-hostname "$VPS_HOSTNAME" || true
echo "127.0.0.1 $VPS_HOSTNAME" >> /etc/hosts
log_success "System localization applied."

# ─────────────────────────────────────────────────────────────────
# PHASE 9: Platform Orchestration (Sub-Bootstrap)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 9: Triggering interior platform-bootstrap..."
# V11.0: Pass token inline only to the interior bootstrap (Audit F-04)
BWS_TOKEN="$BWS_TOKEN" bash "$INSTALL_DIR/bootstrap/platform-bootstrap.sh"
ln -sf "$INSTALL_DIR/bin/platform" /usr/local/bin/platform
chmod +x "$INSTALL_DIR/bin/platform"
log_success "Platform CLI linked and initialized."

# ─────────────────────────────────────────────────────────────────
# PHASE 10: Security Hardening & Handover
# ─────────────────────────────────────────────────────────────────
log_info "Phase 10: Finalizing security hardening..."

# 1. BWS Persistence (Hardened)
mkdir -p /opt/platform/config
echo "$BWS_TOKEN" > /opt/platform/config/.bws_token
chmod 600 /opt/platform/config/.bws_token
# V11.0: Removed profile.d export to prevent environment leakage

# 2. Audit Trail
mkdir -p /opt/platform/state
(cd "$INSTALL_DIR" && git rev-parse HEAD) > /opt/platform/state/bootstrap-sha

# 3. Permissions & Owner
chown -R root:root /opt/platform /etc/loans-platform
git config --system --add safe.directory /opt/platform

# 3. Log Hygiene
cat <<EOF > /etc/logrotate.d/platform
/var/log/platform-*.log { weekly ; rotate 4 ; compress ; missingok ; notifempty ; create 0640 root root }
EOF

# 4. Perimeter Hardening
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

TS_IP=$(tailscale ip -4 2>/dev/null | head -n 1 || echo "not-reached")

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     🎉 ignite Bootstrap Complete!                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "✅ Docker:      $(docker --version | cut -d' ' -f3 | tr -d ',')"
echo "✅ Tailscale:   $(tailscale version | head -1)"
echo "✅ Platform:    $INSTALL_DIR"
echo "📡 Tailscale IP: $TS_IP"
echo ""
echo "🚀 Next Steps:"
echo "   tailscale ssh root@$VPS_HOSTNAME"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  🛡️ ROOT ACCESS ENABLED VIA TAILSCALE ONLY${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
