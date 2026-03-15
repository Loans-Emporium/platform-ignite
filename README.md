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
bash <(curl -fsSL https://raw.githubusercontent.com/your-org/ignite/main/bootstrap.sh)
```

## What This Does

1. **Runtimes**: Installs Docker Engine, Git, and **`yq`** (official binary for manifest parsing).
2. **Hardening**: Configures UFW (Zero Open Ports), Tailscale (WireGuard Mesh), and Timezone/Hostname.
3. **Backup Engine**: Installs **`rclone`** for R2 synchronization.
4. **Secret Management**: Installs Bitwarden Secrets Manager CLI (`bws`).
5. **Kickstart**: Clones `platform-core` and hand-off to the internal bootstrap.

## 🔐 Security Design

This repository follows security-by-design principles:

- **Zero Secrets in Code**: No secrets, tokens, or credentials reside in this repository. All secrets are fetched at runtime.
- **Forced Token Prompt**: `bootstrap.sh` enforces a masked runtime prompt for `BWS_TOKEN`, preventing exposure in process lists or shell history.
- **Zero Open Ports**: The VPS has no inbound ports open. All ingress is handled via Cloudflare Tunnel (outbound-only).
- **SSH via Mesh**: SSH access is restricted to the Tailscale mesh network only.

## 🛡️ Reporting a Vulnerability

If you discover a security vulnerability, please do NOT open a public issue. Email security concerns to: **security@loansemporium.com**. We acknowledge reports within 48 hours.

## Prerequisites

| Requirement | Purpose |
|-------------|---------|
| Ubuntu 22.04+ VPS | Target production server |
| Bitwarden Token | Fetches all infra & app secrets |
| GitHub PAT | Clones the private `platform-core` |

## The PaaS Hand-off

After `ignite` completes, the machine is ready for the **App Life-cycle**.
- All management is done via the `platform` command at `/opt/platform/bin/platform`.
- Applications are added via `platform app add <repo>`.

---

**Maintained by**: Loans Emporium Platform Team  
**Status**: Production Ready ✅
