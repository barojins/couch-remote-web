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

struct PendingWebDevice: Identifiable {
    let id: String
    let name: String
    let code: String
    let expiresIn: Int
}

struct WebClientSession {
    var code: String?
    var deviceToken: String?
    var deviceID: UUID?
    var approved: Bool
    fileprivate let name: String
    fileprivate var bootstrapToken: String
    fileprivate var pairingProofHash: String? = nil
    fileprivate var lastSeen: Date
    fileprivate let requestedAt: Date
}

private struct ExpiredWebApproval {
    let connection: WebClientSession
    let expiredAt: Date
}

struct RemoteSession {
    var trustedDevices: [TrustedWebDevice] = []
    private var connections: [String: WebClientSession] = [:]
    private var expiredApprovals: [String: ExpiredWebApproval] = [:]
    private(set) var token = Self.newToken()
    private(set) var entryCode = Self.newEntryCode()
    private var entryAttempts = 0
    private var entryWindow = Date.distantPast

    var pendingDevices: [PendingWebDevice] {
        connections.sorted {
            $0.value.requestedAt == $1.value.requestedAt ? $0.key < $1.key : $0.value.requestedAt < $1.value.requestedAt
        }.compactMap { id, connection in
            guard !connection.approved, let code = connection.code else { return nil }
            return PendingWebDevice(id: id, name: connection.name, code: code,
                                    expiresIn: remainingApprovalTime(for: id))
        }
    }
    var activeDeviceIDs: Set<UUID> {
        Set(connections.values.compactMap { $0.approved ? $0.deviceID : nil })
    }
    func connection(for id: String) -> WebClientSession? { connections[id] }
    func remainingApprovalTime(for id: String, now: Date = Date()) -> Int {
        guard let connection = connections[id], !connection.approved else { return 0 }
        return max(0, Int(ceil(60 - now.timeIntervalSince(connection.requestedAt))))
    }
    func approvalExpired(for id: String, now: Date = Date()) -> Bool {
        guard let expired = expiredApprovals[id] else { return false }
        return now.timeIntervalSince(expired.connection.requestedAt) > 60
    }

    mutating func renameDevice(_ id: UUID, name: String) {
        guard let index = trustedDevices.firstIndex(where: { $0.id == id }) else { return }
        trustedDevices[index].name = TrustedWebDevice.cleanName(name)
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func matches(_ authorization: String?, token: String) -> Bool {
        guard let authorization else { return false }
        let expected = Array(("Bearer " + token).utf8), actual = Array(authorization.utf8)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private func trustedDevice(_ authorization: String?) -> TrustedWebDevice? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let digest = Self.digest(String(authorization.dropFirst(7)))
        return trustedDevices.first { $0.credentialHash == digest }
    }
    func isTrusted(_ authorization: String?) -> Bool { trustedDevice(authorization) != nil }
    func authorizesClient(_ id: String, authorization: String?) -> Bool {
        guard let connection = connections[id], connection.approved,
              let device = trustedDevice(authorization) else { return false }
        return device.id == connection.deviceID
    }
    // Old QR links remain usable only by the pending/credential-collecting client
    // already bound to them. Rotating the link never interrupts that handshake.
    func authenticatesBootstrap(_ authorization: String?, client id: String) -> Bool {
        if let connection = connections[id] {
            guard !connection.approved || connection.deviceToken != nil else { return false }
            return Self.matches(authorization, token: connection.bootstrapToken)
        }
        if let expired = expiredApprovals[id] {
            return Self.matches(authorization, token: expired.connection.bootstrapToken)
        }
        return Self.matches(authorization, token: token)
    }
    func authenticates(_ authorization: String?, client: String? = nil) -> Bool {
        if isTrusted(authorization) || Self.matches(authorization, token: token) { return true }
        guard let client else { return false }
        return authenticatesBootstrap(authorization, client: client)
    }
    mutating func forgetDevice(_ id: UUID) {
        trustedDevices.removeAll { $0.id == id }
        connections = connections.filter { $0.value.deviceID != id }
    }
    mutating func reconnectTrusted(_ id: String, authorization: String?, now: Date = Date()) -> Bool {
        expire(now: now)
        guard UUID(uuidString: id) != nil, expiredApprovals[id] == nil,
              let device = trustedDevice(authorization) else { return false }
        if let connection = connections[id] {
            guard connection.approved, connection.deviceID == device.id else { return false }
            connections[id]?.lastSeen = now
            acknowledgeCredential(id)
        } else {
            connections[id] = WebClientSession(code: nil, deviceToken: nil, deviceID: device.id,
                                               approved: true, name: device.displayName, bootstrapToken: "",
                                               lastSeen: now, requestedAt: now)
        }
        return true
    }
    mutating func acknowledgeCredential(_ id: String) {
        connections[id]?.deviceToken = nil
        connections[id]?.pairingProofHash = nil
    }

    static func newToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func newEntryCode() -> String { String(format: "%08d", Int.random(in: 0...99999999)) }
    // A Home Screen launch has no token. Limit code guesses across all clients.
    static func validPairingSecret(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    mutating func redeemEntryCode(_ value: String, client id: String, name: String? = nil,
                                 pairingSecret: String? = nil, retryApproval: Bool = false,
                                 now: Date = Date()) -> Int {
        expire(now: now)
        let proofHash = pairingSecret.flatMap { Self.validPairingSecret($0) ? Self.digest($0) : nil }
        // Possession of this browser-generated secret makes a lost response
        // retryable without treating a public client UUID as proof of ownership.
        if let proofHash, let connection = connections[id], connection.pairingProofHash == proofHash {
            connections[id]?.lastSeen = now
            return 200
        }
        if let proofHash, let expired = expiredApprovals[id], expired.connection.pairingProofHash == proofHash {
            if !approvalExpired(for: id, now: now) { return connect(id, now: now) ? 200 : 409 }
            guard retryApproval else { return 401 }
            return retryExpiredApproval(id, now: now) ? 200 : 409
        }
        if now.timeIntervalSince(entryWindow) >= 60 { entryWindow = now; entryAttempts = 0 }
        guard entryAttempts < 5 else { return 429 }
        entryAttempts += 1
        guard value == entryCode else { return 403 }
        // The entry code starts a new browser session. It does not prove ownership
        // of an existing client's request or its eventual device credential.
        guard connections[id] == nil, expiredApprovals[id] == nil else { return 409 }
        guard connect(id, name: name, now: now) else { return 409 }
        connections[id]?.pairingProofHash = proofHash
        entryCode = Self.newEntryCode()
        return 200
    }
    mutating func connect(_ id: String, name: String? = nil, now: Date = Date()) -> Bool {
        expire(now: now)
        guard UUID(uuidString: id) != nil else { return false }
        if let expired = expiredApprovals[id] {
            guard !approvalExpired(for: id, now: now), pendingDevices.count < 16 else { return false }
            // A short interruption keeps the same code and original deadline.
            var resumed = expired.connection
            resumed.lastSeen = now
            connections[id] = resumed
            expiredApprovals.removeValue(forKey: id)
            return true
        }
        if let connection = connections[id] {
            guard !connection.approved else { return false }
            // Retry the same request without changing the code or absolute deadline.
            connections[id]?.lastSeen = now
            return true
        }
        guard pendingDevices.count < 16 else { return false }
        connections[id] = WebClientSession(code: String(format: "%06d", Int.random(in: 0...999999)),
                                           deviceToken: nil, deviceID: nil, approved: false,
                                           name: TrustedWebDevice.cleanName(name), bootstrapToken: token,
                                           lastSeen: now, requestedAt: now)
        return true
    }
    mutating func touch(_ id: String, now: Date = Date()) -> Bool {
        expire(now: now)
        guard connections[id] != nil else { return false }
        connections[id]?.lastSeen = now
        return true
    }
    mutating func approve(_ id: String, now: Date = Date()) {
        expire(now: now)
        guard let connection = connections[id], !connection.approved, connection.code != nil else { return }
        let credential = Self.newToken()
        let device = TrustedWebDevice(id: UUID(), credentialHash: Self.digest(credential), name: connection.name)
        trustedDevices.append(device)
        connections[id]?.deviceID = device.id
        connections[id]?.deviceToken = credential
        connections[id]?.approved = true
        connections[id]?.code = nil
        connections[id]?.lastSeen = now
    }
    mutating func expire(now: Date = Date()) {
        for (id, connection) in connections where !connection.approved &&
            (now.timeIntervalSince(connection.lastSeen) > 30 || now.timeIntervalSince(connection.requestedAt) > 60) {
            expiredApprovals[id] = ExpiredWebApproval(connection: connection, expiredAt: now)
        }
        connections = connections.filter { _, connection in
            now.timeIntervalSince(connection.lastSeen) <= 30 &&
                (connection.approved || now.timeIntervalSince(connection.requestedAt) <= 60)
        }
        // Keep enough state to explain expiry and authenticate an explicit retry,
        // with bounded memory even when an old QR link is repeatedly opened.
        expiredApprovals = expiredApprovals.filter { now.timeIntervalSince($0.value.expiredAt) < 300 }
        if expiredApprovals.count > 128 {
            for id in expiredApprovals.sorted(by: { $0.value.expiredAt < $1.value.expiredAt }).prefix(expiredApprovals.count - 128).map(\.key) {
                expiredApprovals.removeValue(forKey: id)
            }
        }
    }
    mutating func retryExpiredApproval(_ id: String, now: Date = Date()) -> Bool {
        guard let expired = expiredApprovals.removeValue(forKey: id) else { return false }
        guard connect(id, name: expired.connection.name, now: now) else {
            expiredApprovals[id] = expired
            return false
        }
        connections[id]?.bootstrapToken = expired.connection.bootstrapToken
        connections[id]?.pairingProofHash = expired.connection.pairingProofHash
        return true
    }
    mutating func disconnect(_ id: String) {
        connections.removeValue(forKey: id)
        expiredApprovals.removeValue(forKey: id)
    }
    mutating func decline(_ id: String) {
        guard connections[id]?.approved == false else { return }
        disconnect(id)
        rotateLink()
    }
    mutating func rotateLink() { token = Self.newToken(); entryCode = Self.newEntryCode() }
    mutating func revoke() { connections.removeAll(); expiredApprovals.removeAll(); rotateLink() }
}

struct RemoteAPI {
    var session = RemoteSession()
    var authority: String
    var origin: String { "http://" + authority }
    private func expiredApprovalResponse() -> HTTPResponse {
        HTTPResponse(401, json: ["reason": "approvalExpired", "error": "Approval expired. Connect again and approve the new code on your Mac."])
    }
    private func result(for id: String, hasPermission: Bool) -> [String: Any] {
        let connection = session.connection(for: id)
        let state = connection == nil ? "disconnected" : connection?.approved != true ? "pending" : hasPermission ? "ready" : "permission"
        var result: [String: Any] = ["state": state, "code": connection?.code ?? ""]
        if connection?.approved == false { result["expiresIn"] = session.remainingApprovalTime(for: id) }
        return result
    }

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
        session.expire()
        if request.path == "/api/pair" {
            struct Pair: Decodable {
                let code: String
                let deviceName: String?
                let pairingSecret: String?
                let retryApproval: Bool?
            }
            guard let pair = try? JSONDecoder().decode(Pair.self, from: request.body) else { return HTTPResponse(400, json: ["error": "Enter the code shown on your Mac."]) }
            if let secret = pair.pairingSecret, !RemoteSession.validPairingSecret(secret) {
                return HTTPResponse(400, json: ["error": "Invalid pairing request. Reload this page and try again."])
            }
            let status = session.redeemEntryCode(pair.code, client: id, name: pair.deviceName,
                                               pairingSecret: pair.pairingSecret, retryApproval: pair.retryApproval == true)
            guard status == 200 else {
                if status == 401 { return expiredApprovalResponse() }
                return HTTPResponse(status, json: ["error": status == 429 ? "Too many attempts. Wait one minute and try again." : status == 409 ? "This connection is already approved or too many phones are waiting for approval. Try again shortly." : "That code is incorrect or expired. Check your Mac."])
            }
            guard let connection = session.connection(for: id) else { return HTTPResponse(401, json: ["error": "Connection expired."]) }
            var response = result(for: id, hasPermission: hasPermission)
            response["token"] = connection.bootstrapToken
            if let credential = connection.deviceToken { response["deviceToken"] = credential }
            return HTTPResponse(json: response)
        }
        let authorization = request.headers["authorization"]
        guard session.authenticates(authorization, client: id) else { return HTTPResponse(403, json: ["error": "Connection link expired. Enter the code shown on your Mac."]) }
        let trusted = session.isTrusted(authorization)
        if session.approvalExpired(for: id) {
            guard !trusted, session.authenticatesBootstrap(authorization, client: id) else {
                return HTTPResponse(403, json: ["error": "This phone does not own this connection."])
            }
            struct Retry: Decodable { let retryApproval: Bool? }
            let retry = (try? JSONDecoder().decode(Retry.self, from: request.body))?.retryApproval == true
            guard request.path == "/api/connect", retry else { return expiredApprovalResponse() }
            guard session.retryExpiredApproval(id) else {
                return HTTPResponse(409, json: ["error": "Too many phones are waiting for approval. Try again shortly."])
            }
        }
        if request.path == "/api/connect" {
            if trusted {
                guard session.reconnectTrusted(id, authorization: authorization) else {
                    return HTTPResponse(403, json: ["error": "This phone does not own this connection."])
                }
            } else {
                // A bootstrap can retry its pending request or collect its approved
                // credential via status; it cannot reset an approved connection.
                guard session.authenticatesBootstrap(authorization, client: id),
                      session.connection(for: id)?.approved != true else {
                    return HTTPResponse(403, json: ["error": "Use this phone's approved credential."])
                }
                struct Connect: Decodable { let deviceName: String? }
                let name = (try? JSONDecoder().decode(Connect.self, from: request.body))?.deviceName
                guard session.connect(id, name: name) else { return HTTPResponse(409, json: ["error": "Too many phones are waiting for approval. Try again shortly."]) }
            }
        } else {
            guard let connection = session.connection(for: id) else { return HTTPResponse(401, json: ["error": "Connection expired. Reconnecting…"]) }
            if trusted {
                guard session.authorizesClient(id, authorization: authorization) else {
                    return HTTPResponse(403, json: ["error": "This phone does not own this connection."])
                }
            } else {
                guard session.authenticatesBootstrap(authorization, client: id),
                      !connection.approved || (request.path == "/api/status" && connection.deviceToken != nil) else {
                    return HTTPResponse(403, json: ["error": "Use this phone's approved credential."])
                }
            }
            // Check ownership before touching a session's heartbeat.
            guard session.touch(id) else { return HTTPResponse(401, json: ["error": "Connection expired. Reconnecting…"]) }
        }
        if trusted { session.acknowledgeCredential(id) }
        switch request.path {
        case "/api/connect", "/api/status": break
        case "/api/disconnect": session.disconnect(id)
        case "/api/commands":
            guard session.authorizesClient(id, authorization: authorization), hasPermission else { return HTTPResponse(403, json: ["error": "Approve the connection and enable Accessibility on the Mac."]) }
            do {
                let values = try JSONDecoder().decode([WebCommand].self, from: request.body)
                guard !values.isEmpty, values.count <= 128 else { throw WebError.badRequest }
                let commands = try values.flatMap { try $0.validated() }
                execute(commands)
            } catch { return HTTPResponse(400, json: ["error": "Invalid command. Nothing was sent."]) }
        default: return HTTPResponse(404, json: ["error": "Not found."])
        }
        let connection = session.connection(for: id)
        var result = result(for: id, hasPermission: hasPermission)
        // Trusted requests acknowledge only their own credential. A bootstrap may
        // retrieve a newly issued token only for the client it was bound to.
        if request.path == "/api/status", !trusted, let credential = connection?.deviceToken { result["deviceToken"] = credential }
        return HTTPResponse(json: result)
    }
}
