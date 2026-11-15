# Distribution and updates

## Build the Mac installer

Run on macOS with Xcode:

```sh
bash Scripts/PackageMac.sh
```

This builds an Intel/Apple Silicon universal application targeting macOS 13 and creates `dist/CouchRemoteWeb-macOS13-universal.dmg`. The default is an ad-hoc signed, non-notarized build for personal use. Another Mac does not need Xcode to install the application, but Gatekeeper may require the user to follow [Apple's opening instructions](https://support.apple.com/102445).

## Developer ID signing and notarization

When an Apple Developer Program membership and Developer ID Application certificate are available:

1. Save notarization credentials in a notarytool Keychain profile using Apple's official instructions. Keep private keys and passwords out of the repository.
2. Run:

```sh
DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)' NOTARY_PROFILE=couch-remote bash Scripts/NotarizeMac.sh
```

3. Confirm the notarization submission was accepted and stapler validation succeeded before uploading the DMG. The script enables hardened runtime and timestamp signing, submits for notarization, and staples/verifies the ticket.

Accessibility and Local Network approvals are still granted by each user. The iPhone client runs in Safari and does not require TestFlight, the App Store, or an iPhone developer certificate.

References: [Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## In-app updates

Sparkle 2.10.0 checks the HTTPS feed at `Updates/appcast.xml` on `main`. It requires a signed feed and verifies the archive signature before extraction. Checks are manual by default. Archives are public GitHub release assets, and the app contains no GitHub credentials.

Sparkle signing is separate from Apple signing/notarization. Ad-hoc releases can still trigger Gatekeeper on first installation. Keep macOS 13 Ventura and both Intel and Apple Silicon support.

The existing Ed25519 private key was stored in the release Mac's login Keychain under account `couch-remote-web`. The corresponding public key is in `project.yml`. Preserve this key: a new unrelated key cannot sign updates trusted by existing installations.

## Publish the next release

1. Increase `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` and the checked-in Xcode project. `Info.plist` derives both values from these settings. Sparkle compares the build number, so it must increase.
2. Update the English release notes in `Docs/RELEASE_NOTES.md`.
3. Run the tests and complete a universal Mac build/package. Finish signing and notarization before generating a feed; do not modify the archive afterward.
4. Generate the signed feed using the existing key and official Sparkle tools:

```sh
SPARKLE_BIN=/path/to/Sparkle/bin Scripts/GenerateAppcast.sh v1.0.10
```

5. Publish the GitHub release and upload the exact DMG and SHA256SUMS.txt before pushing the signed feed to `main`. This prevents the updater from advertising an unavailable download.
6. Verify the public release assets, signed feed, and Check for Updates from the previous application version, including installation and relaunch.

The release workflow automates macOS tests, universal packaging, version checks, and GitHub publication. Its optional `SPARKLE_PRIVATE_KEY` repository secret must contain the existing key in the format supported by Sparkle's `--ed-key-file` option. It is written only to a protected temporary file on the ephemeral runner. The workflow verifies signatures against the app's existing public key before publishing a new feed.

If the signing secret is unavailable, the workflow publishes a manual-download installer and leaves `Updates/appcast.xml` unchanged. Release notes identify whether the in-app update feed was published. Configure the secret through GitHub's secure settings; never paste a private key into chat, logs, source files, or release assets.

Back up the signing key securely before replacing the release Mac. Do not hand-edit a generated signed feed; regenerate it with Sparkle's signing tool.
