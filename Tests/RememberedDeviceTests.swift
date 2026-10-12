import XCTest
@testable import CouchWebCore

final class RememberedDeviceTests: XCTestCase {
    func testNamesMigratePersistAndFollowConnectionLifecycle() throws {
        let id = UUID()
        let legacy = "[{\"id\":\"\(id.uuidString)\",\"credentialHash\":\"hash\"}]"
        let old = try JSONDecoder().decode([TrustedWebDevice].self, from: Data(legacy.utf8))
        XCTAssertEqual(old[0].displayName, "Phone")
        var session = RemoteSession()
        XCTAssertTrue(session.connect(UUID().uuidString, name: "iPhone 5s"))
        session.approve()
        let device = try XCTUnwrap(session.trustedDevices.first)
        XCTAssertEqual(device.displayName, "iPhone 5s")
        XCTAssertEqual(session.activeDeviceID, device.id)
        let token = try XCTUnwrap(session.deviceToken)
        session.renameDevice(device.id, name: " Living room phone ")
        let restored = try JSONDecoder().decode([TrustedWebDevice].self, from: JSONEncoder().encode(session.trustedDevices))
        XCTAssertEqual(restored[0].displayName, "Living room phone")
        session.disconnect()
        XCTAssertNil(session.activeDeviceID)
        XCTAssertTrue(session.reconnectTrusted(UUID().uuidString, authorization: "Bearer " + token))
        XCTAssertEqual(session.activeDeviceID, device.id)
        XCTAssertEqual(session.trustedDevices[0].displayName, "Living room phone")
        session.forgetDevice(device.id)
        XCTAssertNil(session.activeDeviceID)
        XCTAssertTrue(session.trustedDevices.isEmpty)
        XCTAssertEqual(TrustedWebDevice.cleanName("\n\t"), "Phone")
        XCTAssertEqual(TrustedWebDevice.cleanName(String(repeating: "a", count: 50)).count, 40)
    }
    func request(_ path: String, api: RemoteAPI, client: String, credential: String, body: String = "{}") -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: ["host": api.authority, "origin": api.origin, "content-type": "application/json", "authorization": "Bearer " + credential, "x-couch-client": client], body: Data(body.utf8))
    }
    func testHomeScreenPairingCanReplaceUnapprovedSafariRequest() {
        var session = RemoteSession()
        XCTAssertTrue(session.connect(UUID().uuidString))
        let homeClient = UUID().uuidString
        XCTAssertEqual(session.redeemEntryCode(session.entryCode, client: homeClient), 200)
        XCTAssertEqual(session.client, homeClient)
        XCTAssertFalse(session.approved)
        XCTAssertNil(session.deviceToken)
    }
    func testApprovedCredentialSurvivesSessionExpiryAndMacRestart() throws {
        var session = RemoteSession()
        let client = UUID().uuidString, now = Date()
        XCTAssertTrue(session.connect(client, now: now))
        XCTAssertNil(session.deviceToken)
        session.approve(now: now)
        let token = try XCTUnwrap(session.deviceToken)
        let saved = try JSONEncoder().encode(session.trustedDevices)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(token))
        session.expire(now: now.addingTimeInterval(31))
        XCTAssertTrue(session.reconnectTrusted(client, authorization: "Bearer " + token, now: now.addingTimeInterval(32)))
        XCTAssertTrue(session.approved)
        XCTAssertNil(session.code)
        var restarted = RemoteSession()
        restarted.trustedDevices = try JSONDecoder().decode([TrustedWebDevice].self, from: saved)
        XCTAssertTrue(restarted.reconnectTrusted(UUID().uuidString, authorization: "Bearer " + token))
        XCTAssertTrue(restarted.approved)
    }
    func testForgetRevokesCredentialAndActiveControl() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let client = UUID().uuidString
        XCTAssertTrue(api.session.connect(client)); api.session.approve()
        let token = try XCTUnwrap(api.session.deviceToken)
        let id = try XCTUnwrap(api.session.trustedDevices.first?.id)
        api.session.forgetDevice(id)
        for path in ["/api/connect", "/api/status", "/api/commands"] {
            let req = request(path, api: api, client: client, credential: token, body: "[{\"type\":\"click\"}]")
            XCTAssertEqual(api.handle(req, hasPermission: true) { _ in XCTFail("Revoked input") }.code, 403)
        }
        XCTAssertNil(api.session.client)
        XCTAssertFalse(api.session.approved)
    }
    func testQRCodeTokenCannotSendApprovedInputAndOtherPhoneCannotTakeOver() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let first = UUID().uuidString, second = UUID().uuidString
        XCTAssertTrue(api.session.connect(second)); api.session.approve()
        let otherToken = try XCTUnwrap(api.session.deviceToken)
        api.session.disconnect()
        XCTAssertTrue(api.session.connect(first)); api.session.approve()
        let firstToken = try XCTUnwrap(api.session.deviceToken)
        let command = request("/api/commands", api: api, client: first, credential: api.session.token, body: "[{\"type\":\"click\"}]")
        XCTAssertEqual(api.handle(command, hasPermission: true) { _ in XCTFail("QR token authorized input") }.code, 403)
        let other = request("/api/connect", api: api, client: second, credential: otherToken)
        XCTAssertEqual(api.handle(other, hasPermission: true) { _ in XCTFail() }.code, 409)
        XCTAssertEqual(api.session.client, first)
        let replay = request("/api/commands", api: api, client: first, credential: otherToken, body: "[{\"type\":\"click\"}]")
        XCTAssertEqual(api.handle(replay, hasPermission: true) { _ in XCTFail() }.code, 403)
        let valid = request("/api/commands", api: api, client: first, credential: firstToken, body: "[{\"type\":\"click\"}]")
        XCTAssertEqual(api.handle(valid, hasPermission: false) { _ in XCTFail() }.code, 403)
        var executed = false
        XCTAssertEqual(api.handle(valid, hasPermission: true) { _ in executed = true }.code, 200)
        XCTAssertTrue(executed)
    }
    func testStatusDeliversCredentialOnlyAfterApprovalToOwningClient() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let client = UUID().uuidString
        XCTAssertTrue(api.session.connect(client))
        let status = request("/api/status", api: api, client: client, credential: api.session.token)
        var response = api.handle(status, hasPermission: true) { _ in }
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("deviceToken"))
        api.session.approve()
        let stranger = request("/api/status", api: api, client: UUID().uuidString, credential: api.session.token)
        XCTAssertEqual(api.handle(stranger, hasPermission: true) { _ in }.code, 403)
        response = api.handle(status, hasPermission: true) { _ in }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: String])
        XCTAssertEqual(result["deviceToken"], api.session.deviceToken)
        XCTAssertEqual(result["state"], "ready")
    }
}
