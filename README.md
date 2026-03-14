# ignite
## One-command VPS Hardening for Loans Emporium PaaS

**Version**: V6.0  
**Target Architecture**: Internal PaaS (Platform-as-a-Service)  
**Last Updated**: March 13, 2026

---

## 🚀 Quick Start (Machine Root)

```bash
# Hardens machine, installs runtimes, and clones PaaS control plane.
BWS_TOKEN=your-vps-token \
  bash <(curl -fsSL https://raw.githubusercontent.com/your-org/ignite/main/bootstrap.sh)
```

## What This Does

1. **Runtimes**: Installs Docker Engine, Git, and **`yq`** (official binary for manifest parsing).
2. **Hardening**: Configures UFW (Zero Open Ports), Tailscale (WireGuard Mesh), and Timezone/Hostname.
3. **Backup Engine**: Installs **`rclone`** for OneDrive/R2 synchronization.
4. **Secret Management**: Installs Bitwarden Secrets Manager CLI (`bws`).
5. **Kickstart**: Clones `platform-core` and hand-off to the internal bootstrap.

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
