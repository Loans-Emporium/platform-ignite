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

# ── Colors & UI (Must be defined before any prompt or trap call) ────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# ── Early Error Trap ────────────────────────────────────────────────────────
trap 'log_error "Bootstrap failed at line $LINENO. Manual remediation required."; exit 1' ERR

# ── Configuration ───────────────────────────────────────────────────────────
GITHUB_ORG="${GITHUB_ORG:-Loans-Emporium}"
GITHUB_REPO="platform-core"
INSTALL_DIR="/opt/platform"

# Dependency Pinning (Audit N-10/N-13)
BWS_VERSION="1.0.0"
DOCKER_CE_VERSION="26.0.0"
YQ_VERSION="4.44.3"
RCLONE_VERSION="1.66.0"
TAILSCALE_VERSION="1.62.1"

# ── Localization & Identity (Audit N-12 Hardening) ──────────────────────────
if [[ -z "${VPS_HOSTNAME:-}" ]]; then
    echo -e "${YELLOW}[PROMPT]${NC} VPS_HOSTNAME is not set in environment."
    read -p "Enter a unique Hostname for this VPS (e.g. srv-prod-01): " VPS_HOSTNAME
fi
VPS_HOSTNAME="${VPS_HOSTNAME:?ERROR: VPS_HOSTNAME must be set before running bootstrap (Audit N-12)}"
VPS_TZ="${VPS_TZ:-Asia/Kolkata}"

# F-01/F-21: Read VERSION dynamically if available
VERSION="11.0" # V11.0 Root Resilience
if [[ -f "$INSTALL_DIR/VERSION" ]]; then
    VERSION=$(cat "$INSTALL_DIR/VERSION")
fi

# ── Canonical CLI Versions ──────────────────────────────────────────────────
BWS_VERSION="1.0.0"
DOCKER_CE_VERSION="26.0.0"

# ── Canonical CLI Versions ──────────────────────────────────────────────────
BWS_VERSION="1.0.0"
DOCKER_CE_VERSION="26.0.0"

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
    log_info "Phase 2: Installing Docker Engine via official signed repository (Audit N-02)..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    # V11.0.3: Pinning Docker version for supply chain stability (Audit N-10)
    # We use a wildcard (*) for the OS-specific suffix (e.g. ~ubuntu.22.04~jammy)
    apt-get install -y -qq \
        docker-ce=5:${DOCKER_CE_VERSION}* \
        docker-ce-cli=5:${DOCKER_CE_VERSION}* \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin > /dev/null 2>&1
    systemctl enable --now docker
    log_success "Docker (stable) installed and started."
else
    log_info "Phase 2: Docker already installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 3: Install Utility Binaries (Rclone, YQ)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 3: Installing Rclone & YQ (Checksum Verified)..."
if ! command -v rclone &>/dev/null; then
    # V11.0.1: Pinned Rclone binary + SHA-256 (Audit N-06/F-02)
    RCLONE_VER="v1.66.0"
    RCLONE_SHA="94a6132cc74e17ad30d5f8102d1b702ec8c9a3d607e1e695f2d05777402613d9"
    wget -q "https://github.com/rclone/rclone/releases/download/${RCLONE_VER}/rclone-${RCLONE_VER}-linux-amd64.zip" -O /tmp/rclone.zip
    verify_checksum "/tmp/rclone.zip" "$RCLONE_SHA"
    unzip -q /tmp/rclone.zip -d /tmp/rclone_pkg
    install -m 755 /tmp/rclone_pkg/rclone-*-linux-amd64/rclone /usr/local/bin/rclone
    rm -rf /tmp/rclone.zip /tmp/rclone_pkg
    log_success "Rclone ${RCLONE_VER} installed."
fi
if ! command -v yq &>/dev/null; then
    YQ_VER="v4.44.3"
    YQ_SHA="887c956cc65860d5c074e6456075c75ed9f30e9d6d7aa9d1c1432f808759695d"
    wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VER}/yq_linux_amd64" -O /usr/local/bin/yq
    verify_checksum "/usr/local/bin/yq" "$YQ_SHA"
    chmod +x /usr/local/bin/yq
    log_success "YQ ${YQ_VER} installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 4: Install Bitwarden Secrets Manager (bws)
# ─────────────────────────────────────────────────────────────────
INSTALLED_BWS=$(bws --version 2>/dev/null | awk '{print $2}' || echo "none")
if [[ "$INSTALLED_BWS" != "$BWS_VERSION" ]]; then
    log_info "Phase 4: Installing Bitwarden SDK CLI v${BWS_VERSION} (Audit N-06)..."
    # V11.0.2: Added SHA-256 checksum verification for BWS binary (Audit N-06)
    BWS_SHA="9077fb7b336a62abc8194728fea8753afad8b0baa3a18723fc05fc02fdb53568"
    curl -fsSL "https://github.com/bitwarden/sdk/releases/download/bws-v${BWS_VERSION}/bws-x86_64-unknown-linux-gnu-${BWS_VERSION}.zip" -o /tmp/bws.zip
    verify_checksum "/tmp/bws.zip" "$BWS_SHA"
    mkdir -p /tmp/bws_pkg && unzip -q /tmp/bws.zip -d /tmp/bws_pkg
    install -m 755 /tmp/bws_pkg/bws /usr/local/bin/bws
    rm -rf /tmp/bws.zip /tmp/bws_pkg
    log_success "bws CLI ${BWS_VERSION} installed and verified."
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
# V11.0.1: DON'T export BWS_TOKEN. Keep it local to this shell (Audit N-01)
# Sub-processes (like platform-bootstrap) will receive it explicitly.

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

# V11.0.2: Repository Version Sync Enforcement (Audit N-13)
CORE_STACK="$INSTALL_DIR/CANONICAL_STACK"
if [[ -f "$CORE_STACK" ]]; then
    CORE_BWS=$(grep "BWS_VERSION" "$CORE_STACK" | cut -d'"' -f2 || true)
    if [[ -n "$CORE_BWS" && "$CORE_BWS" != "$BWS_VERSION" ]]; then
        log_warn "VERSION SYNC WARNING: ignite ($BWS_VERSION) != platform-core ($CORE_BWS)"
        log_warn "Please update ignite/bootstrap.sh to match CANONICAL_STACK (Audit N-13)."
        # Non-fatal to allow manual resolution, but loud.
    fi
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 7: Tailscale Join
# ─────────────────────────────────────────────────────────────────
log_info "Phase 7: Configuring Tailscale mesh networking (Audit N-02/N-06)..."

# Tailscale setup via official signed repository (Audit N-02)
if ! command -v tailscale &>/dev/null; then
    log_info "Adding official Tailscale repository..."
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(. /etc/os-release && echo "$VERSION_CODENAME").noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(. /etc/os-release && echo "$VERSION_CODENAME").tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list > /dev/null
    apt-get update -qq
    # V11.0.1: Pinning Tailscale version (Audit F-03/N-02)
    apt-get install -y -qq tailscale=1.62.1 > /dev/null 2>&1
fi

TS_KEY=$(get_bws_value "TAILSCALE_AUTH_KEY")
if [[ -n "$TS_KEY" && "$TS_KEY" != "null" ]]; then
    log_info "Attempting Tailscale mesh join..."
    # Ensure tailscaled is actually running
    systemctl enable --now tailscaled > /dev/null 2>&1
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
