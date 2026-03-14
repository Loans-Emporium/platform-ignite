# Quick Start Guide

5-minute guide to bootstrap a new VPS.

## Prerequisites

1. **Ubuntu 22.04+ VPS** (2GB RAM, 20GB disk minimum)
2. **Bitwarden Secrets Manager** account with:
   - `github-pat` secret (GitHub Personal Access Token)
   - `tailscale-auth-key` secret (Tailscale auth key)
   - `cloudflare-tunnel-token` secret (Cloudflare Tunnel token)
3. **BWS_TOKEN** for your VPS (scoped to loans_emporium_platform project)
4. **BWS Secrets** for localization (optional but recommended):
   - `vps-hostname`: Desired system hostname
   - `vps-timezone`: Desired system timezone (default: `Asia/Kolkata`)
   - `deploy-user-password`: Password for the `deploy` user

## Step 1: Bootstrap Command

```bash
BWS_TOKEN=your-vps-token \
  bash <(curl -fsSL https://raw.githubusercontent.com/your-org/ignite/main/bootstrap.sh)
```

## Step 2: What Happens

The bootstrap script:

1. **Installs tools**: Docker, Git, curl, jq, unzip, gpg
3. **Configures networking**: Tailscale, Cloudflared
4. **Localization**: Sets hostname and timezone from secrets
5. **Fetches secrets**: From Bitwarden Secrets Manager
6. **Clones platform-core**: Private infrastructure repository
7. **Triggers platform bootstrap**: Sets up containers and services
8. **User Provisioning**: Creates `deploy` user and sets up SSH access

## Step 3: Verify Installation

After bootstrap completes:

```bash
# Check platform status
platform status

# Check Docker containers
docker ps

# Check Tailscale connection
tailscale status
```

## Step 4: Access Services

| Service | URL | Access |
|---------|-----|--------|
| Platform CLI | `platform` command | SSH via Tailscale (as `deploy`) |
| Docker containers | Localhost | Via platform CLI |
| Cloudflare Tunnel | Your domain | Public internet |

## Troubleshooting

### Bootstrap Fails

```bash
# Check logs
journalctl -u docker
tail -f /var/log/syslog

# Verify BWS_TOKEN
echo $BWS_TOKEN

# Manual retry
cd /opt/platform
bash bootstrap/platform-bootstrap.sh
```

### Tailscale Not Connected

```bash
# Check status
tailscale status

# Reconnect
tailscale up --reset
```

### Cloudflared Issues

```bash
# Check tunnel status
cloudflared tunnel list

# View logs
journalctl -u cloudflared
```

## Next Steps

1. **Read documentation**: `/opt/platform/docs/`
2. **Test backup**: `platform backup`
3. **Verify monitoring**: Check UptimeRobot alerts
4. **Deploy first app**: `platform app add my-app`

## Common Commands

```bash
# Platform management
platform status
platform backup
platform update

# Container management
docker ps
docker logs platform-postgres
docker compose logs -f

# Secret management
bws secret list --access-token $BWS_TOKEN
```

## Support

- **Documentation**: `/opt/platform/docs/`
- **Architecture**: `docs/architecture/`
- **Operations**: `docs/operations/`

---

**Time to complete**: 5-10 minutes  
**Expected outcome**: Production-ready VPS with zero open ports

