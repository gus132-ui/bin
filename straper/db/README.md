# sanctum — full state database

| | |
|---|---|
| **Host** | sanctum |
| **OS** | Debian GNU/Linux 13 (trixie) |
| **Kernel** | 6.12.73+deb13-amd64 |
| **Captured** | 2026-03-20T16:27:47 |

## Structure

```
db/
├── public/         Safe inventory — no secret values, git-trackable
└── secret/
    ├── <category>/     Secret files in plain subdirectories
    └── secrets.index   Index of what is inside (no values)
```

## Decrypt secrets

```bash
# List contents without extracting
  find /srv/sanctum-rebuild/db/secret -type f | sort

# Extract to a directory
mkdir /tmp/secrets-out
  sudo cat /srv/sanctum-rebuild/db/secret/wireguard/etc-wireguard/wg0.conf

# Wipe after use
find /tmp/secrets-out -type f -exec shred -u {} \;
rm -rf /tmp/secrets-out
```

## What is in the secret archive

See `db/secret/secrets.index` for a full list.

Key items:
- WireGuard private + preshared keys
- TLS private keys (Let's Encrypt)
- SSH host keys + user SSH keys
- GPG secret keyrings (all users)
- Docker .env files and full unredacted compose files
- MariaDB credentials + schema dumps
- i2pd destination private keys
- Tor hidden service private keys
- LUKS header backups
- Lufi app secret, Grafana credentials, Alloy tokens
- Postfix SASL credentials
- nginx htpasswd files

## Warnings during capture
None
