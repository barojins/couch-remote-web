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
cat > "$staging_path/설치 안내.txt" <<'EOF'
Couch Remote Web — Mac + iPhone Safari

지원: macOS 13 이상, Intel 또는 Apple Silicon Mac.
1. CouchRemoteWeb 앱을 Applications 폴더로 드래그하세요.
2. Mac과 iPhone을 같은 신뢰할 수 있는 Wi-Fi에 연결하세요.
3. 앱을 열고 Accessibility 권한을 허용한 뒤 Start receiver를 누르세요.
4. iPhone 카메라로 QR 코드를 스캔하고 Safari에서 여세요.
5. Safari에서 바로 쓸 때는 두 코드를 비교하고 Trust this phone을 누르세요.
6. Safari의 공유 메뉴 → 홈 화면에 추가 → 웹 앱으로 열기를 켜세요.
   홈 화면 앱에서 처음 실행할 때 Mac의 First-time connection code
   8자리를 입력하고 코드를 비교한 뒤 Trust this phone을 누르세요.
   다음부터 저장된 승인으로 자동 재연결됩니다.
   이전 IP 주소 바로가기는 새 .local 주소의 QR로 한 번 다시 추가하세요.
7. Mac에서 Launch at login을 켜면 로그인할 때 수신기를 실행합니다.
   Trusted phones의 Forget으로 승인한 휴대폰을 철회할 수 있습니다.

iPhone 앱 설치나 개발자 멤버십은 필요하지 않습니다.
연결은 HTTP이며 암호화되지 않습니다. 개인용 신뢰 Wi-Fi에서만 사용하고
암호나 민감한 내용을 입력하지 마세요. 인터넷에 포트를 개방하지 마세요.

이 개인 테스트용 설치 파일은 Apple 공증을 받지 않았으므로
macOS에서 차단할 수 있습니다. 파일 출처를 확인하고 Apple 안내를 참고하세요.
https://support.apple.com/102445
EOF

mkdir -p "$project_root/dist"
hdiutil create -ov -volname 'Couch Remote Web' -srcfolder "$staging_path" \
    -format UDZO "$output_path"
hdiutil verify "$output_path"
printf '\nCreated: %s\n' "$output_path"
