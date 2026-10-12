import AppKit
import Network
import Darwin
import SystemConfiguration

final class WebHost: ObservableObject {
    @Published private(set) var message = "Start the receiver to connect your iPhone."
    @Published private(set) var url = ""
    @Published private(set) var approvalCode: String?
    @Published private(set) var entryCode = ""
    @Published private(set) var hasPermission = false
    @Published private(set) var isRunning = false
    @Published private(set) var isApproved = false
    @Published private(set) var trustedDevices: [TrustedWebDevice] = []
    @Published private(set) var connectedDeviceID: UUID?
    @Published private(set) var pendingDeviceName = "Phone"
    @Published var address = ""
    @Published private(set) var addresses: [String] = []
    var onApproval: (() -> Void)?
    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]
    private var api = RemoteAPI(authority: "")
    private let input = InputController()
    private var timer: Timer?
    private var networkTicks = 0

    init() {
        if let saved = UserDefaults.standard.data(forKey: "trustedWebDevices"),
           let devices = try? JSONDecoder().decode([TrustedWebDevice].self, from: saved) {
            api.session.trustedDevices = devices
            trustedDevices = devices
        }
        refreshAddresses()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.api.session.expire()
            self.networkTicks += 1
            if self.networkTicks % 5 == 0, UserDefaults.standard.bool(forKey: "receiverEnabled") {
                let available = Self.localAddresses()
                if self.listener == nil || !available.contains(self.address) {
                    self.refreshAddresses()
                    if !self.address.isEmpty { self.start() }
                }
            }
            if self.isRunning { self.publish() }
            else { self.hasPermission = self.input.hasPermission }
        }
        hasPermission = input.hasPermission
        if UserDefaults.standard.bool(forKey: "receiverEnabled") { start() }
    }
    func refreshAddresses() {
        addresses = Self.localAddresses()
        if !addresses.contains(address) { address = addresses.first ?? "" }
    }
    func start() {
        stop(keepEnabled: true)
        UserDefaults.standard.set(true, forKey: "receiverEnabled")
        guard !address.isEmpty, Self.localAddresses().contains(address) else {
            message = "Connect this Mac to your private Wi-Fi network, then refresh."
            return
        }
        do {
            let parameters = NWParameters.tcp
            let savedPort = UserDefaults.standard.integer(forKey: "receiverPort")
            let port = (1024...65535).contains(savedPort) ? NWEndpoint.Port(rawValue: UInt16(savedPort))! : .any
            // NWListener applies the saved port; setting it in both places is invalid.
            parameters.requiredLocalEndpoint = .hostPort(host: .init(address), port: .any)
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    UserDefaults.standard.set(Int(port.rawValue), forKey: "receiverPort")
                    let hostname = (SCDynamicStoreCopyLocalHostName(nil) as String?)?.lowercased()
                    self.api.authority = "\(hostname.map { $0 + ".local" } ?? self.address):\(port.rawValue)"
                    self.isRunning = true
                    self.updateURL()
                    self.publish()
                case .failed:
                    self.stop(keepEnabled: true)
                    self.message = "Could not start. Quit other copies of Couch Remote Web, then check Local Network permission and Wi-Fi."
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: .main)
            message = "Starting…"
        } catch { message = "Could not start the local receiver. Try refreshing your network address." }
    }
    func stop(keepEnabled: Bool = false) {
        if !keepEnabled { UserDefaults.standard.set(false, forKey: "receiverEnabled") }
        listener?.cancel()
        listener = nil
        let previous = Array(connections.values)
        connections.removeAll()
        previous.forEach { $0.cancel() }
        api.session.revoke()
        input.resetPointer()
        isRunning = false
        url = ""
        publish()
    }
    func disconnect() {
        api.session.revoke()
        input.resetPointer()
        updateURL()
        publish()
    }
    func approve() { api.session.approve(); saveTrust(); publish() }
    func renameDevice(_ id: UUID, name: String) { api.session.renameDevice(id, name: name); saveTrust(); publish() }
    func forgetDevice(_ id: UUID) {
        api.session.forgetDevice(id)
        saveTrust()
        input.resetPointer()
        updateURL()
        publish()
    }
    private func saveTrust() {
        trustedDevices = api.session.trustedDevices
        if let data = try? JSONEncoder().encode(trustedDevices) {
            UserDefaults.standard.set(data, forKey: "trustedWebDevices")
        }
    }
    func requestPermission() { input.requestPermission() }
    private func updateURL() { url = isRunning ? "http://\(api.authority)/#\(api.session.token)" : "" }
    private func publish() {
        hasPermission = input.hasPermission
        approvalCode = api.session.code
        entryCode = api.session.entryCode
        isApproved = api.session.approved
        connectedDeviceID = api.session.activeDeviceID
        pendingDeviceName = api.session.pendingDeviceName
        message = !isRunning ? "Receiver stopped" : approvalCode != nil ? "Compare the code on your iPhone before allowing control." : isApproved ? "iPhone connected" : trustedDevices.isEmpty ? "Scan the QR code with your iPhone." : "Ready for your trusted phone. Open Couch Remote on your iPhone."
    }
    private func accept(_ connection: NWConnection) {
        guard isRunning, connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        let handler = HTTPConnection(connection: connection, handle: { [weak self] request in
            self?.handle(request) ?? HTTPResponse(503, json: ["error": "Receiver stopped."])
        }, onClose: { [weak self] in self?.connections.removeValue(forKey: id) })
        connections[id] = handler
        handler.start()
    }
    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard isRunning, api.accepts(request) else { return HTTPResponse(403, json: ["error": "Connection not allowed."]) }
        if request.method == "GET" {
            let assets = ["/": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"), "/gesture.js": ("gesture.js", "text/javascript; charset=utf-8"), "/connection.js": ("connection.js", "text/javascript; charset=utf-8"), "/app.css": ("app.css", "text/css; charset=utf-8"), "/icon.png": ("icon.png", "image/png"), "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json")]
            guard let (name, type) = assets[request.path],
                  let directory = Bundle.main.resourceURL?.appendingPathComponent("Web"),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return HTTPResponse(404, json: ["error": "Not found."]) }
            return HTTPResponse(data: data, contentType: type)
        }
        let previousCode = api.session.code
        let response = api.handle(request, hasPermission: input.hasPermission) { [input] commands in
            commands.forEach { input.execute($0) }
        }
        publish()
        if approvalCode != nil && approvalCode != previousCode { onApproval?() }
        return response
    }
    static func localAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: Set<String> = [], entry = first
        while let item = entry {
            defer { entry = item.pointee.ifa_next }
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.pointee.ifa_name).hasPrefix("en"),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host), parts = value.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) else { continue }
            result.insert(value)
        }
        return result.sorted()
    }
}

private final class HTTPConnection {
    private let connection: NWConnection
    private let handle: (HTTPRequest) -> HTTPResponse
    private let onClose: () -> Void
    private var parser = HTTPParser()
    private var deadline: Timer?
    private var closed = false
    init(connection: NWConnection, handle: @escaping (HTTPRequest) -> HTTPResponse, onClose: @escaping () -> Void) {
        self.connection = connection; self.handle = handle; self.onClose = onClose
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
        }
        connection.start(queue: .main)
        armTimeout()
        receive()
    }
    func cancel() {
        guard !closed else { return }
        closed = true
        deadline?.invalidate()
        connection.cancel()
        onClose()
    }
    private func armTimeout() {
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.cancel() }
    }
    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] bytes, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let bytes, !bytes.isEmpty else { self.cancel(); return }
            do { try self.parser.append(bytes); self.process(closeAfter: complete) }
            catch { self.cancel() }
        }
    }
    private func process(closeAfter: Bool = false) {
        guard !closed else { return }
        do {
            guard let request = try parser.next() else {
                if closeAfter { cancel() } else { receive() }
                return
            }
            let response = handle(request)
            connection.send(content: response.data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil || closeAfter || request.headers["connection"]?.lowercased() == "close" { self.cancel(); return }
                self.armTimeout()
                self.process()
            })
        } catch { cancel() }
    }
}
