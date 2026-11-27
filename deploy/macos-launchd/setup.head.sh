#!/bin/bash
# setup-gha-macos.sh — built by deploy/macos-launchd/build.sh; run on the Mac:
#   sudo bash setup-gha-macos.sh
#
# Sets up an ephemeral GitHub Actions runner fleet for the SkepticDogSoftware org,
# running as a hidden, non-admin user under launchd, via the same autoscaler
# scripts as the Linux fleet: one runner instance, taking one job at a time (the
# Mac also runs simulators and agent work, so it shares the machine lightly).
# gha-macos's shell and the launchd entry point are zsh; the fleet scripts
# themselves stay bash (they use bash arrays).
# Labels: self-hosted, macOS, ARM64, skeptic-macmini.
# Safe to re-run. Prompts for the GitHub token; never prints it.
set -euo pipefail

U=gha-macos
H=/Users/$U
FLEET=$H/fleet
LABEL=com.skepticdog.gha-fleet
PLIST=/Library/LaunchDaemons/$LABEL.plist
TOOL_PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

[ "$(uname -s)" = Darwin ] || { echo "macOS only"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

echo "== 0. prerequisites"
for b in curl git tar jq; do
  p=$(PATH=$TOOL_PATH command -v "$b" || true)
  [ -n "$p" ] || { echo "missing $b (install with: brew install $b), then re-run"; exit 1; }
  echo "$b: $p"
done
PATH=$TOOL_PATH command -v git-lfs >/dev/null || echo "note: git-lfs not found; jobs using actions/checkout lfs: true need 'brew install git-lfs'"

echo "== 1. user $U (standard, hidden, no admin)"
if ! id "$U" >/dev/null 2>&1; then
  PW=$(openssl rand -base64 24)
  sysadminctl -addUser "$U" -fullName "GitHub Actions runner" -password "$PW" -home "$H" -shell /bin/zsh 2>&1 | grep -v -i 'secure token' || true
  unset PW
  createhomedir -c -u "$U" >/dev/null
  dscl . create "/Users/$U" IsHidden 1
fi
dscl . create "/Users/$U" UserShell /bin/zsh
if dseditgroup -o checkmember -m "$U" admin >/dev/null 2>&1; then
  echo "ERROR: $U is an admin; refusing to continue"; exit 1
fi
chmod 750 "$H"
id "$U"

echo "== 2. GitHub token -> $H/.fleet.env (mode 600)"
if [ -s "$H/.fleet.env" ] && [ "${REPLACE_TOKEN:-0}" != 1 ]; then
  echo "keeping existing token (set REPLACE_TOKEN=1 to replace it)"
else
  read -rsp "Paste the GitHub token for SkepticDogSoftware runners: " PAT; echo
  [ -n "$PAT" ] || { echo "empty token"; exit 1; }
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $PAT" \
    https://api.github.com/orgs/SkepticDogSoftware/actions/runners)
  [ "$code" = 200 ] || { echo "token can't list SkepticDogSoftware runners (HTTP $code)"; exit 1; }
  ( umask 077
    printf 'GH_RUNNER_PAT=%s\nGH_RUNNER_ORG=SkepticDogSoftware\nGH_RUNNER_LABELS=skeptic-macmini\nGH_RUNNER_NAME_PREFIX=macmini-runner\n' "$PAT" > "$H/.fleet.env" )
  unset PAT
  chown "$U":staff "$H/.fleet.env"
fi

echo "== 3. fleet code -> $FLEET"
if [ -f "$FLEET/stop.sh" ]; then sudo -u "$U" -H "$FLEET/stop.sh" >/dev/null 2>&1 || true; fi
mkdir -p "$FLEET"
sed -n '/^__FLEET_TGZ_BASE64__$/,$p' "$0" | tail -n +2 | base64 -D | tar -xzf - -C "$FLEET"
printf 'MAX_RUNNERS=1\nMIN_IDLE=1\nPOLL_INTERVAL=15\n' > "$FLEET/scaler.properties"
cat > "$FLEET/launchd-start.sh" <<EOF
#!/bin/zsh
# Started by launchd ($LABEL). Loads the token and runs the autoscaler.
set -a; . "$H/.fleet.env"; set +a
export PATH=$TOOL_PATH
cd "$FLEET"
rm -f ./*.pid(N)
exec ./start.sh
EOF
chmod 755 "$FLEET/launchd-start.sh"
chown -R "$U":staff "$FLEET"

echo "== 4. launchd daemon $PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>UserName</key><string>$U</string>
  <key>GroupName</key><string>staff</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$FLEET/launchd-start.sh</string></array>
  <key>WorkingDirectory</key><string>$FLEET</string>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$H</string></dict>
  <key>RunAtLoad</key><true/>
  <!-- start.sh backgrounds the autoscaler and exits; keep its children alive -->
  <key>AbandonProcessGroup</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$FLEET/launchd.log</string>
  <key>StandardErrorPath</key><string>$FLEET/launchd.log</string>
</dict></plist>
EOF
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo "== 5. waiting for the runner to register (up to 3 min)"
for i in $(seq 1 36); do
  sleep 5
  grep -q 'Listening for Jobs' "$FLEET/runner-1.log" 2>/dev/null && break
done
for r in 1; do
  if grep -q 'Listening for Jobs' "$FLEET/runner-$r.log" 2>/dev/null; then echo "runner $r online"; else echo "runner $r not online yet; see $FLEET/runner-$r.log, autoscaler.log, launchd.log"; fi
done
echo "== done. Stop: sudo -u $U $FLEET/stop.sh   Restart: stop first, then sudo launchctl kickstart -k system/$LABEL"
exit 0
__FLEET_TGZ_BASE64__
