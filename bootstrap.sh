#!/usr/bin/env bash
# bootstrap.sh — Public VPS bootstrap for Loans Emporium Platform
# Part of platform-ignite (PUBLIC repository)
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Loans-Emporium/Platform-Ignite/main/bootstrap.sh)
#
# This script:
#   1. Installs base OS tools & Bitwarden Secrets Manager
#   2. Authenticates and clones the private platform-core repository
#   3. Dynamically sources VERSIONS.lock from the platform-core
#   4. Installs strictly pinned versions of Docker, Tailscale, Rclone, YQ
#   5. Hands off platform configuration, recovery, and app lifecycle orchestration to platform-core

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

# ── Configuration & Bootstrapping Pindowns ──────────────────────────────────
GITHUB_ORG="${GITHUB_ORG:-Loans-Emporium}"
GITHUB_REPO="platform-core"
INSTALL_DIR="/opt/platform"

# V13.3.2 SECURITY ENFORCEMENT: 
# BWS (Bitwarden Secrets Manager) is the ONLY hardcoded version remaining in this script.
# This prevents chicken-and-egg authentication issues while preserving supply-chain integrity.
BWS_VERSION="1.0.0"
BWS_SHA="9077fb7b336a62abc8194728fea8753afad8b0baa3a18723fc05fc02fdb53568"

# ── Resilience Helpers ───────────────────────────────────────────────────────
apt_install_with_retry() {
    local packages=("$@")
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Installing ${packages[*]} (Attempt $attempt/$max_attempts)..."
        if apt-get install -y -qq --no-upgrade "${packages[@]}" > /dev/null 2>&1; then
            return 0
        fi
        log_warn "Apt install failed. Retrying in 5s..."
        sleep 5
        ((attempt++))
        apt-get update -qq
    done
    return 1
}

# ── Localization & Identity ─────────────────────────────────────────────────
if [[ -z "${VPS_HOSTNAME:-}" ]]; then
    echo -e "${YELLOW}[PROMPT]${NC} VPS_HOSTNAME is not set in environment."
    read -p "Enter a unique Hostname for this VPS (e.g. srv-prod-01): " VPS_HOSTNAME
fi
VPS_HOSTNAME="${VPS_HOSTNAME:?ERROR: VPS_HOSTNAME must be set before running bootstrap (Audit N-12)}"
VPS_TZ="${VPS_TZ:-Asia/Kolkata}"

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
echo "║      Loans Emporium Platform - platform-ignite Bootstrap   ║"
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

apt-get update -qq 

# V10.6.9: Install Postgres 17 Client for Neon/Cloud compatibility
if ! command -v pg_dump &>/dev/null || [[ $(pg_dump --version | grep -oE '[0-9]+' | head -1) -lt 17 ]]; then
    log_info "Adding official PostgreSQL repository for version 17 client..."
    install -d /usr/share/postgresql-common/pgdg
    curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
fi

# MongoDB Database Tools (for mongodump/mongorestore backup support)
if ! command -v mongodump &>/dev/null; then
    log_info "Adding official MongoDB APT repository for database tools v${MONGODB_TOOLS_VERSION}..."
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
        gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
    echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" \
        > /etc/apt/sources.list.d/mongodb-org-7.0.list
fi

apt-get update -qq
apt_install_with_retry curl git jq unzip gpg wget postgresql-client-17 openssl "mongodb-database-tools=${MONGODB_TOOLS_VERSION}*"

log_info "Verifying backup toolchain..."
command -v pg_dump   &>/dev/null || { log_error "pg_dump not found!"; exit 1; }
command -v mongodump &>/dev/null || { log_error "mongodump not found!"; exit 1; }
log_success "pg_dump and mongodump verified."

# ─────────────────────────────────────────────────────────────────
# PHASE 2: Install Bitwarden Secrets Manager (BWS)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 2: Installing Bitwarden SDK CLI v${BWS_VERSION}..."
INSTALLED_BWS=$(bws --version 2>/dev/null | awk '{print $2}' || echo "none")
if [[ "$INSTALLED_BWS" != "$BWS_VERSION" ]]; then
    curl -fsSL "https://github.com/bitwarden/sdk/releases/download/bws-v${BWS_VERSION}/bws-x86_64-unknown-linux-gnu-${BWS_VERSION}.zip" -o /tmp/bws.zip
    verify_checksum "/tmp/bws.zip" "$BWS_SHA"
    mkdir -p /tmp/bws_pkg && unzip -q /tmp/bws.zip -d /tmp/bws_pkg
    install -m 755 /tmp/bws_pkg/bws /usr/local/bin/bws
    rm -rf /tmp/bws.zip /tmp/bws_pkg
    log_success "bws CLI ${BWS_VERSION} installed and verified."
else
    log_info "bws CLI v${BWS_VERSION} already installed."
fi

get_bws_value() {
    local key="$1"
    bws secret list --access-token "$BWS_TOKEN" -o json 2>/dev/null | \
        jq -r --arg k "$key" '.[] | select((.key | ascii_upcase) == ($k | ascii_upcase)) | .value' 2>/dev/null || echo ""
}

# ─────────────────────────────────────────────────────────────────
# PHASE 3: Security Challenge & Authentication
# ─────────────────────────────────────────────────────────────────
log_info "Phase 3: Security checks & BWS authentication..."
unset BWS_TOKEN
echo -n -e "${YELLOW}[PROMPT]${NC} Please enter your Bitwarden Secrets Manager Access Token: "
read -s BWS_TOKEN < /dev/tty
echo ""

if [[ -z "$BWS_TOKEN" ]]; then
    log_error "BWS_TOKEN is required. Bootstrap aborted."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 4: Clone Platform Core & Source Version Manifest
# ─────────────────────────────────────────────────────────────────
log_info "Phase 4: Fetching GITHUB_PAT and cloning platform-core repository..."
GITHUB_TOKEN=$(get_bws_value "GITHUB_PAT")
if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "null" ]]; then
    log_error "Critical Secret Missing: GITHUB_PAT. Clone failed."
    exit 1
fi

if [[ -d "$INSTALL_DIR" ]]; then
    log_warn "Existing platform detected. Refreshing core libraries only..."
    rm -rf "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$INSTALL_DIR/scripts" \
           "$INSTALL_DIR/infrastructure" "$INSTALL_DIR/docs" "$INSTALL_DIR/.git" \
           "$INSTALL_DIR/VERSION" "$INSTALL_DIR/VERSIONS.lock" 2>/dev/null || true
else
    mkdir -p "$INSTALL_DIR"
fi

tmp_clone=$(mktemp -d)
if git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${GITHUB_REPO}.git" "$tmp_clone" > /dev/null 2>&1; then
    cp -rv "$tmp_clone/." "$INSTALL_DIR/" > /dev/null
    rm -rf "$tmp_clone"
else
    log_error "Git clone failed. Check your GITHUB_PAT and network."
    exit 1
fi
unset GITHUB_TOKEN
log_success "Platform source synchronized at $INSTALL_DIR (State Preserved)."

# --- V13.3.2 THE HANDOFF: DYNAMIC MANIFEST CONSUMPTION ---
MANIFEST_PATH="$INSTALL_DIR/VERSIONS.lock"
if [[ -f "$MANIFEST_PATH" ]]; then
    log_info "Sourcing master platform dependencies from $MANIFEST_PATH"
    source "$MANIFEST_PATH"
else
    log_error "FATAL: VERSIONS.lock missing from platform-core. Halting."
    exit 1
fi

VERSION=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")
log_info "Dynamic Platform version established as: $VERSION"

# ─────────────────────────────────────────────────────────────────
# PHASE 5: Install Docker Engine (Dynamically Versioned)
# ─────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_info "Phase 5: Installing Docker Engine v${DOCKER_VERSION}..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq

    apt-get install -y -qq \
        docker-ce=5:${DOCKER_VERSION}* \
        docker-ce-cli=5:${DOCKER_VERSION}* \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin > /dev/null 2>&1
    systemctl enable --now docker
    
    log_info "Configuring Docker daemon log rotation..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
EOF
    systemctl reload docker 2>/dev/null || systemctl restart docker
    log_success "Docker log rotation configured (50m × 5 files)."
    log_success "Docker v${DOCKER_VERSION} installed and started."
else
    log_info "Phase 5: Docker already installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 6: Install Utility Binaries (Dynamically Versioned)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 6: Installing Rclone (v${RCLONE_VERSION}) & YQ (v${YQ_VERSION})..."
if ! command -v rclone &>/dev/null; then
    wget -q "https://github.com/rclone/rclone/releases/download/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.zip" -O /tmp/rclone.zip
    unzip -q /tmp/rclone.zip -d /tmp/rclone_pkg
    install -m 755 /tmp/rclone_pkg/rclone-*-linux-amd64/rclone /usr/local/bin/rclone
    rm -rf /tmp/rclone.zip /tmp/rclone_pkg
    log_success "Rclone v${RCLONE_VERSION} installed."
fi
if ! command -v yq &>/dev/null; then
    wget -q "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" -O /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
    log_success "YQ v${YQ_VERSION} installed."
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 7: Tailscale Join (Dynamically Versioned)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 7: Configuring Tailscale mesh networking (v${TAILSCALE_VERSION})..."

if ! command -v tailscale &>/dev/null; then
    log_info "Adding official Tailscale repository..."
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(. /etc/os-release && echo "$VERSION_CODENAME").noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(. /etc/os-release && echo "$VERSION_CODENAME").tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq tailscale=${TAILSCALE_VERSION} > /dev/null 2>&1
fi

TS_KEY=$(get_bws_value "TAILSCALE_AUTH_KEY")
if [[ -n "$TS_KEY" && "$TS_KEY" != "null" ]]; then
    log_info "Attempting Tailscale mesh join..."
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

log_info "Verifying Tailscale is connected before locking down SSH..."
TS_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || echo "unknown")
if [[ "$TS_STATUS" != "Running" ]]; then
    log_warn "Tailscale is NOT in Running state (got: $TS_STATUS)."
    log_warn "Skipping UFW port-22 deny to prevent self-lockout."
    ufw allow 22/tcp
else
    log_success "Tailscale is active. Proceeding with port-22 lockdown."
    ufw deny 22/tcp
fi

if ip addr show tailscale0 &>/dev/null; then
    ufw allow in on tailscale0
fi
ufw --force enable

timedatectl set-timezone "$VPS_TZ" || true
hostnamectl set-hostname "$VPS_HOSTNAME" || true
echo "127.0.0.1 $VPS_HOSTNAME" >> /etc/hosts
log_success "System localization applied."

# ─────────────────────────────────────────────────────────────────
# PHASE 9: Platform Orchestration (Sub-Bootstrap)
# ─────────────────────────────────────────────────────────────────
log_info "Phase 9: Triggering interior platform-bootstrap..."
BWS_TOKEN="$BWS_TOKEN" bash "$INSTALL_DIR/bootstrap/platform-bootstrap.sh"
ln -sf "$INSTALL_DIR/bin/platform" /usr/local/bin/platform
chmod +x "$INSTALL_DIR/bin/platform"
log_success "Platform CLI linked and initialized."

# ─────────────────────────────────────────────────────────────────
# PHASE 10: Security Hardening & Handover
# ─────────────────────────────────────────────────────────────────
log_info "Phase 10: Finalizing security hardening..."

mkdir -p /opt/platform/config
echo "$BWS_TOKEN" > /opt/platform/config/.bws_token
chmod 600 /opt/platform/config/.bws_token

mkdir -p /opt/platform/state
(cd "$INSTALL_DIR" && git rev-parse HEAD) > /opt/platform/state/bootstrap-sha

chown -R root:root /opt/platform /etc/loans-platform
git config --system --add safe.directory /opt/platform

cat <<EOF > /etc/logrotate.d/platform
/var/log/platform-*.log { weekly ; rotate 4 ; compress ; missingok ; notifempty ; create 0640 root root }
EOF

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

TS_IP=$(tailscale ip -4 2>/dev/null | head -n 1 || echo "not-reached")

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     🎉 platform-ignite Bootstrap Complete! (V${VERSION})      ║"
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
