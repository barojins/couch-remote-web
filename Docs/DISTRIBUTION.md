# 배포

## 멤버십 없는 개인 테스트

`bash Scripts/PackageMac.sh`는 Intel/Apple Silicon universal 앱을 빌드하고 `dist/CouchRemoteWeb-macOS13-universal.dmg`를 만듭니다. 다른 Mac에 Xcode가 없어도 앱을 복사할 수 있지만 **Apple 공증을 받지 않은 ad-hoc 빌드**이므로 Gatekeeper 경고가 나타날 수 있습니다. [Apple의 공식 안내](https://support.apple.com/102445)에 따라 출처를 확인하세요. macOS 13 이상이 필요합니다.

## 일반 사용자에게 배포

Apple Developer Program 멤버십과 Developer ID Application 인증서가 있을 때:

1. Apple 공식 안내에 따라 notarytool 인증 정보를 Keychain profile로 저장합니다. 비밀번호나 인증서 개인 키를 저장소에 넣지 마세요.
2. 다음 명령을 실행합니다.

```sh
DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)' NOTARY_PROFILE=couch-remote bash Scripts/NotarizeMac.sh
```

3. 제출이 Accepted이고 stapler 검증이 성공한 DMG를 Releases에 올립니다. 스크립트는 hardened runtime과 timestamp 서명, notarytool 제출, staple 및 검증을 수행합니다. 현재 포함된 개인 테스트 릴리스는 공증 완료 버전이 아닙니다.
4. 비공개 저장소의 릴리스는 권한 있는 GitHub 계정만 다운로드할 수 있습니다.

설치 시 Mac의 Accessibility와 필요시 로컬 네트워크 권한 승인은 사용자가 직접 합니다. 공증도 이를 생략하지 않습니다. iPhone은 Safari로 접속하므로 TestFlight/App Store/개발자 인증서가 필요하지 않습니다.

공식 문서: [Developer ID](https://developer.apple.com/developer-id/), [공증](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
