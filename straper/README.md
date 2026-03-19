# sanctum / labunix rebuild toolkit

A modular, idempotent, Unix-style rebuild toolkit designed to reduce recovery time from weeks to hours.

## Design goals

- Separate **install**, **restore**, and **verify**.
- Keep base connectivity stable before touching overlay networking.
- Make secrets and identities opt-in.
- Never abort the whole run because one restore item failed.
- Back up before overwrite and write a machine-readable report.
- Work on both **VM** and **real hardware**.

## Files

- `lib/common.sh` — shared helpers
- `install-base.sh` — installs packages and base structure only
- `restore-configs.sh` — restores configs from `capture-full.sh` database
- `doctor.sh` — read-only health and readiness checks

## Defaults

- Safe by default
- No automatic identity transplant
- No blind `/etc/network` overwrite unless explicitly requested
- No immutable `/etc/resolv.conf`
- No automatic WireGuard activation unless explicitly requested

## Roles

- `lab` — VM / test clone, least invasive
- `hardware` — real machine, still conservative
- `replacement` — real disaster-recovery target, identities allowed when requested

## Recommended recovery order

### 1. Base install

```bash
sudo ./install-base.sh --role replacement --profile core --start-safe-services
```

### 2. Restore essentials first

```bash
sudo ./restore-configs.sh \
  --role replacement \
  --category system-basics \
  --category users \
  --category ssh \
  --category apt-sources \
  --start-services
```

### 3. Restore network/DNS/firewall carefully

```bash
sudo ./restore-configs.sh \
  --role replacement \
  --category network-base \
  --category dns \
  --category firewall \
  --network-mode source \
  --dns-mode chain \
  --start-services
```

### 4. Restore services

```bash
sudo ./restore-configs.sh \
  --role replacement \
  --category nginx \
  --category mariadb \
  --category postfix \
  --category prosody \
  --category docker \
  --restore-secrets \
  --start-services
```

### 5. Restore identities last

```bash
sudo ./restore-configs.sh \
  --role replacement \
  --category privacy \
  --category tls \
  --category identities \
  --restore-secrets \
  --restore-identities \
  --start-services
```

### 6. Verify

```bash
sudo ./doctor.sh --role replacement --strict
```

## Reports and state

Each run writes:

- `/var/log/labunix-rebuild/report-<RUN_ID>.tsv`
- `/var/log/labunix-rebuild/doctor-<RUN_ID>.txt`
- `/var/lib/labunix-rebuild/state-<RUN_ID>.env`
- `/var/lib/labunix-rebuild/backups/<RUN_ID>/...`

## Notes

- `install-base.sh` does **not** restore your server identity.
- `restore-configs.sh` is intentionally interactive unless `--yes` is used.
- `doctor.sh` is read-only.
- For network restore, use local console access when possible.


## Latest patch notes

- v0.1.1 fixes early exit in `load_optional_config()` under `set -e`
- `install-base.sh` now has a bootstrap DNS fallback for broken `systemd-resolved` stub setups
- initial `apt-get update` is now validated and fails loudly instead of being reported as success
- locale handling no longer requires locale tools before base packages install them
