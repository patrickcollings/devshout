#!/bin/bash
# Builds devshout.app into build/ (git-ignored) and prints its path.
#
#   scripts/build-app.sh            # Debug
#   scripts/build-app.sh Release
#
# Signing: uses the "devshout-dev" code-signing certificate when the login keychain has one, so that macOS keeps
# the app's Microphone and Accessibility grants (and its Keychain access) across rebuilds. Without it the build
# is ad-hoc signed, and every rebuild looks like a new app to macOS. See CLAUDE.md for how to make the certificate.
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${1:-Debug}"
xcodegen generate --quiet

# Xcode resolves packages separately from SwiftPM: pin it to the versions Mac/ was built and tested with.
resolved="Devshout.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved"
cp Mac/Package.resolved "$resolved/Package.resolved"

log="build/xcodebuild.log"
mkdir -p build
if ! xcodebuild -project Devshout.xcodeproj -scheme Devshout -configuration "$configuration" \
    -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' \
    build >"$log" 2>&1; then
  grep -E "error:|BUILD FAILED" "$log" >&2 || tail -n 40 "$log" >&2
  echo "Build failed. Full log: $log" >&2
  exit 1
fi

app="build/DerivedData/Build/Products/$configuration/devshout.app"

# Xcode signs ad hoc (project.yml). Re-sign with the stable certificate afterwards: passing the identity to
# xcodebuild would also apply it to the packages' resource bundles, which then demand a development team.
identity="${DEVSHOUT_SIGN_IDENTITY:-devshout-dev}"
if security find-identity -p codesigning | grep -q "\"$identity\""; then
  codesign --force --deep --sign "$identity" "$app" 2>>"$log"
else
  echo "No \"$identity\" certificate found: left ad-hoc signed (permissions reset on every rebuild)." >&2
fi

echo "$app"
