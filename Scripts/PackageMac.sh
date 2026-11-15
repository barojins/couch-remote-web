#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_path="$project_root/build/distribution"
output_path="$project_root/dist/CouchRemoteWeb-macOS13-universal.dmg"
staging_path="$(mktemp -d "${TMPDIR:-/tmp}/couchremote-package.XXXXXX")"
trap 'rm -rf "$staging_path"' EXIT

# Ad-hoc by default; Developer ID release signing is explicit.
signing_identity="${SIGNING_IDENTITY:--}"
signing_flags=(CODE_SIGN_STYLE=Manual)
if [[ "$signing_identity" != "-" ]]; then
    [[ "$signing_identity" == "Developer ID Application:"* ]] || { echo 'Use a Developer ID Application identity.' >&2; exit 1; }
    signing_flags+=(ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp)
fi
xcodebuild -quiet -project "$project_root/CouchRemoteWeb.xcodeproj" \
    -scheme CouchRemoteWeb -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$build_path" \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="$signing_identity" "${signing_flags[@]}" build

app_path="$build_path/Build/Products/Release/CouchRemoteWeb.app"
codesign --verify --strict "$app_path"
architectures="$(lipo -archs "$app_path/Contents/MacOS/CouchRemoteWeb")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]
ditto "$app_path" "$staging_path/CouchRemoteWeb.app"
ln -s /Applications "$staging_path/Applications"
cat > "$staging_path/Installation.txt" <<'EOF'
Couch Remote Web — Mac + iPhone Safari

Requires macOS 13 or later on an Intel or Apple Silicon Mac.
1. Drag CouchRemoteWeb to Applications.
2. Connect the Mac and iPhone to the same trusted private Wi-Fi network.
3. Open the Mac app, grant Accessibility access, and choose Start receiver.
4. Scan the QR code with the iPhone camera and open it in Safari.
5. Compare the approval codes, then choose Trust this phone on the Mac.
   Approve each phone separately; multiple phones can remain connected.
6. For a full-screen remote, use Safari > Share > Add to Home Screen.
   Open the Home Screen icon and enter the Mac's 8-digit Connection code.
   Compare the approval codes and choose Trust this phone once.
   Future visits reconnect automatically using the saved approval.
   Replace old IP-address shortcuts with the current .local QR link.
7. Enable Launch at login to start the receiver when you sign in.
   Use Forget under Connected devices to revoke a phone's approval.

No iPhone app, Xcode, or developer membership is needed on the phone.
The connection uses unencrypted HTTP. Use trusted private Wi-Fi only.
Do not enter passwords or sensitive text, and do not forward the receiver
port to the internet.

The default personal test build is ad-hoc signed and is not Apple-notarized.
macOS may block its first launch. Verify the source and follow Apple's guidance:
https://support.apple.com/102445
EOF

mkdir -p "$project_root/dist"
hdiutil create -ov -volname 'Couch Remote Web' -srcfolder "$staging_path" \
    -format UDZO "$output_path"
hdiutil verify "$output_path"
printf '\nCreated: %s\n' "$output_path"
