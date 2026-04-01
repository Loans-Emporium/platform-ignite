# platform-ignite
## One-command VPS Hardening for Loans Emporium Platform

**Version**: V13.0.0 (Production Blueprint)  
**Target Architecture**: Internal PaaS (Platform-as-a-Service)  
**Last Updated**: March 29, 2026

---

## 🚀 Quick Start (Root-Only)

```bash
# Hardens machine, installs runtimes, and clones PaaS control plane.
# Forced Auth: The script will prompt for your BWS_TOKEN during execution.
bash <(curl -fsSL https://raw.githubusercontent.com/Loans-Emporium/Platform-Ignite/main/bootstrap.sh)
```

## 🛠️ What This Does

The bootstrap script performs a 5-minute automated setup for root-only operation with built-in monitoring:

1. **OS Hardening**: Performs initial `apt-get upgrade` and installs base tools (`git`, `curl`, `jq`, `openssl`). *Ongoing patching managed by V12.5 Maintenance Cron.*
2. **Binary Integrity**: Installs **Docker**, **`yq`**, and **`rclone`** with SHA-256 checksum verification (F-02).
3. **Secret Management**: Installs Bitwarden Secrets Manager CLI (`bws` v1.0.0).
4. **Network Hardening**: Configures **UFW** (Blocking public SSH, allowing 80/443 and Tailscale mesh).
5. **Vesting**: Clones `platform-core` and hand-off to the internal `platform-bootstrap.sh`.
6. **Persistence**: Hardens secret storage to `0600` and un-exports master tokens from the environment (F-01/F-04).

## Ownership Boundary

`platform-ignite` owns first-mile machine preparation only:
- OS update and base tooling
- Binary installation and integrity verification
- Tailscale join and UFW hardening
- Cloning `platform-core` and handing off bootstrap context

`platform-core` owns everything after the handoff:
- Platform config materialization
- Caddy and Gatus startup
- Registry, ingress, monitoring, and recovery state
- App lifecycle, backup, and restore workflows

## 🔐 Security Design (V13.0.0)

Follows "Root Resilience" and "Zero Secrets" principles:
- **Binary Checksums**: Every 3rd-party binary is verified against a hardcoded SHA-256 hash.
- **Narrow Secret Scoping**: `BWS_TOKEN` is passed only to specific setup processes and never exported globally.
- **Root-Only**: Eliminates the `deploy` user abstraction, reducing privilege escalation vectors.
- **Mandatory UFW**: Default incoming policy is `DENY`, including public port 22 (SSH).
- **Tailscale Only**: Admin access is strictly routed through the authenticated Tailscale mesh.

## 🛡️ Security Maintenance

To maintain the high security bar of V13.0.0:

1. **Linting**: All changes must pass `shellcheck` before being merged:
   ```bash
   shellcheck bootstrap.sh
   ```
2. **Audit Trail**: Every provisioned server logs the core platform SHA in `/opt/platform/state/bootstrap-sha`.
3. **Review Cadence**: A manual security audit (F-01 through F-13) is performed before every major version release.

## 📋 Prerequisites

| Requirement | Purpose |
|-------------|---------|
| Ubuntu 22.04+ VPS | Target production server (2GB RAM min) |
| Bitwarden Token | Provides access to infra & app secrets |
| GitHub PAT | Required to clone the private `platform-core` |

---

**Maintained by**: Loans Emporium Platform Team  
**Status**: Production Ready ✅ (V13.0.0 Hardened)
