#!/bin/bash
set -euo pipefail
# Run after packaging (and notarization, if configured). No credentials go in the app.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
release_tag="${1:?Usage: GenerateAppcast.sh v0.1.3}"
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
sparkle_bin="${SPARKLE_BIN:?Set SPARKLE_BIN to the Sparkle 2.10.0 bin directory}"
staging_path="$(mktemp -d "${TMPDIR:-/tmp}/couchremote-appcast.XXXXXX")"
trap 'rm -rf "$staging_path"' EXIT
cp "$project_root/dist/CouchRemoteWeb-macOS13-universal.dmg" "$staging_path/"
"$sparkle_bin/generate_appcast" --account couch-remote-web --maximum-deltas 0 \
    --download-url-prefix "https://github.com/barojins/couch-remote-web/releases/download/$release_tag/" \
    -o "$staging_path/appcast.xml" "$staging_path"
"$sparkle_bin/sign_update" --account couch-remote-web --verify "$staging_path/appcast.xml"
mkdir -p "$project_root/Updates"
cp "$staging_path/appcast.xml" "$project_root/Updates/appcast.xml"
(cd "$project_root/dist" && shasum -a 256 CouchRemoteWeb-macOS13-universal.dmg > SHA256SUMS.txt)
