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

  maybe_restore "ssh" "sshd_config"   "${pub_users}/sshd_config"   "/etc/ssh/sshd_config"
  maybe_restore "ssh" "sshd_config.d" "${pub_users}/sshd_config.d" "/etc/ssh/sshd_config.d"

  if [[ "${ROLE}" == "replacement" || "${ROLE}" == "hardware" ]]; then
    if [[ -d "${sec_ssh}/etc-ssh" ]]; then
      if prompt_yes_no "Restore SSH host keys from secret DB?" no; then
        restore_path "${SCRIPT_NAME}" "ssh" "host-keys" "${sec_ssh}/etc-ssh" "/etc/ssh" || true
      else
        report "${SCRIPT_NAME}" "ssh" "host-keys" "restore" "skipped" "operator skipped host keys" ""
      fi
    fi
  else
    report "${SCRIPT_NAME}" "ssh" "host-keys" "restore" "skipped" "lab role: host keys not restored" ""
  fi

  if [[ -d "${sec_ssh}/user-lukasz" ]]; then
    if prompt_yes_no "Restore lukasz user SSH material from secret DB?" no; then
      restore_path "${SCRIPT_NAME}" "ssh" "user-lukasz" "${sec_ssh}/user-lukasz" "/home/lukasz/.ssh" || true
      if [[ ${DRY_RUN} == false ]]; then
        chown -R lukasz:lukasz /home/lukasz/.ssh 2>/dev/null || true
        chmod 700 /home/lukasz/.ssh 2>/dev/null || true
        find /home/lukasz/.ssh -maxdepth 1 -type f -exec chmod 600 {} \; 2>/dev/null || true
      fi
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
  maybe_restore "network" "hosts.allow"      "${base}/hosts.allow"      "/etc/hosts.allow"
  maybe_restore "network" "hosts.deny"       "${base}/hosts.deny"       "/etc/hosts.deny"
}

restore_dns() {
  local base="${PUBLIC_DIR}/dns"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "dns" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'dns'? This can disrupt resolver state." no; then
    report "${SCRIPT_NAME}" "dns" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if [[ "${ROLE}" == "lab" ]]; then
    report "${SCRIPT_NAME}" "dns" "category" "manual" "manual" "lab role: DNS restore intentionally skipped" ""
    return 0
  fi

  maybe_restore "dns" "dnsmasq.conf" "${base}/dnsmasq.conf" "/etc/dnsmasq.conf"
  maybe_restore "dns" "dnsmasq.d"    "${base}/dnsmasq.d"    "/etc/dnsmasq.d"
  maybe_restore "dns" "etc-unbound"  "${base}/etc-unbound"  "/etc/unbound"
  maybe_restore "dns" "resolv.conf"  "${base}/resolv.conf"  "/etc/resolv.conf"
}

restore_firewall() {
  local base="${PUBLIC_DIR}/firewall"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "firewall" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'firewall'? This can disrupt connectivity." no; then
    report "${SCRIPT_NAME}" "firewall" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if [[ "${ROLE}" == "lab" ]]; then
    report "${SCRIPT_NAME}" "firewall" "category" "manual" "manual" "lab role: firewall restore intentionally skipped" ""
    return 0
  fi

  maybe_restore "firewall" "nftables.conf" "${base}/nftables.conf" "/etc/nftables.conf"
  maybe_restore "firewall" "nftables.d"    "${base}/nftables.d"    "/etc/nftables.d"

  if [[ ${DRY_RUN} == false && -f /etc/nftables.conf ]] && have_cmd nft; then
    nft -c -f /etc/nftables.conf >/dev/null 2>&1 || note_failure "${SCRIPT_NAME}" "firewall" "validate" "check" "nftables config validation failed"
  fi
}

restore_nginx() {
  local base="${PUBLIC_DIR}/nginx/etc-nginx"
  [[ -d "${base}" ]] || { mark_manual "${SCRIPT_NAME}" "nginx" "db" "missing ${base}"; return 0; }

  if ! prompt_yes_no "Restore category 'nginx'?" no; then
    report "${SCRIPT_NAME}" "nginx" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  maybe_restore "nginx" "etc-nginx" "${base}" "/etc/nginx"

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

  maybe_restore "mariadb" "etc-mysql" "${base}" "/etc/mysql"
}

restore_postfix() {
  local base="${PUBLIC_DIR}/postfix"
  [[ -d "${base}" ]] || {
    mark_manual "${SCRIPT_NAME}" "postfix" "db" "missing ${base}"
    return 0
  }

  if ! prompt_yes_no "Restore category 'postfix'?" no; then
    report "${SCRIPT_NAME}" "postfix" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  if prompt_yes_no "Restore postfix/main.cf -> /etc/postfix/main.cf?" yes; then
    restore_path "${SCRIPT_NAME}" "postfix" "main.cf" \
      "${base}/main.cf" "/etc/postfix/main.cf" \
      0644 root root || true
  else
    report "${SCRIPT_NAME}" "postfix" "main.cf" "restore" "skipped" "operator skipped" ""
  fi

  if prompt_yes_no "Restore postfix/master.cf -> /etc/postfix/master.cf?" yes; then
    restore_path "${SCRIPT_NAME}" "postfix" "master.cf" \
      "${base}/master.cf" "/etc/postfix/master.cf" \
      0644 root root || true
  else
    report "${SCRIPT_NAME}" "postfix" "master.cf" "restore" "skipped" "operator skipped" ""
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

  maybe_restore "tor" "torrc"   "${pub_base}/torrc"   "/etc/tor/torrc"
  maybe_restore "tor" "torrc.d" "${pub_base}/torrc.d" "/etc/tor/torrc.d"

  if [[ "${ROLE}" == "replacement" && -d "${sec_base}/var-lib-tor" ]]; then
    maybe_restore "tor" "var-lib-tor" "${sec_base}/var-lib-tor" "/var/lib/tor"
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

  maybe_restore "i2pd" "etc-i2pd" "${pub_base}/etc-i2pd" "/etc/i2pd"

  if [[ "${ROLE}" == "replacement" && -d "${sec_base}/var-lib-i2pd" ]]; then
    maybe_restore "i2pd" "var-lib-i2pd" "${sec_base}/var-lib-i2pd" "/var/lib/i2pd"
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

  maybe_restore "docker" "daemon.json" "${pub_base}/daemon.json" "/etc/docker/daemon.json"

  if [[ -d "${sec_base}/compose-full" ]]; then
    report "${SCRIPT_NAME}" "docker" "compose-full" "manual" "manual" "compose files available in secret DB; restore manually per stack" ""
  fi
}

restore_monitoring() {
  if ! prompt_yes_no "Restore category 'monitoring'?" no; then
    report "${SCRIPT_NAME}" "monitoring" "category" "restore" "skipped" "operator skipped category" ""
    return 0
  fi

  [[ -d "${PUBLIC_DIR}/prometheus/etc-prometheus" ]] && maybe_restore "monitoring" "prometheus" "${PUBLIC_DIR}/prometheus/etc-prometheus" "/etc/prometheus"
  [[ -f "${PUBLIC_DIR}/prometheus/node-exporter-defaults" ]] && maybe_restore "monitoring" "prometheus-node-exporter" "${PUBLIC_DIR}/prometheus/node-exporter-defaults" "/etc/default/prometheus-node-exporter"
  [[ -d "${PUBLIC_DIR}/loki/etc-loki" ]] && maybe_restore "monitoring" "loki" "${PUBLIC_DIR}/loki/etc-loki" "/etc/loki"
  [[ -d "${PUBLIC_DIR}/grafana/etc-grafana" ]] && maybe_restore "monitoring" "grafana" "${PUBLIC_DIR}/grafana/etc-grafana" "/etc/grafana"
  [[ -d "${SECRET_DIR}/alloy/etc-alloy" ]] && maybe_restore "monitoring" "alloy" "${SECRET_DIR}/alloy/etc-alloy" "/etc/alloy"
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
    *) note_failure "${SCRIPT_NAME}" "category" "${category}" "restore" "unknown category" ;;
  esac
done

set_state restore_configs done
report "${SCRIPT_NAME}" "run" "finish" "exit" "ok" "completed" ""
log "${SCRIPT_NAME}: done; report=${REPORT_FILE}"
