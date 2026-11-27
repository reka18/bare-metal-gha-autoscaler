#!/bin/bash
# deploy/linux-systemd/setup.sh — run from a checkout:  sudo bash deploy/linux-systemd/setup.sh
#
# Installs one fleet as a system service running as a dedicated, unprivileged
# user, isolated from other fleets and from personal accounts on the host:
#   - user $FLEET_USER (locked password, no extra groups), own home and rustup
#   - code copied to /home/$FLEET_USER/fleet (no .git)
#   - token in /etc/$FLEET_USER/fleet.env, readable by root only; systemd loads it
#   - systemd unit $FLEET_SERVICE.service, NoNewPrivileges, enabled at boot
# Safe to re-run: keeps an existing token and scaler.properties.
#
# Settings (environment, all optional except where noted):
#   FLEET_USER      default gha-runner
#   FLEET_SERVICE   systemd unit name, default gha-fleet-$FLEET_USER
#   GH_RUNNER_ORG   required on first run
#   GH_RUNNER_LABELS, GH_RUNNER_CARGO_TARGET_BASE (see README)
#   JAVA_HOME       added to the service PATH if set
#   RUST_TOOLCHAINS space-separated toolchains to preinstall, e.g. "1.99.1"
#   HIDE_PATHS      space-separated paths the service may not access, e.g. other users' homes
set -euo pipefail

SRC=$(cd "$(dirname "$0")/../.." && pwd)
U=${FLEET_USER:-gha-runner}
H=/home/$U
FLEET=$H/fleet
ENV_DIR=/etc/$U
ENVF=$ENV_DIR/fleet.env
SVC=${FLEET_SERVICE:-gha-fleet-$U}
UNIT=/etc/systemd/system/$SVC.service

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

echo "== 1. user $U (no sudo/docker/adm groups, password locked)"
id "$U" >/dev/null 2>&1 || useradd --create-home --home-dir "$H" --shell /bin/bash --user-group "$U"
passwd -l "$U" >/dev/null
chmod 750 "$H"
id "$U"

echo "== 2. fleet code $SRC -> $FLEET"
install -d -o "$U" -g "$U" -m 750 "$FLEET"
rsync -a --exclude=.git --exclude=deploy --exclude=scaler.properties "$SRC"/ "$FLEET"/
[ -f "$FLEET/scaler.properties" ] || cp "$SRC/scaler.properties.example" "$FLEET/scaler.properties"
chown -R "$U:$U" "$FLEET"

echo "== 3. settings -> $ENVF (root-only; systemd reads it)"
install -d -o root -g root -m 700 "$ENV_DIR"
if [ ! -s "$ENVF" ]; then
  : "${GH_RUNNER_ORG:?set GH_RUNNER_ORG for the first run}"
  read -rsp "Paste the GitHub token for $GH_RUNNER_ORG runners: " PAT; echo
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $PAT" \
    "https://api.github.com/orgs/$GH_RUNNER_ORG/actions/runners")
  [ "$code" = 200 ] || { echo "token can't list $GH_RUNNER_ORG runners (HTTP $code)"; exit 1; }
  ( umask 077; printf 'GH_RUNNER_PAT=%s\nGH_RUNNER_ORG=%s\n' "$PAT" "$GH_RUNNER_ORG" > "$ENVF" )
  unset PAT
fi
for v in GH_RUNNER_LABELS GH_RUNNER_CARGO_TARGET_BASE; do
  if [ -n "${!v:-}" ] && ! grep -q "^$v=" "$ENVF"; then echo "$v=${!v}" >> "$ENVF"; fi
done
TBASE=$(sed -n 's/^GH_RUNNER_CARGO_TARGET_BASE=//p' "$ENVF")
[ -z "$TBASE" ] || install -d -o "$U" -g "$U" -m 750 "$TBASE"
sed 's/^GH_RUNNER_PAT=.*/GH_RUNNER_PAT=<hidden>/' "$ENVF"

echo "== 4. rustup for $U (own ~/.cargo and ~/.rustup)"
if [ ! -x "$H/.cargo/bin/rustup" ]; then
  sudo -u "$U" -H bash -c 'curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path'
fi
for t in ${RUST_TOOLCHAINS:-}; do sudo -u "$U" -H "$H/.cargo/bin/rustup" toolchain install "$t" --profile minimal; done

echo "== 5. systemd unit $UNIT"
SVC_PATH=$H/.cargo/bin:${JAVA_HOME:+$JAVA_HOME/bin:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
{
cat <<EOF
[Unit]
Description=GitHub Actions runner fleet (user $U)
Wants=network-online.target
After=network-online.target

[Service]
# oneshot rather than Restart=: supervision would undo a manual ./stop.sh.
Type=oneshot
RemainAfterExit=yes
User=$U
Group=$U
WorkingDirectory=$FLEET
EnvironmentFile=$ENVF
Environment=HOME=$H
Environment=PATH=$SVC_PATH
EOF
[ -z "${JAVA_HOME:-}" ] || echo "Environment=JAVA_HOME=$JAVA_HOME"
echo "NoNewPrivileges=yes"
[ -z "${HIDE_PATHS:-}" ] || echo "InaccessiblePaths=$HIDE_PATHS"
cat <<EOF
TimeoutStartSec=300
ExecStartPre=/bin/sh -c 'rm -f $FLEET/*.pid'
ExecStart=$FLEET/start.sh
ExecStop=$FLEET/stop.sh

[Install]
WantedBy=multi-user.target
EOF
} > "$UNIT"
systemctl daemon-reload
systemctl enable "$SVC.service"
systemctl restart "$SVC.service"
systemctl --no-pager status "$SVC.service" | head -6
