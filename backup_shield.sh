#!/usr/bin/env bash
set -euo pipefail

#################### CONFIG – EDIT THESE ####################

# LUKS2 block device
LUKS_DEVICE="/dev/disk/by-uuid/6659e638-d52a-4c32-9781-9dcedd44db35"

# Name for the mapper device (will appear as /dev/mapper/${LUKS_NAME})
LUKS_NAME="shield"

# Mount point for the decrypted filesystem
LUKS_MOUNTPOINT="/mnt/shield"

# Local folders to back up with rsync → LUKS volume
# Each folder will be mirrored into ${LUKS_MOUNTPOINT}/<basename-of-folder>
BACKUP_ITEMS=(
    "$HOME/"
    "/media/.secrets/"
)

# Machine identifier (destination subdir on the LUKS volume)
MACHINE_DIR="T480"

#################### INTERNALS – NO NEED TO EDIT ############

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }

cleanup() {
    echo
    echo ">>> Cleaning up..."

    # Try to unmount, if mounted
    if mountpoint -q "${LUKS_MOUNTPOINT}"; then
        echo ">>> Unmounting ${LUKS_MOUNTPOINT}..."
        sudo umount "${LUKS_MOUNTPOINT}" || true
    fi

    # Close LUKS mapping if it exists
    if [ -e "/dev/mapper/${LUKS_NAME}" ]; then
        echo ">>> Closing LUKS mapping ${LUKS_NAME}..."
        sudo cryptsetup close "${LUKS_NAME}" || true
    fi
}
trap cleanup EXIT

need_cmd cryptsetup
need_cmd rclone
need_cmd rsync
need_cmd mountpoint

# Cache sudo credentials early to avoid surprises mid-run
sudo -v

echo ">>> Ensuring mountpoint exists: ${LUKS_MOUNTPOINT}"
sudo mkdir -p "${LUKS_MOUNTPOINT}"

# Check if already open
if [ -e "/dev/mapper/${LUKS_NAME}" ]; then
    echo ">>> WARNING: /dev/mapper/${LUKS_NAME} already exists, assuming already open."
else
    echo ">>> Opening LUKS volume (interactive prompt)..."
    sudo cryptsetup open "${LUKS_DEVICE}" "${LUKS_NAME}"
fi

# At this point /dev/mapper/${LUKS_NAME} must exist
if [ ! -e "/dev/mapper/${LUKS_NAME}" ]; then
    echo "ERROR: /dev/mapper/${LUKS_NAME} not found after cryptsetup open." >&2
    exit 1
fi

# Mount if not already mounted
if mountpoint -q "${LUKS_MOUNTPOINT}"; then
    echo ">>> WARNING: ${LUKS_MOUNTPOINT} already mounted."
else
    echo ">>> Mounting /dev/mapper/${LUKS_NAME} on ${LUKS_MOUNTPOINT}..."
    sudo mount "/dev/mapper/${LUKS_NAME}" "${LUKS_MOUNTPOINT}"
fi

echo ">>> LUKS volume mounted at ${LUKS_MOUNTPOINT}"

# Ensure SharePoint destinations exist in root of shield
sudo mkdir -p \
  "${LUKS_MOUNTPOINT}/SP_Administration" \
  "${LUKS_MOUNTPOINT}/SP_Operations" \
  "${LUKS_MOUNTPOINT}/SP_Skyscale"

echo ">>> Starting rclone syncs (SharePoint -> ${LUKS_MOUNTPOINT}/SP_*)..."
rclone sync 'SP_Administration:' "${LUKS_MOUNTPOINT}/SP_Administration" --create-empty-src-dirs --fast-list --progress
rclone sync 'SP_Operations:'    "${LUKS_MOUNTPOINT}/SP_Operations"    --create-empty-src-dirs --fast-list --progress
rclone sync 'SP_SkyscaleCommerce:'      "${LUKS_MOUNTPOINT}/SP_Skyscale"      --create-empty-src-dirs --fast-list --progress
echo ">>> All rclone syncs finished."

echo ">>> Starting rsync backups of local folders -> ${LUKS_MOUNTPOINT}/${MACHINE_DIR}/..."

# Ensure machine root exists
sudo mkdir -p "${LUKS_MOUNTPOINT}/${MACHINE_DIR}"

# Explicit destination mapping while keeping your BACKUP_ITEMS sources as-is
# - "$HOME/"          -> /mnt/shield/T480/HOME
# - "/media/.secrets/"-> /mnt/shield/T480/secrets
for SRC in "${BACKUP_ITEMS[@]}"; do
    if [ ! -d "$SRC" ]; then
        echo ">>> WARNING: source folder does not exist, skipping: $SRC"
        continue
    fi

    case "$SRC" in
        "$HOME/"|"$HOME")
            RELDEST="${MACHINE_DIR}/HOME"
            ;;
        "/media/.secrets/"|"/media/.secrets")
            RELDEST="${MACHINE_DIR}/secrets"
            ;;
        *)
            # Fallback (shouldn't happen with your current BACKUP_ITEMS)
            # Note: basename "$SRC" with trailing slash becomes "home"; avoid relying on it.
            NAME="$(basename "${SRC%/}")"
            RELDEST="${MACHINE_DIR}/${NAME}"
            ;;
    esac

    DEST="${LUKS_MOUNTPOINT}/${RELDEST}"
    sudo mkdir -p "${DEST}"

    echo ">>> rsync: ${SRC} -> ${DEST}"
    rsync -a --delete --progress \
        "${SRC%/}/" \
        "${DEST}/"
done

echo ">>> All rsync backups finished."
echo ">>> Unmounting and closing LUKS (via trap)..."
# cleanup() will run automatically on script exit

