import XCTest
@testable import CouchWebCore

final class WebCoreTests: XCTestCase {
    func request(_ path: String, api: RemoteAPI, client: String, body: String = "{}") -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: ["host": api.authority, "origin": api.origin, "content-type": "application/json", "authorization": "Bearer " + api.session.token, "x-couch-client": client], body: Data(body.utf8))
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
        api.session.approve()
        XCTAssertEqual(api.handle(req, hasPermission: false) { executed += $0 }.code, 403)
        XCTAssertTrue(executed.isEmpty)
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 200)
        XCTAssertEqual(executed, [.move(2, -3)])
    }
    func testWrongTokenOriginAndHostAreRejected() {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let base = request("/api/connect", api: api, client: UUID().uuidString)
        for (header, value) in [("host", "attacker.example"), ("origin", "https://attacker.example"), ("authorization", "Bearer bad"), ("sec-fetch-site", "cross-site")] {
            var headers = base.headers; headers[header] = value
            let req = HTTPRequest(method: "POST", path: base.path, headers: headers, body: base.body)
            XCTAssertEqual(api.handle(req, hasPermission: true) { _ in XCTFail("Input executed") }.code, 403)
            XCTAssertNil(api.session.client)
        }
    }
    func testMalformedBatchIsAtomicAndUnicodeIsPreserved() {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let client = UUID().uuidString
        XCTAssertTrue(api.session.connect(client)); api.session.approve()
        var executed: [RemoteCommand] = []
        var req = request("/api/commands", api: api, client: client, body: "[{\"type\":\"click\"},{\"type\":\"move\",\"x\":999999,\"y\":0}]")
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 400)
        XCTAssertTrue(executed.isEmpty)
        req = request("/api/commands", api: api, client: client, body: "[{\"type\":\"text\",\"text\":\"한글 🎬\\nabc\"},{\"type\":\"rightClick\"}]")
        XCTAssertEqual(api.handle(req, hasPermission: true) { executed += $0 }.code, 200)
        XCTAssertEqual(executed, [.text("한글 🎬"), .key(.returnKey), .text("abc"), .rightClick])
    }
    func testSessionCannotBeReplacedAndExpires() {
        var session = RemoteSession()
        let first = UUID().uuidString, second = UUID().uuidString, now = Date()
        XCTAssertTrue(session.connect(first, now: now))
        XCTAssertFalse(session.connect(second, now: now))
        session.approve(now: now)
        XCTAssertTrue(session.approved)
        session.expire(now: now.addingTimeInterval(31))
        XCTAssertNil(session.client)
        XCTAssertFalse(session.approved)
        XCTAssertFalse(session.touch(first, now: now.addingTimeInterval(31)))
        let old = session.token
        session.revoke()
        XCTAssertNotEqual(old, session.token)
        XCTAssertFalse(session.authenticates("Bearer " + old))
    }
    func testPendingApprovalHasAbsoluteTimeoutEvenWhilePolling() {
        var session = RemoteSession(); let now = Date(), client = UUID().uuidString
        XCTAssertTrue(session.connect(client, now: now))
        for second in stride(from: 10, through: 60, by: 10) { XCTAssertTrue(session.touch(client, now: now.addingTimeInterval(Double(second)))) }
        session.approve(now: now.addingTimeInterval(61))
        XCTAssertFalse(session.approved)
        XCTAssertNil(session.client)
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
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: String])
        XCTAssertEqual(body["token"], api.session.token)
        XCTAssertEqual(body["state"], "pending")
        XCTAssertFalse(api.session.approved)
        let command = request("/api/commands", api: api, client: client, body: "[{\"type\":\"click\"}]")
        XCTAssertEqual(api.handle(command, hasPermission: true) { _ in XCTFail("Approval bypassed") }.code, 403)
        api.session.disconnect()
        XCTAssertEqual(api.handle(req, hasPermission: true) { _ in }.code, 403)
    }
    func testHomeScreenCodeRateLimitCannotBeResetByClientOrRevocation() {
        var session = RemoteSession(); let now = Date()
        for _ in 0..<5 { XCTAssertEqual(session.redeemEntryCode("bad", client: UUID().uuidString, now: now), 403) }
        session.revoke()
        XCTAssertEqual(session.redeemEntryCode(session.entryCode, client: UUID().uuidString, now: now.addingTimeInterval(59)), 429)
        XCTAssertEqual(session.redeemEntryCode(session.entryCode, client: UUID().uuidString, now: now.addingTimeInterval(60)), 200)
    }
    func testHomeScreenPairingRejectsForeignOriginAndBusyReceiver() throws {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let client = UUID().uuidString
        var headers = request("/api/pair", api: api, client: client).headers
        headers["origin"] = "http://attacker.example"
        let data = try JSONSerialization.data(withJSONObject: ["code": api.session.entryCode])
        var req = HTTPRequest(method: "POST", path: "/api/pair", headers: headers, body: data)
        XCTAssertEqual(api.handle(req, hasPermission: true) { _ in }.code, 403)
        XCTAssertNil(api.session.client)
        XCTAssertTrue(api.session.connect(UUID().uuidString)); api.session.approve()
        headers["origin"] = api.origin
        req = HTTPRequest(method: "POST", path: "/api/pair", headers: headers, body: data)
        XCTAssertEqual(api.handle(req, hasPermission: true) { _ in }.code, 409)
        XCTAssertTrue(api.session.approved)
    }
    func testReconnectAlwaysRequiresFreshMacApproval() {
        var api = RemoteAPI(authority: "192.168.1.2:8000")
        let client = UUID().uuidString
        XCTAssertTrue(api.session.connect(client)); api.session.approve()
        let req = request("/api/connect", api: api, client: client)
        XCTAssertEqual(api.handle(req, hasPermission: true) { _ in }.code, 200)
        XCTAssertFalse(api.session.approved)
        XCTAssertNotNil(api.session.code)
    }

}
