import XCTest
@testable import CouchWebCore

final class PairingRecoveryTests: XCTestCase {
    func request(_ path: String, api: RemoteAPI, client: String, credential: String = "", body: [String: Any] = [:]) throws -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: ["host": api.authority, "origin": api.origin,
                    "content-type": "application/json", "authorization": "Bearer " + credential,
                    "x-couch-client": client], body: try JSONSerialization.data(withJSONObject: body))
    }
    func json(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }
    func testDeclineStopsRejectedPhoneWithoutInterruptingOtherHandshakesAndInput() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let rejected = UUID().uuidString, pending = UUID().uuidString, handoff = UUID().uuidString, live = UUID().uuidString
        let bootstrap = api.session.token
        for id in [rejected, pending, handoff, live] { XCTAssertTrue(api.session.connect(id)) }
        api.session.approve(handoff); api.session.approve(live)
        let handoffCredential = try XCTUnwrap(api.session.connection(for: handoff)?.deviceToken)
        let liveCredential = try XCTUnwrap(api.session.connection(for: live)?.deviceToken)
        let pendingCode = api.session.connection(for: pending)?.code
        api.session.decline(rejected)
        XCTAssertNotEqual(api.session.token, bootstrap)
        let rejectedConnect = try request("/api/connect", api: api, client: rejected, credential: bootstrap)
        XCTAssertEqual(api.handle(rejectedConnect, hasPermission: true) { _ in XCTFail() }.code, 403)
        XCTAssertNil(api.session.connection(for: rejected))
        let pendingStatus = try request("/api/status", api: api, client: pending, credential: bootstrap)
        XCTAssertEqual(try json(api.handle(pendingStatus, hasPermission: true) { _ in })["code"] as? String, pendingCode)
        let collect = try request("/api/status", api: api, client: handoff, credential: bootstrap)
        XCTAssertEqual(try json(api.handle(collect, hasPermission: true) { _ in })["deviceToken"] as? String, handoffCredential)
        let input = try request("/api/commands", api: api, client: live, credential: liveCredential)
        // Use a correctly encoded command array after establishing ownership.
        let command = HTTPRequest(method: input.method, path: input.path, headers: input.headers, body: Data("[{\"type\":\"click\"}]".utf8))
        var executed: [RemoteCommand] = []
        XCTAssertEqual(api.handle(command, hasPermission: true) { executed += $0 }.code, 200)
        XCTAssertEqual(executed, [.click])
    }
    func testLostManualResponseRetriesKeepCodeDeadlineAndEntryCode() throws {
        var session = RemoteSession()
        let now = Date(), client = UUID().uuidString, secret = RemoteSession.newToken(), originalEntry = session.entryCode
        XCTAssertEqual(session.redeemEntryCode(originalEntry, client: client, pairingSecret: secret, now: now), 200)
        let code = session.connection(for: client)?.code, currentEntry = session.entryCode
        for second in [5, 15, 25, 35, 45, 55] {
            XCTAssertEqual(session.redeemEntryCode(originalEntry, client: client, pairingSecret: secret, now: now.addingTimeInterval(Double(second))), 200)
            XCTAssertEqual(session.connection(for: client)?.code, code)
            XCTAssertEqual(session.entryCode, currentEntry)
            XCTAssertEqual(session.remainingApprovalTime(for: client, now: now.addingTimeInterval(Double(second))), 60 - second)
        }
        XCTAssertEqual(session.redeemEntryCode(originalEntry, client: client, pairingSecret: secret, now: now.addingTimeInterval(61)), 401)
        XCTAssertNil(session.connection(for: client))
        XCTAssertTrue(session.approvalExpired(for: client, now: now.addingTimeInterval(61)))
    }
    func testManualRetryProofDoesNotResetGuessRateLimit() {
        var session = RemoteSession()
        let now = Date(), client = UUID().uuidString, secret = RemoteSession.newToken(), code = session.entryCode
        XCTAssertEqual(session.redeemEntryCode(code, client: client, pairingSecret: secret, now: now), 200)
        for _ in 0..<7 { XCTAssertEqual(session.redeemEntryCode(code, client: client, pairingSecret: secret, now: now), 200) }
        for _ in 0..<4 { XCTAssertEqual(session.redeemEntryCode("wrong", client: UUID().uuidString, now: now), 403) }
        XCTAssertEqual(session.redeemEntryCode(session.entryCode, client: UUID().uuidString, now: now), 429)
    }
    func testManualProofRetryRecoversApprovalAndRetiresAfterTrustedAcknowledgement() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let client = UUID().uuidString, secret = RemoteSession.newToken()
        let body: [String: Any] = ["code": api.session.entryCode, "pairingSecret": secret]
        let pair = try request("/api/pair", api: api, client: client, body: body)
        let initial = api.handle(pair, hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(initial.code, 200)
        XCTAssertEqual(try json(initial)["expiresIn"] as? Int, 60)
        api.session.approve(client)
        let credential = try XCTUnwrap(api.session.connection(for: client)?.deviceToken)
        let recovered = api.handle(pair, hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(recovered.code, 200)
        XCTAssertEqual(try json(recovered)["state"] as? String, "ready")
        XCTAssertEqual(try json(recovered)["deviceToken"] as? String, credential)
        let ack = try request("/api/status", api: api, client: client, credential: credential)
        XCTAssertEqual(api.handle(ack, hasPermission: true) { _ in }.code, 200)
        let replay = api.handle(pair, hasPermission: true) { _ in XCTFail() }
        XCTAssertNotEqual(replay.code, 200)
        XCTAssertNil(try json(replay)["token"])
        XCTAssertNil(try json(replay)["deviceToken"])
    }
    func testWrongOrMissingProofCannotClaimManualSessionEvenWithCurrentCode() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let client = UUID().uuidString, secret = RemoteSession.newToken()
        XCTAssertEqual(api.session.redeemEntryCode(api.session.entryCode, client: client, pairingSecret: secret), 200)
        let pendingCode = api.session.connection(for: client)?.code
        for proof in [nil, RemoteSession.newToken()] as [String?] {
            var body: [String: Any] = ["code": api.session.entryCode]
            body["pairingSecret"] = proof
            let claim = try request("/api/pair", api: api, client: client, body: body)
            let response = api.handle(claim, hasPermission: true) { _ in XCTFail() }
            XCTAssertEqual(response.code, 409)
            XCTAssertNil(try json(response)["token"])
            XCTAssertEqual(api.session.connection(for: client)?.code, pendingCode)
        }
        api.session.approve(client)
        let credential = api.session.connection(for: client)?.deviceToken
        let claim = try request("/api/pair", api: api, client: client, body: ["code": api.session.entryCode, "pairingSecret": RemoteSession.newToken()])
        let response = api.handle(claim, hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(response.code, 409)
        XCTAssertNil(try json(response)["deviceToken"])
        XCTAssertEqual(api.session.connection(for: client)?.deviceToken, credential)
    }
    func testIdleManualRetryKeepsOriginalCodeAndDeadline() {
        var session = RemoteSession()
        let now = Date(), client = UUID().uuidString, secret = RemoteSession.newToken(), entry = session.entryCode
        XCTAssertEqual(session.redeemEntryCode(entry, client: client, pairingSecret: secret, now: now), 200)
        let originalCode = session.connection(for: client)?.code
        session.expire(now: now.addingTimeInterval(31))
        XCTAssertNil(session.connection(for: client))
        XCTAssertEqual(session.redeemEntryCode(entry, client: client, pairingSecret: secret, now: now.addingTimeInterval(32)), 200)
        XCTAssertEqual(session.connection(for: client)?.code, originalCode)
        XCTAssertEqual(session.remainingApprovalTime(for: client, now: now.addingTimeInterval(32)), 28)
    }
    func testCountdownExpiryIsExplicitUntilUserRequestsNewApproval() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let client = UUID().uuidString, bootstrap = api.session.token, now = Date()
        XCTAssertTrue(api.session.connect(client, now: now.addingTimeInterval(-59)))
        XCTAssertTrue(api.session.touch(client, now: now.addingTimeInterval(-39)))
        XCTAssertTrue(api.session.touch(client, now: now.addingTimeInterval(-19)))
        XCTAssertTrue(api.session.touch(client, now: now))
        let status = try request("/api/status", api: api, client: client, credential: bootstrap)
        let pending = api.handle(status, hasPermission: true) { _ in }
        XCTAssertEqual(try json(pending)["expiresIn"] as? Int, 1)
        api.session.disconnect(client)
        XCTAssertTrue(api.session.connect(client, now: now.addingTimeInterval(-61)))
        api.session.expire(now: now)
        for path in ["/api/status", "/api/connect"] {
            let request = try self.request(path, api: api, client: client, credential: bootstrap)
            let expired = api.handle(request, hasPermission: true) { _ in XCTFail() }
            XCTAssertEqual(expired.code, 401)
            XCTAssertEqual(try json(expired)["reason"] as? String, "approvalExpired")
            XCTAssertNil(api.session.connection(for: client))
        }
        let retry = try request("/api/connect", api: api, client: client, credential: bootstrap, body: ["retryApproval": true])
        let restarted = api.handle(retry, hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(restarted.code, 200)
        XCTAssertEqual(try json(restarted)["expiresIn"] as? Int, 60)
        XCTAssertFalse(api.session.approvalExpired(for: client))
    }
    func testExpiredLostManualResponseRetriesNeedProofAndExplicitIntent() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let now = Date(), client = UUID().uuidString, secret = RemoteSession.newToken(), code = api.session.entryCode
        XCTAssertEqual(api.session.redeemEntryCode(code, client: client, pairingSecret: secret, now: now.addingTimeInterval(-61)), 200)
        api.session.expire(now: now)
        api.session.rotateLink()
        let body: [String: Any] = ["code": code, "pairingSecret": secret]
        let automatic = try request("/api/pair", api: api, client: client, body: body)
        let expired = api.handle(automatic, hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(expired.code, 401)
        XCTAssertEqual(try json(expired)["reason"] as? String, "approvalExpired")
        let attack = try request("/api/pair", api: api, client: client,
                                 body: ["code": api.session.entryCode, "pairingSecret": RemoteSession.newToken(), "retryApproval": true])
        XCTAssertNotEqual(api.handle(attack, hasPermission: true) { _ in XCTFail() }.code, 200)
        XCTAssertNil(api.session.connection(for: client))
        var retryBody = body; retryBody["retryApproval"] = true
        let retry = try request("/api/pair", api: api, client: client, body: retryBody)
        let response = api.handle(retry, hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(response.code, 200)
        XCTAssertEqual(try json(response)["expiresIn"] as? Int, 60)
        XCTAssertNotNil(try json(response)["token"])
        XCTAssertNil(try json(response)["deviceToken"])
    }
}
