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
├── capture-full.sh      Capture live server state into db/
├── lint-db.sh           Validate DB shape before restore
├── install-base.sh      Install packages and baseline
├── restore-configs.sh   Restore config categories from DB
├── doctor.sh            Read-only health and readiness checks
├── rebuild.conf.example Optional config overrides
├── .gitignore           Excludes db/secret/ from git
├── lib/
│   └── common.sh        Shared helpers, restore_path(), report()
└── db/                  Rebuild database (auto-created by capture-full.sh)
    ├── public/          Unencrypted inventory — git-tracked
    └── secret/          Root-only (chmod 700) — never committed
```

The toolkit is **self-contained** — `capture-full.sh` writes the DB to `db/` inside the toolkit directory. No external paths needed.

Runtime artifacts: `/var/log/labunix-rebuild/` and `/var/lib/labunix-rebuild/`.

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
```

Writes to `~/.local/bin/straper/db/public/` and `db/secret/`. Run after any significant change.

### Step 2 — Lint

Always lint before restore. Do not proceed if lint fails.

```bash
sudo ~/.local/bin/straper/lint-db.sh
```

Catches: nested duplicate roots, overlapping captures, backup junk, duplicate canonical files.

### Step 3 — Transfer to target

```bash
rsync -av ~/.local/bin/straper/ lukasz@TARGET:~/rebuild-test/sanctum-rebuild-toolkit/
```

Both toolkit and DB are transferred in one rsync — they live in the same directory.

### Step 4 — Install base

```bash
cd ~/rebuild-test/sanctum-rebuild-toolkit
sudo bash ./install-base.sh --role hardware --profile core
```

Installs packages (including Grafana repo setup, Docker, dns-root-data), sets up baseline, stops conflicting services. Does **not** restore any config.

### Step 5 — Restore categories

Restore in blocks. Run `doctor.sh` after each block.

**Safe first block:**
```bash
sudo bash ./restore-configs.sh \
  --role hardware --yes \
  --category system-basics \
  --category users \
  --category ssh
```

**Service block:**
```bash
sudo bash ./restore-configs.sh \
  --role hardware --yes \
  --category nginx \
  --category mariadb \
  --category postfix \
  --category prosody \
  --category docker \
  --category monitoring \
  --category tor \
  --category i2pd
```

**TLS:**
```bash
sudo bash ./restore-configs.sh \
  --role hardware --yes \
  --category tls
```

**Risky block (run last):**
```bash
sudo bash ./restore-configs.sh \
  --role hardware \
  --category dns \
  --category firewall \
  --category network
```

### Step 6 — Verify

```bash
sudo bash ./doctor.sh --role hardware
```

---

## Smart adaptive restore

`dns`, `firewall`, and `network` adapt to the target machine rather than blindly copying files.

### DNS (`restore_dns`)

1. Scans live interfaces, IPs, WireGuard ifaces, Docker bridges, port 53 owner
2. Adapts `dnsmasq.conf` and `dnsmasq.d/*` — strips non-live IPs, comments out absent `interface=` lines
3. Installs `dns-root-data` if missing, runs `unbound-helper` to seed trust anchor
4. Disables DNSSEC validator for bootstrap (re-enable after system stable)
5. Disables `systemd-resolved` stub if it conflicts with dnsmasq
6. Fetches `root.hints` from internic.net **after** DNS is confirmed working
7. Starts unbound → dnsmasq in correct order, verifies each is listening
8. Writes `/etc/resolv.conf` only after resolution is confirmed
9. Prints precise manual task list

WireGuard and Docker rules are preserved as dormant comments — activate automatically when those interfaces come up.

### Firewall (`restore_firewall`)

1. Scans live interfaces
2. Comments out rules referencing absent interfaces (`wg0`, `enx*`, `br-*`/`docker0`)
3. Validates with `nft -c`, loads with `nft -f`, enables and starts `nftables.service`
4. Docker bridge rules collapsed to single manual task

### Network (`restore_network`)

Restores `/etc/network`, `systemd-network`, `nsswitch.conf`, `hosts.allow/deny`. Refreshes postfix chroot after nsswitch restore. Skipped in `lab` role.

---

## Validated restore order

```
system-basics → users → ssh
nginx → mariadb → postfix → prosody → docker → monitoring → tor → i2pd → tls
dns → firewall → network
```

DNS before firewall. Network last. TLS before DNS (nginx needs certs to start).

---

## Validated doctor baseline (hardware role)

```
Summary: ok=27 warn=2 fail=0 manual=1
```

Expected permanent warnings: `kvm` (VM only), DNS chain intentional.

---

## Restore categories

| Category | Risk | Notes |
|----------|------|-------|
| `system-basics` | low | hostname, hosts, locale, timezone |
| `users` | low | sudoers with ownership fix, shells |
| `ssh` | low | sshd_config; host keys in hardware/replacement only |
| `nginx` | low | lab: default site only; enables service |
| `mariadb` | low | /etc/mysql tree with normalization |
| `postfix` | low | main.cf, master.cf; enables and starts service |
| `prosody` | low | tree + cert permission normalization |
| `docker` | low | daemon.json; adds user to docker group |
| `monitoring` | low | prometheus, loki, grafana, alloy trees |
| `tor` | low | torrc; /var/lib/tor only in replacement role |
| `i2pd` | low | /etc/i2pd tree; /var/lib/i2pd only in replacement role |
| `tls` | low | letsencrypt certs from secret DB; reloads nginx |
| `dns` | **risky** | smart adaptive — see above |
| `firewall` | **risky** | smart adaptive — see above |
| `network` | **risky** | skipped in lab |

---

## Known lessons

**Metadata matters.** Content restore alone is not enough — owner, group, mode must be normalized. `restore_path()` handles this.

**DB shape matters.** A polluted DB produces bad restores even with correct logic. Always lint first.

**Tree restores are overlay-style.** Use a fresh VM or clean the destination before retesting.

**resolv.conf is sacred.** Never write it until a local resolver is confirmed listening. `install-base.sh` always writes a static file (breaking the systemd-resolved symlink) at bootstrap time.

**DNSSEC on Debian 13.** `unbound-anchor` is not shipped — use `dns-root-data` package + `unbound-helper`. Disable validator module for initial bring-up; re-enable after stable.

**Service start order.** unbound must be listening before dnsmasq starts.

**nftables interface references.** Rules referencing absent interfaces must be commented out or nftables refuses to load entirely.

**Docker on Debian.** `docker.io` ships v1 compose (`docker-compose`), not the v2 plugin (`docker compose`). Use `docker-compose` or install `docker-compose-plugin` separately.

---

## Public vs secret DB tiers

`db/public/` — unencrypted, git-tracked. Safe for remote backup.

`db/secret/` — root-only (`chmod 700`), excluded by `.gitignore`. Protected at rest by ZFS-on-LUKS. Contains SSH keys, TLS private keys, WireGuard keys, LUKS headers, service secrets.

---

## Quick reference

```bash
# Capture (self-contained — writes to db/ in toolkit dir)
sudo ~/.local/bin/straper/capture-full.sh

# Lint
sudo ~/.local/bin/straper/lint-db.sh

# Transfer toolkit + DB to target in one rsync
rsync -av ~/.local/bin/straper/ lukasz@TARGET:~/rebuild-test/sanctum-rebuild-toolkit/

# Install
sudo bash ./install-base.sh --role hardware --profile core

# Restore (non-interactive)
sudo bash ./restore-configs.sh --role hardware --yes --category dns

# Verify
sudo bash ./doctor.sh --role hardware

# List categories
sudo bash ./restore-configs.sh --list-categories
```

---

## Status

All 15 restore categories validated including risky (`dns`, `firewall`, `network`).
Validated doctor baseline: `ok=27 warn=2 fail=0`.
Suitable for: structured lab testing, staged hardware migration, disciplined disaster-recovery rehearsal.
