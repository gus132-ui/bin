#!/usr/bin/env bash
set -euo pipefail

#################### CONFIG ####################

# LUKS2 container UUID (LUKS header UUID)
LUKS_SOURCE="/dev/disk/by-uuid/bdd2a016-b6db-493d-ad0a-e8dd8a93dfbd"

# Name for /dev/mapper/<name>
MAPPER_NAME="usb_safe"

# Mountpoint for decrypted filesystem
MOUNTPOINT="/mnt/usb_safe"

# Optional underlying block device for power-off (set "" to disable)
RAW_DEVICE=""

# Items to mirror from $HOME to the encrypted drive (files and directories)
BACKUP_ITEMS=(
  "$HOME/.abook"
  "$HOME/.config"
  "$HOME/Documents"
  "$HOME/dotfiles"
  "$HOME/.password-store"
  "$HOME/secure"
  "$HOME/vimwiki"
  "$HOME/.password.tomb"
  "$HOME/.secrets.tomb"
)

RSYNC_OPTS=(
  -a
  --delete
  --no-perms
  --no-owner
  --no-group
  --no-xattrs
  --omit-dir-times
  --progress
)

LOGFILE="$HOME/backup_flash_rsync.log"

#################### HELPERS ####################

die() { echo "ERROR: $*" >&2; exit 1; }

is_mapper_open() { [[ -e "/dev/mapper/${MAPPER_NAME}" ]]; }
is_mounted()     { mountpoint -q "${MOUNTPOINT}"; }

busy_report() {
  echo ">>> Busy report for ${MOUNTPOINT}:"
  echo ">>> lsof:"
  sudo lsof +f -- "${MOUNTPOINT}" || true
  echo ">>> fuser:"
  sudo fuser -vm "${MOUNTPOINT}" || true
}

cleanup() {
  set +e

  if is_mounted; then
    echo ">>> Unmounting ${MOUNTPOINT}..."
    sudo umount "${MOUNTPOINT}" || {
      echo ">>> Unmount failed (device busy)."
      busy_report
      echo ">>> Last resort: sudo umount -l '${MOUNTPOINT}'"
    }
  fi

  if is_mapper_open; then
    echo ">>> Closing LUKS mapper ${MAPPER_NAME}..."
    sudo cryptsetup close "${MAPPER_NAME}" || true
  fi

  if [[ -n "${RAW_DEVICE}" ]]; then
    echo ">>> Powering off ${RAW_DEVICE}..."
    udisksctl power-off -b "${RAW_DEVICE}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

#################### OPEN + MOUNT ####################

echo ">>> Checking LUKS source exists: ${LUKS_SOURCE}"
[[ -e "${LUKS_SOURCE}" ]] || die "LUKS source not found: ${LUKS_SOURCE}"

echo ">>> Ensuring mountpoint exists: ${MOUNTPOINT}"
sudo mkdir -p "${MOUNTPOINT}"

is_mounted     && die "Mountpoint already in use: ${MOUNTPOINT}"
is_mapper_open && die "Mapper already open: /dev/mapper/${MAPPER_NAME}"

echo ">>> Opening LUKS2 container (prompt for passphrase)..."
sudo cryptsetup open --type luks2 "${LUKS_SOURCE}" "${MAPPER_NAME}"

echo ">>> Mounting decrypted filesystem..."
sudo mount "/dev/mapper/${MAPPER_NAME}" "${MOUNTPOINT}"

echo ">>> Mounted at ${MOUNTPOINT}"
echo ">>> Logging rsync output to: ${LOGFILE}"
echo "[$(date)] Backup run started" >> "${LOGFILE}"

#################### RSYNC LOOP ####################

ANY_WARNING=0

for SRC in "${BACKUP_ITEMS[@]}"; do
  [[ -e "${SRC}" ]] || die "Missing source item: ${SRC}"

  NAME="$(basename "${SRC}")"
  DEST="${MOUNTPOINT}/${NAME}"

  echo ">>> rsync: ${SRC} -> ${DEST}"
  echo "[$(date)] rsync: ${SRC} -> ${DEST}" >> "${LOGFILE}"

  set +e
  if [[ -d "${SRC}" ]]; then
    rsync "${RSYNC_OPTS[@]}" "${SRC}/" "${DEST}/" 2>> "${LOGFILE}"
  else
    # file
    rsync "${RSYNC_OPTS[@]}" "${SRC}" "${DEST}" 2>> "${LOGFILE}"
  fi
  RS=$?
  set -e

  if [[ "${RS}" -eq 0 ]]; then
    echo ">>> rsync OK: ${SRC}"
    echo "[$(date)] rsync OK: ${SRC}" >> "${LOGFILE}"
  elif [[ "${RS}" -eq 23 || "${RS}" -eq 24 ]]; then
    echo ">>> WARNING: rsync non-critical issues (code ${RS}) for: ${SRC}"
    echo ">>> See ${LOGFILE}."
    echo "[$(date)] WARNING: rsync code ${RS} for: ${SRC}" >> "${LOGFILE}"
    ANY_WARNING=1
  else
    echo "[$(date)] ERROR: rsync failed code ${RS} for: ${SRC}" >> "${LOGFILE}"
    exit "${RS}"
  fi
done

echo ">>> Backup loop finished."
if [[ "${ANY_WARNING}" -eq 1 ]]; then
  echo ">>> Backup completed WITH WARNINGS. See ${LOGFILE}."
  echo "[$(date)] Backup completed WITH WARNINGS" >> "${LOGFILE}"
else
  echo ">>> Backup completed OK."
  echo "[$(date)] Backup completed OK" >> "${LOGFILE}"
fi

echo ">>> Syncing..."
sync

echo ">>> Done. (Auto-cleanup will unmount + close mapper.)"

