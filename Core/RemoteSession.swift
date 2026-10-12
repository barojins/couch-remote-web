import Foundation
import CryptoKit

struct TrustedWebDevice: Codable, Identifiable {
    let id: UUID
    let credentialHash: String
    var name: String? = nil
    var displayName: String { Self.cleanName(name) }
    static func cleanName(_ value: String?) -> String {
        let cleaned = String((value ?? "").unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0.properties.generalCategory != .control }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return cleaned.isEmpty ? "Phone" : cleaned
    }
}

struct RemoteSession {
    var trustedDevices: [TrustedWebDevice] = []
    private(set) var deviceToken: String?
    private(set) var activeDeviceID: UUID?
    private(set) var pendingDeviceName = "Phone"
    mutating func renameDevice(_ id: UUID, name: String) {
        guard let index = trustedDevices.firstIndex(where: { $0.id == id }) else { return }
        trustedDevices[index].name = TrustedWebDevice.cleanName(name)
    }


    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func trustedDevice(_ authorization: String?) -> TrustedWebDevice? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let digest = Self.digest(String(authorization.dropFirst(7)))
        return trustedDevices.first { $0.credentialHash == digest }
    }
    func authorizesActiveDevice(_ authorization: String?) -> Bool {
        guard let device = trustedDevice(authorization) else { return false }
        return device.id == activeDeviceID
    }
    mutating func forgetDevice(_ id: UUID) {
        trustedDevices.removeAll { $0.id == id }
        if activeDeviceID == id { revoke() }
    }
    mutating func reconnectTrusted(_ id: String, authorization: String?, now: Date = Date()) -> Bool {
        expire(now: now)
        guard UUID(uuidString: id) != nil, let device = trustedDevice(authorization),
              client == nil || activeDeviceID == device.id else { return false }
        client = id
        activeDeviceID = device.id
        approved = true
        code = nil
        deviceToken = nil
        lastSeen = now
        return true
    }
    mutating func acknowledgeCredential() { deviceToken = nil }
    func isTrusted(_ authorization: String?) -> Bool { trustedDevice(authorization) != nil }

    private(set) var token = Self.newToken()
    private(set) var entryCode = Self.newEntryCode()
    private var entryAttempts = 0
    private var entryWindow = Date.distantPast
    private(set) var client: String?
    private(set) var code: String?
    private(set) var approved = false
    private var lastSeen = Date.distantPast
    private var requestedAt = Date.distantPast

    static func newToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func newEntryCode() -> String { String(format: "%08d", Int.random(in: 0...99999999)) }
    // A Home Screen launch has no token. Limit code guesses across all clients.
    mutating func redeemEntryCode(_ value: String, client id: String, name: String? = nil, now: Date = Date()) -> Int {
        if now.timeIntervalSince(entryWindow) >= 60 { entryWindow = now; entryAttempts = 0 }
        guard entryAttempts < 5 else { return 429 }
        entryAttempts += 1
        guard value == entryCode else { return 403 }
        expire(now: now)
        // Moving from Safari to a fresh Home Screen app may leave an unapproved
        // QR session behind. A correct Mac entry code can replace that request.
        if !approved { disconnect() }
        guard client == nil, connect(id, name: name, now: now) else { return 409 }
        entryCode = Self.newEntryCode()
        return 200
    }
    func authenticates(_ value: String?) -> Bool {
        if isTrusted(value) { return true }
        guard let value else { return false }
        let expected = Array(("Bearer " + token).utf8), actual = Array(value.utf8)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    mutating func connect(_ id: String, name: String? = nil, now: Date = Date()) -> Bool {
        expire(now: now)
        guard UUID(uuidString: id) != nil else { return false }
        if let client { return client == id }
        client = id
        pendingDeviceName = TrustedWebDevice.cleanName(name)
        code = String(format: "%06d", Int.random(in: 0...999999))
        approved = false
        lastSeen = now
        requestedAt = now
        return true
    }
    mutating func touch(_ id: String, now: Date = Date()) -> Bool {
        expire(now: now)
        guard id == client else { return false }
        lastSeen = now
        return true
    }
    mutating func approve(now: Date = Date()) {
        expire(now: now)
        guard client != nil, code != nil else { return }
        let credential = Self.newToken()
        let device = TrustedWebDevice(id: UUID(), credentialHash: Self.digest(credential), name: pendingDeviceName)
        trustedDevices.append(device)
        activeDeviceID = device.id
        deviceToken = credential
        approved = true
        code = nil
        lastSeen = now
    }
    mutating func expire(now: Date = Date()) {
        if client != nil && (now.timeIntervalSince(lastSeen) > 30 || (!approved && now.timeIntervalSince(requestedAt) > 60)) {
            disconnect()
        }
    }
    mutating func disconnect() { client = nil; code = nil; approved = false; activeDeviceID = nil; deviceToken = nil }
    mutating func revoke() { disconnect(); token = Self.newToken(); entryCode = Self.newEntryCode() }
}

struct RemoteAPI {
    var session = RemoteSession()
    var authority: String
    var origin: String { "http://" + authority }

    // Host and Origin checks prevent DNS rebinding and browser cross-site requests.
    func accepts(_ request: HTTPRequest) -> Bool {
        guard request.headers["host"] == authority else { return false }
        if let origin = request.headers["origin"], origin != self.origin { return false }
        if let site = request.headers["sec-fetch-site"], !["same-origin", "none"].contains(site) { return false }
        return true
    }
    mutating func handle(_ request: HTTPRequest, hasPermission: Bool,
                         execute: ([RemoteCommand]) -> Void) -> HTTPResponse {
        guard accepts(request), request.method == "POST", request.headers["origin"] == origin,
              request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else { return HTTPResponse(403, json: ["error": "Connection not authorized."]) }
        guard let id = request.headers["x-couch-client"], UUID(uuidString: id) != nil else { return HTTPResponse(400, json: ["error": "Invalid client."]) }
        if request.path == "/api/pair" {
            struct Pair: Decodable { let code: String; let deviceName: String? }
            guard let pair = try? JSONDecoder().decode(Pair.self, from: request.body) else { return HTTPResponse(400, json: ["error": "Enter the code shown on your Mac."]) }
            let result = session.redeemEntryCode(pair.code, client: id, name: pair.deviceName)
            guard result == 200 else {
                return HTTPResponse(result, json: ["error": result == 429 ? "Too many attempts. Wait one minute and try again." : result == 409 ? "Another phone is connected. Disconnect it on the Mac." : "That code is incorrect or expired. Check your Mac."])
            }
            return HTTPResponse(json: ["token": session.token, "state": "pending", "code": session.code ?? ""])
        }
        guard session.authenticates(request.headers["authorization"]) else { return HTTPResponse(403, json: ["error": "Connection link expired. Enter the code shown on your Mac."]) }
        let trusted = session.isTrusted(request.headers["authorization"])
        // The pairing link is only a bootstrap credential. Once approved, it can
        // collect the new device credential but cannot reset/control that session.
        if session.approved, !trusted,
           !(request.path == "/api/status" && session.client == id && session.deviceToken != nil) {
            return HTTPResponse(403, json: ["error": "Use this phone's approved credential."])
        }
        if request.path == "/api/connect" {
            if session.isTrusted(request.headers["authorization"]) {
                guard session.reconnectTrusted(id, authorization: request.headers["authorization"]) else {
                    return HTTPResponse(409, json: ["error": "Another phone is connected. Waiting to reconnect…"])
                }
            } else {
                if session.client == id { session.disconnect() }
                struct Connect: Decodable { let deviceName: String? }
                let name = (try? JSONDecoder().decode(Connect.self, from: request.body))?.deviceName
                guard session.connect(id, name: name) else { return HTTPResponse(409, json: ["error": "Another phone is connected. Waiting to reconnect…"]) }
            }
        } else if !session.touch(id) { return HTTPResponse(401, json: ["error": "Connection expired. Scan the Mac's QR code again."]) }
        if session.isTrusted(request.headers["authorization"]), !session.authorizesActiveDevice(request.headers["authorization"]) {
            return HTTPResponse(403, json: ["error": "This phone does not own the active connection."])
        }
        if trusted { session.acknowledgeCredential() }
        switch request.path {
        case "/api/connect", "/api/status": break
        case "/api/disconnect": session.disconnect()
        case "/api/commands":
            guard session.approved, session.authorizesActiveDevice(request.headers["authorization"]), hasPermission else { return HTTPResponse(403, json: ["error": "Approve the connection and enable Accessibility on the Mac."]) }
            do {
                let values = try JSONDecoder().decode([WebCommand].self, from: request.body)
                guard !values.isEmpty, values.count <= 128 else { throw WebError.badRequest }
                let commands = try values.flatMap { try $0.validated() }
                execute(commands)
            } catch { return HTTPResponse(400, json: ["error": "Invalid command. Nothing was sent."]) }
        default: return HTTPResponse(404, json: ["error": "Not found."])
        }
        let state = session.client == nil ? "disconnected" : !session.approved ? "pending" : hasPermission ? "ready" : "permission"
        var result = ["state": state, "code": session.code ?? ""]
        // Only the approved client can collect its newly issued credential.
        if request.path == "/api/status", let credential = session.deviceToken { result["deviceToken"] = credential }
        return HTTPResponse(json: result)
    }
}
