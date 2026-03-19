#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

SCRIPT_NAME="doctor.sh"
STRICT=false
OUTFILE=""

usage() {
  cat <<USAGE
Usage: sudo ./doctor.sh [options]

Purpose:
  Read-only health and readiness checks for a rebuilt sanctum/labunix host.

Options:
  --db-dir PATH
  --role lab|hardware|replacement
  --strict            Exit non-zero if any FAIL is found
  --output PATH       Write human report to this path
  --dry-run           Still read-only; only affects report/state writes
  --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-dir) DB_DIR="$2"; PUBLIC_DIR="${DB_DIR}/db/public"; SECRET_DIR="${DB_DIR}/db/secret"; shift ;;
    --role) ROLE="$2"; shift ;;
    --strict) STRICT=true ;;
    --output) OUTFILE="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
    --help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

ensure_root
load_optional_config
ensure_runtime_dirs
require_cmd ip systemctl ss awk sed grep

OUTFILE="${OUTFILE:-${LOG_DIR}/doctor-${RUN_ID}.txt}"
: > "${OUTFILE}"

FAILS=0
WARNS=0
OKS=0
MANUALS=0

emit() {
  printf '%s\n' "$*" | tee -a "${OUTFILE}"
}

ok_line() {
  ((OKS+=1))
  emit "OK    | $1"
  report "${SCRIPT_NAME}" doctor "$1" check ok "$1" ""
}
warn_line() {
  ((WARNS+=1))
  emit "WARN  | $1"
  report "${SCRIPT_NAME}" doctor "$1" check warn "$1" ""
}
fail_line() {
  ((FAILS+=1))
  emit "FAIL  | $1"
  report "${SCRIPT_NAME}" doctor "$1" check failed "$1" ""
}
manual_line() {
  ((MANUALS+=1))
  emit "MANUAL| $1"
  report "${SCRIPT_NAME}" doctor "$1" manual manual "$1" ""
}

service_report() {
  local svc="$1"
  local unit="$svc"
  local load active enabled

  [[ "${unit}" == *.* ]] || unit="${unit}.service"

  load="$(systemctl show -P LoadState "${unit}" 2>/dev/null || true)"
  if [[ -z "${load}" || "${load}" == "not-found" ]]; then
    warn_line "service ${unit} not installed"
    return 0
  fi

  active="$(systemctl show -P ActiveState "${unit}" 2>/dev/null || true)"
  enabled="$(systemctl show -P UnitFileState "${unit}" 2>/dev/null || true)"

  if [[ "${active}" == "active" ]]; then
    ok_line "service ${unit} active (${enabled})"
  else
    warn_line "service ${unit} ${active:-unknown} (${enabled:-unknown})"
  fi
}

emit "labunix/sanctum rebuild doctor"
emit "timestamp: $(now_iso)"
emit "role: ${ROLE}"
emit "db: ${DB_DIR}"
emit ""

virt="$(detect_virtualization)"
if [[ -n ${virt} ]]; then
  warn_line "virtualization detected: ${virt}"
else
  ok_line "bare metal or virtualization not detected"
fi

current_host="$(hostname -s 2>/dev/null || true)"
captured_host="$(head -n1 "${PUBLIC_DIR}/system/etc-hostname" 2>/dev/null || true)"
if [[ -n ${captured_host} && ${current_host} == ${captured_host} ]]; then
  ok_line "hostname matches DB (${current_host})"
elif [[ -n ${captured_host} ]]; then
  warn_line "hostname differs: current=${current_host} captured=${captured_host}"
else
  warn_line "captured hostname not found in DB"
fi

if has_default_route; then
  ok_line "default route present"
else
  fail_line "no default route"
fi

iface="$(primary_iface)"
src_ip="$(primary_src_ip)"
[[ -n ${iface} ]] && ok_line "primary route uses iface=${iface} src=${src_ip}" || fail_line "could not determine primary interface via ip route get 1.1.1.1"

if can_reach_ip 1.1.1.1; then
  ok_line "outbound IP reachability to 1.1.1.1"
else
  fail_line "cannot reach 1.1.1.1"
fi

if can_resolve_name deb.debian.org; then
  ok_line "DNS resolves deb.debian.org"
else
  fail_line "DNS resolution failed for deb.debian.org"
fi

owner="$(guess_dns_owner)"
case "${owner}" in
  resolved) ok_line "DNS owner appears to be systemd-resolved" ;;
  dnsmasq)  ok_line "DNS owner appears to be dnsmasq" ;;
  unbound)  ok_line "DNS owner appears to be unbound" ;;
  chain)    warn_line "DNS owner appears chained (dnsmasq + unbound); verify port ownership intentionally" ;;
  *)        warn_line "DNS owner unclear" ;;
esac

failed_units="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
if [[ -z ${failed_units} ]]; then
  ok_line "no failed systemd units"
else
  fail_line "failed units present: $(echo "${failed_units}" | paste -sd, -)"
fi

# Config validators
have_cmd sshd && validate_sshd && ok_line "sshd config validates" || warn_line "sshd config validation failed or sshd missing"
have_cmd nginx && validate_nginx && ok_line "nginx config validates" || warn_line "nginx config validation failed or nginx missing"
have_cmd nft && [[ -f /etc/nftables.conf ]] && validate_nft && ok_line "nftables config validates" || warn_line "nftables config validation failed or /etc/nftables.conf missing"
have_cmd unbound-checkconf && validate_unbound && ok_line "unbound config validates" || warn_line "unbound config validation failed or unbound missing"
have_cmd dnsmasq && validate_dnsmasq && ok_line "dnsmasq config validates" || warn_line "dnsmasq config validation failed or dnsmasq missing"
have_cmd postfix && validate_postfix && ok_line "postfix config validates" || warn_line "postfix config validation failed or postfix missing"

emit ""
emit "Service snapshot"
service_report ssh
service_report systemd-resolved
service_report dnsmasq
service_report unbound
service_report nftables
service_report nginx
service_report mariadb
service_report postfix
service_report prosody
service_report docker
service_report prometheus
service_report grafana-server
service_report tor
service_report i2pd

emit ""
emit "Listening ports snapshot"
ss -tlnp 2>/dev/null | tee -a "${OUTFILE}" >/dev/null || true

if have_cmd docker; then
  emit ""
  emit "Docker snapshot"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | tee -a "${OUTFILE}" >/dev/null || warn_line "docker present but docker ps failed"
fi

if [[ -d ${PUBLIC_DIR}/docker/compose-redacted || -d ${SECRET_DIR}/docker/compose-full ]]; then
  local_count="$(find /srv /opt /home /root -maxdepth 4 \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null | wc -l | tr -d ' ')"
  ok_line "compose files found locally: ${local_count}"
fi

if [[ -f /etc/resolv.conf ]]; then
  emit ""
  emit "/etc/resolv.conf"
  sed -n '1,20p' /etc/resolv.conf | tee -a "${OUTFILE}" >/dev/null || true
fi

if [[ -f ${STATE_DIR}/state-${RUN_ID}.env ]]; then
  manual_line "current run state file: ${STATE_DIR}/state-${RUN_ID}.env"
fi

emit ""
emit "Summary: ok=${OKS} warn=${WARNS} fail=${FAILS} manual=${MANUALS}"

set_state doctor_done true
report "${SCRIPT_NAME}" run finish exit ok "ok=${OKS}; warn=${WARNS}; fail=${FAILS}; manual=${MANUALS}" ""

if [[ ${STRICT} == true && ${FAILS} -gt 0 ]]; then
  exit 1
fi
