import Foundation

struct RemoteSession {
    private(set) var token = Self.newToken()
    private(set) var client: String?
    private(set) var code: String?
    private(set) var approved = false
    private var lastSeen = Date.distantPast
    private var requestedAt = Date.distantPast

    static func newToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func authenticates(_ value: String?) -> Bool {
        guard let value else { return false }
        let expected = Array(("Bearer " + token).utf8), actual = Array(value.utf8)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    mutating func connect(_ id: String, now: Date = Date()) -> Bool {
        expire(now: now)
        guard UUID(uuidString: id) != nil else { return false }
        if let client { return client == id }
        client = id
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
        approved = true
        code = nil
        lastSeen = now
    }
    mutating func expire(now: Date = Date()) {
        if client != nil && (now.timeIntervalSince(lastSeen) > 30 || (!approved && now.timeIntervalSince(requestedAt) > 60)) {
            disconnect()
        }
    }
    mutating func disconnect() { client = nil; code = nil; approved = false }
    mutating func revoke() { disconnect(); token = Self.newToken() }
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
              request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              session.authenticates(request.headers["authorization"]) else { return HTTPResponse(403, json: ["error": "Connection not authorized."]) }
        guard let id = request.headers["x-couch-client"], UUID(uuidString: id) != nil else { return HTTPResponse(400, json: ["error": "Invalid client."]) }
        if request.path == "/api/connect" {
            guard session.connect(id) else { return HTTPResponse(409, json: ["error": "Another phone is connected. Disconnect it on the Mac."]) }
        } else if !session.touch(id) { return HTTPResponse(401, json: ["error": "Connection expired. Scan the Mac's QR code again."]) }
        switch request.path {
        case "/api/connect", "/api/status": break
        case "/api/disconnect": session.disconnect()
        case "/api/commands":
            guard session.approved, hasPermission else { return HTTPResponse(403, json: ["error": "Approve the connection and enable Accessibility on the Mac."]) }
            do {
                let values = try JSONDecoder().decode([WebCommand].self, from: request.body)
                guard !values.isEmpty, values.count <= 128 else { throw WebError.badRequest }
                let commands = try values.flatMap { try $0.validated() }
                execute(commands)
            } catch { return HTTPResponse(400, json: ["error": "Invalid command. Nothing was sent."]) }
        default: return HTTPResponse(404, json: ["error": "Not found."])
        }
        let state = session.client == nil ? "disconnected" : !session.approved ? "pending" : hasPermission ? "ready" : "permission"
        return HTTPResponse(json: ["state": state, "code": session.code ?? ""])
    }
}
