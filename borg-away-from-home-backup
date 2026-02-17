#!/bin/bash
set -euo pipefail

REPO="borg@sanctum-wg:/tank/backups/borg"
NAME="home-$(date +%F_%H-%M)"
SRC="/home/lukasz"

export BORG_RSH="ssh -p 57385 -i $HOME/.ssh/sacrum.key -o IdentitiesOnly=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

LOGDIR="$HOME/.local/state/borg"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/backup-$(date +%F).log"

ARGS=(--compression lz4 --exclude-from "$HOME/.config/borg/excludes")
if [ -t 1 ]; then
  ARGS+=(--progress --list --stats)
else
  ARGS+=(--stats)
fi

borg create "${ARGS[@]}" "$REPO"::"$NAME" "$SRC" 2>&1 | tee -a "$LOGFILE"

