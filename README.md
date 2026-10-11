# Couch Remote Web

Mac 수신 앱 + iPhone Safari 리모컨. 같은 Wi-Fi에서 포인터 이동, 탭/더블탭, 두 손가락 우클릭/스크롤, 키보드 입력을 제공합니다. iPhone에 앱을 설치하거나 Apple 개발자 계정으로 서명할 필요가 없습니다.

별도 Bluetooth 네이티브 앱: [couch-remote-bluetooth](https://github.com/barojins/couch-remote-bluetooth).

## 설치와 연결

1. [Releases](https://github.com/barojins/couch-remote-web/releases)에서 Mac DMG를 내려받고 앱을 Applications로 드래그합니다. **macOS 13 이상**, Intel 또는 Apple Silicon Mac이 필요합니다. 소스만 빌드할 때 Xcode가 필요합니다.
2. 앱의 **Grant Accessibility access**를 누르고 시스템 설정에서 Couch Remote Web을 허용합니다. macOS가 로컬 네트워크 접근을 묻는 경우 허용합니다.
3. 두 기기를 같은 개인용 Wi-Fi에 연결하고 **Start receiver**를 누릅니다. 여러 주소가 있으면 iPhone과 같은 네트워크의 주소를 선택합니다.
4. iPhone 카메라로 QR을 읽고 Safari에서 엽니다. 양쪽 화면의 6자리 코드가 일치하는지 확인한 뒤 Mac에서 **Allow control**을 누릅니다.
5. 한 손가락으로 이동/탭/더블탭, 두 손가락으로 우클릭/스크롤합니다. Keyboard에서 텍스트를 입력하고 오른쪽 화살표로 전송합니다. Return, Backspace, 방향키 등도 제공합니다.

화면을 잠그거나 Safari/웹 앱을 떠나면 연결이 해제됩니다. 돌아온 뒤 Reconnect와 Mac 승인이 필요합니다. 새로고침이나 홈 화면에서 새로 실행할 때에는 Mac에 표시된 8자리 연결 코드를 입력할 수 있습니다. **New connection link**는 기존 연결과 링크를 폐기하고 **Stop receiver**는 서버를 닫습니다.

초기 릴리스의 DMG는 개인 테스트용 ad-hoc 서명이며 Apple 공증을 받지 않았습니다. macOS가 차단할 수 있습니다. 정식 Developer ID 서명/공증 절차는 [배포 안내](Docs/DISTRIBUTION.md)를 참고하세요. 비공개 저장소에 접근 가능한 계정만 릴리스를 다운로드할 수 있습니다.

## Safari 도구 막대 없이 사용하기

1. 먼저 QR로 Safari에서 리모컨을 엽니다.
2. Safari의 공유 메뉴 → **홈 화면에 추가(Add to Home Screen)** → **웹 앱으로 열기(Open as Web App)**를 켜고 추가합니다(iOS 26 기준).
3. 홈 화면의 Couch Remote 아이콘으로 실행합니다. Safari 주소창/도구 막대 없이 열립니다.
4. 연결 화면에서 Mac 앱의 **Home Screen connection code** 8자리를 입력합니다. 이어서 양쪽의 6자리 승인 코드가 일치하는지 확인하고 Mac에서 Allow control을 누릅니다.

키보드 버튼은 위쪽, 빈 트랙패드는 그 아래, 연결 상태는 아래쪽에 배치했습니다. Disconnect 버튼, 트랙패드의 그림/안내 문구, 별도 WI-FI 표시와 소개 문구를 제거했습니다. 홈 제스처 영역에서 거리를 확보했지만 iOS 시스템 제스처 자체를 막지는 않습니다.

앱은 서버 포트를 Mac에 저장해 재시작 후에도 같은 주소를 사용합니다. 이미 해당 포트를 쓰는 앱이 있으면 다른 Couch Remote Web 복사본을 종료하세요. 공유기가 Mac의 IP를 바꾸거나 다른 네트워크로 이동하면 QR을 다시 스캔하고 홈 화면 바로가기를 새로 추가해야 합니다. Mac 수신기는 실행 중이어야 하며 오프라인 사용은 지원하지 않습니다. QR 링크를 읽는 기존 방식도 유지됩니다.

연결 토큰은 메모리에만 보관합니다. 연결 코드는 사용 후 바뀌고 New connection link/Stop receiver에서도 교체됩니다. 코드 입력은 수신기 전체 기준 1분에 최대 5회로 제한되며 올바른 코드를 알아도 Mac 승인이 필요합니다. 홈 화면 바로가기는 영구 제어 권한을 저장하지 않습니다.

## 사용 범위와 보안

- **HTTP 연결이며 통신이 암호화되지 않습니다. 신뢰하는 개인용 Wi-Fi에서만 사용하고 암호/민감한 텍스트는 입력하지 마세요.** 공용 Wi-Fi, 외부 인터넷 공개, 공유기 포트 포워딩은 지원하지 않습니다. Bluetooth 버전과 보안 특성이 다릅니다.
- QR의 256비트 임시 토큰, Mac의 매 연결 승인, Accessibility 권한이 모두 필요합니다. 토큰과 입력을 디스크나 서버 로그에 저장하지 않습니다. QR 링크는 다른 사람에게 공유하지 마세요.
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

런타임 외부 의존성은 없습니다. Swift 테스트는 HTTP 파싱/크기 제한, 인증/Origin, 승인/권한, 만료, 원자적 명령 검증을 확인합니다. Node 테스트는 이동 소수점 누적, 두 손가락 제스처, 취소, 큐 병합을 확인합니다. CI는 두 테스트와 universal Mac 빌드를 실행합니다.

## 검증 현황

로컬 Swift 테스트 11개, JavaScript 테스트 4개 통과. macOS 앱 빌드 및 Safari에서 QR 링크의 연결 코드가 Mac과 일치하는 것, 승인 전 입력 차단, 외부 Origin/인증 없는 API의 403 거부를 확인했습니다. 기존 v0.1.1은 사용자가 Ventura에서 동작을 확인했습니다. 이번 홈 화면 실행/재접속과 터치 감각은 실제 iPhone에서 추가 확인해야 하며, Developer ID 공증은 아직 진행하지 않았습니다.

Ventura compatibility update: the Mac deployment target is macOS 13.0, and both Intel and Apple Silicon binaries were rebuilt and checked. The user confirmed v0.1.1 runs on Ventura. This update still needs real iPhone Home Screen testing; the current development Mac runs a newer macOS.


### Software updates

From version 1.0.3, use **Check for Updates…** in the Mac window or menu-bar
menu to download and install future releases without a GitHub login. Install
this version manually once if your current app has no update button. Both the
repository and release downloads are now public. Updates retain macOS 13
Ventura support on Intel and Apple Silicon. See [distribution](Docs/DISTRIBUTION.md)
for the signed-update publishing process.
