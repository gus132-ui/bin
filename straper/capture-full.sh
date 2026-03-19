#!/usr/bin/env bash
# =============================================================================
# capture-full.sh — sanctum full-state capture with encrypted secret database
# =============================================================================
# Captures the complete state of sanctum into two tiers:
#
#   db/public/    — safe, unencrypted inventory (same as capture-state.sh)
#   db/secret/    — ALL secrets, root-only (chmod 700), never committed to git
#
# Together these two tiers contain everything needed to fully reproduce
# this machine on a fresh Debian 13 minimal install via bootstrap.sh.
#
# USAGE
#   sudo ./capture-full.sh [--dry-run] [--help]
#
# OPTIONS
#   --dry-run    Show what would be captured without writing anything
#   --help       Show this message
#
# REQUIREMENTS
#   - Must be run as root (sudo)
#   - GPG must be installed: apt install gnupg
#   - GPG_RECIPIENT must be set (key fingerprint or email), OR
#     set it in /etc/labunix/capture.conf or ~/.config/labunix/capture.conf
#   - jq must be installed: apt install jq
#   - Output goes to CAPTURE_DIR (default: /srv/sanctum-rebuild)
#
# OUTPUT STRUCTURE
#   /srv/sanctum-rebuild/
#   ├── capture-full.sh         this script (self-referential copy)
#   ├── bootstrap.sh            reproduction script (generated separately)
#   ├── db/
#   │   ├── public/             unencrypted inventory — git-safe
#   │   │   ├── system/
#   │   │   ├── packages/
#   │   │   ├── services/
#   │   │   ├── docker/
#   │   │   ├── network/
#   │   │   ├── firewall/
#   │   │   └── ...
#   │   ├── secret/             GPG-encrypted — NEVER commit to git
#   │   │   ├── secrets.tar.gpg all secret material in one encrypted archive
#   │   │   └── secrets.index   unencrypted index of what is inside (no values)
#   │   └── README.md
#   └── README.md
#
# SECURITY MODEL
#   - db/public/  : safe to push to private git repo
#   - db/secret/  : local only, root-only permissions (chmod 700)
#                     protected by ZFS-on-LUKS disk encryption
#   - The .gitignore in CAPTURE_DIR excludes db/secret/ entirely
#   - bootstrap.sh reads db/public/ for structure and db/secret/ for values
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
#  CONFIGURATION
# --------------------------------------------------------------------------- #
CAPTURE_DIR="${CAPTURE_DIR:-/srv/sanctum-rebuild}"
PUBLIC_DIR="${CAPTURE_DIR}/db/public"
SECRET_DIR="${CAPTURE_DIR}/db/secret"
TIMESTAMP="$(date +"%Y-%m-%dT%H:%M:%S")"
HOSTNAME_SHORT="$(hostname -s)"
DRY_RUN=false
WARNINGS=()

# Load config file if present
for conf in /etc/labunix/capture.conf "${HOME}/.config/labunix/capture.conf"; do
  [[ -f "$conf" ]] && source "$conf" || true
done

# --------------------------------------------------------------------------- #
#  ARGUMENT PARSING
# --------------------------------------------------------------------------- #
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help)
      grep '^#' "$0" | head -40 | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
#  HELPERS
# --------------------------------------------------------------------------- #
log()     { echo "  [$(date +%H:%M:%S)] $*"; }
warn()    { echo "  [$(date +%H:%M:%S)] WARN: $*" >&2; WARNINGS+=("$*"); }
section() { echo ""; echo "── $* ──"; }
die()     { echo "ERROR: $*" >&2; exit 1; }

# pub <outfile> <cmd...>
# Capture command output into public (unencrypted) tier.
pub() {
  local out="${PUBLIC_DIR}/$1"; shift
  if $DRY_RUN; then echo "  [pub] $* → ${out#$PUBLIC_DIR/}"; return; fi
  mkdir -p "$(dirname "$out")"
  if ! "$@" > "$out" 2>&1; then
    warn "command failed: $*"
    echo "# ERROR: '$*' failed at ${TIMESTAMP}" > "$out"
  fi
}

# pub_copy <src> <dst_relative>
# Copy file/dir into public tier.
pub_copy() {
  local src="$1" dst="${PUBLIC_DIR}/$2"
  if $DRY_RUN; then echo "  [pub] copy ${src} → $2"; return; fi
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst" 2>/dev/null || warn "could not copy ${src}"
}

# sec <dst_relative> <src_path>
# Copy secret material directly into the secret directory.
sec() {
  local dst="${SECRET_DIR}/$1" src="$2"
  if $DRY_RUN; then echo "  [sec] ${src} → secret/$1"; return; fi
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst" 2>/dev/null || warn "could not stage secret: ${src}"
}

# sec_val <dst_relative> <value>
# Write a literal secret value as a file.
sec_val() {
  local dst="${SECRET_DIR}/$1"
  if $DRY_RUN; then echo "  [sec] value → secret/$1"; return; fi
  mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$2" > "$dst"
}

# sec_cmd <dst_relative> <cmd...>
# Capture command output as a secret.
sec_cmd() {
  local dst="${SECRET_DIR}/$1"; shift
  if $DRY_RUN; then echo "  [sec] command → secret/$1"; return; fi
  mkdir -p "$(dirname "$dst")"
  if ! "$@" > "$dst" 2>&1; then
    warn "secret command failed: $*"
    echo "# ERROR: '$*' failed" > "$dst"
  fi
}

# index_secret <path> <description>
# Add an entry to the secrets index (unencrypted — shows what exists, not values).
SECRET_INDEX_ENTRIES=()
index_secret() {
  SECRET_INDEX_ENTRIES+=("$(printf '%-50s  %s' "$1" "$2")")
}

# --------------------------------------------------------------------------- #
#  PRE-FLIGHT CHECKS
# --------------------------------------------------------------------------- #
[[ $EUID -eq 0 ]] || die "run with sudo"

if ! $DRY_RUN; then
  command -v jq  &>/dev/null || die "jq not found — apt install jq"
  command -v tar &>/dev/null || die "tar not found"

  mkdir -p "${PUBLIC_DIR}" "${SECRET_DIR}"
  chmod 700 "${SECRET_DIR}"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  labunix · capture-full — full state + secret DB    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
log "host      : ${HOSTNAME_SHORT}"
log "timestamp : ${TIMESTAMP}"
log "public    : ${PUBLIC_DIR}"
log "secret    : ${SECRET_DIR}/ (root-only, chmod 700)"
$DRY_RUN && log "(DRY RUN — nothing will be written)"

# =========================================================================== #
#  PUBLIC TIER — safe inventory, no secret values
# =========================================================================== #

# --------------------------------------------------------------------------- #
#  P1. SYSTEM IDENTITY
# --------------------------------------------------------------------------- #
section "P1 system"

pub "system/hostname.txt"    hostname -f
pub "system/os-release.txt"  cat /etc/os-release
pub "system/kernel.txt"      uname -a
pub "system/lscpu.txt"       lscpu
pub "system/memory.txt"      free -h
pub "system/lsblk.txt"       lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID,LABEL
pub "system/df.txt"          df -hT --exclude-type=tmpfs --exclude-type=devtmpfs
pub "system/locale.txt"      locale
pub "system/timedatectl.txt" timedatectl
pub "system/uptime.txt"      uptime
pub "system/dmesg-err.txt"   dmesg --level=err,crit,alert,emerg

pub_copy /etc/hostname    "system/etc-hostname"
pub_copy /etc/hosts       "system/etc-hosts"
pub_copy /etc/fstab       "system/etc-fstab"
pub_copy /etc/crypttab    "system/etc-crypttab"
pub_copy /etc/environment "system/etc-environment"
pub_copy /etc/locale.gen  "system/locale.gen"
pub_copy /etc/timezone    "system/timezone"

log "done"

# --------------------------------------------------------------------------- #
#  P2. ZFS
# --------------------------------------------------------------------------- #
section "P2 zfs"

if command -v zpool &>/dev/null; then
  pub "zfs/zpool-status.txt"   zpool status -v
  pub "zfs/zpool-list.txt"     zpool list -v
  pub "zfs/zpool-history.txt"  zpool history
  pub "zfs/zfs-list.txt"       zfs list -t all -o name,used,avail,refer,mountpoint,type
  pub "zfs/zfs-properties.txt" zfs get all
  pub "zfs/zfs-snapshots.txt"  zfs list -t snapshot -o name,used,creation -s creation
  pub_copy /etc/zfs            "zfs/etc-zfs"
  log "done"
else
  warn "zpool not found — skipping ZFS"
fi

# --------------------------------------------------------------------------- #
#  P3. NETWORK
# --------------------------------------------------------------------------- #
section "P3 network"

pub "network/ip-addr.txt"      ip -s addr show
pub "network/ip-route.txt"     ip route show table all
pub "network/ip-rule.txt"      ip rule show
pub "network/ss-listening.txt" ss -tlnpue

pub_copy /etc/network         "network/etc-network"
pub_copy /etc/netplan         "network/etc-netplan"
pub_copy /etc/systemd/network "network/systemd-network"
pub_copy /etc/nsswitch.conf   "network/nsswitch.conf"
pub_copy /etc/hosts.allow     "network/hosts.allow"
pub_copy /etc/hosts.deny      "network/hosts.deny"

log "done"

# --------------------------------------------------------------------------- #
#  P4. FIREWALL
# --------------------------------------------------------------------------- #
section "P4 firewall"

pub "firewall/nft-ruleset.txt"  nft list ruleset
pub "firewall/nft-ruleset.json" nft -j list ruleset

pub_copy /etc/nftables.conf "firewall/nftables.conf"
pub_copy /etc/nftables.d    "firewall/nftables.d"

log "done"

# --------------------------------------------------------------------------- #
#  P5. WIREGUARD — public info only
# --------------------------------------------------------------------------- #
section "P5 wireguard"

if command -v wg &>/dev/null; then
  pub "wireguard/wg-show.txt"       wg show
  pub "wireguard/wg-interfaces.txt" ip link show type wireguard

  # Redacted public copy (PrivateKey + PresharedKey scrubbed)
  if ! $DRY_RUN && [[ -d /etc/wireguard ]]; then
    mkdir -p "${PUBLIC_DIR}/wireguard/etc-wireguard"
    for f in /etc/wireguard/*.conf; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      sed \
        -e 's/^\(PrivateKey\s*=\s*\).*/\1<REDACTED>/' \
        -e 's/^\(PresharedKey\s*=\s*\).*/\1<REDACTED>/' \
        "$f" > "${PUBLIC_DIR}/wireguard/etc-wireguard/${base}" 2>/dev/null \
        || warn "could not sanitize ${f}"
    done
    log "public: PrivateKey + PresharedKey redacted"
  fi
  log "done"
else
  warn "wg not found — skipping WireGuard"
fi

# --------------------------------------------------------------------------- #
#  P6. DNS
# --------------------------------------------------------------------------- #
section "P6 dns"

if [[ -f /etc/dnsmasq.conf ]] || command -v dnsmasq &>/dev/null; then
  command -v dnsmasq &>/dev/null && pub "dns/dnsmasq-version.txt" dnsmasq --version
  pub_copy /etc/dnsmasq.conf "dns/dnsmasq.conf"
  pub_copy /etc/dnsmasq.d    "dns/dnsmasq.d"
fi

if [[ -d /etc/unbound ]]; then
  command -v unbound &>/dev/null && pub "dns/unbound-version.txt" unbound -V
  pub_copy /etc/unbound "dns/etc-unbound"
fi

pub_copy /etc/resolv.conf "dns/resolv.conf"

log "done"

# --------------------------------------------------------------------------- #
#  P7. TLS — cert metadata only (no key material)
# --------------------------------------------------------------------------- #
section "P7 tls"

if command -v certbot &>/dev/null; then
  pub "tls/certbot-version.txt"      certbot --version
  pub "tls/certbot-certificates.txt" certbot certificates
fi

pub_copy /etc/letsencrypt/renewal "tls/renewal-configs"
pub_copy /etc/letsencrypt/cli.ini "tls/cli.ini"

# Cert expiry summary
if ! $DRY_RUN && [[ -d /etc/letsencrypt/live ]]; then
  {
    printf "# TLS certificate expiry — %s\n" "${TIMESTAMP}"
    printf "# %-40s  %-28s  %-28s  %s\n" "domain" "not_before" "not_after" "days_left"
    echo ""
    for cert in /etc/letsencrypt/live/*/fullchain.pem; do
      [[ -f "$cert" ]] || continue
      domain="$(basename "$(dirname "$cert")")"
      not_before="$(openssl x509 -noout -startdate -in "$cert" 2>/dev/null | cut -d= -f2)"
      not_after="$(openssl x509  -noout -enddate   -in "$cert" 2>/dev/null | cut -d= -f2)"
      expiry_epoch="$(date -d "$not_after" +%s 2>/dev/null || echo 0)"
      days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
      printf "%-42s  %-28s  %-28s  %d\n" \
        "$domain" "$not_before" "$not_after" "$days_left"
    done
  } > "${PUBLIC_DIR}/tls/cert-expiry.txt"
fi

log "done"

# --------------------------------------------------------------------------- #
#  P8. NGINX — config (may reference secrets but config itself is public)
# --------------------------------------------------------------------------- #
section "P8 nginx"

if command -v nginx &>/dev/null; then
  pub "nginx/nginx-version.txt" nginx -v
  pub "nginx/nginx-T.txt"       nginx -T
  pub "nginx/nginx-t.txt"       nginx -t
  pub_copy /etc/nginx           "nginx/etc-nginx"

  if ! $DRY_RUN; then
    # Remove auth files from the public copy
    find "${PUBLIC_DIR}/nginx/etc-nginx" \
      \( -name "*.htpasswd" -o -name "htpasswd-*" -o -name ".htpasswd" -o -name "lufi.htpasswd" \) \
      -delete 2>/dev/null || true

    # Remove local backup trees from the public copy
    find "${PUBLIC_DIR}/nginx/etc-nginx" \
      -maxdepth 1 -type d -name 'sites-available.bak.*' \
      -exec rm -rf {} + 2>/dev/null || true

    log "htpasswd files removed from public nginx copy"
    log "nginx backup dirs removed from public copy"
  fi

  log "done"
else
  warn "nginx not found"
fi

# --------------------------------------------------------------------------- #
#  P9. DOCKER — sanitized inventory
# --------------------------------------------------------------------------- #
section "P9 docker"

if command -v docker &>/dev/null; then
  pub "docker/docker-version.txt"    docker version
  pub "docker/docker-info.txt"       docker info
  pub "docker/docker-ps.txt"         docker ps -a \
    --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  pub "docker/docker-images.txt"     docker images \
    --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedAt}}"
  pub "docker/docker-volumes.txt"    docker volume ls
  pub "docker/docker-networks.txt"   docker network ls \
    --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}\t{{.ID}}"
  pub "docker/docker-compose-ls.txt" docker compose ls 2>/dev/null || true
  pub_copy /etc/docker/daemon.json   "docker/daemon.json"

  # Inspect with Env[] stripped
  if ! $DRY_RUN && command -v jq &>/dev/null; then
    mkdir -p "${PUBLIC_DIR}/docker/inspect"
    docker ps -aq 2>/dev/null | while read -r cid; do
      name="$(docker inspect --format '{{.Name}}' "$cid" \
              | tr '/' '_' | sed 's/^_//')"
      docker inspect "$cid" 2>/dev/null \
        | jq '.[0] | del(.Config.Env, .HostConfig.Env)' \
        > "${PUBLIC_DIR}/docker/inspect/${name}.json" 2>/dev/null || true
    done
    log "inspect captured (Env[] stripped)"
  fi

  # Compose files — redact secret-looking values
  if ! $DRY_RUN; then
    mkdir -p "${PUBLIC_DIR}/docker/compose-redacted"
    find /srv /opt /home /root -maxdepth 3 \
      \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \
         -o -name "compose.yml"     -o -name "compose.yaml" \) \
      -not -path "*/sanctum-rebuild/*" \
      -not -path "*/labunix-infra/*" \
      -not -path "*/\.*" \
      2>/dev/null \
      | while read -r f; do
          rel="$(echo "$f" | sed 's|^/||; s|/|__|g')"
          sed -E \
            -e 's/(PASSWORD|SECRET|TOKEN|API_KEY|APIKEY|AUTH_KEY|PRIVATE_KEY|DB_PASS|MYSQL_PASS|POSTGRES_PASS|REDIS_PASS|SMTP_PASS)[[:space:]]*=[[:space:]]*[^[:space:]#].*/\1=<REDACTED>/gI' \
            -e 's/(PASSWORD|SECRET|TOKEN|API_KEY|APIKEY|AUTH_KEY|PRIVATE_KEY|DB_PASS|MYSQL_PASS|POSTGRES_PASS|REDIS_PASS|SMTP_PASS):[[:space:]]*"[^"]*"/\1: "<REDACTED>"/gI' \
            "$f" > "${PUBLIC_DIR}/docker/compose-redacted/${rel}" 2>/dev/null || true
        done
    log "compose files collected (secrets redacted)"
  fi

  log "done"
else
  warn "docker not found"
fi

# --------------------------------------------------------------------------- #
#  P10. PACKAGES
# --------------------------------------------------------------------------- #
section "P10 packages"

pub "packages/dpkg-list.txt"       dpkg -l
pub "packages/dpkg-selections.txt" dpkg --get-selections
pub "packages/apt-mark-manual.txt" apt-mark showmanual
pub "packages/apt-mark-auto.txt"   apt-mark showauto

pub_copy /etc/apt/sources.list   "packages/apt/sources.list"
pub_copy /etc/apt/sources.list.d "packages/apt/sources.list.d"
pub_copy /etc/apt/preferences    "packages/apt/preferences"
pub_copy /etc/apt/preferences.d  "packages/apt/preferences.d"
pub_copy /etc/apt/apt.conf.d     "packages/apt/apt.conf.d"

command -v pip3    &>/dev/null && pub "packages/pip3-list.txt"    pip3 list --format=columns
command -v npm     &>/dev/null && pub "packages/npm-global.txt"   npm list -g --depth=0
command -v cargo   &>/dev/null && pub "packages/cargo-list.txt"   cargo install --list
command -v gem     &>/dev/null && pub "packages/gem-list.txt"     gem list

log "done"

# --------------------------------------------------------------------------- #
#  P11. SYSTEMD SERVICES
# --------------------------------------------------------------------------- #
section "P11 services"

pub "services/units-enabled.txt"  systemctl list-unit-files --state=enabled  --no-pager
pub "services/units-running.txt"  systemctl list-units --type=service --state=running --no-pager
pub "services/units-failed.txt"   systemctl list-units --state=failed --no-pager
pub "services/timers.txt"         systemctl list-timers --all --no-pager
pub "services/unit-files-all.txt" systemctl list-unit-files --no-pager

if ! $DRY_RUN; then
  mkdir -p "${PUBLIC_DIR}/services/custom-units"
  for f in /etc/systemd/system/*.service \
            /etc/systemd/system/*.timer   \
            /etc/systemd/system/*.socket  \
            /etc/systemd/system/*.mount   \
            /etc/systemd/system/*.target  \
            /etc/systemd/system/*.path; do
    [[ -f "$f" ]] || continue
    cp "$f" "${PUBLIC_DIR}/services/custom-units/" 2>/dev/null || true
  done
  for d in /etc/systemd/system/*.d; do
    [[ -d "$d" ]] || continue
    cp -a "$d" "${PUBLIC_DIR}/services/custom-units/" 2>/dev/null || true
  done
  log "custom units + drop-ins copied"
fi

pub_copy /etc/systemd/journald.conf  "services/journald.conf"
pub_copy /etc/systemd/logind.conf    "services/logind.conf"
pub_copy /etc/systemd/system.conf    "services/system.conf"
pub_copy /etc/systemd/timesyncd.conf "services/timesyncd.conf"

log "done"

# --------------------------------------------------------------------------- #
#  P12. CRON
# --------------------------------------------------------------------------- #
section "P12 cron"

pub_copy /etc/crontab           "cron/crontab"
pub_copy /etc/cron.d            "cron/cron.d"
pub_copy /etc/cron.daily        "cron/cron.daily"
pub_copy /etc/cron.weekly       "cron/cron.weekly"
pub_copy /etc/cron.monthly      "cron/cron.monthly"

log "done"

# --------------------------------------------------------------------------- #
#  P13. USERS — sanitized (no hashes)
# --------------------------------------------------------------------------- #
section "P13 users"

if ! $DRY_RUN; then
  mkdir -p "${PUBLIC_DIR}/users"
  awk -F: '{print $1":"$3":"$4":"$5":"$6":"$7}' /etc/passwd \
    > "${PUBLIC_DIR}/users/passwd-sanitized.txt" 2>/dev/null || true
  awk -F: '{print $1":"$3}' /etc/group \
    > "${PUBLIC_DIR}/users/groups-sanitized.txt" 2>/dev/null || true
  grep -E '(/bin/bash|/bin/zsh|/bin/sh|/usr/bin/zsh)$' /etc/passwd \
    | awk -F: '{print $1" home="$6" shell="$7}' \
    > "${PUBLIC_DIR}/users/login-users.txt" 2>/dev/null || true
fi

pub_copy /etc/ssh/sshd_config   "users/sshd_config"
pub_copy /etc/ssh/sshd_config.d "users/sshd_config.d"
pub_copy /etc/sudoers           "users/sudoers"
pub_copy /etc/sudoers.d         "users/sudoers.d"
pub_copy /etc/shells            "users/shells"
pub_copy /etc/login.defs        "users/login.defs"

log "done"

# --------------------------------------------------------------------------- #
#  P14–P35: remaining public captures (configs without embedded secrets)
# --------------------------------------------------------------------------- #
section "P14-P35 service configs"

# Kernel
pub "kernel/sysctl-all.txt" sysctl -a
pub "kernel/lsmod.txt"      lsmod
pub_copy /etc/sysctl.conf    "kernel/sysctl.conf"
pub_copy /etc/sysctl.d       "kernel/sysctl.d"
pub_copy /etc/modules        "kernel/modules"
pub_copy /etc/modules-load.d "kernel/modules-load.d"
pub_copy /etc/modprobe.d     "kernel/modprobe.d"

# i2pd (no key material)
if [[ -f /etc/i2pd/i2pd.conf ]]; then
  pub_copy /etc/i2pd "i2pd/etc-i2pd"
fi

# Tor (no private keys)
if [[ -f /etc/tor/torrc ]]; then
  pub_copy /etc/tor/torrc   "tor/torrc"
  pub_copy /etc/tor/torrc.d "tor/torrc.d"
  if ! $DRY_RUN && [[ -d /var/lib/tor ]]; then
    mkdir -p "${PUBLIC_DIR}/tor/hidden-services"
    find /var/lib/tor -name "hostname" 2>/dev/null \
      | while read -r hf; do
          svc="$(basename "$(dirname "$hf")")"
          cp "$hf" "${PUBLIC_DIR}/tor/hidden-services/${svc}.hostname" 2>/dev/null || true
        done
  fi
fi

# Hugo
command -v hugo &>/dev/null && pub "hugo/hugo-version.txt" hugo version
for site_dir in /srv/www/labunix /srv/www/labunix.xyz; do
  [[ -d "$site_dir" ]] || continue
  pub_copy "${site_dir}/hugo.toml"  "hugo/hugo.toml"
  pub_copy "${site_dir}/config"     "hugo/config-dir"
  pub_copy "${site_dir}/go.mod"     "hugo/go.mod"
  break
done

# Agate
if [[ -f /home/lukasz/apps/agate/agate ]]; then
  pub "agate/agate-version.txt" /home/lukasz/apps/agate/agate --version
  if ! $DRY_RUN && [[ -d /srv/gemini-capsule ]]; then
    find /srv/gemini-capsule -not -path "*/.certificates*" \
      | sort > "${PUBLIC_DIR}/agate/capsule-structure.txt" 2>/dev/null || true
  fi
fi

# Pygopherd
pub_copy /etc/pygopherd "pygopherd/etc-pygopherd"

# Agate service unit
pub_copy /etc/systemd/system/agate.service "agate/agate.service"

# Postfix (main.cf is public, sasl_passwd goes to secret)
if [[ -d /etc/postfix ]]; then
  pub_copy /etc/postfix/main.cf   "postfix/main.cf"
  pub_copy /etc/postfix/master.cf "postfix/master.cf"
  pub "postfix/postconf.txt" postconf 2>/dev/null || true
fi

# MariaDB (config only, no credentials)
pub_copy /etc/mysql "mariadb/etc-mysql"
if ! $DRY_RUN; then
  mariadb --defaults-file=/etc/mysql/debian.cnf \
    -e "SHOW DATABASES;" 2>/dev/null \
    > "${PUBLIC_DIR}/mariadb/databases.txt" || true
fi

# Alloy
pub_copy /etc/alloy         "alloy/etc-alloy"
pub_copy /etc/default/alloy "alloy/etc-default-alloy"

# Prometheus
pub_copy /etc/prometheus "prometheus/etc-prometheus"
pub_copy /etc/default/prometheus-node-exporter "prometheus/node-exporter-defaults"

# Fail2ban
pub_copy /etc/fail2ban "fail2ban/etc-fail2ban"

# Prosody
pub_copy /etc/prosody "prosody/etc-prosody"

# Grafana (provisioning configs, no secrets)
pub_copy /etc/grafana "grafana/etc-grafana"

# Loki + Promtail
pub_copy /etc/loki    "loki/etc-loki"
pub_copy /etc/promtail "loki/etc-promtail"

# Mumble
pub_copy /etc/mumble "mumble/etc-mumble"

# AppArmor
command -v aa-status &>/dev/null \
  && pub "apparmor/aa-status.txt" aa-status 2>/dev/null || true
pub_copy /etc/apparmor.d "apparmor/apparmor.d"

# Boot / initramfs — critical for LUKS+ZFS rebuild
pub_copy /etc/default/grub         "boot/grub-default"
pub_copy /etc/grub.d               "boot/grub.d"
pub_copy /etc/kernel               "boot/etc-kernel"
pub_copy /etc/cryptsetup-initramfs "boot/cryptsetup-initramfs"
pub_copy /etc/initramfs-tools      "boot/initramfs-tools"
pub_copy /etc/default              "boot/etc-default"

# Lufi
pub_copy /srv/lufi/cpanfile "lufi/cpanfile"
if ! $DRY_RUN && [[ -d /srv/lufi ]]; then
  git -C /srv/lufi log --oneline -5 2>/dev/null \
    > "${PUBLIC_DIR}/lufi/git-log.txt" || true
fi

# Environment
pub_copy /etc/profile   "environment/profile"
pub_copy /etc/profile.d "environment/profile.d"
pub_copy /etc/zsh       "environment/zsh"

# Logging
pub_copy /etc/logrotate.conf "logging/logrotate.conf"
pub_copy /etc/logrotate.d    "logging/logrotate.d"
pub_copy /etc/rsyslog.conf   "logging/rsyslog.conf"
pub_copy /etc/rsyslog.d      "logging/rsyslog.d"

# Hardware
command -v lshw  &>/dev/null && pub "hardware/lshw.txt"  lshw -short
command -v lspci &>/dev/null && pub "hardware/lspci.txt" lspci -v
command -v lsusb &>/dev/null && pub "hardware/lsusb.txt" lsusb
pub "hardware/cpuinfo.txt"   cat /proc/cpuinfo
pub "hardware/meminfo.txt"   cat /proc/meminfo

log "done"

# =========================================================================== #
#  SECRET TIER — full secrets, will be GPG-encrypted
# =========================================================================== #

section "SECRET TIER"
log "Staging secret material..."

# ── WireGuard — real private keys ───────────────────────────────────────────
if [[ -d /etc/wireguard ]]; then
  sec "wireguard/etc-wireguard" /etc/wireguard
  index_secret "wireguard/etc-wireguard" "WireGuard interface configs with PrivateKey + PresharedKey"
fi

# ── TLS private keys ─────────────────────────────────────────────────────────
if [[ -d /etc/letsencrypt ]]; then
  sec "tls/letsencrypt" /etc/letsencrypt
  index_secret "tls/letsencrypt" "Full Let's Encrypt dir including private keys"
fi

# ── SSH host keys ────────────────────────────────────────────────────────────
if [[ -d /etc/ssh ]]; then
  sec "ssh/etc-ssh" /etc/ssh
  index_secret "ssh/etc-ssh" "SSH host keys (id_* private key files)"
fi

# ── User SSH keys + authorized_keys ─────────────────────────────────────────
if ! $DRY_RUN; then
  while IFS=: read -r user _ _ _ _ homedir _; do
    [[ -d "${homedir}/.ssh" ]] || continue
    sec "ssh/user-${user}" "${homedir}/.ssh"
    index_secret "ssh/user-${user}" "SSH keys and authorized_keys for ${user}"
  done < /etc/passwd
fi

# ── Docker compose files — full unredacted ──────────────────────────────────
if ! $DRY_RUN; then
  mkdir -p "${SECRET_DIR}/docker/compose-full"
  find /srv /opt /home /root -maxdepth 3 \
    \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \
       -o -name "compose.yml"     -o -name "compose.yaml" \
       -o -name ".env"            -o -name "*.env" \) \
    -not -path "*/sanctum-rebuild/*" \
    -not -path "*/labunix-infra/*" \
    -not -path "*/\.*env.example" \
    2>/dev/null \
    | while read -r f; do
        rel="$(echo "$f" | sed 's|^/||; s|/|__|g')"
        cp "$f" "${SECRET_DIR}/docker/compose-full/${rel}" 2>/dev/null || true
      done
  index_secret "docker/compose-full" "All compose files + .env files with real secrets"
fi

# ── MariaDB credentials + dumps ──────────────────────────────────────────────
if [[ -f /etc/mysql/debian.cnf ]]; then
  sec "mariadb/debian.cnf" /etc/mysql/debian.cnf
  index_secret "mariadb/debian.cnf" "MariaDB debian-sys-maint credentials"
fi

# Dump all database schemas (structure only, no data) — for rebuild reference
if ! $DRY_RUN && command -v mysqldump &>/dev/null; then
  mkdir -p "${SECRET_DIR}/mariadb"
  mariadb --defaults-file=/etc/mysql/debian.cnf \
    -e "SHOW DATABASES;" 2>/dev/null \
    | grep -v "^Database\|information_schema\|performance_schema\|sys" \
    | while read -r db; do
        mysqldump --defaults-file=/etc/mysql/debian.cnf \
          --no-data --routines --triggers \
          "$db" 2>/dev/null \
          > "${SECRET_DIR}/mariadb/schema-${db}.sql" || true
      done
  index_secret "mariadb/schema-*.sql" "MariaDB schema dumps (structure only, no data)"
fi

# ── Postfix SASL credentials ─────────────────────────────────────────────────
if [[ -f /etc/postfix/sasl_passwd ]]; then
  sec "postfix/sasl_passwd" /etc/postfix/sasl_passwd
  index_secret "postfix/sasl_passwd" "Postfix SASL relay credentials"
fi

# ── GPG keys (export secret keyring) ────────────────────────────────────────
if ! $DRY_RUN && command -v gpg &>/dev/null; then
  mkdir -p "${SECRET_DIR}/gpg"
  # Export all secret keys for all users with home dirs
  while IFS=: read -r user _ _ _ _ homedir _; do
    [[ -d "${homedir}/.gnupg" ]] || continue
    # Run gpg as the actual user, not as root, so it can access their keyring
    sudo -u "${user}"       GNUPGHOME="${homedir}/.gnupg" gpg       --batch --yes       --export-secret-keys --armor       > "${SECRET_DIR}/gpg/${user}-secret-keys.asc" 2>/dev/null || true
    sudo -u "${user}"       GNUPGHOME="${homedir}/.gnupg" gpg       --batch --yes       --export --armor       > "${SECRET_DIR}/gpg/${user}-public-keys.asc" 2>/dev/null || true
    sudo -u "${user}"       GNUPGHOME="${homedir}/.gnupg" gpg       --batch --yes       --export-ownertrust       > "${SECRET_DIR}/gpg/${user}-ownertrust.txt" 2>/dev/null || true
  done < /etc/passwd
  index_secret "gpg/" "GPG secret + public keyrings and ownertrust for all users"
fi

# ── i2pd destination keys ────────────────────────────────────────────────────
if [[ -d /var/lib/i2pd ]]; then
  sec "i2pd/var-lib-i2pd" /var/lib/i2pd
  index_secret "i2pd/var-lib-i2pd" "i2pd full data dir including destination private keys"
fi

# ── Tor hidden service keys ──────────────────────────────────────────────────
if [[ -d /var/lib/tor ]]; then
  sec "tor/var-lib-tor" /var/lib/tor
  index_secret "tor/var-lib-tor" "Tor full data dir including hidden service private keys"
fi

# ── Nginx htpasswd files ─────────────────────────────────────────────────────
if ! $DRY_RUN; then
  mkdir -p "${SECRET_DIR}/nginx"
  find /etc/nginx -name "*.htpasswd" -o -name "htpasswd-*" -o -name ".htpasswd" \
    2>/dev/null \
    | while read -r f; do
        cp "$f" "${SECRET_DIR}/nginx/" 2>/dev/null || true
      done
  index_secret "nginx/" "nginx htpasswd files (bcrypt password hashes)"
fi

# ── User shell configs (may contain tokens/API keys) ────────────────────────
for user_home in /root /home/lukasz; do
  user="$(basename "$user_home")"
  [[ "$user" == "root" ]] && user="root"
  if ! $DRY_RUN; then
    mkdir -p "${SECRET_DIR}/shell/${user}"
    for f in .bashrc .zshrc .profile .bash_profile .zprofile \
              .netrc .ssh/config; do
      [[ -f "${user_home}/${f}" ]] \
        && cp "${user_home}/${f}" \
              "${SECRET_DIR}/shell/${user}/$(basename "$f")" 2>/dev/null || true
    done
  fi
  index_secret "shell/${user}" "Shell configs for ${user} (may contain tokens/API keys)"
done

# ── Lufi app config (contains app secret + DB path) ─────────────────────────
if [[ -f /srv/lufi/lufi.conf ]]; then
  sec "lufi/lufi.conf" /srv/lufi/lufi.conf
  index_secret "lufi/lufi.conf" "Lufi app config (secret key, DB path, domain)"
fi

# ── Grafana secrets ──────────────────────────────────────────────────────────
if [[ -f /etc/grafana/grafana.ini ]]; then
  sec "grafana/grafana.ini" /etc/grafana/grafana.ini
  index_secret "grafana/grafana.ini" "Grafana config (admin password, secret key)"
fi

# ── Alloy config (may contain remote write credentials) ─────────────────────
if [[ -d /etc/alloy ]]; then
  sec "alloy/etc-alloy" /etc/alloy
  index_secret "alloy/etc-alloy" "Grafana Alloy config (may contain remote write tokens)"
fi

# ── Borg backup passphrase / config ─────────────────────────────────────────
if [[ -d /etc/borg ]]; then
  sec "borg/etc-borg" /etc/borg
  index_secret "borg/etc-borg" "Borg backup config (repo paths, passphrase)"
fi
for f in /root/.config/borg/config /root/.borgmatic.yaml /etc/borgmatic.d; do
  if [[ -e "$f" ]]; then
    sec "borg/$(basename "$f")" "$f"
    index_secret "borg/$(basename "$f")" "Borgmatic config"
  fi
done

# ── User crontabs (may contain tokens in commands) ──────────────────────────
if [[ -d /var/spool/cron/crontabs ]]; then
  sec "cron/user-crontabs" /var/spool/cron/crontabs
  index_secret "cron/user-crontabs" "User crontabs (may contain API keys in commands)"
fi

# ── Prosody secrets (SSL certs + account data location) ─────────────────────
if [[ -d /etc/prosody ]]; then
  sec "prosody/etc-prosody" /etc/prosody
  index_secret "prosody/etc-prosody" "Full Prosody config including any embedded credentials"
fi

# ── LUKS header backup ───────────────────────────────────────────────────────
# Backing up the LUKS header is critical for recovery if the header gets corrupted
if ! $DRY_RUN && command -v cryptsetup &>/dev/null; then
  mkdir -p "${SECRET_DIR}/luks"
  # Find LUKS devices
  lsblk -o NAME,TYPE,FSTYPE -J 2>/dev/null \
    | jq -r '.blockdevices[] | .. | objects | select(.fstype=="crypto_LUKS") | .name' \
    2>/dev/null \
    | while read -r dev; do
        rm -f "${SECRET_DIR}/luks/${dev}-header.bin"
        cryptsetup luksHeaderBackup "/dev/${dev}" \
          --header-backup-file "${SECRET_DIR}/luks/${dev}-header.bin" \
          2>/dev/null \
          && log "LUKS header backup: /dev/${dev}" \
          || warn "could not backup LUKS header for /dev/${dev}"
      done
  index_secret "luks/" "LUKS header backups — critical for encrypted volume recovery"
fi

log "Secret staging complete"

# =========================================================================== #
#  ENCRYPT SECRET TIER
# =========================================================================== #

section "finalise secrets"

if ! $DRY_RUN; then
  # Lock down permissions — secret dir readable only by root
  chmod 700 "${SECRET_DIR}"
  find "${SECRET_DIR}" -type f -exec chmod 600 {} \;
  find "${SECRET_DIR}" -type d -exec chmod 700 {} \;
  log "Secret dir locked: chmod 700 ${SECRET_DIR}"

  log "Secret files written to ${SECRET_DIR}/"
else
  log "[dry] secret files would be written to ${SECRET_DIR}/ (chmod 700)"
  log "[dry] staging area would be wiped after encryption"
fi

# =========================================================================== #
#  WRITE .gitignore
# =========================================================================== #

if ! $DRY_RUN; then
  cat > "${CAPTURE_DIR}/.gitignore" << 'GITIGNORE'
# Secret tier — NEVER commit (contains private keys, credentials, LUKS headers)
db/secret/

# Exception: the index is safe to commit (shows what exists, not values)
!db/secret/secrets.index
GITIGNORE
fi

# =========================================================================== #
#  WRITE db/README.md
# =========================================================================== #

if ! $DRY_RUN; then
  OS_NAME="$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
  cat > "${CAPTURE_DIR}/db/README.md" << EOF
# sanctum — full state database

| | |
|---|---|
| **Host** | ${HOSTNAME_SHORT} |
| **OS** | ${OS_NAME} |
| **Kernel** | $(uname -r) |
| **Captured** | ${TIMESTAMP} |

## Structure

\`\`\`
db/
├── public/         Safe inventory — no secret values, git-trackable
└── secret/
    ├── <category>/     Secret files in plain subdirectories
    └── secrets.index   Index of what is inside (no values)
\`\`\`

## Decrypt secrets

\`\`\`bash
# List contents without extracting
  find /srv/sanctum-rebuild/db/secret -type f | sort

# Extract to a directory
mkdir /tmp/secrets-out
  sudo cat /srv/sanctum-rebuild/db/secret/wireguard/etc-wireguard/wg0.conf

# Wipe after use
find /tmp/secrets-out -type f -exec shred -u {} \\;
rm -rf /tmp/secrets-out
\`\`\`

## What is in the secret archive

See \`db/secret/secrets.index\` for a full list.

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
$(if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  for w in "${WARNINGS[@]}"; do echo "- ${w}"; done
else
  echo "None"
fi)
EOF
fi

# =========================================================================== #
#  DONE
# =========================================================================== #

echo ""
echo "╔══════════════════════════════════════════════════════╗"
if $DRY_RUN; then
  echo "║  dry run complete — nothing written                  ║"
else
  echo "║  capture-full complete ✓                             ║"
  echo "║                                                      ║"
  printf "║  public:  %-42s║\n" "${PUBLIC_DIR}"
  printf "║  secret:  %-42s║\n" "${SECRET_DIR}/"
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    printf "║  ⚠  %-47s║\n" "${#WARNINGS[@]} warning(s) — see db/README.md"
  fi
fi
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Next step: bootstrap.sh will read this database to"
echo "  reproduce this machine on a fresh Debian 13 install."
echo ""
