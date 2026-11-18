#!/bin/bash
# Installs the latest released devshout.app into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/patrickcollings/devshout/main/install.sh | bash
#
# Run it again to update. A download made by curl is not marked as "from the internet", so macOS opens the
# app without the "unidentified developer" block (the app is not notarised by Apple).
#
# For testing: DEVSHOUT_ZIP_URL (another zip, file:// works), DEVSHOUT_INSTALL_DIR (another folder),
# DEVSHOUT_NO_OPEN=1 (don't launch).
set -euo pipefail

repository="${DEVSHOUT_REPO:-patrickcollings/devshout}"
url="${DEVSHOUT_ZIP_URL:-https://github.com/$repository/releases/latest/download/devshout.zip}"
destination="${DEVSHOUT_INSTALL_DIR:-/Applications}"

fail() { echo "devshout: $1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this is a macOS app."
[ "$(uname -m)" = "arm64" ] || fail "an Apple silicon Mac is needed (M1 or later)."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "macOS 14 (Sonoma) or later is needed; this Mac has $(sw_vers -productVersion)."
[ -d "$destination" ] && [ -w "$destination" ] || fail "can't write to $destination."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading devshout…"
if ! curl -fL --progress-bar "$url" -o "$work/devshout.zip"; then
  # A private repository refuses anonymous downloads: the GitHub CLI can fetch it for someone with access.
  if [ -z "${DEVSHOUT_ZIP_URL:-}" ] && command -v gh >/dev/null; then
    echo "Trying the GitHub CLI…"
    gh release download --repo "$repository" --pattern devshout.zip --dir "$work" \
      || fail "couldn't download the release (is 'gh auth login' done, and do you have access to $repository?)"
  else
    fail "couldn't download $url"
  fi
fi
ditto -x -k "$work/devshout.zip" "$work/unpacked"
app="$work/unpacked/devshout.app"
[ -d "$app" ] || fail "the download doesn't contain devshout.app."
codesign --verify --deep --strict "$app" || fail "the downloaded app is damaged (its signature doesn't verify)."

# Only the copy being replaced: a build running from somewhere else is left alone.
if pgrep -f "$destination/devshout.app/" >/dev/null; then
  echo "Quitting the running devshout…"
  pkill -f "$destination/devshout.app/" || true
  sleep 1
fi

rm -rf "$destination/devshout.app"
ditto "$app" "$destination/devshout.app"
xattr -dr com.apple.quarantine "$destination/devshout.app" 2>/dev/null || true

version="$(defaults read "$destination/devshout.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Installed devshout $version in $destination."
echo "After an update, macOS may ask for Accessibility again: System Settings → Privacy & Security →"
echo "Accessibility, remove devshout with −, then add it back with +."

if [ -z "${DEVSHOUT_NO_OPEN:-}" ]; then
  open "$destination/devshout.app"
  echo "devshout is in the menu bar. Its set-up window walks you through the rest."
fi
