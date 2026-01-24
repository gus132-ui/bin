#!/usr/bin/env bash
set -euo pipefail

# ================= CONFIG =================
WG_CON="wg-sanctum"
SERVER_WG_IP="10.50.0.1"
SERVER_USER="lukasz"
SSH_PORT="57385"
SSH_KEY="$HOME/.ssh/sacrum.key"

# ================= HELPERS =================
log() { printf "\n==> %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

# ================= 1) RESTART WG =================
log "Restarting WireGuard connection: $WG_CON"

nmcli -t -f NAME con show | grep -Fxq "$WG_CON" \
  || die "NetworkManager connection '$WG_CON' not found"

nmcli con down "$WG_CON" >/dev/null 2>&1 || true
nmcli con up "$WG_CON"   >/dev/null

sleep 2

log "WireGuard status (host)"
sudo wg show "$WG_CON" || die "wg show failed"

# ================= 2) TEST WG =================
log "Testing WG reachability to server ($SERVER_WG_IP)"

if ! ping -c 2 -W 2 "$SERVER_WG_IP" >/dev/null; then
  die "WG ping failed (likely VPN/killswitch or routing issue)"
fi

log "WG ping OK"

# ================= 3) FIX SSH ON SERVER =================
log "Fixing SSH permissions on server (interactive, safe)"

ssh -tt -i "$SSH_KEY" -p "$SSH_PORT" \
  -o IdentitiesOnly=yes \
  "$SERVER_USER@$SERVER_WG_IP" \
  "set -e;
   USER_NAME='lukasz';
   HOME_DIR=\"/home/\$USER_NAME\";
   SSH_DIR=\"\$HOME_DIR/.ssh\";
   AUTH_KEYS=\"\$SSH_DIR/authorized_keys\";

   echo '-> Enforcing SSH directory invariants';
   sudo mkdir -p \"\$SSH_DIR\";
   sudo chown -R \"\$USER_NAME:\$USER_NAME\" \"\$SSH_DIR\";
   sudo chmod 700 \"\$SSH_DIR\";

   if [ -f \"\$AUTH_KEYS\" ]; then
     sudo chown \"\$USER_NAME:\$USER_NAME\" \"\$AUTH_KEYS\";
     sudo chmod 600 \"\$AUTH_KEYS\";
   fi;

   echo '-> Restarting sshd';
   sudo systemctl restart ssh;
  "

# ================= 4) FINAL VERIFICATION =================
log "Final SSH verification over WireGuard"

ssh -i "$SSH_KEY" -p "$SSH_PORT" \
  -o IdentitiesOnly=yes \
  "$SERVER_USER@$SERVER_WG_IP" \
  'echo "SSH OK via WireGuard"'

log "ALL FIXES APPLIED SUCCESSFULLY"

