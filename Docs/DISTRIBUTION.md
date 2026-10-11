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
4. 이 저장소와 릴리스는 공개되어 있어 GitHub 로그인 없이 다운로드할 수 있습니다.

설치 시 Mac의 Accessibility와 필요시 로컬 네트워크 권한 승인은 사용자가 직접 합니다. 공증도 이를 생략하지 않습니다. iPhone은 Safari로 접속하므로 TestFlight/App Store/개발자 인증서가 필요하지 않습니다.

공식 문서: [Developer ID](https://developer.apple.com/developer-id/), [공증](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).


## In-app updates (from 1.0.3 / build 4)

The Mac window and menu-bar menu provide **Check for Updates…**. Updates use
Sparkle 2.10.0 over HTTPS, require a signed feed, and verify the archive signature
before extraction. Checks are manual by default. The iPhone web UI is bundled
with the Mac app; reconnect/reload after updating. Existing versions without the
updater need one manual installation into Applications.

The feed is `Updates/appcast.xml` on main. Archives are public GitHub release
assets; no GitHub credentials are stored in the app. Sparkle signing does not
replace Apple notarization: these ad-hoc releases can still trigger Gatekeeper
on first installation. Ventura / Intel compatibility remains required.

### Publishing the next update

1. Increase `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in project.yml.
   Run `xcodegen generate`. Sparkle compares **CURRENT_PROJECT_VERSION**.
2. Run tests and `Scripts/PackageMac.sh` (or the notarization script). Finish all
   signing/stapling before generating the feed; never modify an archive afterward.
3. With the official Sparkle 2.10.0 tools available, run:
   `SPARKLE_BIN=/path/to/Sparkle/bin Scripts/GenerateAppcast.sh v0.1.4`
4. Create the GitHub release and upload the exact DMG and SHA256SUMS.txt. Make
   the release available before pushing the new feed, so it never advertises a
   missing download. Commit/push source and signed feed to main. Verify both
   feed and DMG are available without authentication.
5. Test Check for Updates from the previous version, including install/relaunch.

The private Ed25519 key stays in this Mac's login Keychain under account
`couch-remote-web`. Do not commit it, embed it in the app, or upload it to GitHub.
Back it up securely before replacing this Mac: losing it can require a manual
reinstallation for users of these ad-hoc builds. The public key is in project.yml.
Do not hand-edit the generated signed feed; regenerate it with the signing tool.
