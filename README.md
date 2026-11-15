# Couch Remote Web

A Mac receiver and an iPhone Safari remote for controlling a Mac connected to a TV. Move the pointer, click, scroll, search, and control playback over the same private Wi-Fi network. No iPhone app installation or Apple developer membership is required.

Requires macOS 13 Ventura or later on Intel or Apple Silicon. The separate native Bluetooth project is [couch-remote-bluetooth](https://github.com/barojins/couch-remote-bluetooth).

## Install and connect

1. Download the DMG from [Releases](https://github.com/barojins/couch-remote-web/releases) and drag Couch Remote Web into Applications.
2. Open the Mac app. Choose **Grant Accessibility access**, enable the app in System Settings, and allow Local Network access if macOS requests it.
3. Connect the Mac and phone to the same private Wi-Fi network. Choose the appropriate network address and select **Start receiver**.
4. Scan the Mac's QR code with the iPhone camera and open it in Safari. Give the phone a device name, compare the six-digit approval codes, and select **Trust this phone** on the Mac.
5. Use the remote. Multiple phones can connect at once; approve each new phone separately.

The QR code and eight-digit connection code remain available while other phones are connected. Approval requests show their remaining time and expire after 60 seconds. Keep the phone's remote open during approval. If approval expires, choose **Connect again** to request a new code. Declining a request stops that attempt while preserving other phones' connections. Interrupted first-time pairing retries the same request safely.

## Remote controls

- **Trackpad:** slide with one finger to move; tap to click; double-tap to double-click. Tap with two fingers to right-click, or slide two fingers to scroll.
- **Scroll buttons:** the right edge has separate up/down buttons. Tap for a small scroll step, or hold for continuous scrolling at maximum speed. Release to stop. Holding uses the maximum speed regardless of the saved Scroll speed setting.
- **Playback row:** full-width left, play/pause, and right buttons in a 2:1:2 width ratio. Play/pause sends the Mac's system media key to the active media app.
- **Search:** select the destination text field on the Mac, then type in the remote's inline search field. Choose **Search** on the phone keyboard or beside the field to send the text and Return together. Backspace, Enter, and Esc are available below it. Search and trackpad stay on the same page.
- **Top row:** Help, movement settings, mute, volume down, and volume up. Digital audio outputs such as HDMI may require the TV's own volume controls.
- **Movement settings:** pointer speed, acceleration, smoothing, and scroll speed are saved on the phone.

Text requests are not replayed automatically. If a send has an uncertain result, check the Mac before sending again. Returning from the background keeps an unfinished text request locked until it settles.

All connected phones control the same Mac pointer and keyboard. Drag-and-drop, momentum, and native macOS multi-finger system gestures are not supported.

## Use as an iPhone Home Screen app

1. Open the remote in Safari using the QR code.
2. Choose Share → **Add to Home Screen**. Enable **Open as Web App** when that option is available.
3. Open the new Home Screen icon, enter the Mac's eight-digit **Connection code**, compare approval codes, and approve the phone once.
4. Future launches reconnect using the saved approval.

Safari and Home Screen apps use separate storage, so each needs its own first approval. Clearing site data also removes that browser's saved approval. The remote includes touch-event and layout fallbacks for iOS 12; physical iPhone 5s testing remains necessary.

## Devices and reconnecting

The Mac lists saved devices with **Connected / Offline**, **Rename**, and **Forget** controls. Unnamed older approvals display as **Phone**. Offline status appears when that phone's live session expires, up to 30 seconds after its last request.

Locking or leaving the phone stops its local input. Returning reconnects automatically without replaying input. **Forget** revokes that device only. **New connection link** replaces the temporary QR link and entry code while preserving connected devices and existing approval handshakes. **Stop receiver** closes all connections and disables automatic receiver startup.

The Mac remembers its receiver port and selected network interface. It follows DHCP address changes on that interface and waits if the selected network disappears instead of switching to another LAN. You can explicitly choose another address while waiting. The link uses the Mac's Bonjour `.local` name when available; older IP-based Home Screen shortcuts should be added again from the current QR code. Renaming the Mac or blocking Bonjour can invalidate the link.

The Mac receiver must be running. **Launch at login** can start it when you sign in. If the stored port is occupied, quit other copies of the receiver.

## Privacy and supported networks

This remote uses **unencrypted local HTTP**. Use a trusted private Wi-Fi network, avoid passwords or sensitive text, and never expose the receiver through router port forwarding or the public internet.

The receiver binds to one selected private IPv4 LAN address. It uses no cloud relay, analytics, or advertising SDK. Host/Origin checks, command limits, per-device credentials, explicit approval, and session expiry restrict access but do not encrypt traffic.

After approval, the browser stores a separate 256-bit device token in localStorage. The Mac stores only its SHA-256 hash in preferences. Input text is not saved. Temporary entry codes rotate after use and allow at most five guesses per minute across clients.

IPv6-only networks, guest Wi-Fi that isolates devices, macOS versions before 13, and offline operation are not supported. Wi-Fi latency and Safari event handling affect responsiveness.

## Updates and releases

The Mac window and menu bar include **Check for Updates…**. Sparkle verifies the signed feed and archive before installation. The iPhone interface is bundled with the Mac app; reload or reconnect after updating. Versions without the updater require a manual installation first.

A downloadable GitHub release and an in-app update are separate publication steps. The existing Sparkle signing key is required to update the feed. If a release is published without that key, download its installer manually; the last valid signed feed remains unchanged.

Current distribution builds use ad-hoc signing and are not Apple-notarized. macOS may show a Gatekeeper warning. See [distribution and publishing](Docs/DISTRIBUTION.md) for signing, notarization, and release automation.

## Development

Open `CouchRemoteWeb.xcodeproj` and run the CouchRemoteWeb scheme. The project is checked in; XcodeGen is needed only when regenerating it after editing `project.yml`.

```sh
swift test
npm test
bash Scripts/PackageMac.sh
```

CI runs the Swift and JavaScript tests and a universal Mac build. Tests cover HTTP parsing, authentication, independent device connections, approval and credential recovery, network selection, atomic command validation, gestures, keyboard input, and input ordering.

Cloud verification also uses the actual Swift Core with Chromium browser sessions through a temporary Linux CryptoKit compatibility module backed by Apple's swift-crypto. That does not exercise the native macOS window, network adapter, or WindowServer input injection. Physical Mac/iPhone testing remains necessary for those paths.
