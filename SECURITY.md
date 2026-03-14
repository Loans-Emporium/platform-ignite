# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest  | ✅ Yes    |

## Reporting a Vulnerability

If you discover a security vulnerability:

1. **Do NOT** open a public issue
2. Email security concerns to: [security@loansemporium.com]
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 7 days
- **Resolution**: Depends on severity

## Security Design

This repository follows security-by-design principles:

### Zero Secrets in Code

- No secrets, tokens, or credentials in this repository
- All secrets fetched at runtime from Bitwarden Secrets Manager
- Bootstrap script contains zero sensitive data

### Zero Open Ports

- VPS has no inbound ports open
- All traffic via Cloudflare Tunnel (outbound-only)
- SSH via Tailscale mesh only

### Minimal Attack Surface

- Only installs required tools
- No unnecessary services
- Principle of least privilege

## Scope

This security policy covers:
- `bootstrap.sh` script
- Documentation in this repository

For platform-core security, see the private repository.

---

**Last Updated**: March 2026
