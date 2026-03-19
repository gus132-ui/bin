Below is a rewritten `README.md` that matches the **actual suite**, the **actual workflow**, and the **validated lessons** from today.

````markdown
# sanctum / labunix rebuild toolkit

A modular rebuild toolkit for restoring a Debian 13 system in a controlled order:

1. **capture**
2. **lint**
3. **install**
4. **restore**
5. **doctor**

The goal is to reduce rebuild time from weeks to hours while keeping risky state changes explicit, reversible, and testable.

---

## What this suite is for

This toolkit is for rebuilding a server such as `sanctum` onto:

- a **lab VM** for safe testing
- a **hardware-like machine** for conservative migration
- a **replacement target** after real failure

It is designed to separate:

- **base OS/bootstrap**
- **captured configuration state**
- **service-by-service restore**
- **read-only validation**

This suite is intentionally **interactive by default** and does **not** assume that every category should be restored in one step.

---

## Current toolkit components

- `capture-full.sh` — captures the source machine into a rebuild DB
- `lint-db.sh` — checks the DB for structural problems before restore
- `install-base.sh` — installs packages and generic baseline only
- `restore-configs.sh` — restores selected categories from the DB
- `doctor.sh` — read-only health and readiness checks
- `common.sh` — shared helpers and runtime/reporting functions

---

## Core design rules

- Keep **capture**, **restore**, and **verify** separate.
- Prefer **fresh VMs or snapshots** when testing restore behavior.
- Restore **category-by-category**, not all at once.
- Do not let one failed item abort the whole restore run unless explicitly required.
- Back up before overwrite.
- Write machine-readable reports and state files.
- Keep **identity/state restores** deliberate.
- Do not touch risky network/DNS/firewall state early in a rebuild.
- Treat the DB as a contract: **capture must produce a clean tree before restore can be trusted**.

---

## Roles

### `lab`
Use for:
- VM validation
- dry runs
- low-risk service restore tests

Behavior:
- conservative
- identity-heavy/private restores are skipped or limited
- network/DNS/firewall restore is intentionally deferred

### `hardware`
Use for:
- real machine migration when you still want to stay conservative

Behavior:
- broader than `lab`
- still avoids blindly assuming full disaster-recovery replacement semantics

### `replacement`
Use for:
- real rebuild after failure
- full recovery target where identities and service state may need to be restored

Behavior:
- allows more sensitive state restores when explicitly requested
- should be used only after DB quality and restore flow have already been validated

---

## Canonical workflow

## 1. On the source host: capture the DB

Create a fresh rebuild DB from the live server:

```bash
sudo ~/.local/bin/straper/capture-full.sh
````

To capture into a different path:

```bash
sudo CAPTURE_DIR=/tmp/sanctum-rebuild-clean ~/.local/bin/straper/capture-full.sh
```

This creates a rebuild database with:

* `db/public/`
* `db/secret/`

### Important

Capture should be run on the **real source machine**, not on the test VM.

---

## 2. Lint the DB before trusting it

Always lint the DB after capture and before restore:

```bash
sudo ~/.local/bin/straper/lint-db.sh --db-dir /tmp/sanctum-rebuild-clean
```

The linter is meant to catch DB-shape problems such as:

* nested duplicate roots like `nginx/nginx` or `i2pd/i2pd`
* overlapping category captures
* captured backup directories like `*.bak.*`
* duplicate canonical files at two depths

### Rule

If lint fails, do **not** treat that DB as canonical for restore.

---

## 3. Move toolkit and DB to the target machine

Typical pattern:

### Copy toolkit

```bash
rsync -av --delete ~/.local/bin/straper/ lukasz@TARGET:~/.local/bin/straper/
```

### Copy DB

```bash
rsync -av /tmp/sanctum-rebuild-clean/db/ lukasz@TARGET:~/sanctum-rebuild/db/
```

The target machine should then have:

* toolkit in `~/.local/bin/straper/`
* DB in `~/sanctum-rebuild/db/`

---

## 4. Install base system first

On the target machine:

```bash
cd ~/.local/bin/straper
sudo bash ./install-base.sh --role lab --profile core
```

For real rebuilds, use the appropriate role:

```bash
sudo bash ./install-base.sh --role replacement --profile core
```

### What `install-base.sh` is for

It prepares:

* package set
* generic base services
* baseline directories and runtime assumptions

It is **not** meant to transplant full server identity by itself.

---

## 5. Restore configs category-by-category

Do **not** restore everything blindly.

Use `restore-configs.sh` in blocks, validating after each block.

### Safe first block

```bash
sudo bash ./restore-configs.sh \
  --db-dir /home/lukasz/sanctum-rebuild \
  --role lab \
  --category system-basics \
  --category users \
  --category ssh
```

### Service block

```bash
sudo bash ./restore-configs.sh \
  --db-dir /home/lukasz/sanctum-rebuild \
  --role lab \
  --category nginx \
  --category mariadb \
  --category postfix \
  --category prosody
```

### Additional validated categories

```bash
sudo bash ./restore-configs.sh \
  --db-dir /home/lukasz/sanctum-rebuild \
  --role lab \
  --category monitoring \
  --category docker \
  --category tor \
  --category i2pd
```

### Risky categories to leave for later

These should be handled only after the machine is already stable:

* `network`
* `dns`
* `firewall`

And for replacement scenarios, also:

* SSH host keys
* `/var/lib/tor`
* `/var/lib/i2pd`

---

## 6. Run doctor after each block

Use `doctor.sh` after install and after meaningful restore steps:

```bash
sudo bash ./doctor.sh --db-dir /home/lukasz/sanctum-rebuild --role lab
```

This gives a read-only summary of:

* system readiness
* config validation
* service state
* warning profile
* current run state file

---

## Validated restore order

The currently validated rebuild order is:

1. **capture on source host**
2. **lint the DB**
3. **move toolkit and DB to target**
4. **run `install-base.sh`**
5. **run `restore-configs.sh` category-by-category**
6. **run `doctor.sh`**
7. **only then move into risky network/identity categories**

This is the canonical order to follow unless there is a strong reason to deviate.

---

## Current restore categories

`restore-configs.sh --list-categories` currently supports:

* `system-basics`
* `users`
* `ssh`
* `network`
* `dns`
* `firewall`
* `nginx`
* `mariadb`
* `postfix`
* `prosody`
* `tor`
* `i2pd`
* `docker`
* `monitoring`

---

## What has been validated in `lab`

The following categories have been exercised successfully in `lab`:

* `system-basics`
* `users`
* `ssh`
* `nginx`
* `mariadb`
* `postfix`
* `prosody`
* `docker`
* `tor`
* `i2pd`
* `monitoring`

### Important caveat

For tree-category retests on a **reused VM**, stale files may survive because tree restores currently behave like **overlay restores**, not strict replacements.

That means:

* use a **fresh VM/snapshot** when possible, or
* move the old destination tree aside before re-testing a tree category

Examples of tree categories affected by this testing rule:

* `nginx`
* `monitoring`
* `i2pd`
* `mariadb`

This is a testing-method concern, not necessarily a DB defect.

---

## Public vs secret DB tiers

## `db/public`

Safe, non-secret inventory and configs intended for rebuild structure and general restore use.

## `db/secret`

Sensitive material such as:

* SSH keys
* TLS private keys
* service secrets
* database credentials
* Tor/I2P private state
* user shell configs that may contain tokens

### Rule

Do **not** commit `db/secret` to git.

---

## Reports, backups, and state

The suite writes runtime artifacts under:

* `/var/log/labunix-rebuild/`
* `/var/lib/labunix-rebuild/`

Common outputs include:

* report TSV files
* doctor output
* state files
* per-run backups of overwritten targets

### Typical state file

* `/var/lib/labunix-rebuild/state-<RUN_ID>.env`

### Typical report file

* `/var/log/labunix-rebuild/report-<RUN_ID>.tsv`

---

## Lab VM workflow

Use this when validating on a fresh VM.

### On source host

```bash
sudo CAPTURE_DIR=/tmp/sanctum-rebuild-clean ~/.local/bin/straper/capture-full.sh
sudo ~/.local/bin/straper/lint-db.sh --db-dir /tmp/sanctum-rebuild-clean
```

### Copy to VM

```bash
rsync -av ~/.local/bin/straper/ lukasz@VM:~/rebuild-test/sanctum-rebuild-toolkit/
rsync -av /tmp/sanctum-rebuild-clean/db/ lukasz@VM:~/sanctum-rebuild/db/
```

### On VM

```bash
cd ~/rebuild-test/sanctum-rebuild-toolkit
sudo bash ./install-base.sh --role lab --profile core
```

Then restore in blocks and run `doctor.sh` after each block.

---

## Hardware / replacement workflow

Use this when preparing a real migration or real recovery target.

### On source machine

Capture and lint first:

```bash
sudo ~/.local/bin/straper/capture-full.sh
sudo ~/.local/bin/straper/lint-db.sh --db-dir /srv/sanctum-rebuild
```

### On target

Install base:

```bash
sudo bash ./install-base.sh --role replacement --profile core
```

Restore safe categories first:

```bash
sudo bash ./restore-configs.sh \
  --db-dir /srv/sanctum-rebuild \
  --role replacement \
  --category system-basics \
  --category users \
  --category ssh
```

Then service categories:

```bash
sudo bash ./restore-configs.sh \
  --db-dir /srv/sanctum-rebuild \
  --role replacement \
  --category nginx \
  --category mariadb \
  --category postfix \
  --category prosody \
  --category docker \
  --category monitoring
```

Only after the machine is stable should you move into:

* `network`
* `dns`
* `firewall`
* identity/state-heavy restores

Then run:

```bash
sudo bash ./doctor.sh --db-dir /srv/sanctum-rebuild --role replacement
```

---

## What this toolkit deliberately does not assume

* that a dirty VM is a valid proof environment for repeated tree restores
* that network restore is safe early
* that secrets/identities should be transplanted automatically
* that the DB is trustworthy unless it passes lint
* that one giant all-at-once restore is the right recovery method

---

## Known lessons from validation

### 1. Metadata matters

Restoring content is not enough. Sensitive files and trees also need:

* owner
* group
* mode

### 2. DB shape matters

A structurally polluted DB can create duplicate nested restore trees even if restore logic is otherwise correct.

### 3. Tree restores are not strict replacement

Current behavior is overlay-style unless the destination is cleaned first.

### 4. Testing method matters

For tree-category retests:

* use a fresh VM/snapshot, or
* move the old destination aside first

---

## Current recommended stopping rule

A rebuild step is “good enough to proceed” when:

* DB passes `lint-db.sh`
* `install-base.sh` completes
* restore block completes without new obvious regressions
* `doctor.sh` baseline remains stable
* service-specific validation passes where relevant

---

## Minimal quick-reference

### Capture

```bash
sudo ~/.local/bin/straper/capture-full.sh
```

### Lint

```bash
sudo ~/.local/bin/straper/lint-db.sh --db-dir /srv/sanctum-rebuild
```

### Install base

```bash
sudo bash ./install-base.sh --role lab --profile core
```

### Restore safe block

```bash
sudo bash ./restore-configs.sh \
  --db-dir /home/lukasz/sanctum-rebuild \
  --role lab \
  --category system-basics \
  --category users \
  --category ssh
```

### Verify

```bash
sudo bash ./doctor.sh --db-dir /home/lukasz/sanctum-rebuild --role lab
```

---

## Status

This suite is now suitable for:

* structured lab rebuild testing
* staged migration preparation
* disciplined disaster-recovery rehearsal

It should still be used with:

* staged restores
* DB linting
* post-step validation
* caution around risky network and identity layers

