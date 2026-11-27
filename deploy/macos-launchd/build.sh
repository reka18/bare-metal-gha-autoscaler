#!/bin/bash
# deploy/macos-launchd/build.sh — builds dist/setup-gha-macos.sh: setup.head.sh
# followed by this checkout's fleet code as a base64 tarball, so the Mac needs
# only the one file (no git or GitHub access to fetch the code).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$D/../.." && pwd)
OUT="$D/dist/setup-gha-macos.sh"
mkdir -p "$D/dist"
{ cat "$D/setup.head.sh"; tar -C "$ROOT" --exclude=.git --exclude=deploy -czf - . | openssl base64; } > "$OUT"
chmod 755 "$OUT"
bash -n "$OUT"
echo "$OUT"
shasum -a 256 "$OUT" 2>/dev/null || sha256sum "$OUT"
