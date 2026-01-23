#!/bin/bash
set -euo pipefail

REPO="borg@192.168.33.5:/tank/backups/borg"
NAME="home-$(date +%F_%H-%M)"
SRC="/home/lukasz"

export BORG_RSH="ssh -p 57385 -i $HOME/.ssh/sacrum.key -o IdentitiesOnly=yes"

LOGDIR="$HOME/.local/state/borg"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/backup-$(date +%F).log"

# Show progress if stdout is a terminal (manual run)
ARGS=(--compression lz4 --exclude-from "$HOME/.config/borg/excludes")
if [ -t 1 ]; then
  ARGS+=(--progress --list --stats)
else
  ARGS+=(--stats)
fi

# Always log; show on screen when interactive
borg create "${ARGS[@]}" "$REPO"::"$NAME" "$SRC" 2>&1 | tee -a "$LOGFILE"

