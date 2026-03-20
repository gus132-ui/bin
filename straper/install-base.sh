#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

SCRIPT_NAME="install-base.sh"
USE_DB_APT_SOURCES=false
FROM_DB_MANUAL=false
HOSTNAME_WANTED=""
TIMEZONE_WANTED="Europe/Warsaw"
LOCALE_WANTED="en_US.UTF-8"

usage() {
  cat <<USAGE
Usage: sudo ./install-base.sh [options]

Purpose:
  Install a reproducible Debian base for sanctum/labunix recovery without
  importing host-specific configs or identities.

Options:
  --db-dir PATH               Capture DB root (default: ${DB_DIR})
  --role lab|hardware|replacement
  --profile minimal|core|full
  --hostname NAME             Set hostname
  --timezone TZ               Set timezone (default: ${TIMEZONE_WANTED})
  --locale LOCALE             Set locale (default: ${LOCALE_WANTED})
  --use-db-apt-sources        Restore apt sources from db/public/packages/apt
  --from-db-manual            Install packages listed in apt-mark-manual.txt
  --start-safe-services       Enable/start low-risk services after install
  --yes                       Non-interactive yes to prompts
  --dry-run                   Print actions only
  --verbose                   More logging
  --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-dir) DB_DIR="$2"; PUBLIC_DIR="${DB_DIR}/db/public"; SECRET_DIR="${DB_DIR}/db/secret"; shift ;;
    --role) ROLE="$2"; shift ;;
    --profile) PROFILE="$2"; shift ;;
    --hostname) HOSTNAME_WANTED="$2"; shift ;;
    --timezone) TIMEZONE_WANTED="$2"; shift ;;
    --locale) LOCALE_WANTED="$2"; shift ;;
    --use-db-apt-sources) USE_DB_APT_SOURCES=true ;;
    --from-db-manual) FROM_DB_MANUAL=true ;;
    --start-safe-services) START_SERVICES=true ;;
    --yes) ASSUME_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --verbose) VERBOSE=true ;;
    --help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

ensure_root
load_optional_config
ensure_runtime_dirs
require_cmd apt-get apt-cache dpkg hostnamectl rsync

mkdir -p -- /etc/labunix

log "${SCRIPT_NAME}: role=${ROLE} profile=${PROFILE} db=${DB_DIR}"
report "${SCRIPT_NAME}" "run" "start" "init" "ok" "role=${ROLE} profile=${PROFILE}" ""

case "${ROLE}" in
  lab|hardware|replacement) ;;
  *) die "invalid role: ${ROLE}" ;;
esac
case "${PROFILE}" in
  minimal|core|full) ;;
  *) die "invalid profile: ${PROFILE}" ;;
esac

BASE_PACKAGES=(
  ca-certificates curl wget gnupg2 jq rsync vim zsh sudo
  locales tzdata lsb-release apt-transport-https
  net-tools iproute2 iputils-ping dnsutils ethtool
  openssh-server systemd-resolved nftables fail2ban
)

CORE_PACKAGES=(
  wireguard wireguard-tools dnsmasq unbound dns-root-data docker.io nginx mariadb-server postfix prosody
  tor i2pd pygopherd mumble-server prometheus prometheus-node-exporter loki
  apparmor apparmor-utils
)

FULL_EXTRA_PACKAGES=(
  git tmux htop build-essential pkg-config
  docker.io
)

bootstrap_dns_prepare() {
  local test_host="${BOOTSTRAP_TEST_HOST:-deb.debian.org}"
  local backup="/etc/resolv.conf.labunix-preinstall.bak"

  # Always write a static resolv.conf for bootstrap — breaks any symlink to
  # systemd-resolved stub which can disappear mid-install when services restart.
  if [[ -e /etc/resolv.conf && ! -e "${backup}" ]]; then
    cp -a /etc/resolv.conf "${backup}" || true
  fi

  if getent ahostsv4 "${test_host}" >/dev/null 2>&1; then
    # DNS works — write static file pointing at current resolver
    local current_ns
    current_ns="$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}')"
    current_ns="${current_ns:-1.1.1.1}"
    # Don't use stub addresses — they won't survive service restarts
    if [[ "$current_ns" == "127.0.0.53" || "$current_ns" == "127.0.0.54" ]]; then
      current_ns="1.1.1.1"
    fi
    printf 'nameserver %s\nnameserver 9.9.9.9\n' "$current_ns" > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    report "${SCRIPT_NAME}" "dns" "bootstrap" "check" "ok" "static resolv.conf written: ${current_ns}" ""
    return 0
  fi

  if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    note_failure "${SCRIPT_NAME}" "dns" "bootstrap" "check" "no outbound IP connectivity"
    die "bootstrap DNS check failed: no outbound IP connectivity"
  fi

  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > /etc/resolv.conf
  chmod 644 /etc/resolv.conf

  if getent ahostsv4 "${test_host}" >/dev/null 2>&1; then
    report "${SCRIPT_NAME}" "dns" "bootstrap" "fallback" "changed" "static fallback resolv.conf applied" "${backup}"
    return 0
  fi

  note_failure "${SCRIPT_NAME}" "dns" "bootstrap" "check" "DNS still broken after fallback attempt"
  die "bootstrap DNS check failed"
}

install_pkg_group() {
  local group_name="$1"; shift
  local pkgs=("$@")
  log "installing package group: ${group_name}"
  if apt_install_if_missing "${pkgs[@]}"; then
    report "${SCRIPT_NAME}" "packages" "${group_name}" "install" "ok" "group processed" ""
  else
    note_failure "${SCRIPT_NAME}" "packages" "${group_name}" "install" "apt install failed"
    die "package group failed: ${group_name}"
  fi
}

apply_hostname_locale_timezone() {
  if [[ -n ${HOSTNAME_WANTED} ]]; then
    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] hostnamectl set-hostname %s\n' "${HOSTNAME_WANTED}"
    else
      hostnamectl set-hostname "${HOSTNAME_WANTED}"
      printf '%s\n' "${HOSTNAME_WANTED}" > /etc/hostname
    fi
    report "${SCRIPT_NAME}" "system" "hostname" "set" "changed" "${HOSTNAME_WANTED}" ""
  fi

  if [[ -f /etc/locale.gen ]] && grep -Eq "^#?\s*${LOCALE_WANTED}\b" /etc/locale.gen 2>/dev/null; then
    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] enable locale %s in /etc/locale.gen\n' "${LOCALE_WANTED}"
    else
      if have_cmd locale-gen && have_cmd update-locale; then
        sed -i "s/^# *\(${LOCALE_WANTED}\b.*\)/\1/" /etc/locale.gen
        locale-gen "${LOCALE_WANTED}" >/dev/null
        update-locale LANG="${LOCALE_WANTED}" >/dev/null
      else
        report "${SCRIPT_NAME}" "system" "locale" "manual" "manual" "locale tools missing; install locales first or rerun after base packages" ""
        return 0
      fi
    fi
    report "${SCRIPT_NAME}" "system" "locale" "set" "changed" "${LOCALE_WANTED}" ""
  else
    report "${SCRIPT_NAME}" "system" "locale" "manual" "manual" "locale missing in /etc/locale.gen: ${LOCALE_WANTED}" ""
  fi

  if [[ ${DRY_RUN} == true ]]; then
    printf '[dry] set timezone %s\n' "${TIMEZONE_WANTED}"
  else
    ln -sf "/usr/share/zoneinfo/${TIMEZONE_WANTED}" /etc/localtime
    dpkg-reconfigure -f noninteractive tzdata >/dev/null
  fi
  report "${SCRIPT_NAME}" "system" "timezone" "set" "changed" "${TIMEZONE_WANTED}" ""
}

restore_apt_sources_from_db() {
  local src="${PUBLIC_DIR}/packages/apt"
  [[ -d ${src} ]] || { mark_manual "${SCRIPT_NAME}" "apt" "sources" "db/public/packages/apt missing"; return 0; }

  if ! prompt_yes_no "Restore APT sources from DB now?" no; then
    report "${SCRIPT_NAME}" "apt" "sources" "restore" "skipped" "operator skipped" ""
    return 0
  fi

  restore_path "${SCRIPT_NAME}" "apt" "sources.list" "${src}/sources.list" "/etc/apt/sources.list"
  restore_path "${SCRIPT_NAME}" "apt" "sources.list.d" "${src}/sources.list.d" "/etc/apt/sources.list.d"
  restore_path "${SCRIPT_NAME}" "apt" "preferences" "${src}/preferences" "/etc/apt/preferences"
  restore_path "${SCRIPT_NAME}" "apt" "preferences.d" "${src}/preferences.d" "/etc/apt/preferences.d"
  restore_path "${SCRIPT_NAME}" "apt" "apt.conf.d" "${src}/apt.conf.d" "/etc/apt/apt.conf.d"

  if [[ ${DRY_RUN} == true ]]; then
    printf '[dry] apt-get update\n'
  else
    if apt-get update; then
      report "${SCRIPT_NAME}" "apt" "update-after-restore" "update" "ok" "apt metadata refreshed" ""
    else
      note_failure "${SCRIPT_NAME}" "apt" "update-after-restore" "update" "apt-get update failed after restoring sources"
    fi
  fi
}

package_available() {
  local pkg="$1"
  apt-cache show -- "${pkg}" >/dev/null 2>&1
}

install_from_db_manual() {
  local f="${PUBLIC_DIR}/packages/apt-mark-manual.txt" pkg installed=0 skipped=0 failed=0
  [[ -f ${f} ]] || { mark_manual "${SCRIPT_NAME}" "packages" "db-manual" "apt-mark-manual.txt missing"; return 0; }

  while IFS= read -r pkg; do
    [[ -n ${pkg} ]] || continue
    [[ ${pkg} =~ ^# ]] && continue
    if dpkg -s -- "${pkg}" >/dev/null 2>&1; then
      ((installed+=1))
      continue
    fi
    if ! package_available "${pkg}"; then
      ((skipped+=1))
      report "${SCRIPT_NAME}" "packages" "${pkg}" "install" "skipped" "package not available in current apt sources" ""
      continue
    fi
    if [[ ${DRY_RUN} == true ]]; then
      printf '[dry] apt-get install -y --no-install-recommends %s\n' "${pkg}"
      ((installed+=1))
      continue
    fi
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkg}"; then
      ((installed+=1))
      report "${SCRIPT_NAME}" "packages" "${pkg}" "install" "changed" "installed from apt-mark-manual" ""
    else
      ((failed+=1))
      note_failure "${SCRIPT_NAME}" "packages" "${pkg}" "install" "apt install failed"
    fi
  done < <(list_from_file "${f}")

  report "${SCRIPT_NAME}" "packages" "db-manual-summary" "install" "ok" "installed=${installed} skipped=${skipped} failed=${failed}" ""
}
normalize_service_baseline() {
  local keep_active=(
    ssh.service
    systemd-resolved.service
    fail2ban.service
  )

  local stop_disable=(
    dnsmasq.service
    unbound.service
    unbound-resolvconf.service
    nginx.service
    mariadb.service
    postfix.service
    prosody.service
    prometheus.service
    tor.service
    i2pd.service
    mumble-server.service
    pygopherd.service
  )

  local unit

  for unit in "${stop_disable[@]}"; do
    if systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -qx -- "${unit}"; then
      systemctl disable --now "${unit}" >/dev/null 2>&1 || true
    fi
  done

  systemctl reset-failed "${stop_disable[@]}" >/dev/null 2>&1 || true

  for unit in "${keep_active[@]}"; do
    if systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -qx -- "${unit}"; then
      systemctl enable "${unit}" >/dev/null 2>&1 || true
      systemctl restart "${unit}" >/dev/null 2>&1 || true
    fi
  done

  report "${SCRIPT_NAME}" "services" "baseline" "normalize" "changed" "safe services kept; app/conflicting services stopped" ""
}
start_safe_services() {
  local svc
  for svc in ssh systemd-resolved fail2ban; do
    systemctl_safe_enable "${svc}" || true
    systemctl_safe_start "${svc}" || true
  done

  case "${DNS_MODE}" in
    resolved)
      systemctl_safe_enable systemd-resolved || true
      systemctl_safe_start systemd-resolved || true
      ;;
  esac
  report "${SCRIPT_NAME}" "services" "safe-start" "start" "ok" "safe services processed" ""
}

if [[ ${DRY_RUN} == false ]]; then
  bootstrap_dns_prepare
  if apt-get update; then
    report "${SCRIPT_NAME}" "apt" "update" "update" "ok" "initial apt update" ""
  else
    note_failure "${SCRIPT_NAME}" "apt" "update" "update" "initial apt-get update failed"
    die "initial apt-get update failed"
  fi
else
  report "${SCRIPT_NAME}" "apt" "update" "update" "ok" "initial apt update (dry-run)" ""
fi

install_pkg_group base "${BASE_PACKAGES[@]}"
case "${PROFILE}" in
  minimal) ;;
  core) install_pkg_group core "${CORE_PACKAGES[@]}" ;;
  full)
    install_pkg_group core "${CORE_PACKAGES[@]}"
    install_pkg_group full-extra "${FULL_EXTRA_PACKAGES[@]}"
    ;;
esac

normalize_service_baseline
apply_hostname_locale_timezone

if [[ ${USE_DB_APT_SOURCES} == true ]]; then
  restore_apt_sources_from_db
fi

if [[ ${FROM_DB_MANUAL} == true ]]; then
  install_from_db_manual
fi

install -d -m 0755 /srv /srv/www /srv/docs /etc/wireguard /etc/labunix /var/lib/labunix
report "${SCRIPT_NAME}" "filesystem" "base-dirs" "create" "ok" "/srv /etc/wireguard /etc/labunix prepared" ""

if [[ ${START_SERVICES} == true ]]; then
  start_safe_services
else
  report "${SCRIPT_NAME}" "services" "safe-start" "start" "skipped" "--start-safe-services not requested" ""
fi

set_state install_base done
report "${SCRIPT_NAME}" "run" "finish" "exit" "ok" "completed" ""
log "${SCRIPT_NAME}: done; report=${REPORT_FILE}"
