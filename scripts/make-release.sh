#!/bin/bash
# Builds the Release app, zips it and publishes it as a GitHub release, which is what install.sh downloads.
#
#   scripts/make-release.sh            # build build/devshout.zip only
#   scripts/make-release.sh --publish  # …and create the GitHub release v<version>
#
# The version is CFBundleShortVersionString in project.yml: bump it there first. Built on a developer's Mac
# rather than in CI because macOS CI minutes are scarce. The app is signed with the "devshout-dev" certificate
# when there is one (see scripts/build-app.sh); it is not notarised.
set -euo pipefail

cd "$(dirname "$0")/.."
version="$(sed -n 's/.*CFBundleShortVersionString: *"\(.*\)".*/\1/p' project.yml)"
[ -n "$version" ] || { echo "No CFBundleShortVersionString in project.yml." >&2; exit 1; }
tag="v$version"

if [ "${1:-}" = "--publish" ]; then
  [ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first." >&2; exit 1; }
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "Releases are made from main." >&2; exit 1; }
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || gh release view "$tag" >/dev/null 2>&1; then
    echo "$tag already exists: bump CFBundleShortVersionString in project.yml." >&2
    exit 1
  fi
fi

app="$(scripts/build-app.sh Release)"
codesign --verify --deep --strict "$app"

zip="build/devshout.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip ($(du -h "$zip" | cut -f1 | tr -d ' '))"

if [ "${1:-}" = "--publish" ]; then
  gh release create "$tag" "$zip" --title "devshout $version" --generate-notes
fi
