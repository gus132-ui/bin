#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

SCRIPT_NAME="restore-configs.sh"
CATEGORIES=()
LIST_CATEGORIES=false

usage() {
  cat <<USAGE
Usage: sudo ./restore-configs.sh [options]

Purpose:
  Restore selected configs from a capture DB in a controlled, category-based way.
  Intended to be non-fatal per item whenever possible. Sensitive/identity-heavy
  categories should be restored deliberately.

Options:
  --db-dir PATH
  --role lab|hardware|replacement
  --category NAME           May be used multiple times
  --list-categories
  --yes                     Non-interactive yes to prompts
  --dry-run
  --verbose
  --help

Categories:
  system-basics
  users
  ssh
  network
  dns
  firewall
  nginx
  mariadb
  postfix
  prosody
  tor
  i2pd
  docker
  monitoring
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-dir) DB_DIR="$2"; PUBLIC_DIR="${DB_DIR}/db/public"; SECRET_DIR="${DB_DIR}/db/secret"; shift ;;
    --role) ROLE="$2"; shift ;;
    --category) CATEGORIES+=("$2"); shift ;;
    --list-categories) LIST_CATEGORIES=true ;;
    --yes) ASSUME_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --verbose) VERBOSE=true ;;
    --help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

if [[ "${LIST_CATEGORIES}" == true ]]; then
  printf '%s\n' \
    system-basics \
    users \
    ssh \
    network \
    dns \
    firewall \
    nginx \
    mariadb \
    postfix \
    prosody \
    tor \
    i2pd \
    docker \
    monitoring
  exit 0
fi

ensure_root
load_optional_config
ensure_runtime_dirs
require_cmd cp chmod chown find grep sed awk systemctl

[[ -d "${PUBLIC_DIR}" ]] || die "public DB not found: ${PUBLIC_DIR}"
[[ ${#CATEGORIES[@]} -gt 0 ]] || die "no categories specified; use --category or --list-categories"

log "${SCRIPT_NAME}: role=${ROLE} categories=${CATEGORIES[*]} db=${DB_DIR}"
report "${SCRIPT_NAME}" "run" "start" "init" "ok" "role=${ROLE} categories=${CATEGORIES[*]}" ""

case "${ROLE}" in
  lab|hardware|replacement) ;;
  *) die "invalid role: ${ROLE}" ;;
esac

fix_sudoers_perms() {
  if [[ ${DRY_RUN} == true ]]; then
    printf '[dry] normalize sudoers ownership and permissions\n'
    return 0
  fi

  if [[ -f /etc/sudoers ]]; then
    chown root:root /etc/sudoers || true
    chmod 0440 /etc/sudoers || true
  fi

  if [[ -d /etc/sudoers.d ]]; then
    chown root:root /etc/sudoers.d || true
    chmod 0755 /etc/sudoers.d || true
    find /etc/sudoers.d -maxdepth 1 -type f -exec chown root:root {} \; || true
    find /etc/sudoers.d -maxdepth 1 -type f -exec chmod 0440 {} \; || true
  fi

  if visudo -c >/dev/null 2>&1; then
    report "${SCRIPT_NAME}" "users" "sudoers-perms" "fix" "changed" "sudoers ownership and permissions normalized" ""
    return 0
  fi

  note_failure "${SCRIPT_NAME}" "users" "sudoers-perms" "fix" "visudo validation failed after permission normalization"
  return 1
}

maybe_restore() {
  local category="$1" item="$2" src="$3" dst="$4"
  local prompt_text="Restore ${category}/${item} -> ${dst}?"

  if ! prompt_yes_no "${prompt_text}" yes; then
    report "${SCRIPT_NAME}" "${category}" "${item}" "restore" "skipped" "operator skipped" ""
    return 0
  fi

  restore_path "${SCRIPT_NAME}" "${category}" "${item}" "${src}" "${dst}" || true
}

category_enabled() {
  local want="$1" x
  for x in "${CATEGORIES[@]}"; do
    [[ "${x}" == "${want}" ]] && return 0
  done
  return 1
}

restore_system_basics() {
  local base="${PUBLIC_DIR}/system"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "system-basics" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'system-basics'?" yes; then
    report "${SCRIPT_NAME}" "system-basics" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  maybe_restore "system-basics" "etc-hostname"      "${base}/etc-hostname"      "/etc/hostname"
  maybe_restore "system-basics" "etc-hosts"         "${base}/etc-hosts"         "/etc/hosts"
  maybe_restore "system-basics" "etc-environment"   "${base}/etc-environment"   "/etc/environment"
  maybe_restore "system-basics" "locale.gen"        "${base}/locale.gen"        "/etc/locale.gen"
  maybe_restore "system-basics" "timezone"          "${base}/timezone"          "/etc/timezone"

  if [[ -f "${base}/etc-hostname" ]]; then
    local captured_hostname
    captured_hostname="$(head -n1 "${base}/etc-hostname" 2>/dev/null || true)"
    if [[ -n "${captured_hostname}" ]]; then
      if prompt_yes_no "Apply captured hostname now?" yes; then
        if [[ ${DRY_RUN} == true ]]; then
          printf '[dry] hostnamectl set-hostname %s\n' "${captured_hostname}"
        else
          hostnamectl set-hostname "${captured_hostname}" || note_failure "${SCRIPT_NAME}" "system-basics" "hostnamectl" "set" "hostnamectl failed"
        fi
        report "${SCRIPT_NAME}" "system-basics" "hostnamectl" "set" "changed" "${captured_hostname}" ""
      else
        report "${SCRIPT_NAME}" "system-basics" "hostnamectl" "set" "skipped" "operator skipped hostnamectl" ""
      fi
    fi
  fi
}

restore_users() {
  local base="${PUBLIC_DIR}/users"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "users" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'users'?" yes; then
    report "${SCRIPT_NAME}" "users" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  maybe_restore "users" "sudoers"    "${base}/sudoers"    "/etc/sudoers"
  maybe_restore "users" "sudoers.d"  "${base}/sudoers.d"  "/etc/sudoers.d"
  fix_sudoers_perms || true
  maybe_restore "users" "shells"     "${base}/shells"     "/etc/shells"
  maybe_restore "users" "login.defs" "${base}/login.defs" "/etc/login.defs"
}

restore_ssh() {
  local pub_users="${PUBLIC_DIR}/users"
  local sec_ssh="${SECRET_DIR}/ssh"

  if ! prompt_yes_no "Restore category 'ssh'?" yes; then
    report "${SCRIPT_NAME}" "ssh" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if prompt_yes_no "Restore ssh/sshd_config -> /etc/ssh/sshd_config?" yes; then
    restore_path "${SCRIPT_NAME}" "ssh" "sshd_config" \
      "${pub_users}/sshd_config" "/etc/ssh/sshd_config" \
      0644 root root || true
  else
    report "${SCRIPT_NAME}" "ssh" "sshd_config" "restore" "skipped" "operator skipped" ""
  fi

  if prompt_yes_no "Restore ssh/sshd_config.d -> /etc/ssh/sshd_config.d?" yes; then
    restore_path "${SCRIPT_NAME}" "ssh" "sshd_config.d" \
      "${pub_users}/sshd_config.d" "/etc/ssh/sshd_config.d" || true

    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] chown -R root:root /etc/ssh/sshd_config.d\n'
      printf '[dry] find /etc/ssh/sshd_config.d -type d -exec chmod 0755 {} +\n'
      printf '[dry] find /etc/ssh/sshd_config.d -type f -exec chmod 0644 {} +\n'
    else
      if [[ -d /etc/ssh/sshd_config.d ]]; then
        chown -R root:root /etc/ssh/sshd_config.d 2>/dev/null || true
        find /etc/ssh/sshd_config.d -type d -exec chmod 0755 {} + 2>/dev/null || true
        find /etc/ssh/sshd_config.d -type f -exec chmod 0644 {} + 2>/dev/null || true
      fi
    fi

    report "${SCRIPT_NAME}" "ssh" "sshd_config.d-metadata" "restore" "changed" \
      "normalized /etc/ssh/sshd_config.d ownership=root:root dirs=0755 files=0644" ""
  else
    report "${SCRIPT_NAME}" "ssh" "sshd_config.d" "restore" "skipped" "operator skipped" ""
  fi

  if [[ "${ROLE}" == "replacement" || "${ROLE}" == "hardware" ]]; then
    if [[ -d "${sec_ssh}/etc-ssh" ]]; then
      if prompt_yes_no "Restore SSH host keys from secret DB?" no; then
        restore_path "${SCRIPT_NAME}" "ssh" "host-keys" \
          "${sec_ssh}/etc-ssh" "/etc/ssh" || true

        if [[ ${DRY_RUN} == true ]]; then
          printf '[dry] chown root:root /etc/ssh\n'
          printf '[dry] chmod 0755 /etc/ssh\n'
          printf '[dry] find /etc/ssh -maxdepth 1 -type f -name '\''ssh_host_*_key'\'' -exec chown root:root {} +\n'
          printf '[dry] find /etc/ssh -maxdepth 1 -type f -name '\''ssh_host_*_key'\'' -exec chmod 0600 {} +\n'
          printf '[dry] find /etc/ssh -maxdepth 1 -type f -name '\''ssh_host_*_key.pub'\'' -exec chown root:root {} +\n'
          printf '[dry] find /etc/ssh -maxdepth 1 -type f -name '\''ssh_host_*_key.pub'\'' -exec chmod 0644 {} +\n'
        else
          chown root:root /etc/ssh 2>/dev/null || true
          chmod 0755 /etc/ssh 2>/dev/null || true
          find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key' -exec chown root:root {} + 2>/dev/null || true
          find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key' -exec chmod 0600 {} + 2>/dev/null || true
          find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key.pub' -exec chown root:root {} + 2>/dev/null || true
          find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key.pub' -exec chmod 0644 {} + 2>/dev/null || true
        fi

        report "${SCRIPT_NAME}" "ssh" "host-keys-metadata" "restore" "changed" \
          "normalized SSH host key ownership=root:root private=0600 public=0644" ""
      else
        report "${SCRIPT_NAME}" "ssh" "host-keys" "restore" "skipped" "operator skipped host keys" ""
      fi
    fi
  else
    report "${SCRIPT_NAME}" "ssh" "host-keys" "restore" "skipped" "lab role: host keys not restored" ""
  fi

  if [[ -d "${sec_ssh}/user-lukasz" ]]; then
    if prompt_yes_no "Restore lukasz user SSH material from secret DB?" no; then
      restore_path "${SCRIPT_NAME}" "ssh" "user-lukasz" \
        "${sec_ssh}/user-lukasz" "/home/lukasz/.ssh" || true

      if [[ ${DRY_RUN} == true ]]; then
        printf '[dry] chown -R lukasz:lukasz /home/lukasz/.ssh\n'
        printf '[dry] chmod 700 /home/lukasz/.ssh\n'
        printf '[dry] find /home/lukasz/.ssh -maxdepth 1 -type f -exec chmod 600 {} +\n'
      else
        chown -R lukasz:lukasz /home/lukasz/.ssh 2>/dev/null || true
        chmod 700 /home/lukasz/.ssh 2>/dev/null || true
        find /home/lukasz/.ssh -maxdepth 1 -type f -exec chmod 600 {} + 2>/dev/null || true
      fi

      report "${SCRIPT_NAME}" "ssh" "user-lukasz-metadata" "restore" "changed" \
        "normalized /home/lukasz/.ssh ownership=lukasz:lukasz dir=0700 files=0600" ""
    else
      report "${SCRIPT_NAME}" "ssh" "user-lukasz" "restore" "skipped" "operator skipped user ssh material" ""
    fi
  fi

  if have_cmd sshd; then
    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] sshd -t\n'
      report "${SCRIPT_NAME}" "ssh" "validate" "check" "ok" "dry-run only" ""
    else
      if sshd -t; then
        report "${SCRIPT_NAME}" "ssh" "validate" "check" "ok" "sshd config validates" ""
        systemctl restart ssh >/dev/null 2>&1 || true
      else
        note_failure "${SCRIPT_NAME}" "ssh" "validate" "check" "sshd validation failed"
      fi
    fi
  fi
}

restore_network() {
  local base="${PUBLIC_DIR}/network"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "network" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'network'? This can disrupt connectivity." no; then
    report "${SCRIPT_NAME}" "network" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if [[ "${ROLE}" == "lab" ]]; then
    manual_line="lab role: full network restore intentionally skipped"
    report "${SCRIPT_NAME}" "network" "category" "manual" "manual" "${manual_line}" ""
    return 0
  fi

  maybe_restore "network" "etc-network"      "${base}/etc-network"      "/etc/network"
  maybe_restore "network" "etc-netplan"      "${base}/etc-netplan"      "/etc/netplan"
  maybe_restore "network" "systemd-network"  "${base}/systemd-network"  "/etc/systemd/network"
  maybe_restore "network" "nsswitch.conf"    "${base}/nsswitch.conf"    "/etc/nsswitch.conf"

  # Postfix maintains a chroot copy of nsswitch.conf — refresh it after restore
  if ! $DRY_RUN && have_cmd postfix; then
    postfix set-permissions 2>/dev/null || true
    report "${SCRIPT_NAME}" "network" "postfix-chroot-sync" "fix" "ok" "postfix chroot permissions refreshed" ""
  fi
  maybe_restore "network" "hosts.allow"      "${base}/hosts.allow"      "/etc/hosts.allow"
  maybe_restore "network" "hosts.deny"       "${base}/hosts.deny"       "/etc/hosts.deny"
}

# =============================================================================
# restore_dns() — smart, adaptive DNS category restore
# =============================================================================
#
# DROP-IN REPLACEMENT for the naive restore_dns() in restore-configs.sh.
# Replace lines 326-344 with this entire block.
#
# What this does that the old version did not:
#
#   1. SCAN   — detects live interfaces, IPs, WireGuard ifaces, Docker bridges,
#               who currently owns port 53
#   2. ANALYZE — classifies each captured dnsmasq.conf and dnsmasq.d/* file:
#               safe | adapted | dormant-wireguard | dormant-docker | manual
#   3. ADAPT  — rewrites listen-address/server lines to only use IPs that
#               exist on this machine right now
#   4. PREPARE — bootstraps unbound root.key if missing
#               disables systemd-resolved stub if it would conflict
#   5. START  — enables + starts unbound then dnsmasq in correct order
#               verifies each is listening before proceeding
#   6. VERIFY — confirms deb.debian.org resolves
#               only then writes /etc/resolv.conf
#   7. REPORT — prints a precise summary with ✓/⚠/✗ and a MANUAL TASKS list
#
# Roles:
#   lab         — skipped (architecture mismatch too severe for lab)
#   hardware    — full adaptive restore, services started
#   replacement — full adaptive restore, services started
#
# =============================================================================

# ── Internal helpers ──────────────────────────────────────────────────────────

# Print a DNS-category-specific status line (not using global report() for
# the inline summary — those go to TSV separately)
_dns_ok()     { printf '  \033[32m✓\033[0m adapted    %s\n' "$*"; }
_dns_dormant(){ printf '  \033[33m⚠\033[0m dormant    %s\n' "$*"; }
_dns_manual() { printf '  \033[31m✗\033[0m MANUAL     %s\n' "$*"; }
_dns_info()   { printf '  \033[36m·\033[0m            %s\n' "$*"; }

# Collect all IPs currently assigned to any interface on this machine
_live_ips() {
  ip -o addr show 2>/dev/null \
    | awk '{print $4}' \
    | sed 's|/.*||' \
    | sort -u
}

# Collect WireGuard interface names currently present
_wg_ifaces() {
  ip link show type wireguard 2>/dev/null \
    | awk -F': ' '/^[0-9]+:/{print $2}' \
    | awk '{print $1}' \
    | sort -u
}

# Collect Docker bridge IPs (172.x.x.1 pattern on br-* or docker0)
_docker_bridge_ips() {
  ip -o addr show 2>/dev/null \
    | awk '/br-|docker0/{print $4}' \
    | sed 's|/.*||' \
    | sort -u
}

# Who owns port 53 right now?
_port53_owner() {
  local line
  line="$(ss -tlnp 2>/dev/null | grep ':53 ' | head -1)"
  if   echo "$line" | grep -q dnsmasq;  then echo "dnsmasq"
  elif echo "$line" | grep -q unbound;  then echo "unbound"
  elif echo "$line" | grep -q systemd;  then echo "resolved"
  elif [[ -z "$line" ]];                then echo "none"
  else                                       echo "unknown"
  fi
}

# Is an IP a WireGuard-range IP? (10.50.x.x by default on sanctum)
# Also checks if it matches any IP on a wg interface
_is_wg_ip() {
  local ip="$1"
  # Check against known wg interface IPs
  local wg_ips
  wg_ips="$(ip -o addr show type wireguard 2>/dev/null | awk '{print $4}' | sed 's|/.*||')"
  echo "$wg_ips" | grep -qx "$ip" && return 0
  # Heuristic: 10.50.x.x is sanctum's WireGuard subnet
  [[ "$ip" =~ ^10\.50\. ]] && return 0
  return 1
}

# Is an IP a Docker bridge IP?
_is_docker_ip() {
  local ip="$1"
  _docker_bridge_ips | grep -qx "$ip" && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
  return 1
}

# Is an IP live on this machine right now?
_ip_is_live() {
  _live_ips | grep -qx "$1"
}

# Is an IP in a private LAN range (RFC1918) that is just not live on this machine?
# These are likely the source host's LAN IPs — dormant on fresh hardware, not truly foreign.
_is_lan_ip() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]]          && return 0
  [[ "$ip" =~ ^192\.168\. ]]    && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
  return 1
}

# Classify a single IP from a dnsmasq config perspective
# Returns: live | wg | docker | lan | foreign
_classify_ip() {
  local ip="$1"
  [[ "$ip" == "127.0.0.1" || "$ip" == "::1" ]] && { echo "live"; return; }
  _ip_is_live "$ip"   && { echo "live";    return; }
  _is_wg_ip   "$ip"   && { echo "wg";      return; }
  _is_docker_ip "$ip" && { echo "docker";  return; }
  _is_lan_ip  "$ip"   && { echo "lan";     return; }
  echo "foreign"
}

# Rewrite a dnsmasq config file, adapting listen-address and server= lines.
# Writes adapted file to $dst. Returns classification of the file overall.
# Prints per-line notes to stdout.
_adapt_dnsmasq_file() {
  local src="$1" dst="$2" fname="$3"
  local line classification="safe"
  local has_wg=false has_docker=false has_foreign=false has_live=false
  local dropped_lan=()
  local has_lan_dropped=false

  local tmp
  tmp="$(mktemp)"

  while IFS= read -r line; do
    # ── listen-address = a,b,c ──────────────────────────────────────────────
    if [[ "$line" =~ ^[[:space:]]*listen-address= ]]; then
      local addr_str="${line#*=}"
      local new_addrs=() dropped_wg=() dropped_docker=() dropped_foreign=()

      IFS=',' read -ra addrs <<< "$addr_str"
      for addr in "${addrs[@]}"; do
        addr="${addr// /}"
        local cls
        cls="$(_classify_ip "$addr")"
        case "$cls" in
          live)    new_addrs+=("$addr"); has_live=true ;;
          wg)      dropped_wg+=("$addr"); has_wg=true ;;
          docker)  dropped_docker+=("$addr"); has_docker=true ;;
          lan)     dropped_lan+=("$addr"); has_lan_dropped=true ;;
          foreign) dropped_foreign+=("$addr"); has_foreign=true ;;
        esac
      done

      if [[ ${#new_addrs[@]} -gt 0 ]]; then
        printf 'listen-address=%s\n' "$(IFS=','; echo "${new_addrs[*]}")" >> "$tmp"
      else
        # No live addresses left — bind to loopback only as safe fallback
        printf 'listen-address=127.0.0.1\n' >> "$tmp"
        _dns_info "$fname: all listen-address IPs non-local — fell back to 127.0.0.1"
      fi

      [[ ${#dropped_wg[@]} -gt 0 ]]      && classification="dormant-wg"
      [[ ${#dropped_docker[@]} -gt 0 ]]  && [[ "$classification" == "safe" ]] && classification="dormant-docker"
      [[ ${#dropped_foreign[@]} -gt 0 ]] && classification="foreign"
      continue
    fi

    # ── interface= lines referencing named interfaces ───────────────────────
    if [[ "$line" =~ ^[[:space:]]*interface= ]]; then
      local iface_name="${line#*=}"
      iface_name="${iface_name// /}"
      if ip link show "$iface_name" >/dev/null 2>&1; then
        printf '%s\n' "$line" >> "$tmp"
      else
        printf '# [adapted] interface=%s not present — uncomment when interface exists\n' \
          "$iface_name" >> "$tmp"
        if [[ "$iface_name" =~ ^wg ]]; then
          has_wg=true
        elif [[ "$iface_name" =~ ^br-|^docker ]]; then
          has_docker=true
        else
          has_foreign=true
        fi
      fi
      continue
    fi

    # ── server= lines pointing at specific IPs ──────────────────────────────
    if [[ "$line" =~ ^[[:space:]]*server= ]]; then
      local server_val="${line#*=}"
      # Extract just the IP part (before any #port or @iface)
      local server_ip
      server_ip="$(echo "$server_val" | sed 's|[#@].*||' | tr -d '/')"
      if [[ -n "$server_ip" && "$server_ip" != "127.0.0.1" && "$server_ip" != "::1" ]]; then
        local cls
        cls="$(_classify_ip "$server_ip")"
        case "$cls" in
          wg)     has_wg=true ;;
          docker) has_docker=true ;;
          foreign) has_foreign=true ;;
        esac
      fi
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi

    # All other lines pass through unchanged
    printf '%s\n' "$line" >> "$tmp"
  done < "$src"

  # Final classification
  # Note: "lan" IPs (RFC1918 not live on this machine) are treated as
  # dormant-hardware — they belong to the source host's LAN and will be
  # valid on real replacement hardware. They do NOT trigger "foreign".
  if $has_foreign; then
    classification="foreign"
  elif $has_wg; then
    classification="dormant-wg"
  elif $has_docker; then
    classification="dormant-docker"
  fi
  # If only lan IPs were dropped (no wg/docker/foreign), mark dormant-hardware
  if [[ "$classification" == "safe" && ${#dropped_lan[@]} -gt 0 ]]; then
    classification="dormant-hardware"
  fi

  mv "$tmp" "$dst"
  echo "$classification"
}

# ── Main restore_dns() ────────────────────────────────────────────────────────

restore_dns() {
  local base="${PUBLIC_DIR}/dns"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "dns" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'dns'? This will adapt and apply the captured DNS stack." no; then
    report "${SCRIPT_NAME}" "dns" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  # lab: architecture too machine-specific, skip
  if [[ "${ROLE}" == "lab" ]]; then
    report "${SCRIPT_NAME}" "dns" "category" "manual" "manual" \
      "lab role: DNS restore intentionally skipped — run with --role hardware to test" ""
    return 0
  fi

  # ── MANUAL TASKS accumulator ────────────────────────────────────────────────
  local manual_tasks=()

  # ── PHASE 1: SCAN ──────────────────────────────────────────────────────────
  log "dns: scanning local topology..."

  local live_ips wg_ifaces docker_ips port53_owner
  live_ips="$(_live_ips | tr '\n' ' ')"
  wg_ifaces="$(_wg_ifaces | tr '\n' ' ')"
  docker_ips="$(_docker_bridge_ips | tr '\n' ' ')"
  port53_owner="$(_port53_owner)"

  log "dns: live IPs: ${live_ips:-none}"
  log "dns: WireGuard ifaces: ${wg_ifaces:-none}"
  log "dns: Docker bridge IPs: ${docker_ips:-none}"
  log "dns: port 53 currently owned by: ${port53_owner}"

  report "${SCRIPT_NAME}" "dns" "topology-scan" "scan" "ok" \
    "live_ips=${live_ips} wg=${wg_ifaces:-none} docker=${docker_ips:-none} port53=${port53_owner}" ""

  # ── PHASE 2: DISABLE SYSTEMD-RESOLVED STUB if it owns port 53 ──────────────
  # systemd-resolved's stub listener on 127.0.0.53 conflicts with dnsmasq
  # wanting to own 127.0.0.1:53. The correct fix for sanctum's architecture
  # is to disable the stub and let dnsmasq own the port.
  if [[ "$port53_owner" == "resolved" ]]; then
    log "dns: systemd-resolved stub owns port 53 — disabling stub listener..."
    if $DRY_RUN; then
      printf '[dry] mkdir -p /etc/systemd/resolved.conf.d\n'
      printf '[dry] write DNSStubListener=no to /etc/systemd/resolved.conf.d/no-stub.conf\n'
      printf '[dry] systemctl restart systemd-resolved\n'
    else
      mkdir -p /etc/systemd/resolved.conf.d
      printf '[Resolve]\nDNSStubListener=no\n' \
        > /etc/systemd/resolved.conf.d/no-stub.conf
      systemctl restart systemd-resolved >/dev/null 2>&1 || true
      sleep 1
      port53_owner="$(_port53_owner)"
      log "dns: port 53 owner after stub disable: ${port53_owner}"
    fi
    report "${SCRIPT_NAME}" "dns" "resolved-stub" "adapt" "changed" \
      "disabled systemd-resolved DNSStubListener to free port 53 for dnsmasq" ""
  fi

  # ── PHASE 3: ADAPT AND RESTORE DNSMASQ.CONF ────────────────────────────────
  if [[ -f "${base}/dnsmasq.conf" ]]; then
    log "dns: adapting dnsmasq.conf..."
    local adapted_conf
    adapted_conf="$(mktemp)"

    if $DRY_RUN; then
      printf '[dry] adapt dnsmasq.conf → /etc/dnsmasq.conf\n'
      report "${SCRIPT_NAME}" "dns" "dnsmasq.conf" "restore" "ok" "dry-run only" ""
    else
      local cls
      cls="$(_adapt_dnsmasq_file "${base}/dnsmasq.conf" "$adapted_conf" "dnsmasq.conf")"
      cp "$adapted_conf" /etc/dnsmasq.conf
      rm -f "$adapted_conf"
      chown root:root /etc/dnsmasq.conf
      chmod 0644 /etc/dnsmasq.conf

      case "$cls" in
        safe)
          _dns_ok "dnsmasq.conf (no adaptation needed)"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.conf" "restore" "changed" "restored unchanged" "" ;;
        dormant-wg)
          _dns_ok "dnsmasq.conf (adapted — WireGuard IPs dormant until wg0 exists)"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.conf" "restore" "changed" "adapted: WireGuard IPs stripped from listen-address" ""
          manual_tasks+=("WireGuard IPs in dnsmasq.conf will activate automatically once wg0 is up") ;;
        dormant-docker)
          _dns_ok "dnsmasq.conf (adapted — Docker bridge IPs dormant until Docker is up)"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.conf" "restore" "changed" "adapted: Docker IPs stripped from listen-address" ""
          manual_tasks+=("Docker bridge IPs in dnsmasq.conf will activate automatically once Docker is up") ;;
        dormant-hardware)
          _dns_ok "dnsmasq.conf (adapted — source-host LAN IPs stripped, will need real NIC IP)"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.conf" "restore" "changed" "adapted: source LAN IPs stripped" ""
          manual_tasks+=("dnsmasq.conf: add this machine's LAN IP to listen-address once NIC is configured") ;;
        foreign)
          _dns_dormant "dnsmasq.conf (contains unrecognized IPs — adapted to 127.0.0.1 only)"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.conf" "restore" "changed" "adapted: foreign IPs stripped" ""
          manual_tasks+=("dnsmasq.conf had unrecognized IPs — verify listen-address in /etc/dnsmasq.conf") ;;
      esac
    fi
  else
    mark_manual "${SCRIPT_NAME}" "dns" "dnsmasq.conf" "not found in DB"
  fi

  # ── PHASE 4: ADAPT AND RESTORE DNSMASQ.D/* ─────────────────────────────────
  if [[ -d "${base}/dnsmasq.d" ]]; then
    log "dns: adapting dnsmasq.d/..."
    local dest_d="/etc/dnsmasq.d"
    mkdir -p "$dest_d"

    for src_file in "${base}/dnsmasq.d"/*; do
      [[ -f "$src_file" ]] || continue
      local fname
      fname="$(basename "$src_file")"
      local dst_file="${dest_d}/${fname}"
      local adapted_f
      adapted_f="$(mktemp)"

      if $DRY_RUN; then
        printf '[dry] adapt dnsmasq.d/%s → %s\n' "$fname" "$dst_file"
        rm -f "$adapted_f"
        continue
      fi

      local cls
      cls="$(_adapt_dnsmasq_file "$src_file" "$adapted_f" "dnsmasq.d/${fname}")"
      cp "$adapted_f" "$dst_file"
      rm -f "$adapted_f"
      chown root:root "$dst_file"
      chmod 0644 "$dst_file"

      case "$cls" in
        safe)
          _dns_ok "dnsmasq.d/${fname}"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.d/${fname}" "restore" "changed" "restored unchanged" "" ;;
        dormant-wg)
          _dns_dormant "dnsmasq.d/${fname} (WireGuard-dependent — dormant until wg0 exists)"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.d/${fname}" "restore" "changed" "adapted: WireGuard IPs dormant" ""
          manual_tasks+=("dnsmasq.d/${fname}: WireGuard-dependent rules preserved, activate when wg0 is up") ;;
        dormant-docker)
          _dns_dormant "dnsmasq.d/${fname} (Docker-dependent — dormant until Docker bridges exist)"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.d/${fname}" "restore" "changed" "adapted: Docker IPs dormant" ""
          manual_tasks+=("dnsmasq.d/${fname}: Docker-dependent rules preserved, activate when Docker is up") ;;
        dormant-hardware)
          _dns_ok "dnsmasq.d/${fname} (adapted — source-host LAN IPs stripped)"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.d/${fname}" "restore" "changed" "adapted: source LAN IPs stripped" ""
          manual_tasks+=("dnsmasq.d/${fname}: add this machine LAN IP to listen-address once NIC is configured") ;;
        foreign)
          _dns_manual "dnsmasq.d/${fname} (contains truly unrecognized IPs — copied but needs review)"
          report "${SCRIPT_NAME}" "dns" "dnsmasq.d/${fname}" "restore" "changed" "adapted: foreign IPs stripped — review needed" ""
          manual_tasks+=("REVIEW: dnsmasq.d/${fname} had unrecognized IPs — verify manually") ;;
      esac
    done

    report "${SCRIPT_NAME}" "dns" "dnsmasq.d" "restore" "changed" "all files adapted and copied" ""
  fi

  # ── PHASE 5: RESTORE UNBOUND ────────────────────────────────────────────────
  if [[ -d "${base}/etc-unbound" ]]; then
    log "dns: restoring unbound config..."
    if $DRY_RUN; then
      printf '[dry] restore etc-unbound → /etc/unbound\n'
    else
      restore_path "${SCRIPT_NAME}" "dns" "etc-unbound" \
        "${base}/etc-unbound" "/etc/unbound" || true
      chown -R root:root /etc/unbound 2>/dev/null || true
      find /etc/unbound -type d -exec chmod 0755 {} + 2>/dev/null || true
      find /etc/unbound -type f -exec chmod 0644 {} + 2>/dev/null || true
    fi
    report "${SCRIPT_NAME}" "dns" "etc-unbound" "restore" "changed" "unbound config restored and permissions normalized" ""
  fi

  # ── PHASE 6: BOOTSTRAP UNBOUND DATA FILES ───────────────────────────────────
  # On Debian 13:
  #   - trust anchor managed by /usr/libexec/unbound-helper root_trust_anchor_update
  #     (ExecStartPre in unbound.service) — no manual unbound-anchor needed
  #   - root.hints must exist at /var/lib/unbound/root.hints if referenced by config
  #     NOT provided by the package — must be fetched from internic.net
  log "dns: preparing unbound data files..."
  if $DRY_RUN; then
    printf '[dry] mkdir -p /var/lib/unbound\n'
    printf '[dry] fetch root.hints if referenced by config and missing\n'
    printf '[dry] chown -R unbound:unbound /var/lib/unbound\n'
  else
    mkdir -p /var/lib/unbound

    # root.hints will be fetched after DNS is confirmed working
    # (fetch requires working DNS — moved to post-verification phase)
    local needs_root_hints=false
    grep -rq 'root-hints' /etc/unbound/ 2>/dev/null && needs_root_hints=true
    if [[ -f /var/lib/unbound/root.hints ]]; then
      _dns_ok "root.hints already present"
    elif $needs_root_hints; then
      _dns_info "root.hints needed — will fetch after DNS is confirmed working"
    fi

    # Detect unbound port from restored config (default 5353 for sanctum)
    local unbound_port=5353
    if [[ -f /etc/unbound/unbound.conf.d/recursive.conf ]]; then
      local cfg_port
      cfg_port="$(grep -h '^ *port:' /etc/unbound/unbound.conf.d/recursive.conf 2>/dev/null | awk '{print $2}' | tail -1)"
      [[ -n "$cfg_port" ]] && unbound_port="$cfg_port"
    fi

    # If recursive.conf specifies validator module, it needs a valid trust anchor.
    # On fresh installs without unbound-anchor, disable validator and force correct port.
    # This gets unbound running; DNSSEC can be re-enabled after the system is stable.
    local validator_in_use=false
    grep -rq 'module-config.*validator' /etc/unbound/ 2>/dev/null && validator_in_use=true

    if $validator_in_use; then
      log "dns: validator module detected — creating no-dnssec override for bootstrap"
      cat > /etc/unbound/unbound.conf.d/no-dnssec.conf << EOF
server:
    module-config: "iterator"
    port: ${unbound_port}
EOF
      # Disable recursive.conf temporarily — it overrides module-config and port
      if [[ -f /etc/unbound/unbound.conf.d/recursive.conf ]]; then
        mv /etc/unbound/unbound.conf.d/recursive.conf            /etc/unbound/unbound.conf.d/recursive.conf.bootstrap-disabled
        _dns_dormant "recursive.conf disabled for bootstrap (re-enable after system is stable)"
        manual_tasks+=("DNSSEC: re-enable DNSSEC after system stable: mv /etc/unbound/unbound.conf.d/recursive.conf.bootstrap-disabled /etc/unbound/unbound.conf.d/recursive.conf && rm /etc/unbound/unbound.conf.d/no-dnssec.conf && systemctl restart unbound")
      fi
      report "${SCRIPT_NAME}" "dns" "unbound-dnssec" "adapt" "changed"         "validator disabled for bootstrap; re-enable after trust anchor is populated" ""
    fi

    # Ensure unbound owns its data directory
    chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true
    chmod 755 /var/lib/unbound 2>/dev/null || true

    # Trust anchor: on Debian 13, root.key is seeded from /usr/share/dns/root.key
    # which is provided by the dns-root-data package. Install it and run the helper.
    if [[ ! -f /usr/share/dns/root.key ]]; then
      log "dns: installing dns-root-data for unbound trust anchor..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y dns-root-data >/dev/null 2>&1 \
        && _dns_ok "dns-root-data installed" \
        || { _dns_manual "dns-root-data install failed — install manually: apt install dns-root-data"; \
             manual_tasks+=("MANUAL: apt install dns-root-data then systemctl restart unbound"); }
    fi
    if [[ -f /usr/share/dns/root.key ]]; then
      rm -f /var/lib/unbound/root.key
      /usr/libexec/unbound-helper root_trust_anchor_update 2>/dev/null || true
      if [[ -f /var/lib/unbound/root.key ]]; then
        chown unbound:unbound /var/lib/unbound/root.key 2>/dev/null || true
        _dns_ok "trust anchor seeded from dns-root-data via unbound-helper"
        report "${SCRIPT_NAME}" "dns" "unbound-trustanchor" "prepare" "changed" "seeded from dns-root-data" ""
      else
        _dns_manual "unbound-helper ran but root.key not created"
        manual_tasks+=("MANUAL: sudo rm /var/lib/unbound/root.key && sudo /usr/libexec/unbound-helper root_trust_anchor_update")
      fi
    else
      _dns_manual "dns-root-data not available — unbound DNSSEC will not work"
      manual_tasks+=("MANUAL: apt install dns-root-data then restart unbound")
    fi
  fi

  # Check for blocklist files referenced in unbound config
  if ! $DRY_RUN; then
    local rpz_refs
    rpz_refs="$(grep -rh 'rpz-file\|include:\|zonefile' /etc/unbound/ 2>/dev/null \
      | grep -v '^#' \
      | grep -oP '"[^"]*\.rpz[^"]*"|/[^ ]+\.rpz[^ ]*' \
      | tr -d '"' \
      | sort -u || true)"
    if [[ -n "$rpz_refs" ]]; then
      while IFS= read -r rpz_file; do
        if [[ ! -f "$rpz_file" ]]; then
          _dns_dormant "unbound references ${rpz_file} which does not exist yet"
          manual_tasks+=("POPULATE: ${rpz_file} referenced by unbound config but not yet present")
        fi
      done <<< "$rpz_refs"
    fi
  fi

  # ── PHASE 7: START UNBOUND ──────────────────────────────────────────────────
  log "dns: starting unbound..."
  if $DRY_RUN; then
    printf '[dry] systemctl enable --now unbound\n'
  else
    systemctl enable unbound >/dev/null 2>&1 || true
    systemctl restart unbound >/dev/null 2>&1 || true
    sleep 2

    # Verify unbound is listening on expected port
    local unbound_port=5353
    # Detect port from config if non-standard
    if [[ -f /etc/unbound/unbound.conf ]]; then
      local cfg_port
      cfg_port="$(grep -h 'port:' /etc/unbound/unbound.conf.d/*.conf /etc/unbound/unbound.conf 2>/dev/null \
        | grep -v '^#' | awk '{print $2}' | tail -1)"
      [[ -n "$cfg_port" ]] && unbound_port="$cfg_port"
    fi

    if ss -tlnp 2>/dev/null | grep -q ":${unbound_port} "; then
      _dns_ok "unbound listening on port ${unbound_port}"
      report "${SCRIPT_NAME}" "dns" "unbound-start" "start" "ok" "listening on :${unbound_port}" ""
    else
      local unbound_err
      unbound_err="$(journalctl -u unbound -n 5 --no-pager 2>/dev/null | tail -3 || true)"
      _dns_manual "unbound NOT listening on port ${unbound_port}"
      log "dns: unbound journal tail: ${unbound_err}"
      report "${SCRIPT_NAME}" "dns" "unbound-start" "start" "failed" "not listening on :${unbound_port}" ""
      manual_tasks+=("MANUAL: unbound failed to start — check: journalctl -u unbound -n 20")
    fi
  fi

  # ── PHASE 8: START DNSMASQ ──────────────────────────────────────────────────
  log "dns: starting dnsmasq..."
  if $DRY_RUN; then
    printf '[dry] systemctl enable --now dnsmasq\n'
  else
    # Give unbound a moment to fully come up before dnsmasq tries to reach it
    # dnsmasq validates its upstream server= at startup — if unbound is not
    # yet listening on 5353, dnsmasq exits with INVALIDARGUMENT
    sleep 3
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    systemctl restart dnsmasq >/dev/null 2>&1 || true
    sleep 2

    if ss -tlnp 2>/dev/null | grep -q ':53 '; then
      local new_owner
      new_owner="$(_port53_owner)"
      _dns_ok "port 53 now owned by: ${new_owner}"
      report "${SCRIPT_NAME}" "dns" "dnsmasq-start" "start" "ok" "listening on :53 owner=${new_owner}" ""
    else
      local dnsmasq_err
      dnsmasq_err="$(journalctl -u dnsmasq -n 5 --no-pager 2>/dev/null | tail -3 || true)"
      _dns_manual "dnsmasq NOT listening on port 53"
      log "dns: dnsmasq journal tail: ${dnsmasq_err}"
      report "${SCRIPT_NAME}" "dns" "dnsmasq-start" "start" "failed" "not listening on :53" ""
      manual_tasks+=("MANUAL: dnsmasq failed to start — check: journalctl -u dnsmasq -n 20")
      manual_tasks+=("       likely cause: port 53 still held by another process (ss -tlnp | grep :53)")
    fi
  fi

  # ── PHASE 9: VERIFY RESOLUTION ─────────────────────────────────────────────
  local resolution_ok=false
  if ! $DRY_RUN; then
    log "dns: verifying resolution..."
    sleep 1
    if getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
      _dns_ok "deb.debian.org resolves ✓"
      resolution_ok=true
      report "${SCRIPT_NAME}" "dns" "verify-resolution" "check" "ok" "deb.debian.org resolves" ""
    else
      _dns_manual "resolution FAILED for deb.debian.org"
      report "${SCRIPT_NAME}" "dns" "verify-resolution" "check" "failed" "deb.debian.org did not resolve" ""
      manual_tasks+=("MANUAL: DNS resolution failed — run: dig deb.debian.org @127.0.0.1 to debug")
    fi
  fi

  # ── PHASE 9b: FETCH ROOT.HINTS — now that DNS works ────────────────────────
  if ! $DRY_RUN && $needs_root_hints && [[ ! -f /var/lib/unbound/root.hints ]]; then
    log "dns: fetching root.hints (DNS now confirmed working)..."
    if curl -sSf https://www.internic.net/domain/named.root             -o /var/lib/unbound/root.hints 2>/dev/null; then
      chown unbound:unbound /var/lib/unbound/root.hints 2>/dev/null || true
      _dns_ok "root.hints fetched from internic.net"
      report "${SCRIPT_NAME}" "dns" "root.hints" "prepare" "changed" "fetched post-DNS-verify" ""
      # Restart unbound with root.hints now available
      systemctl restart unbound >/dev/null 2>&1 || true
      sleep 1
    else
      _dns_manual "could not fetch root.hints"
      manual_tasks+=("MANUAL: curl -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.root && systemctl restart unbound")
    fi
  fi

  # ── PHASE 10: WRITE RESOLV.CONF — only if resolution confirmed ─────────────
  if $DRY_RUN; then
    printf '[dry] write /etc/resolv.conf → nameserver 127.0.0.1 (only if resolution confirmed)\n'
  elif $resolution_ok; then
    log "dns: writing /etc/resolv.conf..."

    # Back up current resolv.conf before touching it
    backup_target /etc/resolv.conf >/dev/null 2>&1 || true

    # Break symlink if it points at systemd-resolved stub
    if [[ -L /etc/resolv.conf ]]; then
      local link_target
      link_target="$(readlink /etc/resolv.conf)"
      log "dns: /etc/resolv.conf is symlink to ${link_target} — replacing with static file"
      rm -f /etc/resolv.conf
    fi

    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
    chown root:root /etc/resolv.conf
    chmod 0644 /etc/resolv.conf

    _dns_ok "/etc/resolv.conf written → nameserver 127.0.0.1"
    report "${SCRIPT_NAME}" "dns" "resolv.conf" "restore" "changed" \
      "written: nameserver 127.0.0.1 (resolution confirmed before write)" ""
  else
    # Resolution failed — write a safe fallback, mark resolv.conf as manual
    log "dns: resolution not confirmed — writing fallback resolv.conf (1.1.1.1)"
    backup_target /etc/resolv.conf >/dev/null 2>&1 || true
    [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
    printf '# fallback — local resolver did not come up cleanly\n# replace with: nameserver 127.0.0.1 once dnsmasq is running\nnameserver 1.1.1.1\nnameserver 9.9.9.9\n' \
      > /etc/resolv.conf
    chown root:root /etc/resolv.conf
    chmod 0644 /etc/resolv.conf

    _dns_dormant "/etc/resolv.conf → fallback 1.1.1.1 (local resolver not confirmed)"
    report "${SCRIPT_NAME}" "dns" "resolv.conf" "restore" "changed" \
      "fallback written: 1.1.1.1 — replace with 127.0.0.1 once dnsmasq is confirmed" ""
    manual_tasks+=("MANUAL: once dnsmasq is running, run: echo 'nameserver 127.0.0.1' > /etc/resolv.conf")
  fi

  # ── PHASE 11: SUMMARY REPORT ────────────────────────────────────────────────
  printf '\n'
  printf '  ── DNS restore summary ────────────────────────────────────────────\n'

  # WireGuard not present
  if [[ -z "${wg_ifaces// /}" ]]; then
    _dns_dormant "WireGuard not present — WireGuard-dependent DNS rules are preserved but dormant"
    _dns_info    "They will activate automatically once WireGuard is restored"
    _dns_info    "Run: restore-configs.sh --category wireguard (when implemented)"
  fi

  # Docker not present or no bridges
  if [[ -z "${docker_ips// /}" ]] && ! have_cmd docker; then
    _dns_dormant "Docker not present — Docker-dependent DNS rules are preserved but dormant"
  fi

  # Print manual task list
  if [[ ${#manual_tasks[@]} -gt 0 ]]; then
    printf '\n'
    printf '  ── MANUAL TASKS REQUIRED ──────────────────────────────────────────\n'
    local i=1
    for task in "${manual_tasks[@]}"; do
      printf '  [%d] %s\n' "$i" "$task"
      ((i+=1))
    done
    printf '\n'
    report "${SCRIPT_NAME}" "dns" "manual-tasks" "manual" "manual" \
      "${#manual_tasks[@]} manual tasks recorded" ""
  else
    printf '\n'
    printf '  ── No manual tasks required ✓\n'
    printf '\n'
  fi

  report "${SCRIPT_NAME}" "dns" "category" "restore" "changed" \
    "adaptive DNS restore completed; manual_tasks=${#manual_tasks[@]}" ""
}

# ── Firewall output helpers ───────────────────────────────────────────────────
_fw_ok()     { printf '  \033[32m✓\033[0m adapted    %s\n' "$*"; }
_fw_dormant(){ printf '  \033[33m⚠\033[0m dormant    %s\n' "$*"; }
_fw_manual() { printf '  \033[31m✗\033[0m MANUAL     %s\n' "$*"; }
_fw_info()   { printf '  \033[36m·\033[0m            %s\n' "$*"; }

_adapt_nftables() {
  local src="$1" dst="$2"
  local dormant_ifaces=()
  local line tmp
  tmp="$(mktemp)"

  while IFS= read -r line; do
    # Extract quoted interface name from iif/oif/iifname/oifname directives
    # Skip wildcard patterns like br-*
    # Pattern: keyword followed by whitespace and a quoted non-wildcard name
    local ref_iface=""
    if echo "$line" | grep -qE '(iif|oif|iifname|oifname)[[:space:]]+"[^"*]+"'; then
      # Extract the interface name that immediately follows an iif/oif keyword
      ref_iface="$(echo "$line" | sed -E 's/.*\b(iif|oif|iifname|oifname)[[:space:]]+"([^"*]+)".*/\2/' | grep -v "^$line$" || true)"
    fi

    if [[ -z "$ref_iface" ]]; then
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi

    if ip link show "$ref_iface" >/dev/null 2>&1; then
      printf '%s\n' "$line" >> "$tmp"
    else
      local reason="dormant"
      [[ "$ref_iface" =~ ^wg ]] && reason="dormant-wireguard"
      [[ "$ref_iface" == enx* || "$ref_iface" == eth* ]] && reason="dormant-hardware-nic"
      printf '# [adapted:%s] %s\n' "$reason" "$line" >> "$tmp"
      local already=false
      local d
      for d in "${dormant_ifaces[@]:-}"; do [[ "$d" == "$ref_iface" ]] && already=true; done
      $already || dormant_ifaces+=("$ref_iface")
    fi
  done < "$src"

  mv "$tmp" "$dst"
  printf '%s\n' "${dormant_ifaces[@]:-}"
}

restore_firewall() {
  local base="${PUBLIC_DIR}/firewall"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "firewall" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'firewall'? This will adapt and apply the captured ruleset." no; then
    report "${SCRIPT_NAME}" "firewall" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if [[ "${ROLE}" == "lab" ]]; then
    report "${SCRIPT_NAME}" "firewall" "category" "manual" "manual" "lab role: firewall restore intentionally skipped" ""
    return 0
  fi

  local fw_manual_tasks=()

  # ── ADAPT AND RESTORE NFTABLES.CONF ────────────────────────────────────────
  if [[ -f "${base}/nftables.conf" ]]; then
    log "firewall: adapting nftables.conf..."
    if $DRY_RUN; then
      printf '[dry] adapt nftables.conf → /etc/nftables.conf\n'
    else
      local adapted dormant_list
      adapted="$(mktemp)"
      dormant_list="$(_adapt_nftables "${base}/nftables.conf" "$adapted")"
      cp "$adapted" /etc/nftables.conf
      rm -f "$adapted"
      chown root:root /etc/nftables.conf
      chmod 0640 /etc/nftables.conf

      if [[ -n "$dormant_list" ]]; then
        local docker_dormant=false
        while IFS= read -r iface; do
          [[ -z "$iface" ]] && continue
          if [[ "$iface" =~ ^wg ]]; then
            _fw_dormant "rules for ${iface} commented out (WireGuard — activate when ${iface} exists)"
            fw_manual_tasks+=("FIREWALL: ${iface} rules dormant — activate when WireGuard is up")
          elif [[ "$iface" == enx* || "$iface" == eth* ]]; then
            _fw_dormant "rules for ${iface} commented out (NIC not present — update if using different interface name)"
            fw_manual_tasks+=("FIREWALL: ${iface} rules dormant — replace with actual NIC name in /etc/nftables.conf")
          elif [[ "$iface" =~ ^br- || "$iface" == docker0 ]]; then
            docker_dormant=true
          else
            _fw_dormant "rules for ${iface} commented out (interface not present)"
            fw_manual_tasks+=("FIREWALL: ${iface} rules dormant — review /etc/nftables.conf")
          fi
        done <<< "$dormant_list"
        if $docker_dormant; then
          _fw_dormant "Docker bridge rules commented out (Docker not yet up — will activate automatically when Docker starts)"
          fw_manual_tasks+=("FIREWALL: Docker bridge rules dormant — start Docker and rules will activate on next nftables reload")
        fi
        report "${SCRIPT_NAME}" "firewall" "nftables.conf" "restore" "changed" "adapted: dormant interfaces commented out" ""
      else
        _fw_ok "nftables.conf (no adaptation needed)"
        report "${SCRIPT_NAME}" "firewall" "nftables.conf" "restore" "changed" "restored unchanged" ""
      fi
    fi
  else
    mark_manual "${SCRIPT_NAME}" "firewall" "nftables.conf" "not found in DB"
  fi

  # ── RESTORE NFTABLES.D ──────────────────────────────────────────────────────
  if [[ -d "${base}/nftables.d" ]]; then
    if $DRY_RUN; then
      printf '[dry] restore nftables.d → /etc/nftables.d\n'
    else
      restore_path "${SCRIPT_NAME}" "firewall" "nftables.d" \
        "${base}/nftables.d" "/etc/nftables.d" || true
      _fw_ok "nftables.d restored"
    fi
  fi

  # ── VALIDATE ────────────────────────────────────────────────────────────────
  if ! $DRY_RUN && [[ -f /etc/nftables.conf ]] && have_cmd nft; then
    local validate_out
    validate_out="$(nft -c -f /etc/nftables.conf 2>&1)"
    if [[ -z "$validate_out" ]]; then
      _fw_ok "nftables.conf validates cleanly"
      report "${SCRIPT_NAME}" "firewall" "validate" "check" "ok" "nft -c passed" ""
    else
      _fw_manual "nftables.conf validation errors:"
      while IFS= read -r vline; do _fw_info "  $vline"; done <<< "$validate_out"
      fw_manual_tasks+=("FIREWALL: fix remaining validation errors: sudo nft -c -f /etc/nftables.conf")
      note_failure "${SCRIPT_NAME}" "firewall" "validate" "check" "nft -c failed"
    fi
  fi

  # ── LOAD ────────────────────────────────────────────────────────────────────
  if ! $DRY_RUN && [[ -f /etc/nftables.conf ]] && have_cmd nft; then
    local load_out
    load_out="$(nft -f /etc/nftables.conf 2>&1)"
    if [[ -z "$load_out" ]]; then
      _fw_ok "ruleset loaded successfully"
      systemctl enable nftables >/dev/null 2>&1 || true
      systemctl start nftables >/dev/null 2>&1 || true
      report "${SCRIPT_NAME}" "firewall" "load" "apply" "ok" "ruleset loaded and service started" ""
    else
      _fw_manual "ruleset failed to load:"
      while IFS= read -r lline; do _fw_info "  $lline"; done <<< "$load_out"
      fw_manual_tasks+=("FIREWALL: load manually once fixed: sudo nft -f /etc/nftables.conf")
      note_failure "${SCRIPT_NAME}" "firewall" "load" "apply" "nft load failed"
    fi
  fi

  # ── SUMMARY ─────────────────────────────────────────────────────────────────
  printf '\n  ── Firewall restore summary ───────────────────────────────────────\n'
  if [[ ${#fw_manual_tasks[@]} -gt 0 ]]; then
    printf '\n  ── MANUAL TASKS REQUIRED ──────────────────────────────────────────\n'
    local i=1
    for task in "${fw_manual_tasks[@]}"; do
      printf '  [%d] %s\n' "$i" "$task"
      ((i+=1))
    done
    printf '\n'
  else
    printf '  ── No manual tasks required ✓\n\n'
  fi

  report "${SCRIPT_NAME}" "firewall" "category" "restore" "changed" \
    "adaptive firewall restore completed; manual_tasks=${#fw_manual_tasks[@]}" ""
}
restore_nginx() {
  local base="${PUBLIC_DIR}/nginx/etc-nginx"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "nginx" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'nginx'?" no; then
    report "${SCRIPT_NAME}" "nginx" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  maybe_restore "nginx" "etc-nginx" "${base}" "/etc/nginx"

  # Enable nginx — it will start properly after TLS certs are restored
  if ! $DRY_RUN; then
    systemctl enable nginx >/dev/null 2>&1 || true
    # Only start if certs exist, otherwise nginx will fail to load
    if [[ -d /etc/letsencrypt/live ]]; then
      nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 || true
    fi
  fi

  if [[ "${ROLE}" == "lab" ]]; then
    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] sanitize /etc/nginx for lab role\n'
      printf '[dry] rm -rf /etc/nginx/nginx\n'
      printf '[dry] find /etc/nginx -maxdepth 1 -type d -name '\''sites-available.bak.*'\'' -exec rm -rf {} +\n'
      printf '[dry] rm -f /etc/nginx/sites-enabled/*\n'
      printf '[dry] ln -sf ../sites-available/default /etc/nginx/sites-enabled/default\n'
    else
      rm -rf /etc/nginx/nginx 2>/dev/null || true
      find /etc/nginx -maxdepth 1 -type d -name 'sites-available.bak.*' -exec rm -rf {} + 2>/dev/null || true

      mkdir -p /etc/nginx/sites-enabled
      find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -exec rm -f {} + 2>/dev/null || true

      if [[ -e /etc/nginx/sites-available/default ]]; then
        ln -sf ../sites-available/default /etc/nginx/sites-enabled/default
      fi
    fi

    report "${SCRIPT_NAME}" "nginx" "lab-sanitize" "restore" "changed" \
      "lab role: dropped captured production sites-enabled and restored only default site" ""
  fi
}

restore_mariadb() {
  local base="${PUBLIC_DIR}/mariadb/etc-mysql"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "mariadb" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'mariadb'?" no; then
    report "${SCRIPT_NAME}" "mariadb" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if prompt_yes_no "Restore mariadb/etc-mysql -> /etc/mysql?" yes; then
    restore_path "${SCRIPT_NAME}" "mariadb" "etc-mysql" "${base}" "/etc/mysql" || true

    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] chown -R root:root /etc/mysql\n'
      printf '[dry] find /etc/mysql -type d -exec chmod 0755 {} +\n'
      printf '[dry] find /etc/mysql -type f -exec chmod 0644 {} +\n'
    else
      if [[ -d /etc/mysql ]]; then
        chown -R root:root /etc/mysql 2>/dev/null || true
        find /etc/mysql -type d -exec chmod 0755 {} + 2>/dev/null || true
        find /etc/mysql -type f -exec chmod 0644 {} + 2>/dev/null || true
      fi
    fi

    report "${SCRIPT_NAME}" "mariadb" "metadata" "restore" "changed" \
      "normalized /etc/mysql ownership=root:root dirs=0755 files=0644" ""
  else
    report "${SCRIPT_NAME}" "mariadb" "etc-mysql" "restore" "skipped" "operator skipped" ""
  fi
}

restore_postfix() {
  local pub_base="${PUBLIC_DIR}/postfix"

  if ! prompt_yes_no "Restore category 'postfix'?" no; then
    report "${SCRIPT_NAME}" "postfix" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if [[ -f "${pub_base}/main.cf" ]]; then
    if prompt_yes_no "Restore postfix/main.cf -> /etc/postfix/main.cf?" yes; then
      restore_path "${SCRIPT_NAME}" "postfix" "main.cf" \
        "${pub_base}/main.cf" "/etc/postfix/main.cf" \
        0644 root root || true
    fi
  fi

  if [[ -f "${pub_base}/master.cf" ]]; then
    if prompt_yes_no "Restore postfix/master.cf -> /etc/postfix/master.cf?" yes; then
      restore_path "${SCRIPT_NAME}" "postfix" "master.cf" \
        "${pub_base}/master.cf" "/etc/postfix/master.cf" \
        0644 root root || true
    fi
  fi

  if [[ -d "${pub_base}/etc-postfix" ]]; then
    if prompt_yes_no "Restore postfix/etc-postfix -> /etc/postfix?" yes; then
      restore_path "${SCRIPT_NAME}" "postfix" "etc-postfix" \
        "${pub_base}/etc-postfix" "/etc/postfix" || true
      chown -R root:root /etc/postfix 2>/dev/null || true
      find /etc/postfix -type f -exec chmod 0644 {} + 2>/dev/null || true
      find /etc/postfix -type d -exec chmod 0755 {} + 2>/dev/null || true
      report "${SCRIPT_NAME}" "postfix" "metadata" "restore" "changed" \
        "normalized /etc/postfix ownership=root:root dirs=0755 files=0644" ""
    fi
  fi

  if have_cmd postfix; then
    postfix set-permissions 2>/dev/null || true
    if postfix check 2>/dev/null; then
      report "${SCRIPT_NAME}" "postfix" "validate" "check" "ok" "postfix check passed" ""
      systemctl enable postfix >/dev/null 2>&1 || true
      systemctl restart postfix >/dev/null 2>&1 || true
    else
      note_failure "${SCRIPT_NAME}" "postfix" "validate" "check" "postfix check failed"
    fi
  fi
}

restore_prosody() {
  local pub_base="${PUBLIC_DIR}/prosody/etc-prosody"
  local sec_base="${SECRET_DIR}/prosody/etc-prosody"
  local base=""
  local label=""

  if ! prompt_yes_no "Restore category 'prosody'?" no; then
    report "${SCRIPT_NAME}" "prosody" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if [[ -d "${sec_base}" ]]; then
    base="${sec_base}"
    label="etc-prosody(secret)"
  elif [[ -d "${pub_base}" ]]; then
    base="${pub_base}"
    label="etc-prosody(public)"
  else
    mark_manual "${SCRIPT_NAME}" "prosody" "db" "missing public/secret prosody config"
    return 0
  fi

  if prompt_yes_no "Restore prosody/${label} -> /etc/prosody?" yes; then
    restore_path "${SCRIPT_NAME}" "prosody" "${label}" "${base}" "/etc/prosody" || true

    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] chown -R root:root /etc/prosody\n'
      printf '[dry] find /etc/prosody -type d -exec chmod 0755 {} +\n'
      printf '[dry] find /etc/prosody -type f -exec chmod 0644 {} +\n'
      printf '[dry] find /etc/prosody/certs -type f -exec chmod 0640 {} + 2>/dev/null || true\n'
    else
      chown -R root:root /etc/prosody 2>/dev/null || true
      find /etc/prosody -type d -exec chmod 0755 {} + 2>/dev/null || true
      find /etc/prosody -type f -exec chmod 0644 {} + 2>/dev/null || true
      [[ -d /etc/prosody/certs ]] && find /etc/prosody/certs -type f -exec chmod 0640 {} + 2>/dev/null || true
    fi

    report "${SCRIPT_NAME}" "prosody" "metadata" "restore" "changed" \
      "normalized /etc/prosody ownership=root:root dirs=0755 files=0644 certs=0640" ""
  else
    report "${SCRIPT_NAME}" "prosody" "${label}" "restore" "skipped" "operator skipped" ""
  fi
}

restore_tor() {
  local pub_base="${PUBLIC_DIR}/tor"
  local sec_base="${SECRET_DIR}/tor"

  if ! prompt_yes_no "Restore category 'tor'?" no; then
    report "${SCRIPT_NAME}" "tor" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if prompt_yes_no "Restore tor/torrc -> /etc/tor/torrc?" yes; then
    restore_path "${SCRIPT_NAME}" "tor" "torrc" \
      "${pub_base}/torrc" "/etc/tor/torrc" \
      0644 root root || true
  else
    report "${SCRIPT_NAME}" "tor" "torrc" "restore" "skipped" "operator skipped" ""
  fi

  if prompt_yes_no "Restore tor/torrc.d -> /etc/tor/torrc.d?" yes; then
    restore_path "${SCRIPT_NAME}" "tor" "torrc.d" \
      "${pub_base}/torrc.d" "/etc/tor/torrc.d" || true

    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] chown -R root:root /etc/tor/torrc.d\n'
      printf '[dry] find /etc/tor/torrc.d -type d -exec chmod 0755 {} +\n'
      printf '[dry] find /etc/tor/torrc.d -type f -exec chmod 0644 {} +\n'
    else
      if [[ -d /etc/tor/torrc.d ]]; then
        chown -R root:root /etc/tor/torrc.d 2>/dev/null || true
        find /etc/tor/torrc.d -type d -exec chmod 0755 {} + 2>/dev/null || true
        find /etc/tor/torrc.d -type f -exec chmod 0644 {} + 2>/dev/null || true
      fi
    fi

    report "${SCRIPT_NAME}" "tor" "torrc.d-metadata" "restore" "changed" \
      "normalized /etc/tor/torrc.d ownership=root:root dirs=0755 files=0644" ""
  else
    report "${SCRIPT_NAME}" "tor" "torrc.d" "restore" "skipped" "operator skipped" ""
  fi

  if [[ "${ROLE}" == "replacement" && -d "${sec_base}/var-lib-tor" ]]; then
    if prompt_yes_no "Restore tor/var-lib-tor -> /var/lib/tor?" no; then
      restore_path "${SCRIPT_NAME}" "tor" "var-lib-tor" \
        "${sec_base}/var-lib-tor" "/var/lib/tor" || true

      if [[ ${DRY_RUN} == true ]]; then
        printf '[dry] chown -R debian-tor:debian-tor /var/lib/tor\n'
        printf '[dry] find /var/lib/tor -type d -exec chmod 0700 {} +\n'
        printf '[dry] find /var/lib/tor -type f -exec chmod 0600 {} +\n'
      else
        if [[ -d /var/lib/tor ]]; then
          chown -R debian-tor:debian-tor /var/lib/tor 2>/dev/null || true
          find /var/lib/tor -type d -exec chmod 0700 {} + 2>/dev/null || true
          find /var/lib/tor -type f -exec chmod 0600 {} + 2>/dev/null || true
        fi
      fi

      report "${SCRIPT_NAME}" "tor" "var-lib-tor-metadata" "restore" "changed" \
        "normalized /var/lib/tor ownership=debian-tor:debian-tor dirs=0700 files=0600" ""
    else
      report "${SCRIPT_NAME}" "tor" "var-lib-tor" "restore" "skipped" "operator skipped" ""
    fi
  else
    report "${SCRIPT_NAME}" "tor" "identity" "restore" "skipped" "tor private data not restored in this role" ""
  fi
}

restore_i2pd() {
  local pub_base="${PUBLIC_DIR}/i2pd"
  local sec_base="${SECRET_DIR}/i2pd"

  if ! prompt_yes_no "Restore category 'i2pd'?" no; then
    report "${SCRIPT_NAME}" "i2pd" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if prompt_yes_no "Restore i2pd/etc-i2pd -> /etc/i2pd?" yes; then
    restore_path "${SCRIPT_NAME}" "i2pd" "etc-i2pd" \
      "${pub_base}/etc-i2pd" "/etc/i2pd" || true

    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] chown -R root:root /etc/i2pd\n'
      printf '[dry] find /etc/i2pd -type d -exec chmod 0755 {} +\n'
      printf '[dry] find /etc/i2pd -type f -exec chmod 0644 {} +\n'
    else
      if [[ -d /etc/i2pd ]]; then
        chown -R root:root /etc/i2pd 2>/dev/null || true
        find /etc/i2pd -type d -exec chmod 0755 {} + 2>/dev/null || true
        find /etc/i2pd -type f -exec chmod 0644 {} + 2>/dev/null || true
      fi
    fi

    report "${SCRIPT_NAME}" "i2pd" "etc-i2pd-metadata" "restore" "changed" \
      "normalized /etc/i2pd ownership=root:root dirs=0755 files=0644" ""
  else
    report "${SCRIPT_NAME}" "i2pd" "etc-i2pd" "restore" "skipped" "operator skipped" ""
  fi

  if [[ "${ROLE}" == "replacement" && -d "${sec_base}/var-lib-i2pd" ]]; then
    if prompt_yes_no "Restore i2pd/var-lib-i2pd -> /var/lib/i2pd?" no; then
      restore_path "${SCRIPT_NAME}" "i2pd" "var-lib-i2pd" \
        "${sec_base}/var-lib-i2pd" "/var/lib/i2pd" || true

      if [[ ${DRY_RUN} == true ]]; then
        printf '[dry] chown -R i2pd:i2pd /var/lib/i2pd\n'
        printf '[dry] find /var/lib/i2pd -type d -exec chmod 0700 {} +\n'
        printf '[dry] find /var/lib/i2pd -type f -exec chmod 0600 {} +\n'
      else
        if [[ -d /var/lib/i2pd ]]; then
          chown -R i2pd:i2pd /var/lib/i2pd 2>/dev/null || true
          find /var/lib/i2pd -type d -exec chmod 0700 {} + 2>/dev/null || true
          find /var/lib/i2pd -type f -exec chmod 0600 {} + 2>/dev/null || true
        fi
      fi

      report "${SCRIPT_NAME}" "i2pd" "var-lib-i2pd-metadata" "restore" "changed" \
        "normalized /var/lib/i2pd ownership=i2pd:i2pd dirs=0700 files=0600" ""
    else
      report "${SCRIPT_NAME}" "i2pd" "var-lib-i2pd" "restore" "skipped" "operator skipped" ""
    fi
  else
    report "${SCRIPT_NAME}" "i2pd" "identity" "restore" "skipped" "i2pd private data not restored in this role" ""
  fi
}

restore_docker() {
  local pub_base="${PUBLIC_DIR}/docker"
  local sec_base="${SECRET_DIR}/docker"

  if ! prompt_yes_no "Restore category 'docker'?" no; then
    report "${SCRIPT_NAME}" "docker" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if prompt_yes_no "Restore docker/daemon.json -> /etc/docker/daemon.json?" yes; then
    restore_path "${SCRIPT_NAME}" "docker" "daemon.json" \
      "${pub_base}/daemon.json" "/etc/docker/daemon.json" \
      0644 root root || true
  else
    report "${SCRIPT_NAME}" "docker" "daemon.json" "restore" "skipped" "operator skipped" ""
  fi

  if [[ -d "${sec_base}/compose-full" ]]; then
    report "${SCRIPT_NAME}" "docker" "compose-full" "manual" "manual" \
      "compose files available in secret DB; restore manually per stack" ""
  fi

  # Ensure primary user is in docker group
  if ! $DRY_RUN && id "${PRIMARY_USER:-lukasz}" >/dev/null 2>&1; then
    if ! id -nG "${PRIMARY_USER:-lukasz}" | grep -qw docker; then
      usermod -aG docker "${PRIMARY_USER:-lukasz}" 2>/dev/null || true
      report "${SCRIPT_NAME}" "docker" "docker-group" "fix" "changed" \
        "${PRIMARY_USER:-lukasz} added to docker group — re-login required" ""
    fi
  fi
}

restore_monitoring() {
  if ! prompt_yes_no "Restore category 'monitoring'?" no; then
    report "${SCRIPT_NAME}" "monitoring" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if [[ -d "${PUBLIC_DIR}/prometheus/etc-prometheus" ]]; then
    if prompt_yes_no "Restore monitoring/prometheus -> /etc/prometheus?" yes; then
      restore_path "${SCRIPT_NAME}" "monitoring" "prometheus" \
        "${PUBLIC_DIR}/prometheus/etc-prometheus" "/etc/prometheus" || true

      if [[ ${DRY_RUN} == true ]]; then
        printf '[dry] chown -R root:root /etc/prometheus\n'
        printf '[dry] find /etc/prometheus -type d -exec chmod 0755 {} +\n'
        printf '[dry] find /etc/prometheus -type f -exec chmod 0644 {} +\n'
      else
        [[ -d /etc/prometheus ]] && chown -R root:root /etc/prometheus 2>/dev/null || true
        [[ -d /etc/prometheus ]] && find /etc/prometheus -type d -exec chmod 0755 {} + 2>/dev/null || true
        [[ -d /etc/prometheus ]] && find /etc/prometheus -type f -exec chmod 0644 {} + 2>/dev/null || true
      fi

      report "${SCRIPT_NAME}" "monitoring" "prometheus-metadata" "restore" "changed" \
        "normalized /etc/prometheus ownership=root:root dirs=0755 files=0644" ""
    else
      report "${SCRIPT_NAME}" "monitoring" "prometheus" "restore" "skipped" "operator skipped" ""
    fi
  fi

  if [[ -f "${PUBLIC_DIR}/prometheus/node-exporter-defaults" ]]; then
    if prompt_yes_no "Restore monitoring/prometheus-node-exporter -> /etc/default/prometheus-node-exporter?" yes; then
      restore_path "${SCRIPT_NAME}" "monitoring" "prometheus-node-exporter" \
        "${PUBLIC_DIR}/prometheus/node-exporter-defaults" \
        "/etc/default/prometheus-node-exporter" \
        0644 root root || true
    else
      report "${SCRIPT_NAME}" "monitoring" "prometheus-node-exporter" "restore" "skipped" "operator skipped" ""
    fi
  fi

  if [[ -d "${PUBLIC_DIR}/loki/etc-loki" ]]; then
    if prompt_yes_no "Restore monitoring/loki -> /etc/loki?" yes; then
      restore_path "${SCRIPT_NAME}" "monitoring" "loki" \
        "${PUBLIC_DIR}/loki/etc-loki" "/etc/loki" || true

      if [[ ${DRY_RUN} == true ]]; then
        printf '[dry] chown -R root:root /etc/loki\n'
        printf '[dry] find /etc/loki -type d -exec chmod 0755 {} +\n'
        printf '[dry] find /etc/loki -type f -exec chmod 0644 {} +\n'
      else
        [[ -d /etc/loki ]] && chown -R root:root /etc/loki 2>/dev/null || true
        [[ -d /etc/loki ]] && find /etc/loki -type d -exec chmod 0755 {} + 2>/dev/null || true
        [[ -d /etc/loki ]] && find /etc/loki -type f -exec chmod 0644 {} + 2>/dev/null || true
      fi

      report "${SCRIPT_NAME}" "monitoring" "loki-metadata" "restore" "changed" \
        "normalized /etc/loki ownership=root:root dirs=0755 files=0644" ""
    else
      report "${SCRIPT_NAME}" "monitoring" "loki" "restore" "skipped" "operator skipped" ""
    fi
  fi

  if [[ -d "${PUBLIC_DIR}/grafana/etc-grafana" ]]; then
    if prompt_yes_no "Restore monitoring/grafana -> /etc/grafana?" yes; then
      restore_path "${SCRIPT_NAME}" "monitoring" "grafana" \
        "${PUBLIC_DIR}/grafana/etc-grafana" "/etc/grafana" || true

      if [[ ${DRY_RUN} == true ]]; then
        printf '[dry] chown -R root:root /etc/grafana\n'
        printf '[dry] find /etc/grafana -type d -exec chmod 0755 {} +\n'
        printf '[dry] find /etc/grafana -type f -exec chmod 0644 {} +\n'
      else
        [[ -d /etc/grafana ]] && chown -R root:root /etc/grafana 2>/dev/null || true
        [[ -d /etc/grafana ]] && find /etc/grafana -type d -exec chmod 0755 {} + 2>/dev/null || true
        [[ -d /etc/grafana ]] && find /etc/grafana -type f -exec chmod 0644 {} + 2>/dev/null || true
      fi

      report "${SCRIPT_NAME}" "monitoring" "grafana-metadata" "restore" "changed" \
        "normalized /etc/grafana ownership=root:root dirs=0755 files=0644" ""
    else
      report "${SCRIPT_NAME}" "monitoring" "grafana" "restore" "skipped" "operator skipped" ""
    fi
  fi

  if [[ -d "${SECRET_DIR}/alloy/etc-alloy" ]]; then
    if prompt_yes_no "Restore monitoring/alloy -> /etc/alloy?" yes; then
      restore_path "${SCRIPT_NAME}" "monitoring" "alloy" \
        "${SECRET_DIR}/alloy/etc-alloy" "/etc/alloy" || true

      if [[ ${DRY_RUN} == true ]]; then
        printf '[dry] chown -R root:root /etc/alloy\n'
        printf '[dry] find /etc/alloy -type d -exec chmod 0755 {} +\n'
        printf '[dry] find /etc/alloy -type f -exec chmod 0644 {} +\n'
      else
        [[ -d /etc/alloy ]] && chown -R root:root /etc/alloy 2>/dev/null || true
        [[ -d /etc/alloy ]] && find /etc/alloy -type d -exec chmod 0755 {} + 2>/dev/null || true
        [[ -d /etc/alloy ]] && find /etc/alloy -type f -exec chmod 0644 {} + 2>/dev/null || true
      fi

      report "${SCRIPT_NAME}" "monitoring" "alloy-metadata" "restore" "changed" \
        "normalized /etc/alloy ownership=root:root dirs=0755 files=0644" ""
    else
      report "${SCRIPT_NAME}" "monitoring" "alloy" "restore" "skipped" "operator skipped" ""
    fi
  fi
}


restore_tls() {
  local sec_tls="${SECRET_DIR}/tls"

  if ! prompt_yes_no "Restore category 'tls' (TLS certificates from secret DB)?" no; then
    report "${SCRIPT_NAME}" "tls" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if [[ ! -d "${sec_tls}/letsencrypt" ]]; then
    mark_manual "${SCRIPT_NAME}" "tls" "db" "no letsencrypt certs found in secret DB at ${sec_tls}/letsencrypt"
    return 0
  fi

  if prompt_yes_no "Restore TLS certs from secret DB -> /etc/letsencrypt?" yes; then
    if $DRY_RUN; then
      printf '[dry] restore %s → /etc/letsencrypt\n' "${sec_tls}/letsencrypt"
    else
      restore_path "${SCRIPT_NAME}" "tls" "letsencrypt"         "${sec_tls}/letsencrypt" "/etc/letsencrypt" || true
      chown -R root:root /etc/letsencrypt 2>/dev/null || true
      # Private keys: root:root 0600
      find /etc/letsencrypt -name 'privkey*.pem' -exec chmod 0600 {} + 2>/dev/null || true
      find /etc/letsencrypt -name 'privkey*.pem' -exec chown root:root {} + 2>/dev/null || true
      # Certs: readable
      find /etc/letsencrypt -name '*.pem' ! -name 'privkey*' -exec chmod 0644 {} + 2>/dev/null || true
      find /etc/letsencrypt -type d -exec chmod 0755 {} + 2>/dev/null || true
      report "${SCRIPT_NAME}" "tls" "letsencrypt" "restore" "changed"         "TLS certs restored; privkeys=0600 certs=0644" ""
    fi

    # Check cert expiry
    if ! $DRY_RUN && have_cmd certbot; then
      local expiry_out
      expiry_out="$(certbot certificates 2>/dev/null | grep -E 'Domains|Expiry|Certificate Name' || true)"
      if [[ -n "$expiry_out" ]]; then
        printf '
  ── TLS cert expiry ──────────────────────────────────────────────
'
        while IFS= read -r line; do printf '  %s
' "$line"; done <<< "$expiry_out"
        printf '
'
      fi
      report "${SCRIPT_NAME}" "tls" "expiry-check" "check" "ok" "certbot certificates checked" ""
    fi

    # Start/reload nginx now that certs exist
    if ! $DRY_RUN && have_cmd nginx && nginx -t >/dev/null 2>&1; then
      systemctl enable nginx >/dev/null 2>&1 || true
      systemctl reload nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true
      report "${SCRIPT_NAME}" "tls" "nginx-reload" "apply" "ok" "nginx started/reloaded with certs" ""
    fi
  fi

  report "${SCRIPT_NAME}" "tls" "category" "restore" "changed" "TLS restore completed" ""
}

for category in "${CATEGORIES[@]}"; do
  log "processing category: ${category}"
  case "${category}" in
    system-basics) restore_system_basics ;;
    users)         restore_users ;;
    ssh)           restore_ssh ;;
    network)       restore_network ;;
    dns)           restore_dns ;;
    firewall)      restore_firewall ;;
    nginx)         restore_nginx ;;
    mariadb)       restore_mariadb ;;
    postfix)       restore_postfix ;;
    prosody)       restore_prosody ;;
    tor)           restore_tor ;;
    i2pd)          restore_i2pd ;;
    docker)        restore_docker ;;
    monitoring)    restore_monitoring ;;
    tls)           restore_tls ;;
    *) note_failure "${SCRIPT_NAME}" "category" "${category}" "restore" "unknown category" ;;
  esac
done

set_state restore_configs done
report "${SCRIPT_NAME}" "run" "finish" "exit" "ok" "completed" ""
log "${SCRIPT_NAME}: done; report=${REPORT_FILE}"
