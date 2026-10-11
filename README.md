# Couch Remote Web

Mac 수신 앱 + iPhone Safari 리모컨. 같은 Wi-Fi에서 포인터 이동, 탭/더블탭, 두 손가락 우클릭/스크롤, 키보드 입력을 제공합니다. iPhone에 앱을 설치하거나 Apple 개발자 계정으로 서명할 필요가 없습니다.

별도 Bluetooth 네이티브 앱: [couch-remote-bluetooth](https://github.com/barojins/couch-remote-bluetooth).

## 설치와 연결

1. [Releases](https://github.com/barojins/couch-remote-web/releases)에서 Mac DMG를 내려받고 앱을 Applications로 드래그합니다. **macOS 14 이상**, Intel 또는 Apple Silicon Mac이 필요합니다. 소스만 빌드할 때 Xcode가 필요합니다.
2. 앱의 **Grant Accessibility access**를 누르고 시스템 설정에서 Couch Remote Web을 허용합니다. macOS가 로컬 네트워크 접근을 묻는 경우 허용합니다.
3. 두 기기를 같은 개인용 Wi-Fi에 연결하고 **Start receiver**를 누릅니다. 여러 주소가 있으면 iPhone과 같은 네트워크의 주소를 선택합니다.
4. iPhone 카메라로 QR을 읽고 Safari에서 엽니다. 양쪽 화면의 6자리 코드가 일치하는지 확인한 뒤 Mac에서 **Allow control**을 누릅니다.
5. 한 손가락으로 이동/탭/더블탭, 두 손가락으로 우클릭/스크롤합니다. Keyboard에서 텍스트를 입력하고 오른쪽 화살표로 전송합니다. Return, Backspace, 방향키 등도 제공합니다.

화면을 잠그거나 Safari를 떠나면 연결이 해제됩니다. 돌아온 뒤 Reconnect와 Mac 승인이 필요합니다. 새로고침/새 탭은 QR을 다시 스캔하세요. 홈 화면 북마크로 영구 자동 연결하는 기능은 없습니다. **New connection link**는 기존 연결과 링크를 폐기하고 **Stop receiver**는 서버를 닫습니다.

초기 릴리스의 DMG는 개인 테스트용 ad-hoc 서명이며 Apple 공증을 받지 않았습니다. macOS가 차단할 수 있습니다. 정식 Developer ID 서명/공증 절차는 [배포 안내](Docs/DISTRIBUTION.md)를 참고하세요. 비공개 저장소에 접근 가능한 계정만 릴리스를 다운로드할 수 있습니다.

## 사용 범위와 보안

- **HTTP 연결이며 통신이 암호화되지 않습니다. 신뢰하는 개인용 Wi-Fi에서만 사용하고 암호/민감한 텍스트는 입력하지 마세요.** 공용 Wi-Fi, 외부 인터넷 공개, 공유기 포트 포워딩은 지원하지 않습니다. Bluetooth 버전과 보안 특성이 다릅니다.
- QR의 256비트 임시 토큰, Mac의 매 연결 승인, Accessibility 권한이 모두 필요합니다. 토큰과 입력을 디스크나 서버 로그에 저장하지 않습니다. QR 링크는 다른 사람에게 공유하지 마세요.
- 선택한 사설 IPv4 LAN 인터페이스에만 바인딩합니다. 클라우드/중계 서버/광고/분석 SDK는 없습니다. Host/Origin 검사, 명령 크기 제한, 한 기기 연결 제한, 연결 만료를 적용합니다. 이러한 검사는 암호화를 대신하지 않으며 같은 네트워크의 도청·변조를 막지 못합니다.
- 동작 속도는 Wi-Fi 지연과 Safari 이벤트 처리에 영향을 받습니다. Apple 트랙패드와 동일한 반응, 시스템 다중 손가락 제스처, 드래그는 지원 범위에 포함되지 않습니다.
- macOS 14 미만, IPv6 전용 네트워크, 기기끼리 접근을 차단하는 게스트 Wi-Fi는 지원하지 않습니다. iPhone Safari 실기기 검증은 필요합니다.

## 개발

Xcode 프로젝트를 열어 CouchRemoteWeb scheme을 실행합니다. 프로젝트 파일을 포함하므로 XcodeGen은 필수가 아닙니다. project.yml을 수정하면 `xcodegen generate`로 다시 생성합니다.

```sh
swift test
npm test
bash Scripts/PackageMac.sh
```

런타임 외부 의존성은 없습니다. Swift 테스트는 HTTP 파싱/크기 제한, 인증/Origin, 승인/권한, 만료, 원자적 명령 검증을 확인합니다. Node 테스트는 이동 소수점 누적, 두 손가락 제스처, 취소, 큐 병합을 확인합니다. CI는 두 테스트와 universal Mac 빌드를 실행합니다.

## 검증 현황

로컬 Swift 테스트 7개, JavaScript 테스트 4개 통과. macOS 앱 빌드 및 Safari에서 QR 링크의 연결 코드가 Mac과 일치하는 것, 승인 전 입력 차단, 외부 Origin/인증 없는 API의 403 거부를 확인했습니다. 실제 iPhone에서의 터치 감각과 다른 Mac의 권한/호환성, Developer ID 공증은 별도 검증해야 합니다.
