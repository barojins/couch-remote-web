import XCTest
@testable import CouchWebCore

final class WebCoreTests: XCTestCase {
    func request(_ path: String, api: RemoteAPI, client: String, body: String = "{}", credential: String? = nil) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: ["host": api.authority, "origin": api.origin, "content-type": "application/json", "authorization": "Bearer " + (credential ?? api.session.connection(for: client)?.deviceToken ?? api.session.token), "x-couch-client": client], body: Data(body.utf8))
    }
    func testFragmentedRequestAndPipeline() throws {
        var parser = HTTPParser()
        try parser.append(Data("POST /api/status HTTP/1.1\r\nHost: 192.168.1.2:8000\r\nContent-Length: 2\r\n\r\n{".utf8))
        XCTAssertNil(try parser.next())
        try parser.append(Data("}GET / HTTP/1.1\r\nHost: 192.168.1.2:8000\r\n\r\n".utf8))
        XCTAssertEqual(try parser.next()?.body, Data("{}".utf8))
        XCTAssertEqual(try parser.next()?.path, "/")
        XCTAssertNil(try parser.next())
    }
    func testAmbiguousAndOversizedRequestsRejected() throws {
        for header in ["Content-Length: 0\r\nContent-Length: 1", "Transfer-Encoding: chunked", "Content-Length: -1", "Content-Length: 999999", " Content-Length: 0"] {
            var parser = HTTPParser()
            try parser.append(Data("POST / HTTP/1.1\r\nHost: localhost\r\n\(header)\r\n\r\n".utf8))
            XCTAssertThrowsError(try parser.next())
        }
        var parser = HTTPParser()
        XCTAssertThrowsError(try parser.append(Data(repeating: 0, count: 65537)))
    }
    func testApprovalAndAccessibilityRequiredBeforeAnyInput() {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let client = UUID().uuidString
        var executed: [RemoteCommand] = []
        let move = "[{\"type\":\"move\",\"x\":2,\"y\":-3}]"
        var req = request("/api/commands", api: api, client: client, body: move)
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 401)
        req = request("/api/connect", api: api, client: client)
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 200)
        req = request("/api/commands", api: api, client: client, body: move)
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 403)
        api.session.approve(client)
        req = request("/api/commands", api: api, client: client, body: move)
        XCTAssertEqual(api.handle(req, hasPermission: false) { executed += $0 }.code, 403)
        XCTAssertTrue(executed.isEmpty)
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 200)
        XCTAssertEqual(executed, [.move(2, -3)])
    }
    func testMediaKeysRequireApprovalAndUseOrderedCommandBatch() {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let client = UUID().uuidString
        let body = "[{\"type\":\"key\",\"key\":\"volumeDown\"},{\"type\":\"key\",\"key\":\"mute\"},{\"type\":\"key\",\"key\":\"volumeUp\"},{\"type\":\"key\",\"key\":\"playPause\"}]"
        _ = api.handle(request("/api/connect", api: api, client: client), hasPermission: true) { _ in }
        var executed: [RemoteCommand] = []
        var req = request("/api/commands", api: api, client: client, body: body)
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 403)
        XCTAssertTrue(executed.isEmpty)
        api.session.approve(client)
        req = request("/api/commands", api: api, client: client, body: body)
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 200)
        XCTAssertEqual(executed, [.key(.volumeDown), .key(.mute), .key(.volumeUp), .key(.playPause)])
    }
    func testWrongTokenOriginAndHostAreRejected() {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let base = request("/api/connect", api: api, client: UUID().uuidString)
        for (header, value) in [("host", "attacker.example"), ("origin", "https://attacker.example"), ("authorization", "Bearer bad"), ("sec-fetch-site", "cross-site")] {
            var headers = base.headers; headers[header] = value
            let req = HTTPRequest(method: "POST", path: base.path, headers: headers, body: base.body)
            XCTAssertEqual(api.handle(req, hasPermission: true) { _ in XCTFail("Input executed") }.code, 403)
            XCTAssertTrue(api.session.pendingDevices.isEmpty)
            XCTAssertTrue(api.session.activeDeviceIDs.isEmpty)
        }
    }
    func testMalformedBatchIsAtomicAndUnicodeIsPreserved() {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let client = UUID().uuidString
        XCTAssertTrue(api.session.connect(client)); api.session.approve(client)
        let credential = api.session.connection(for: client)!.deviceToken!
        var executed: [RemoteCommand] = []
        var req = request("/api/commands", api: api, client: client, body: "[{\"type\":\"click\"},{\"type\":\"move\",\"x\":999999,\"y\":0}]")
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 400)
        XCTAssertTrue(executed.isEmpty)
        req = request("/api/commands", api: api, client: client, body: "[{\"type\":\"text\",\"text\":\"한글 🎬\\nabc\"},{\"type\":\"rightClick\"}]", credential: credential)
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 200)
        XCTAssertEqual(executed, [.text("한글 🎬"), .key(.returnKey), .text("abc"), .rightClick])
    }
    func testSessionsCoexistAndExpireIndependently() {
        var session = RemoteSession()
        let first = UUID().uuidString, second = UUID().uuidString, now = Date()
        XCTAssertTrue(session.connect(first, now: now))
        XCTAssertTrue(session.connect(second, now: now))
        session.approve(first, now: now)
        session.approve(second, now: now)
        XCTAssertEqual(session.activeDeviceIDs.count, 2)
        XCTAssertTrue(session.touch(second, now: now.addingTimeInterval(25)))
        session.expire(now: now.addingTimeInterval(31))
        XCTAssertNil(session.connection(for: first))
        XCTAssertTrue(session.connection(for: second)?.approved ?? false)
        XCTAssertEqual(session.activeDeviceIDs.count, 1)
        XCTAssertFalse(session.touch(first, now: now.addingTimeInterval(31)))
        let old = session.token
        session.revoke()
        XCTAssertTrue(session.activeDeviceIDs.isEmpty)
        XCTAssertNil(session.connection(for: second))
        XCTAssertNotEqual(old, session.token)
        XCTAssertFalse(session.authenticates("Bearer " + old))
        XCTAssertEqual(session.trustedDevices.count, 2)
    }
    func testPendingApprovalHasAbsoluteTimeoutEvenWhilePollingAndReconnecting() {
        var session = RemoteSession(); let now = Date(), client = UUID().uuidString
        XCTAssertTrue(session.connect(client, now: now))
        let code = session.connection(for: client)?.code
        for second in stride(from: 10, through: 60, by: 10) {
            XCTAssertTrue(session.touch(client, now: now.addingTimeInterval(Double(second))))
            XCTAssertTrue(session.connect(client, now: now.addingTimeInterval(Double(second))))
            XCTAssertEqual(session.connection(for: client)?.code, code)
        }
        session.approve(client, now: now.addingTimeInterval(61))
        XCTAssertNil(session.connection(for: client))
        XCTAssertTrue(session.pendingDevices.isEmpty)
        XCTAssertTrue(session.activeDeviceIDs.isEmpty)
    }
    func testHomeScreenCodeRequiresApprovalAndCannotBeReused() throws {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let client = UUID().uuidString, entryCode = api.session.entryCode
        var headers = request("/api/pair", api: api, client: client).headers
        headers.removeValue(forKey: "authorization")
        let req = HTTPRequest(method: "POST", path: "/api/pair", headers: headers,
                              body: try JSONSerialization.data(withJSONObject: ["code": entryCode]))
        let result = api.handle(req, hasPermission: true) { _ in XCTFail("Pairing executed input") }
        XCTAssertEqual(result.code, 200)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        XCTAssertEqual(body["token"] as? String, api.session.token)
        XCTAssertEqual(body["state"] as? String, "pending")
        XCTAssertFalse(api.session.connection(for: client)?.approved ?? false)
        let command = request("/api/commands", api: api, client: client, body: "[{\"type\":\"click\"}]")
        XCTAssertEqual(api.handle(command, hasPermission: true) { _ in XCTFail("Approval bypassed") }.code, 403)
        api.session.disconnect(client)
        XCTAssertEqual(api.handle(req, hasPermission: true) { _ in }.code, 403)
    }
    func testHomeScreenCodeRateLimitCannotBeResetByClientOrRevocation() {
        var session = RemoteSession(); let now = Date()
        for _ in 0..<5 { XCTAssertEqual(session.redeemEntryCode("bad", client: UUID().uuidString, now: now), 403) }
        session.revoke()
        XCTAssertEqual(session.redeemEntryCode(session.entryCode, client: UUID().uuidString, now: now.addingTimeInterval(59)), 429)
        XCTAssertEqual(session.redeemEntryCode(session.entryCode, client: UUID().uuidString, now: now.addingTimeInterval(60)), 200)
    }
    func testHomeScreenPairingRejectsForeignOriginAndAllowsAnotherLivePhone() throws {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let client = UUID().uuidString, owner = UUID().uuidString
        var headers = request("/api/pair", api: api, client: client).headers
        headers["origin"] = "http://attacker.example"
        let data = try JSONSerialization.data(withJSONObject: ["code": api.session.entryCode])
        var req = HTTPRequest(method: "POST", path: "/api/pair", headers: headers, body: data)
        XCTAssertEqual(api.handle(req, hasPermission: true) { _ in }.code, 403)
        XCTAssertTrue(api.session.pendingDevices.isEmpty)
        XCTAssertTrue(api.session.connect(owner)); api.session.approve(owner)
        let ownerDevice = api.session.connection(for: owner)?.deviceID
        headers["origin"] = api.origin
        req = HTTPRequest(method: "POST", path: "/api/pair", headers: headers, body: data)
        XCTAssertEqual(api.handle(req, hasPermission: true) { _ in XCTFail("Pairing executed input") }.code, 200)
        XCTAssertTrue(api.session.connection(for: owner)?.approved ?? false)
        XCTAssertFalse(api.session.connection(for: client)?.approved ?? true)
        XCTAssertEqual(api.session.connection(for: owner)?.deviceID, ownerDevice)
        XCTAssertEqual(api.session.pendingDevices.map(\.id), [client])
    }
    func testTrustedReconnectDoesNotRequireFreshMacApproval() {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let client = UUID().uuidString
        XCTAssertTrue(api.session.connect(client)); api.session.approve(client)
        let req = request("/api/connect", api: api, client: client)
        XCTAssertEqual(api.handle(req, hasPermission: true) { _ in }.code, 200)
        XCTAssertTrue(api.session.connection(for: client)?.approved ?? false)
        XCTAssertNil(api.session.connection(for: client)?.code)
    }

}
