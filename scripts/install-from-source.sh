#!/bin/bash
# Builds devshout from this clone and installs it into /Applications. For anyone who would rather not run a
# downloaded app; most people want install.sh at the top of the repo instead.
#
#   scripts/install-from-source.sh
#
# Needs Xcode 26 (the full app, not just the Command Line Tools) and XcodeGen (`brew install xcodegen`).
set -euo pipefail

cd "$(dirname "$0")/.."
destination="${DEVSHOUT_INSTALL_DIR:-/Applications}"

fail() { echo "devshout: $1" >&2; exit 1; }

[ "$(uname -m)" = "arm64" ] || fail "an Apple silicon Mac is needed (M1 or later)."
if [ -z "${DEVELOPER_DIR:-}" ] && [ ! -d /Applications/Xcode.app ] \
    && [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
  fail "Xcode is needed to build (App Store → Xcode). The Command Line Tools alone can't build the app."
fi
command -v xcodegen >/dev/null || fail "XcodeGen is needed: brew install xcodegen"

echo "Building devshout (a few minutes the first time)…"
app="$(scripts/build-app.sh Release)"

# Only the copy being replaced: a build running from somewhere else is left alone.
if pgrep -f "$destination/devshout.app/" >/dev/null; then
  echo "Quitting the running devshout…"
  pkill -f "$destination/devshout.app/" || true
  sleep 1
fi

rm -rf "$destination/devshout.app"
ditto "$app" "$destination/devshout.app"
echo "Installed in $destination."

if [ -z "${DEVSHOUT_NO_OPEN:-}" ]; then
  open "$destination/devshout.app"
fi
