# sanctum / labunix rebuild toolkit

A modular disaster-recovery toolkit for rebuilding a Debian 13 server (`sanctum`) in a controlled, validated order.

```
capture → lint → install → restore → doctor
```

Rebuild time: weeks → hours. All risky changes are explicit, reversible, and tested.

---

## Toolkit layout

```
~/.local/bin/straper/
├── capture-full.sh      Capture live server state into a rebuild DB
├── lint-db.sh           Validate DB shape before trusting it for restore
├── install-base.sh      Install packages and baseline — no identity transplant
├── restore-configs.sh   Restore config categories from DB, one at a time
├── doctor.sh            Read-only health and readiness checks
├── rebuild.conf.example Optional config overrides
└── lib/
    └── common.sh        Shared helpers, restore_path(), report(), etc.
```

Runtime artifacts go to `/var/log/labunix-rebuild/` and `/var/lib/labunix-rebuild/`.

---

## Roles

| Role | Use for | Behavior |
|------|---------|----------|
| `lab` | VM testing, dry runs | Skips DNS/firewall/network, no identity restores |
| `hardware` | Real machine migration | Full adaptive restore, services started |
| `replacement` | True disaster recovery | All restores including private identities |

---

## Canonical workflow

### Step 1 — Capture (on source host)

```bash
sudo ~/.local/bin/straper/capture-full.sh
# or to a specific path:
sudo CAPTURE_DIR=/tmp/sanctum-rebuild-clean ~/.local/bin/straper/capture-full.sh
```

Produces `db/public/` (safe, git-tracked) and `db/secret/` (root-only, never committed).

### Step 2 — Lint

Always lint before restore. Do not proceed if lint fails.

```bash
sudo ~/.local/bin/straper/lint-db.sh --db-dir /tmp/sanctum-rebuild-clean
```

Catches: nested duplicate roots, overlapping captures, backup junk, duplicate canonical files.

### Step 3 — Transfer to target

```bash
rsync -av ~/.local/bin/straper/ lukasz@TARGET:~/rebuild-test/sanctum-rebuild-toolkit/
rsync -av /tmp/sanctum-rebuild-clean/db/ lukasz@TARGET:~/sanctum-rebuild/db/
```

### Step 4 — Install base

```bash
cd ~/rebuild-test/sanctum-rebuild-toolkit
sudo bash ./install-base.sh --role lab --profile core
```

Installs packages, sets up baseline, stops conflicting services. Does **not** restore any config.

### Step 5 — Restore categories

Restore in blocks. Run `doctor.sh` after each block.

**Safe first block:**
```bash
sudo bash ./restore-configs.sh \
  --db-dir ~/sanctum-rebuild \
  --role lab \
  --category system-basics \
  --category users \
  --category ssh
```

**Service block:**
```bash
sudo bash ./restore-configs.sh \
  --db-dir ~/sanctum-rebuild \
  --role lab \
  --category nginx \
  --category mariadb \
  --category postfix \
  --category prosody \
  --category docker \
  --category monitoring \
  --category tor \
  --category i2pd
```

**Risky block** (use `--role hardware` or `--role replacement`, run last):
```bash
sudo bash ./restore-configs.sh \
  --db-dir ~/sanctum-rebuild \
  --role hardware \
  --category dns \
  --category firewall \
  --category network
```

### Step 6 — Verify

```bash
sudo bash ./doctor.sh --db-dir ~/sanctum-rebuild --role hardware
```

---

## Smart adaptive restore

`dns`, `firewall`, and `network` are not naive file copies — they adapt to the target machine.

### DNS (`restore_dns`)

1. Scans live interfaces, IPs, WireGuard ifaces, Docker bridges, port 53 owner
2. Adapts `dnsmasq.conf` and all `dnsmasq.d/*` — strips non-live IPs from `listen-address`, comments out `interface=` lines for absent interfaces
3. Classifies each file: `safe` | `dormant-wireguard` | `dormant-docker` | `dormant-hardware`
4. Fetches `root.hints` from internic.net if referenced by unbound config
5. Disables DNSSEC validator for bootstrap (re-enable manually once stable)
6. Disables `systemd-resolved` stub listener if it would conflict with dnsmasq
7. Starts unbound → dnsmasq in correct order, verifies each is listening
8. Writes `/etc/resolv.conf` **only after** resolution is confirmed — falls back to `1.1.1.1` if not
9. Prints precise manual task list

WireGuard-dependent and Docker-dependent rules are preserved as dormant comments — they activate automatically when those interfaces come up.

### Firewall (`restore_firewall`)

1. Scans live interfaces
2. Adapts `nftables.conf` — comments out rules referencing absent interfaces
3. Classifies: `wg*` → dormant-wireguard, `enx*/eth*` → dormant-hardware-nic, `br-*/docker0` → dormant-docker (collapsed to one task)
4. Validates with `nft -c` before loading
5. Loads with `nft -f`, enables `nftables.service`

### Network (`restore_network`)

Restores `/etc/network`, `systemd-network`, `nsswitch.conf`, `hosts.allow/deny`. Skipped in `lab` role.

---

## Validated restore order

```
system-basics → users → ssh
nginx → mariadb → postfix → prosody → docker → monitoring → tor → i2pd
dns → firewall → network
```

DNS must come before firewall. Network last. Run `doctor.sh` after each block.

---

## Validated doctor baseline (hardware role)

```
Summary: ok=22 warn=7 fail=0 manual=1
```

Expected warnings in lab: `kvm` detected, `nftables` inactive before first boot, `docker`/`grafana` not installed, `tor`/`i2pd` not started, DNS chain intentional.

---

## Restore categories

| Category | Risk | Notes |
|----------|------|-------|
| `system-basics` | low | hostname, hosts, locale, timezone |
| `users` | low | sudoers with ownership fix, shells, login.defs |
| `ssh` | low | sshd_config; host keys in hardware/replacement only |
| `nginx` | low | lab: default site only, no production vhosts |
| `mariadb` | low | /etc/mysql tree with normalization |
| `postfix` | low | main.cf, master.cf with explicit root:root ownership |
| `prosody` | low | tree + cert permission normalization |
| `docker` | low | daemon.json; compose files are manual |
| `monitoring` | low | prometheus, loki, grafana, alloy trees |
| `tor` | low | torrc; /var/lib/tor only in replacement role |
| `i2pd` | low | /etc/i2pd tree; /var/lib/i2pd only in replacement role |
| `dns` | **risky** | smart adaptive — see above |
| `firewall` | **risky** | smart adaptive — see above |
| `network` | **risky** | skipped in lab |

---

## Known lessons

**Metadata matters.** Content restore alone is not enough — owner, group, and mode must be normalized. `restore_path()` handles this.

**DB shape matters.** A polluted DB produces bad restores even with correct logic. Always lint first.

**Tree restores are overlay-style.** On a reused VM, stale files survive. Use a fresh VM or clean the destination before retesting.

**resolv.conf is sacred.** Never write it until a local resolver is confirmed listening.

**DNSSEC on Debian 13.** `unbound-anchor` is not shipped. Disable the validator module for initial bring-up; re-enable after the system is stable.

**Service start order.** unbound must be listening before dnsmasq starts — dnsmasq validates its `server=` upstream at startup and exits with `INVALIDARGUMENT` if it can't reach it.

**nftables interface references.** Rules referencing absent interfaces must be commented out or nftables refuses to load entirely.

---

## Public vs secret DB tiers

`db/public/` — unencrypted, git-tracked. Safe for remote backup.

`db/secret/` — root-only (`chmod 700`), never committed. Protected at rest by ZFS-on-LUKS. Contains SSH keys, TLS private keys, WireGuard keys, LUKS headers, service secrets.

---

## Quick reference

```bash
# Capture
sudo ~/.local/bin/straper/capture-full.sh

# Lint
sudo ~/.local/bin/straper/lint-db.sh --db-dir /srv/sanctum-rebuild

# Install
sudo bash ./install-base.sh --role hardware --profile core

# Restore (example)
sudo bash ./restore-configs.sh \
  --db-dir ~/sanctum-rebuild \
  --role hardware \
  --category dns

# Verify
sudo bash ./doctor.sh --db-dir ~/sanctum-rebuild --role hardware

# List categories
sudo bash ./restore-configs.sh --list-categories
```

---

## Status

All restore categories validated including risky (`dns`, `firewall`, `network`).
Suitable for: structured lab testing, staged hardware migration, disciplined disaster-recovery rehearsal.
