import SwiftUI
import CoreImage.CIFilterBuiltins

@main
struct CouchRemoteWebApp: App {
    @NSApplicationDelegateAdaptor(WebAppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("Couch Remote Web", systemImage: "wifi") {
            Text(delegate.host.message)
            Button("Open Couch Remote Web") { delegate.showWindow() }
            Button("Stop receiver") { delegate.host.stop() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
final class WebAppDelegate: NSObject, NSApplicationDelegate {
    let host = WebHost()
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        host.onApproval = { [weak self] in self?.showWindow() }
        showWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 700), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Couch Remote Web"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WebSetupView(host: host))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
private struct WebSetupView: View {
    @ObservedObject var host: WebHost
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Couch Remote Web", systemImage: "wifi").font(.largeTitle.bold())
                Text(host.message).foregroundStyle(.secondary)
                if host.isRunning {
                    if let code = host.approvalCode {
                        Text(code).font(.system(size: 36, weight: .semibold, design: .monospaced))
                        HStack {
                            Button("Decline") { host.disconnect() }
                            Button("Allow control") { host.approve(); if host.hasPermission { NSApplication.shared.hide(nil) } }.buttonStyle(.borderedProminent)
                        }
                    } else if !host.isApproved {
                        if let image = qrCode(host.url) {
                            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 210, height: 210).padding(12).background(.white)
                        }
                        Text("Same Wi-Fi → iPhone Camera → scan → open in Safari.").font(.callout)
                        HStack {
                            Text(host.url.components(separatedBy: "#")[0]).font(.caption.monospaced())
                            Button("Copy link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(host.url, forType: .string)
                            }
                        }
                    }
                    HStack {
                        Button("New connection link") { host.disconnect() }
                        Button("Stop receiver") { host.stop() }
                    }
                } else {
                    if !host.addresses.isEmpty {
                        Picker("Network address", selection: $host.address) {
                            ForEach(host.addresses, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    HStack {
                        Button("Refresh") { host.refreshAddresses() }
                        Button("Start receiver") { host.start() }.buttonStyle(.borderedProminent).disabled(host.address.isEmpty)
                    }
                }
                Divider()
                Label(host.hasPermission ? "Accessibility enabled" : "Accessibility required", systemImage: "hand.raised")
                if !host.hasPermission { Button("Grant Accessibility access") { host.requestPermission() } }
                Text("Use only on a trusted private Wi-Fi network. This version uses local HTTP, not HTTPS; do not send passwords or sensitive text. Never forward its port to the internet.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.frame(width: 440, height: 700)
    }
    private func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
