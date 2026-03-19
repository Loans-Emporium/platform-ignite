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
#   3. Installs Cloudflared (tunnel)
#   4. Installs bws CLI (Bitwarden Secrets Manager)
#   5. Clones platform-core and triggers platform-bootstrap.sh

set -euo pipefail

# Configuration
GITHUB_ORG="${GITHUB_ORG:-Loans-Emporium}"
GITHUB_REPO="platform-core"
INSTALL_DIR="/opt/platform"

# F-01/F-21: Read VERSION dynamically if available
VERSION="V8.2" # Fallback
if [[ -f "$INSTALL_DIR/VERSION" ]]; then
    VERSION=$(cat "$INSTALL_DIR/VERSION")
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Loans Emporium Platform - ignite Bootstrap $VERSION        ║"
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
# PHASE 0.5: Pre-Flight Prompt
# ─────────────────────────────────────────────────────────────────

# Forced Security Prompt: Avoid upfront token supply to prevent history/process exposure
log_info "Security check: Forced Bitwarden Token Prompt..."
unset BWS_TOKEN # Clear any pre-supplied token from environment
echo -n -e "${YELLOW}[PROMPT]${NC} Please enter your Bitwarden Secrets Manager Access Token: "
read -s BWS_TOKEN
echo "" # Add newline after silent input
export BWS_TOKEN

if [[ -z "$BWS_TOKEN" ]]; then
    log_error "BWS_TOKEN is required to proceed. Bootstrap aborted."
    exit 1
fi

log_info "Pre-flight checks passed."

# ─────────────────────────────────────────────────────────────────
# PHASE 1: Install Base Tools
# ─────────────────────────────────────────────────────────────────

log_info "Phase 1: Installing base tools..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl git jq unzip gpg > /dev/null 2>&1

# ─────────────────────────────────────────────────────────────────
# PHASE 2: Install Docker
# ─────────────────────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
    log_info "Phase 2: Installing Docker..."
    curl -fsSL https://get.docker.com | bash > /dev/null 2>&1
    systemctl enable --now docker
    log_info "Docker installed and started."
else
    log_info "Phase 2: Docker already installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 3: Install Tailscale
# ─────────────────────────────────────────────────────────────────

if ! command -v tailscale &>/dev/null; then
    log_info "Phase 3: Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | bash > /dev/null 2>&1
    log_info "Tailscale installed."
else
    log_info "Phase 3: Tailscale already installed."
fi

# Attempt auto-join if Auth Key is in Bitwarden
TS_KEY=$(bws secret get "TAILSCALE_AUTH_KEY" --access-token "$BWS_TOKEN" -o json | jq -r '.value' 2>/dev/null || echo "")
if [[ -n "$TS_KEY" && "$TS_KEY" != "null" ]]; then
    log_info "Phase 3.1: Authenticating Tailscale mesh network..."
    tailscale up --authkey="$TS_KEY" > /dev/null 2>&1 || log_warn "Tailscale auto-join failed. You may need to run it manually."
    unset TS_KEY
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 4: Install Cloudflared
# ─────────────────────────────────────────────────────────────────

if ! command -v cloudflared &>/dev/null; then
    log_info "Phase 4: Installing Cloudflared..."
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb > /dev/null 2>&1
    rm -f /tmp/cloudflared.deb
    log_info "Cloudflared installed."
else
    log_info "Phase 4: Cloudflared already installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 5: Install Bitwarden Secrets Manager CLI (bws)
# ─────────────────────────────────────────────────────────────────

if ! command -v bws &>/dev/null; then
    log_info "Phase 5: Installing Bitwarden Secrets Manager CLI..."
    # N-03: Dynamically fetch latest bws version
    BWS_VERSION=$(curl -fsSL "https://api.github.com/repos/bitwarden/sdk/releases/latest" | jq -r '.tag_name' | sed 's/bws-v//')
    if [[ -z "$BWS_VERSION" || "$BWS_VERSION" == "null" ]]; then
        log_warn "Failed to fetch latest bws version, falling back to 0.5.0"
        BWS_VERSION="0.5.0"
    fi
    curl -fsSL "https://github.com/bitwarden/sdk/releases/download/bws-v${BWS_VERSION}/bws-x86_64-unknown-linux-gnu-${BWS_VERSION}.zip" -o /tmp/bws.zip
    unzip -o /tmp/bws.zip -d /usr/local/bin/ > /dev/null 2>&1
    chmod +x /usr/local/bin/bws
    rm -f /tmp/bws.zip
    log_info "bws CLI (v${BWS_VERSION}) installed."
else
    log_info "Phase 5: bws CLI already installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 5.5: Install Rclone and YQ
# ─────────────────────────────────────────────────────────────────

if ! command -v rclone &>/dev/null; then
    log_info "Phase 5.5: Installing Rclone..."
    curl -fsSL https://rclone.org/install.sh | bash > /dev/null 2>&1
    log_info "Rclone installed."
fi

if ! command -v yq &>/dev/null; then
    log_info "Phase 5.5: Installing YQ (Official Binary)..."
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq > /dev/null 2>&1
    chmod +x /usr/local/bin/yq
    log_info "YQ installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 6: Fetch Secrets and Clone Platform-Core
# ─────────────────────────────────────────────────────────────────

log_info "Phase 6: Fetching secrets from Bitwarden..."

# Fetch GitHub PAT for cloning private repo
GITHUB_TOKEN=$(bws secret get "github-pat" --access-token "$BWS_TOKEN" -o json | jq -r '.value' 2>/dev/null || echo "")

if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "null" ]]; then
    log_warn "Failed to fetch GitHub PAT. Defaulting to public clone."
    GITHUB_TOKEN=""
fi

# Localization
VPS_TZ=$(bws secret get "vps-timezone" --access-token "$BWS_TOKEN" -o json | jq -r '.value' 2>/dev/null || echo "Asia/Kolkata")
VPS_HOSTNAME=$(bws secret get "vps-hostname" --access-token "$BWS_TOKEN" -o json | jq -r '.value' 2>/dev/null || echo "loans-platform-vps-1")

log_info "Phase 6.1: Applying system localization..."
timedatectl set-timezone "$VPS_TZ" || true
hostnamectl set-hostname "$VPS_HOSTNAME" || true
echo "127.0.0.1 $VPS_HOSTNAME" >> /etc/hosts

log_info "Secrets and localization applied successfully."

# ─────────────────────────────────────────────────────────────────
# PHASE 6.5: Docker Login to GHCR (V8.2 Standard)
# ─────────────────────────────────────────────────────────────────

log_info "Phase 6.5: Authenticating with GHCR..."
GHCR_TOKEN=$(bws secret get "github-ghcr-token" --access-token "$BWS_TOKEN" -o json | jq -r '.value' 2>/dev/null || echo "")

if [[ -n "$GHCR_TOKEN" && "$GHCR_TOKEN" != "null" ]]; then
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "${GITHUB_ORG}" --password-stdin > /dev/null 2>&1
    log_info "GHCR authenticated successfully."
    unset GHCR_TOKEN
else
    log_warn "GHCR token not found. Private image pulls may fail."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 7: Clone Platform-Core
# ─────────────────────────────────────────────────────────────────

log_info "Phase 7: Cloning platform-core..."

rm -rf "$INSTALL_DIR"
if [[ -n "$GITHUB_TOKEN" ]]; then
    git -c http.extraHeader="Authorization: Bearer ${GITHUB_TOKEN}" clone "https://github.com/${GITHUB_ORG}/${GITHUB_REPO}.git" "$INSTALL_DIR"
else
    git clone "https://github.com/${GITHUB_ORG}/${GITHUB_REPO}.git" "$INSTALL_DIR"
fi
unset GITHUB_TOKEN

log_info "Platform-core cloned to $INSTALL_DIR"

# ─────────────────────────────────────────────────────────────────
# PHASE 8: Trigger Platform Bootstrap
# ─────────────────────────────────────────────────────────────────

log_info "Phase 8: Triggering platform-bootstrap.sh..."

export BWS_TOKEN="$BWS_TOKEN"
bash "$INSTALL_DIR/bootstrap/platform-bootstrap.sh"

# ─────────────────────────────────────────────────────────────────
# PHASE 8.5: Security & Hygiene Hardening
# ─────────────────────────────────────────────────────────────────
log_info "Phase 8.5: Hardening system..."

# 1. Deploy User Provisioning
DEPLOY_PASS=$(bws secret get "deploy-user-password" --access-token "$BWS_TOKEN" -o json | jq -r '.value' 2>/dev/null || echo "")
if [[ -n "$DEPLOY_PASS" && "$DEPLOY_PASS" != "null" ]]; then
    if ! id "deploy" &>/dev/null; then
        log_info "Creating 'deploy' user with restricted sudo..."
        useradd -m -s /bin/bash deploy
        echo "deploy:$DEPLOY_PASS" | chpasswd
        usermod -aG docker deploy
        
        # Restricted Sudo: Only for service/platform commands
        echo "deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart docker, /usr/bin/docker *, /opt/platform/bin/platform *" > /etc/sudoers.d/deploy
        
        mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
        cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys 2>/dev/null || true
        chown -R deploy:deploy /home/deploy/.ssh
    fi
fi

# 2. Log Hygiene (Logrotate)
log_info "Configuring log rotation..."
cat <<EOF > /etc/logrotate.d/platform
/var/log/platform-*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF

# 3. Disable Root SSH Login
log_info "Disabling root SSH login (PermitRootLogin no)..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl reload sshd || true

# 4. Phase 8.6: Persist BWS_TOKEN for operators and cron (N-01)
log_info "Phase 8.6: Persisting BWS_TOKEN for operators and cron..."
cat > /etc/profile.d/platform.sh <<'PROFILE'
# Loans Emporium Platform — sourced at login
export BWS_TOKEN="$(cat /opt/platform/config/.bws_token 2>/dev/null || true)"
PROFILE

# Write token to a root-only file
echo "$BWS_TOKEN" > /opt/platform/config/.bws_token
chmod 600 /opt/platform/config/.bws_token
chown root:root /opt/platform/config/.bws_token

# ─────────────────────────────────────────────────────────────────
# PHASE 9: Complete
# ─────────────────────────────────────────────────────────────────

TS_IP=$(tailscale ip -4 2>/dev/null | head -n 1 || echo "not-configured")

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     🎉 ignite Bootstrap Complete!                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "✅ Docker:      $(docker --version | cut -d' ' -f3 | tr -d ',')"
echo "✅ Tailscale:   $(tailscale version | head -1)"
echo "✅ Cloudflared: $(cloudflared version | head -1)"
echo "✅ bws CLI:     $(bws --version)"
echo "✅ Platform:    $INSTALL_DIR"
echo ""
echo "📡 Tailscale IP: $TS_IP"
echo ""
echo "🚀 Next Steps:"
echo "   1. Verify: platform status"
echo "   2. Check logs: platform logs"
echo "   3. Read docs: $INSTALL_DIR/docs/"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
