#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

SCRIPT_NAME="lint-db.sh"
ISSUES=0

usage() {
  cat <<'USAGE'
Usage: sudo ./lint-db.sh [options]

Purpose:
  Non-destructively lint a rebuild DB for structural problems that can pollute
  restore results.

Checks:
  - backup directories captured into DB (e.g. *.bak.*)
  - nested duplicate service roots (e.g. nginx/nginx, i2pd/i2pd)
  - overlapping category roots (e.g. etc-i2pd plus sibling tunnels.d)
  - duplicate canonical files at two depths within the same category

Options:
  --db-dir PATH
  --verbose
  --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-dir) DB_DIR="$2"; PUBLIC_DIR="${DB_DIR}/db/public"; SECRET_DIR="${DB_DIR}/db/secret"; shift ;;
    --verbose) VERBOSE=true ;;
    --help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

load_optional_config
ensure_runtime_dirs

[[ -d "${PUBLIC_DIR}" ]] || die "public DB not found: ${PUBLIC_DIR}"

say()   { printf '%s\n' "$*"; }
warnx() { printf 'WARN  | %s\n' "$*"; ISSUES=1; }
okx()   { printf 'OK    | %s\n' "$*"; }

emit_section() {
  printf '\n%s\n' "$1"
}

find_matches() {
  local base="$1" pattern="$2"
  find "$base" -path "$pattern" -print 2>/dev/null | sort || true
}

check_backup_dirs() {
  local hits
  hits="$(find "${PUBLIC_DIR}" "${SECRET_DIR}" \
    -type d -name '*.bak.*' -print 2>/dev/null | sort || true)"

  if [[ -n "${hits}" ]]; then
    warnx "captured backup directories found"
    printf '%s\n' "${hits}"
  else
    okx "no captured backup directories found"
  fi
}

check_nested_duplicate_roots() {
  local name hits
  local names=(nginx i2pd grafana loki prometheus alloy tor postfix prosody mysql docker)

  for name in "${names[@]}"; do
    hits="$(find "${PUBLIC_DIR}" "${SECRET_DIR}" \
      -type d -path "*/${name}/${name}" -print 2>/dev/null | sort || true)"
    if [[ -n "${hits}" ]]; then
      warnx "nested duplicate root '${name}/${name}' found"
      printf '%s\n' "${hits}"
    fi
  done
}

check_overlapping_i2pd_capture() {
  local has_root=false has_tunnels=false has_tunnels_conf=false

  [[ -d "${PUBLIC_DIR}/i2pd/etc-i2pd" ]] && has_root=true
  [[ -e "${PUBLIC_DIR}/i2pd/tunnels.d" ]] && has_tunnels=true
  [[ -e "${PUBLIC_DIR}/i2pd/tunnels.conf" ]] && has_tunnels_conf=true

  if [[ "${has_root}" == true && ( "${has_tunnels}" == true || "${has_tunnels_conf}" == true ) ]]; then
    warnx "overlapping i2pd capture roots found (etc-i2pd plus sibling tunnels paths)"
    [[ -d "${PUBLIC_DIR}/i2pd/etc-i2pd" ]] && printf '%s\n' "${PUBLIC_DIR}/i2pd/etc-i2pd"
    [[ -e "${PUBLIC_DIR}/i2pd/tunnels.conf" ]] && printf '%s\n' "${PUBLIC_DIR}/i2pd/tunnels.conf"
    [[ -e "${PUBLIC_DIR}/i2pd/tunnels.d" ]] && printf '%s\n' "${PUBLIC_DIR}/i2pd/tunnels.d"
  else
    okx "no overlapping i2pd capture roots found"
  fi
}

check_duplicate_canonical_files() {
  emit_section "Duplicate canonical file checks"

  check_dup_pair() {
    local a="$1" b="$2" label="$3"
    local ha=false hb=false
    [[ -e "${a}" ]] && ha=true
    [[ -e "${b}" ]] && hb=true

    if [[ "${ha}" == true && "${hb}" == true ]]; then
      warnx "${label} exists at two depths"
      printf '%s\n%s\n' "${a}" "${b}"
    else
      okx "${label} not duplicated across checked depths"
    fi
  }

  check_dup_pair \
    "${PUBLIC_DIR}/prometheus/etc-prometheus/prometheus.yml" \
    "${PUBLIC_DIR}/prometheus/etc-prometheus/prometheus/prometheus.yml" \
    "prometheus.yml"

  check_dup_pair \
    "${PUBLIC_DIR}/loki/etc-loki/config.yml" \
    "${PUBLIC_DIR}/loki/etc-loki/loki/config.yml" \
    "loki config.yml"

  check_dup_pair \
    "${PUBLIC_DIR}/grafana/etc-grafana/grafana.ini" \
    "${PUBLIC_DIR}/grafana/etc-grafana/grafana/grafana.ini" \
    "grafana.ini"

  check_dup_pair \
    "${SECRET_DIR}/alloy/etc-alloy/config.alloy" \
    "${SECRET_DIR}/alloy/etc-alloy/alloy/config.alloy" \
    "alloy config.alloy"

  check_dup_pair \
    "${PUBLIC_DIR}/i2pd/etc-i2pd/i2pd.conf" \
    "${PUBLIC_DIR}/i2pd/etc-i2pd/i2pd/i2pd.conf" \
    "i2pd.conf"

  check_dup_pair \
    "${PUBLIC_DIR}/nginx/etc-nginx/nginx.conf" \
    "${PUBLIC_DIR}/nginx/etc-nginx/nginx/nginx.conf" \
    "nginx.conf"
}

emit_section "labunix/sanctum rebuild DB lint"
say "db: ${DB_DIR}"
say "public: ${PUBLIC_DIR}"
say "secret: ${SECRET_DIR}"

emit_section "Backup junk checks"
check_backup_dirs

emit_section "Nested duplicate root checks"
check_nested_duplicate_roots

emit_section "Overlapping capture-root checks"
check_overlapping_i2pd_capture

check_duplicate_canonical_files

emit_section "Summary"
if [[ ${ISSUES} -eq 0 ]]; then
  okx "no DB shape issues detected"
  exit 0
else
  warnx "DB shape issues detected"
  exit 1
fi
