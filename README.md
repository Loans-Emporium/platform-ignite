# ignite
## One-command VPS Hardening for Loans Emporium PaaS

**Version**: V8.2  
**Target Architecture**: Internal PaaS (Platform-as-a-Service)  
**Last Updated**: March 16, 2026

---

## 🚀 Quick Start (Machine Root)

```bash
# Hardens machine, installs runtimes, and clones PaaS control plane.
# Forced Auth: The script will prompt for your BWS_TOKEN during execution.
bash <(curl -fsSL https://raw.githubusercontent.com/Loans-Emporium/platform-ignite/main/bootstrap.sh)
```

## 🛠️ What This Does

The bootstrap script performs a 5-minute automated setup:

1. **Runtimes**: Installs Docker Engine, Git, and **`yq`** (official binary for manifest parsing).
2. **Hardening**: Configures UFW (Zero Open Ports), Tailscale (WireGuard Mesh), and Timezone/Hostname.
3. **Backup Engine**: Installs **`rclone`** for R2 synchronization.
4. **Secret Management**: Installs Bitwarden Secrets Manager CLI (`bws`).
5. **Localization**: Sets hostname and timezone from Bitwarden secrets (`vps-hostname`, `vps-timezone`).
6. **User Provisioning**: Creates the `deploy` user with restricted sudo access.
7. **Kickstart**: Clones `platform-core` and hand-off to the internal `platform-bootstrap.sh`.

## 🔐 Security Design

Follows security-by-design principles:
- **Zero Secrets in Code**: No secrets reside in this repository.
- **Forced Token Prompt**: Masked runtime prompt for `BWS_TOKEN` prevents process/history exposure.
- **Zero Open Ports**: VPS has no inbound ports open. All traffic via Cloudflare Tunnel.
- **SSH via Mesh**: Access is restricted to the Tailscale mesh network only.

## 🛡️ Reporting a Vulnerability

If you discover a security vulnerability, please do NOT open a public issue. Email: **security@loansemporium.com**.

## ✅ Verification & Troubleshooting

After bootstrap completes:

```bash
# Verify Platform status
platform status

# Check Docker containers
docker ps

# Check networking
tailscale status
cloudflared tunnel list
```

### Common Troubleshooting
- **Failed Bootstrap**: Check system logs with `journalctl -u docker` or `/var/log/syslog`.
- **Secret Error**: Ensure your `BWS_TOKEN` is valid and has access to the `loans_emporium_platform` project.
- **Tailscale Fail**: Run `tailscale status` to verify your node is authenticated to the mesh.

## 📋 Prerequisites

| Requirement | Purpose |
|-------------|---------|
| Ubuntu 22.04+ VPS | Target production server (2GB RAM min) |
| Bitwarden Token | Prodvides access to infra & app secrets |
| GitHub PAT | Required to clone the private `platform-core` |

## 🚀 Next Steps

1. **Verify**: Run `platform doctor` to check system health.
2. **Deploy**: Run `platform app add <repo-url>` to host your first app.
3. **Audit**: Review the audit report at `/opt/platform/docs/05-compliance/01-audit.md`.

---

**Maintained by**: Loans Emporium Platform Team  
**Status**: Production Ready ✅
