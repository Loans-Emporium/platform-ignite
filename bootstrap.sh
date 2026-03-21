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
VERSION="10.5" # V10.5 Release
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

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Loans Emporium Platform - ignite Bootstrap V10.5       ║"
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
# PHASE 1: Install Base Tools
# ─────────────────────────────────────────────────────────────────
log_info "Phase 1: Installing base tools (Git, curl, jq, pg_dump)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq curl git jq unzip gpg wget postgresql-client openssl > /dev/null 2>&1

# ─────────────────────────────────────────────────────────────────
# PHASE 2: Install Docker Engine
# ─────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_info "Phase 2: Installing Docker Engine..."
    curl -fsSL https://get.docker.com | bash > /dev/null 2>&1
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
    curl -fsSL https://rclone.org/install.sh | bash > /dev/null 2>&1
fi
if ! command -v yq &>/dev/null; then
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq > /dev/null 2>&1
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
    bws secret list --access-token "$BWS_TOKEN" -o json 2>/dev/null | \
        jq -r --arg k "$key" '.[] | select((.key | ascii_upcase) == ($k | ascii_upcase)) | .value' || echo ""
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
# PHASE 6: Operator Provisioning (Deploy User)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 6: Provisioning 'deploy' operator..."
DEPLOY_PASS=$(get_bws_value "deploy-user-password")
[[ -z "$DEPLOY_PASS" || "$DEPLOY_PASS" == "null" ]] && DEPLOY_PASS=$(get_bws_value "deploy_user_password")

if [[ -n "$DEPLOY_PASS" && "$DEPLOY_PASS" != "null" ]]; then
    if ! id "deploy" &>/dev/null; then
        log_info "Creating 'deploy' user with Docker access..."
        useradd -m -s /bin/bash deploy
        echo "deploy:$DEPLOY_PASS" | chpasswd
        usermod -aG docker deploy
        echo "deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart docker, /usr/bin/docker *, /opt/platform/bin/platform *, /usr/sbin/reboot, /usr/sbin/shutdown, /usr/bin/apt, /usr/bin/apt-get, /usr/sbin/ufw, /usr/bin/ln -sf /opt/platform/bin/platform /usr/local/bin/platform, /usr/bin/bash, /usr/bin/mount, /usr/bin/umount, /usr/bin/rm, /usr/bin/true, /usr/bin/crontab *, /usr/bin/ss *, /usr/bin/git, /usr/bin/chown, /usr/bin/chmod, /usr/bin/find, /usr/bin/mkdir" > /etc/sudoers.d/deploy
        mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
        cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys 2>/dev/null || true
        chown -R deploy:deploy /home/deploy/.ssh
        log_success "Deploy user created and secured."
    fi
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 7: Network & Localization
# ─────────────────────────────────────────────────────────────────
log_info "Phase 7: Configuring network (Tailscale) & Localization..."

# Tailscale setup
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | bash > /dev/null 2>&1
fi
TS_KEY=$(get_bws_value "TAILSCALE_AUTH_KEY")
if [[ -n "$TS_KEY" && "$TS_KEY" != "null" ]]; then
    tailscale up --authkey="$TS_KEY" --hostname="$VPS_HOSTNAME" --ssh > /dev/null 2>&1 || log_warn "Tailscale join failed."
    log_success "Tailscale mesh joined."
fi

# Hostname & TZ
timedatectl set-timezone "$VPS_TZ" || true
hostnamectl set-hostname "$VPS_HOSTNAME" || true
echo "127.0.0.1 $VPS_HOSTNAME" >> /etc/hosts
log_success "System localization applied."

# ─────────────────────────────────────────────────────────────────
# PHASE 8: Platform Inception (Source Clone)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 8: Cloning platform-core repository..."
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
# PHASE 9: Platform Orchestration (Sub-Bootstrap)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 9: Triggering interior platform-bootstrap..."
export BWS_TOKEN="$BWS_TOKEN"
bash "$INSTALL_DIR/bootstrap/platform-bootstrap.sh"
ln -sf "$INSTALL_DIR/bin/platform" /usr/local/bin/platform
chmod +x "$INSTALL_DIR/bin/platform"
log_success "Platform CLI linked and initialized."

# ─────────────────────────────────────────────────────────────────
# PHASE 10: Security Hardening & Handover
# ─────────────────────────────────────────────────────────────────
log_info "Phase 10: Finalizing security hardening..."

# 1. BWS Persistence
echo "$BWS_TOKEN" > /opt/platform/config/.bws_token
chmod 640 /opt/platform/config/.bws_token
cat > /etc/profile.d/platform.sh <<'PROFILE'
export BWS_TOKEN="$(cat /opt/platform/config/.bws_token 2>/dev/null || true)"
PROFILE

# 2. Permissions & Owner
chown -R deploy:deploy /opt/platform /etc/loans-platform
chown root:deploy /opt/platform/config/.bws_token
git config --system --add safe.directory /opt/platform

# 3. Log Hygiene
cat <<EOF > /etc/logrotate.d/platform
/var/log/platform-*.log { weekly ; rotate 4 ; compress ; missingok ; notifempty ; create 0640 root root }
EOF

# 4. Perimeter Hardening
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
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
echo "   tailscale ssh deploy@$VPS_HOSTNAME"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  ⚠️  EXIT ROOT NOW - ROOT SSH IS DISABLED${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
