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
log_info "Phase 1: Installing base tools..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq curl git jq unzip gpg > /dev/null 2>&1

# ─────────────────────────────────────────────────────────────────
# PHASE 2: Install Bitwarden Secrets Manager CLI (bws)
# ─────────────────────────────────────────────────────────────────
INSTALLED_BWS=$(bws --version 2>/dev/null | awk '{print $2}' || echo "none")
if [[ "$INSTALLED_BWS" != "$BWS_VERSION" ]]; then
    log_info "Phase 2: Installing Bitwarden Secrets Manager CLI v${BWS_VERSION}..."
    curl -fsSL "https://github.com/bitwarden/sdk/releases/download/bws-v${BWS_VERSION}/bws-x86_64-unknown-linux-gnu-${BWS_VERSION}.zip" -o /tmp/bws.zip
    mkdir -p /tmp/bws_pkg && unzip -q /tmp/bws.zip -d /tmp/bws_pkg
    install -m 755 /tmp/bws_pkg/bws /usr/local/bin/bws
    rm -rf /tmp/bws.zip /tmp/bws_pkg
    log_info "bws CLI v${BWS_VERSION} installed."
fi

# ─────────────────────────────────────────────────────────────────
# Helper for Bitwarden Fetching (bws v1.x compatibility)
# ─────────────────────────────────────────────────────────────────
get_bws_value() {
    local key="$1"
    bws secret list --access-token "$BWS_TOKEN" -o json 2>/dev/null | \
        jq -r --arg k "$key" '.[] | select((.key | ascii_upcase) == ($k | ascii_upcase)) | .value' || echo ""
}

# ─────────────────────────────────────────────────────────────────
# PHASE 3: Pre-Flight Prompt
# ─────────────────────────────────────────────────────────────────
log_info "Phase 3: Security checks & authentication..."
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
# PHASE 4: Deploy User Provisioning (V10.5 Fix)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 4: Provisioning 'deploy' operator..."
DEPLOY_PASS=$(get_bws_value "deploy-user-password")
[[ -z "$DEPLOY_PASS" || "$DEPLOY_PASS" == "null" ]] && DEPLOY_PASS=$(get_bws_value "deploy_user_password")

if [[ -n "$DEPLOY_PASS" && "$DEPLOY_PASS" != "null" ]]; then
    if ! id "deploy" &>/dev/null; then
        log_info "Creating 'deploy' user with restricted sudo..."
        useradd -m -s /bin/bash deploy
        echo "deploy:$DEPLOY_PASS" | chpasswd
        usermod -aG docker deploy
        echo "deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart docker, /usr/bin/docker *, /opt/platform/bin/platform *, /usr/sbin/reboot, /usr/sbin/shutdown, /usr/bin/apt, /usr/bin/apt-get, /usr/sbin/ufw, /usr/bin/ln -sf /opt/platform/bin/platform /usr/local/bin/platform, /usr/bin/bash, /usr/bin/mount, /usr/bin/umount, /usr/bin/rm, /usr/bin/true, /usr/bin/crontab *, /usr/bin/ss *, /usr/bin/git, /usr/bin/chown, /usr/bin/chmod, /usr/bin/find, /usr/bin/mkdir" > /etc/sudoers.d/deploy
        mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
        cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys 2>/dev/null || true
        chown -R deploy:deploy /home/deploy/.ssh
        log_success "Deploy user created."
    fi
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 5: Install Docker
# ─────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_info "Phase 5: Installing Docker..."
    curl -fsSL https://get.docker.com | bash > /dev/null 2>&1
    systemctl enable --now docker
    log_info "Docker installed and started."
else
    log_info "Phase 5: Docker already installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 6: System Localization (Host & Time)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 6: Applying system localization..."

log_info "Applying localization: Hostname=$VPS_HOSTNAME, TZ=$VPS_TZ"
timedatectl set-timezone "$VPS_TZ" || true
hostnamectl set-hostname "$VPS_HOSTNAME" || true
echo "127.0.0.1 $VPS_HOSTNAME" >> /etc/hosts

# ─────────────────────────────────────────────────────────────────
# PHASE 7: Install Tailscale
# ─────────────────────────────────────────────────────────────────

if ! command -v tailscale &>/dev/null; then
    log_info "Phase 7: Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | bash > /dev/null 2>&1
    log_info "Tailscale installed."
else
    log_info "Phase 7: Tailscale already installed."
fi

# Attempt auto-join if Auth Key is in Bitwarden
TS_KEY=$(get_bws_value "TAILSCALE_AUTH_KEY")
if [[ -n "$TS_KEY" && "$TS_KEY" != "null" ]]; then
    log_info "Phase 7: Authenticating Tailscale mesh network ($VPS_HOSTNAME)..."
    tailscale up --authkey="$TS_KEY" --hostname="$VPS_HOSTNAME" --ssh > /dev/null 2>&1 || log_warn "Tailscale auto-join failed."
else
    log_warn "Phase 7: TAILSCALE_AUTH_KEY not found in Bitwarden. Skip auto-join."
    log_warn "You MUST run 'tailscale up --ssh' manually before disconnecting root."
fi


# ─────────────────────────────────────────────────────────────────
# PHASE 8: Install Rclone and YQ
# ─────────────────────────────────────────────────────────────────

if ! command -v rclone &>/dev/null; then
    log_info "Phase 8: Installing Rclone..."
    curl -fsSL https://rclone.org/install.sh | bash > /dev/null 2>&1
    log_info "Rclone installed."
fi

if ! command -v yq &>/dev/null; then
    log_info "Phase 8: Installing YQ (Official Binary)..."
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq > /dev/null 2>&1
    chmod +x /usr/local/bin/yq
    log_info "YQ installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 9: Fetch Platform Secrets and Clone Platform-Core
# ─────────────────────────────────────────────────────────────────
log_info "Phase 9: Fetching secrets and cloning core..."

# Fetch GitHub PAT for cloning private repo
GITHUB_TOKEN=$(get_bws_value "GITHUB_PAT")

if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "null" ]]; then
    log_error "Critical Secret Missing: GITHUB_PAT (GitHub Personal Access Token)"
    exit 1
fi

log_info "Phase 9: Cloning platform-core..."


# ─────────────────────────────────────────────────────────────────
# PHASE 7: Clone Platform-Core
# ─────────────────────────────────────────────────────────────────

log_info "Phase 7: Cloning platform-core..."

rm -rf "$INSTALL_DIR"
if [[ -n "$GITHUB_TOKEN" ]]; then
    log_info "Attempting authenticated clone..."
    git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${GITHUB_REPO}.git" "$INSTALL_DIR"
else
    log_warn "No token found, attempting public clone..."
    git clone "https://github.com/${GITHUB_ORG}/${GITHUB_REPO}.git" "$INSTALL_DIR"
fi
unset GITHUB_TOKEN

log_info "Platform-core cloned to $INSTALL_DIR"

# ─────────────────────────────────────────────────────────────────
# PHASE 10: Trigger Platform Bootstrap
# ─────────────────────────────────────────────────────────────────
log_info "Phase 10: Triggering platform-bootstrap.sh..."

export BWS_TOKEN="$BWS_TOKEN"
bash "$INSTALL_DIR/bootstrap/platform-bootstrap.sh"

# Global CLI Link
log_info "Linking platform CLI to /usr/local/bin..."
ln -sf "$INSTALL_DIR/bin/platform" /usr/local/bin/platform
chmod +x "$INSTALL_DIR/bin/platform"

# 8.5: Security & Hygiene Hardening (Move to Phase 0.6)

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
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

# 4. Phase 8.6: Persist BWS_TOKEN for operators and cron (N-01)
log_info "Phase 8.6: Persisting BWS_TOKEN for operators and cron..."
cat > /etc/profile.d/platform.sh <<'PROFILE'
# Loans Emporium Platform — sourced at login
export BWS_TOKEN="$(cat /opt/platform/config/.bws_token 2>/dev/null || true)"
PROFILE

# Write token to a root-only file
echo "$BWS_TOKEN" > /opt/platform/config/.bws_token
chmod 640 /opt/platform/config/.bws_token

# 5. Phase 8.7: Ownership and Git Security (Hardening)
log_info "Phase 8.7: Setting up operator permissions and Git security..."
chown -R deploy:deploy /opt/platform /etc/loans-platform
chmod +x /opt/platform/bin/platform
git config --system --add safe.directory /opt/platform
chown root:deploy /opt/platform/config/.bws_token /opt/platform/config/rclone.conf
chmod 640 /opt/platform/config/.bws_token /opt/platform/config/rclone.conf

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
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  ⚠️  SECURITY HARDENING: EXIT ROOT NOW${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Root SSH login has been \033[1;31mdisabled\033[0m for security."
echo -e "  Please \033[1;32mexit this session\033[0m and login using the \033[1;36mdeploy\033[0m user"
echo -e "  via \033[1;35mTailscale\033[0m for all future management:"
echo ""
echo -e "  \033[1;37mtailscale ssh deploy@$VPS_HOSTNAME\033[0m"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
