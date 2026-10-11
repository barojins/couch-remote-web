# Couch Remote Web

Mac 수신 앱 + iPhone Safari 리모컨. 같은 Wi-Fi에서 포인터 이동, 탭/더블탭, 두 손가락 우클릭/스크롤, 키보드 입력을 제공합니다. iPhone에 앱을 설치하거나 Apple 개발자 계정으로 서명할 필요가 없습니다.

별도 Bluetooth 네이티브 앱: [couch-remote-bluetooth](https://github.com/barojins/couch-remote-bluetooth).

## 설치와 연결

1. [Releases](https://github.com/barojins/couch-remote-web/releases)에서 Mac DMG를 내려받고 앱을 Applications로 드래그합니다. **macOS 13 이상**, Intel 또는 Apple Silicon Mac이 필요합니다. 소스만 빌드할 때 Xcode가 필요합니다.
2. 앱의 **Grant Accessibility access**를 누르고 시스템 설정에서 Couch Remote Web을 허용합니다. macOS가 로컬 네트워크 접근을 묻는 경우 허용합니다.
3. 두 기기를 같은 개인용 Wi-Fi에 연결하고 **Start receiver**를 누릅니다. 여러 주소가 있으면 iPhone과 같은 네트워크의 주소를 선택합니다.
4. iPhone 카메라로 QR을 읽고 Safari에서 엽니다. 홈 화면 앱으로 사용할 경우 아래 절차로 먼저 추가하세요. 사용할 화면에서 양쪽 6자리 코드를 확인하고 Mac에서 **Trust this phone**을 한 번 누릅니다.
5. 한 손가락으로 이동/탭/더블탭, 두 손가락으로 우클릭/스크롤합니다. Keyboard에서 텍스트를 입력하고 오른쪽 화살표로 전송합니다. Return, Backspace, 방향키 등도 제공합니다.

화면을 잠그거나 떠나면 입력을 중단하며, 돌아오면 저장된 승인 정보로 자동 재접속합니다. 매번 코드를 입력하거나 Mac에서 승인할 필요가 없습니다. **Forget**은 해당 휴대폰의 승인을 철회합니다. **New connection link**는 임시 링크만 교체하며 이미 신뢰한 휴대폰은 유지합니다. **Stop receiver**는 서버를 닫고 자동 시작을 중지합니다.

초기 릴리스의 DMG는 개인 테스트용 ad-hoc 서명이며 Apple 공증을 받지 않았습니다. macOS가 차단할 수 있습니다. 정식 Developer ID 서명/공증 절차는 [배포 안내](Docs/DISTRIBUTION.md)를 참고하세요. 공개 릴리스는 GitHub 로그인 없이 다운로드할 수 있습니다.

## Safari 도구 막대 없이 사용하기

1. 먼저 QR로 Safari에서 리모컨을 엽니다.
2. Safari의 공유 메뉴 → **홈 화면에 추가(Add to Home Screen)** → **웹 앱으로 열기(Open as Web App)**를 켜고 추가합니다(iOS 26 기준).
3. 홈 화면의 Couch Remote 아이콘으로 실행합니다. Safari 주소창/도구 막대 없이 열립니다.
4. 연결 화면에서 Mac 앱의 **First-time connection code** 8자리를 입력합니다. 이어서 양쪽의 6자리 승인 코드가 일치하는지 확인하고 Mac에서 Trust this phone을 누릅니다. 이 홈 화면 앱에서 한 번 승인하면 다음부터 자동 연결됩니다.

키보드 버튼은 위쪽, 빈 트랙패드는 그 아래, 연결 상태는 아래쪽에 배치했습니다. Disconnect 버튼, 트랙패드의 그림/안내 문구, 별도 WI-FI 표시와 소개 문구를 제거했습니다. 홈 제스처 영역에서 거리를 확보했지만 iOS 시스템 제스처 자체를 막지는 않습니다.

앱은 서버 포트를 Mac에 저장해 재시작 후에도 같은 주소를 사용합니다. 이미 해당 포트를 쓰는 앱이 있으면 다른 Couch Remote Web 복사본을 종료하세요. 1.0.4부터 Mac의 Bonjour 이름(.local)과 저장된 포트를 사용합니다. 같은 LAN에서 IP가 바뀌면 수신기가 다시 바인딩합니다. 이전 IP 기반 홈 화면 바로가기는 새 QR로 한 번 다시 추가하세요. Mac 이름 변경 또는 Bonjour를 차단하는 네트워크에서는 주소가 더 이상 유효하지 않을 수 있습니다. Mac 수신기는 실행 중이어야 하며 오프라인 사용은 지원하지 않습니다. QR 링크를 읽는 기존 방식도 유지됩니다.

최초 승인 후 별도의 256비트 기기 토큰을 브라우저 localStorage에 저장하고 Mac에는 그 SHA-256 해시만 저장합니다. Safari와 홈 화면 앱은 저장소가 분리되므로 각각 최초 승인이 필요하며 사이트 데이터를 지우면 다시 승인해야 합니다. 입력 내용은 저장하지 않습니다. 초기 연결 코드는 사용 후 교체되고 1분에 최대 5회로 제한됩니다. Mac 앱은 Start receiver 이후 다시 실행하면 수신기를 자동 시작합니다. Launch at login을 켜면 로그인 때 앱을 열 수 있습니다.

## 사용 범위와 보안

- **HTTP 연결이며 통신이 암호화되지 않습니다. 신뢰하는 개인용 Wi-Fi에서만 사용하고 암호/민감한 텍스트는 입력하지 마세요.** 공용 Wi-Fi, 외부 인터넷 공개, 공유기 포트 포워딩은 지원하지 않습니다. Bluetooth 버전과 보안 특성이 다릅니다.
- QR/초기 코드만으로 입력을 실행할 수 없습니다. 최초 Mac 승인과 Accessibility 권한이 필요하고, 이후에는 저장된 기기 토큰을 확인합니다. 신뢰 해시는 Mac 설정에, 비밀 토큰은 브라우저 저장소에 남습니다. 공용/공유 휴대폰을 승인하지 말고 필요하면 Mac에서 Forget을 누르세요. HTTP에서 탈취된 토큰은 철회할 때까지 악용될 수 있으므로 신뢰 LAN에서만 사용합니다.
- 선택한 사설 IPv4 LAN 인터페이스에만 바인딩합니다. 클라우드/중계 서버/광고/분석 SDK는 없습니다. Host/Origin 검사, 명령 크기 제한, 한 기기 연결 제한, 연결 만료를 적용합니다. 이러한 검사는 암호화를 대신하지 않으며 같은 네트워크의 도청·변조를 막지 못합니다.
- 동작 속도는 Wi-Fi 지연과 Safari 이벤트 처리에 영향을 받습니다. Apple 트랙패드와 동일한 반응, 시스템 다중 손가락 제스처, 드래그는 지원 범위에 포함되지 않습니다.
- macOS 13 미만, IPv6 전용 네트워크, 기기끼리 접근을 차단하는 게스트 Wi-Fi는 지원하지 않습니다. iPhone Safari 실기기 검증은 필요합니다.

## 개발

Xcode 프로젝트를 열어 CouchRemoteWeb scheme을 실행합니다. 프로젝트 파일을 포함하므로 XcodeGen은 필수가 아닙니다. project.yml을 수정하면 `xcodegen generate`로 다시 생성합니다.

```sh
swift test
npm test
bash Scripts/PackageMac.sh
```

Mac 소프트웨어 업데이트는 Sparkle를 사용합니다. Swift 테스트는 HTTP 파싱/크기 제한, 인증/Origin, 승인/권한, 만료, 원자적 명령 검증을 확인합니다. Node 테스트는 이동 소수점 누적, 두 손가락 제스처, 취소, 큐 병합을 확인합니다. CI는 두 테스트와 universal Mac 빌드를 실행합니다.

## 검증 현황

Swift 테스트 16개와 JavaScript 테스트 8개로 인증, 승인 저장/철회, 재시작, 페이지 숨김/복귀, 네트워크 재시도와 기존 입력 처리를 검증합니다. macOS universal 빌드와 로컬 .local 주소 응답을 확인합니다. 실제 iPhone 홈 화면 및 Ventura에서의 잠금/해제와 공유기 재연결은 추가 실기기 확인이 필요합니다. Apple 공증은 아직 진행하지 않았습니다.

Ventura compatibility update: the Mac deployment target is macOS 13.0, and both Intel and Apple Silicon binaries were rebuilt and checked. The user confirmed v0.1.1 runs on Ventura. This update still needs real iPhone Home Screen testing; the current development Mac runs a newer macOS.


### Software updates

From version 1.0.3, use **Check for Updates…** in the Mac window or menu-bar
menu to download and install future releases without a GitHub login. Install
this version manually once if your current app has no update button. Both the
repository and release downloads are now public. Updates retain macOS 13
Ventura support on Intel and Apple Silicon. See [distribution](Docs/DISTRIBUTION.md)
for the signed-update publishing process.
