#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for the labunix/sanctum rebuild toolkit.

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(cd -- "${COMMON_DIR}/.." && pwd)"

TOOLKIT_NAME="labunix-rebuild"
TOOLKIT_VERSION="0.1.1"

: "${DB_DIR:=/srv/sanctum-rebuild}"
: "${PUBLIC_DIR:=${DB_DIR}/db/public}"
: "${SECRET_DIR:=${DB_DIR}/db/secret}"
: "${ROLE:=lab}"                   # lab | hardware | replacement
: "${PROFILE:=core}"               # minimal | core | full
: "${RUN_ID:=$(date +%Y%m%dT%H%M%S)}"
: "${STATE_DIR:=/var/lib/${TOOLKIT_NAME}}"
: "${LOG_DIR:=/var/log/${TOOLKIT_NAME}}"
: "${BACKUP_DIR:=${STATE_DIR}/backups/${RUN_ID}}"
: "${REPORT_FILE:=${LOG_DIR}/report-${RUN_ID}.tsv}"
: "${STATE_FILE:=${STATE_DIR}/state-${RUN_ID}.env}"
: "${DRY_RUN:=false}"
: "${ASSUME_YES:=false}"
: "${VERBOSE:=false}"
: "${START_SERVICES:=false}"
: "${RESTORE_IDENTITIES:=false}"
: "${RESTORE_SECRETS:=false}"
: "${NETWORK_MODE:=safe}"          # safe | source
: "${DNS_MODE:=auto}"              # auto | resolved | dnsmasq | unbound | chain
: "${RESTORE_PURGE:=false}"

umask 022

now_iso() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log()  { printf '[%s] %s\n' "$(now_iso)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(now_iso)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(now_iso)" "$*" >&2; exit 1; }

ensure_root() {
  [[ ${EUID} -eq 0 ]] || die "must be run as root"
}

ensure_runtime_dirs() {
  mkdir -p -- "${STATE_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
  touch -- "${REPORT_FILE}" "${STATE_FILE}"
  chmod 700 -- "${STATE_DIR}" "${BACKUP_DIR}"
  chmod 755 -- "${LOG_DIR}"
  if [[ ! -s ${REPORT_FILE} ]]; then
    printf 'timestamp\tscript\tcategory\titem\taction\tstatus\tnote\tbackup\n' > "${REPORT_FILE}"
  fi
}

load_optional_config() {
  local conf
  for conf in /etc/labunix/rebuild.conf /root/.config/labunix/rebuild.conf; do
    if [[ -f ${conf} ]]; then
      # shellcheck disable=SC1090
      source "${conf}"
    fi
  done
  return 0
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v -- "${c}" >/dev/null 2>&1 || die "required command not found: ${c}"
  done
}

have_cmd() {
  command -v -- "$1" >/dev/null 2>&1
}

set_state() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if [[ -f ${STATE_FILE} ]]; then
    grep -v -E "^${key}=" "${STATE_FILE}" > "${tmp}" || true
  fi
  printf '%s=%q\n' "${key}" "${value}" >> "${tmp}"
  mv -- "${tmp}" "${STATE_FILE}"
  chmod 600 -- "${STATE_FILE}"
}

get_state() {
  local key="$1"
  [[ -f ${STATE_FILE} ]] || return 1
  awk -F= -v k="${key}" '$1==k {sub(/^[^=]*=/,""); print; found=1} END {exit(found?0:1)}' "${STATE_FILE}"
}

report() {
  local script="$1" category="$2" item="$3" action="$4" status="$5" note="$6" backup="${7:-}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(now_iso)" "${script}" "${category}" "${item}" "${action}" "${status}" "${note}" "${backup}" \
    >> "${REPORT_FILE}"
}

run() {
  if [[ ${DRY_RUN} == true ]]; then
    printf '[dry] %s\n' "$*"
    return 0
  fi
  "$@"
}

run_capture() {
  local outfile="$1"; shift
  if [[ ${DRY_RUN} == true ]]; then
    printf '[dry] capture %s <= %s\n' "${outfile}" "$*"
    return 0
  fi
  "$@" > "${outfile}" 2>&1
}

backup_target() {
  local target="$1" rel backup
  [[ -e ${target} || -L ${target} ]] || return 1
  rel="${target#/}"
  backup="${BACKUP_DIR}/${rel}"
  mkdir -p -- "$(dirname -- "${backup}")"
  cp -a -- "${target}" "${backup}"
  printf '%s\n' "${backup}"
}

files_equal() {
  local src="$1" dst="$2"
  [[ -f ${src} && -f ${dst} ]] || return 1
  cmp -s -- "${src}" "${dst}"
}

dirs_equal() {
  local src="$1" dst="$2"
  [[ -d ${src} && -d ${dst} ]] || return 1
  diff -qr -- "${src}" "${dst}" >/dev/null 2>&1
}

copy_path() {
  local src="$1" dst="$2"
  if [[ -d ${src} ]]; then
    mkdir -p -- "${dst}"
    if [[ ${RESTORE_PURGE} == true ]]; then
      rsync -a --delete -- "${src}/" "${dst}/"
    else
      rsync -a -- "${src}/" "${dst}/"
    fi
  else
    mkdir -p -- "$(dirname -- "${dst}")"
    cp -a -- "${src}" "${dst}"
  fi
}

restore_path() {
  local script="$1" category="$2" item="$3" src="$4" dst="$5" mode="${6:-}" owner="${7:-}" group="${8:-}"
  local backup="" changed_note="restored"

  if [[ ! -e ${src} && ! -L ${src} ]]; then
    report "${script}" "${category}" "${item}" "restore" "skipped" "source missing: ${src}" ""
    return 0
  fi

  if [[ -f ${src} && -f ${dst} ]] && files_equal "${src}" "${dst}"; then
    if [[ -z ${mode} && -z ${owner} && -z ${group} ]]; then
      report "${script}" "${category}" "${item}" "restore" "ok" "already up to date" ""
      return 0
    fi
    changed_note="metadata normalized"
  fi

  if [[ -d ${src} && -d ${dst} ]] && dirs_equal "${src}" "${dst}"; then
    if [[ -z ${mode} && -z ${owner} && -z ${group} ]]; then
      report "${script}" "${category}" "${item}" "restore" "ok" "already up to date" ""
      return 0
    fi
    changed_note="metadata normalized"
  fi

  if [[ -e ${dst} || -L ${dst} ]]; then
    if [[ ${DRY_RUN} == true ]]; then
      backup="${BACKUP_DIR}/${dst#/}"
      printf '[dry] backup %s -> %s\n' "${dst}" "${backup}"
    else
      backup="$(backup_target "${dst}")"
    fi
  fi

  if [[ ${DRY_RUN} == true ]]; then
    printf '[dry] restore %s -> %s\n' "${src}" "${dst}"
    [[ -n ${mode} ]]  && printf '[dry] chmod %s %s\n' "${mode}" "${dst}"
    [[ -n ${owner} ]] && printf '[dry] chown -R %s%s %s\n' "${owner}" "${group:+:${group}}" "${dst}"
  else
    if [[ "${changed_note}" == "metadata normalized" ]]; then
      :
    else
      copy_path "${src}" "${dst}"
    fi
    [[ -n ${mode} ]]  && chmod "${mode}" -- "${dst}" 2>/dev/null || true
    [[ -n ${owner} ]] && chown -R "${owner}${group:+:${group}}" -- "${dst}" 2>/dev/null || true
  fi

  report "${script}" "${category}" "${item}" "restore" "changed" "${changed_note}" "${backup}"
  return 0
}

prompt_yes_no() {
  local prompt="$1" default="${2:-no}" answer=""
  if [[ ${ASSUME_YES} == true ]]; then
    return 0
  fi
  case "${default}" in
    yes) read -r -p "${prompt} [Y/n]: " answer ;;
    no)  read -r -p "${prompt} [y/N]: " answer ;;
    *)   read -r -p "${prompt} [y/n]: " answer ;;
  esac
  answer="${answer:-${default}}"
  [[ ${answer} =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

list_from_file() {
  local f="$1"
  [[ -f ${f} ]] || return 0
  grep -Ev '^(#|$)' "${f}"
}

apt_install_if_missing() {
  local pkgs=() pkg
  for pkg in "$@"; do
    dpkg -s -- "${pkg}" >/dev/null 2>&1 || pkgs+=("${pkg}")
  done
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  if [[ ${DRY_RUN} == true ]]; then
    printf '[dry] apt-get install -y --no-install-recommends %s\n' "${pkgs[*]}"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
  fi
}

systemctl_safe_enable() {
  local unit="$1"
  if ! systemctl list-unit-files --type=service --type=target --type=timer --type=socket | awk '{print $1}' | grep -qx -- "${unit}"; then
    return 1
  fi
  run systemctl enable "${unit}"
}

systemctl_safe_start() {
  local unit="$1"
  if ! systemctl list-unit-files --type=service --type=target --type=timer --type=socket | awk '{print $1}' | grep -qx -- "${unit}"; then
    return 1
  fi
  run systemctl restart "${unit}"
}

validate_sshd()    { have_cmd sshd && sshd -t; }
validate_nginx()   { have_cmd nginx && nginx -t; }
validate_nft()     { [[ -f /etc/nftables.conf ]] && have_cmd nft && nft -c -f /etc/nftables.conf; }
validate_unbound() { have_cmd unbound-checkconf && unbound-checkconf; }
validate_dnsmasq() { have_cmd dnsmasq && dnsmasq --test; }
validate_postfix() { have_cmd postfix && postfix check; }
validate_mariadb() { have_cmd mariadbd && mariadbd --verbose --help >/dev/null 2>&1; }

service_is_active() {
  systemctl is-active --quiet "$1"
}

service_is_enabled() {
  systemctl is-enabled --quiet "$1"
}

detect_virtualization() {
  if have_cmd systemd-detect-virt; then
    systemd-detect-virt || true
  else
    true
  fi
}

primary_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

primary_src_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

has_default_route() {
  ip route show default | grep -q .
}

can_reach_ip() {
  local ip="$1"
  ping -c1 -W3 "${ip}" >/dev/null 2>&1
}

can_resolve_name() {
  local name="$1"
  getent ahostsv4 "${name}" >/dev/null 2>&1
}

guess_dns_owner() {
  if service_is_active unbound 2>/dev/null && service_is_active dnsmasq 2>/dev/null; then
    printf 'chain\n'
  elif service_is_active unbound 2>/dev/null; then
    printf 'unbound\n'
  elif service_is_active dnsmasq 2>/dev/null; then
    printf 'dnsmasq\n'
  elif service_is_active systemd-resolved 2>/dev/null; then
    printf 'resolved\n'
  else
    printf 'unknown\n'
  fi
}

role_allows_identities() {
  [[ ${ROLE} == replacement ]]
}

role_allows_overlay() {
  [[ ${ROLE} == replacement || ${ROLE} == hardware ]]
}

mark_manual() {
  local script="$1" category="$2" item="$3" note="$4"
  report "${script}" "${category}" "${item}" "manual" "manual" "${note}" ""
}

note_failure() {
  local script="$1" category="$2" item="$3" action="$4" note="$5" backup="${6:-}"
  report "${script}" "${category}" "${item}" "${action}" "failed" "${note}" "${backup}"
}
