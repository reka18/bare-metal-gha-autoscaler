#!/bin/bash
# deploy/linux-systemd/update.sh — run from a checkout:
#   sudo FLEET_USER=gha-runner [FLEET_SERVICE=name] bash deploy/linux-systemd/update.sh [--restart-now]
# Copies this checkout's scripts into /home/$FLEET_USER/fleet, leaving
# scaler.properties, runner directories, logs and .machine-id alone.
# Restarts the fleet only when no job is running (or with --restart-now,
# which cancels running jobs).
set -euo pipefail
SRC=$(cd "$(dirname "$0")/../.." && pwd)
U=${FLEET_USER:-gha-runner}
SVC=${FLEET_SERVICE:-gha-fleet-$U}
FLEET=/home/$U/fleet
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -d "$FLEET" ] || { echo "no fleet at $FLEET; run setup.sh first"; exit 1; }

# rsync writes each file to a temp name and renames it, so the bash processes
# running the old scripts keep reading their old copies until restart.
rsync -a --exclude=.git --exclude=deploy --exclude=scaler.properties "$SRC"/ "$FLEET"/
chown -R "$U:$U" "$FLEET"
echo "code updated from $SRC ($(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"

if [ "${1:-}" != "--restart-now" ] && pgrep -u "$U" -f "$FLEET/actions-runner-[0-9]+/bin[^/]*/Runner.Worker" >/dev/null; then
  echo "jobs running, not restarting. Re-run with --restart-now when idle (that cancels running jobs)."
  pgrep -u "$U" -af "Runner.Worker" | cut -c1-120
  exit 0
fi
systemctl restart "$SVC.service"
systemctl --no-pager status "$SVC.service" | sed -n 3p
