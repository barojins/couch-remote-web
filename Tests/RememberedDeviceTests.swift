import XCTest
@testable import CouchWebCore

final class RememberedDeviceTests: XCTestCase {
    func request(_ path: String, api: RemoteAPI, client: String, credential: String, body: String = "{}") -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: ["host": api.authority, "origin": api.origin, "content-type": "application/json", "authorization": "Bearer " + credential, "x-couch-client": client], body: Data(body.utf8))
    }
    func json(_ response: HTTPResponse) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any]).compactMapValues { $0 as? String }
    }
    func approved(_ client: String, api: inout RemoteAPI, name: String = "Phone", now: Date = Date()) throws -> String {
        XCTAssertTrue(api.session.connect(client, name: name, now: now))
        api.session.approve(client, now: now)
        return try XCTUnwrap(api.session.connection(for: client)?.deviceToken)
    }

    func testNamesMigratePersistAndFollowIndependentConnectionLifecycle() throws {
        let id = UUID()
        let legacy = "[{\"id\":\"\(id.uuidString)\",\"credentialHash\":\"hash\"}]"
        let old = try JSONDecoder().decode([TrustedWebDevice].self, from: Data(legacy.utf8))
        XCTAssertEqual(old[0].displayName, "Phone")
        var session = RemoteSession()
        let client = UUID().uuidString
        XCTAssertTrue(session.connect(client, name: "iPhone 5s"))
        session.approve(client)
        let device = try XCTUnwrap(session.trustedDevices.first)
        XCTAssertEqual(device.displayName, "iPhone 5s")
        XCTAssertEqual(session.activeDeviceIDs, [device.id])
        let token = try XCTUnwrap(session.connection(for: client)?.deviceToken)
        session.renameDevice(device.id, name: " Living room phone ")
        let restored = try JSONDecoder().decode([TrustedWebDevice].self, from: JSONEncoder().encode(session.trustedDevices))
        XCTAssertEqual(restored[0].displayName, "Living room phone")
        session.disconnect(client)
        XCTAssertTrue(session.activeDeviceIDs.isEmpty)
        XCTAssertTrue(session.reconnectTrusted(UUID().uuidString, authorization: "Bearer " + token))
        XCTAssertEqual(session.activeDeviceIDs, [device.id])
        XCTAssertEqual(session.trustedDevices[0].displayName, "Living room phone")
        session.forgetDevice(device.id)
        XCTAssertTrue(session.activeDeviceIDs.isEmpty)
        XCTAssertTrue(session.trustedDevices.isEmpty)
        XCTAssertEqual(TrustedWebDevice.cleanName("\n\t"), "Phone")
        XCTAssertEqual(TrustedWebDevice.cleanName(String(repeating: "a", count: 50)).count, 40)
    }

    func testHomeScreenPairingPreservesOtherPendingSafariRequest() {
        var session = RemoteSession()
        let safariClient = UUID().uuidString, homeClient = UUID().uuidString
        XCTAssertTrue(session.connect(safariClient, name: "Safari"))
        let safariCode = session.connection(for: safariClient)?.code
        XCTAssertEqual(session.redeemEntryCode(session.entryCode, client: homeClient, name: "Home Screen"), 200)
        XCTAssertEqual(session.pendingDevices.count, 2)
        XCTAssertEqual(session.connection(for: safariClient)?.code, safariCode)
        XCTAssertFalse(session.connection(for: homeClient)?.approved ?? true)
        XCTAssertNil(session.connection(for: homeClient)?.deviceToken)
    }

    func testApprovedCredentialSurvivesSessionExpiryAndMacRestart() throws {
        var session = RemoteSession()
        let client = UUID().uuidString, now = Date()
        XCTAssertTrue(session.connect(client, now: now))
        XCTAssertNil(session.connection(for: client)?.deviceToken)
        session.approve(client, now: now)
        let token = try XCTUnwrap(session.connection(for: client)?.deviceToken)
        let saved = try JSONEncoder().encode(session.trustedDevices)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(token))
        session.expire(now: now.addingTimeInterval(31))
        XCTAssertNil(session.connection(for: client))
        XCTAssertTrue(session.reconnectTrusted(client, authorization: "Bearer " + token, now: now.addingTimeInterval(32)))
        XCTAssertTrue(session.connection(for: client)?.approved ?? false)
        XCTAssertNil(session.connection(for: client)?.code)
        var restarted = RemoteSession()
        restarted.trustedDevices = try JSONDecoder().decode([TrustedWebDevice].self, from: saved)
        let newClient = UUID().uuidString
        XCTAssertTrue(restarted.reconnectTrusted(newClient, authorization: "Bearer " + token))
        XCTAssertTrue(restarted.connection(for: newClient)?.approved ?? false)
    }

    func testEntryCodeCannotClaimAnExistingPendingOrApprovedClient() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let client = UUID().uuidString
        XCTAssertTrue(api.session.connect(client))
        let pendingCode = api.session.connection(for: client)?.code
        let entryCode = api.session.entryCode
        let claim = request("/api/pair", api: api, client: client, credential: "", body: "{\"code\":\"\(entryCode)\"}")
        let pendingResponse = api.handle(claim, hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(pendingResponse.code, 409)
        XCTAssertNil(try json(pendingResponse)["token"])
        XCTAssertEqual(api.session.connection(for: client)?.code, pendingCode)
        XCTAssertEqual(api.session.entryCode, entryCode)
        api.session.approve(client)
        let credential = try XCTUnwrap(api.session.connection(for: client)?.deviceToken)
        let approvedResponse = api.handle(claim, hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(approvedResponse.code, 409)
        XCTAssertNil(try json(approvedResponse)["token"])
        XCTAssertNil(try json(approvedResponse)["deviceToken"])
        XCTAssertEqual(api.session.connection(for: client)?.deviceToken, credential)
        XCTAssertTrue(api.session.connection(for: client)?.approved ?? false)
    }

    func testMultiplePhonesCanControlAndNewQRAndManualPairingStayAvailable() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let first = UUID().uuidString, second = UUID().uuidString, qrClient = UUID().uuidString, manualClient = UUID().uuidString
        let firstToken = try approved(first, api: &api, name: "First")
        let secondToken = try approved(second, api: &api, name: "Second")
        XCTAssertEqual(api.session.activeDeviceIDs.count, 2)
        for (client, token) in [(first, firstToken), (second, secondToken)] {
            let status = api.handle(request("/api/status", api: api, client: client, credential: token), hasPermission: true) { _ in XCTFail() }
            XCTAssertEqual(status.code, 200)
            XCTAssertEqual(try json(status)["state"], "ready")
        }
        var executed: [RemoteCommand] = []
        let click = request("/api/commands", api: api, client: first, credential: firstToken, body: "[{\"type\":\"click\"}]")
        let move = request("/api/commands", api: api, client: second, credential: secondToken, body: "[{\"type\":\"move\",\"x\":2,\"y\":-3}]")
        XCTAssertEqual(api.handle(click, hasPermission: true) { executed += $0 }.code, 200)
        XCTAssertEqual(api.handle(move, hasPermission: true) { executed += $0 }.code, 200)
        XCTAssertEqual(executed, [.click, .move(2, -3)])
        let qr = api.handle(request("/api/connect", api: api, client: qrClient, credential: api.session.token, body: "{\"deviceName\":\"Third\"}"), hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(qr.code, 200)
        XCTAssertEqual(try json(qr)["state"], "pending")
        let manual = api.handle(request("/api/pair", api: api, client: manualClient, credential: "", body: "{\"code\":\"\(api.session.entryCode)\",\"deviceName\":\"Fourth\"}"), hasPermission: true) { _ in XCTFail() }
        XCTAssertEqual(manual.code, 200)
        XCTAssertEqual(try json(manual)["state"], "pending")
        XCTAssertEqual(Set(api.session.pendingDevices.map(\.id)), [qrClient, manualClient])
        XCTAssertEqual(api.session.activeDeviceIDs.count, 2)
        XCTAssertEqual(api.handle(click, hasPermission: true) { _ in }.code, 200)
        XCTAssertEqual(api.handle(move, hasPermission: true) { _ in }.code, 200)
    }

    func testApprovalAndDeclineAffectOnlyTheirPendingPhone() throws {
        var session = RemoteSession()
        let first = UUID().uuidString, second = UUID().uuidString, third = UUID().uuidString
        for (id, name) in [(first, "First"), (second, "Second"), (third, "Third")] { XCTAssertTrue(session.connect(id, name: name)) }
        let thirdCode = session.connection(for: third)?.code
        session.approve(first)
        let firstDevice = try XCTUnwrap(session.connection(for: first)?.deviceID)
        session.decline(second)
        XCTAssertNil(session.connection(for: second))
        XCTAssertEqual(session.pendingDevices.map(\.id), [third])
        XCTAssertEqual(session.connection(for: third)?.code, thirdCode)
        XCTAssertEqual(session.activeDeviceIDs, [firstDevice])
        session.decline(first)
        XCTAssertTrue(session.connection(for: first)?.approved ?? false, "Decline only removes pending requests")
        session.approve(third)
        XCTAssertEqual(session.activeDeviceIDs.count, 2)
        XCTAssertTrue(session.pendingDevices.isEmpty)
    }

    func testDisconnectAndForgetLeaveOtherDevicesConnected() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let first = UUID().uuidString, second = UUID().uuidString
        let firstToken = try approved(first, api: &api)
        let secondToken = try approved(second, api: &api)
        let firstDevice = try XCTUnwrap(api.session.connection(for: first)?.deviceID)
        let secondDevice = try XCTUnwrap(api.session.connection(for: second)?.deviceID)
        let disconnect = request("/api/disconnect", api: api, client: first, credential: firstToken)
        XCTAssertEqual(api.handle(disconnect, hasPermission: true) { _ in }.code, 200)
        XCTAssertNil(api.session.connection(for: first))
        XCTAssertEqual(api.session.activeDeviceIDs, [secondDevice])
        XCTAssertTrue(api.session.reconnectTrusted(first, authorization: "Bearer " + firstToken))
        let sameDeviceTab = UUID().uuidString
        XCTAssertTrue(api.session.reconnectTrusted(sameDeviceTab, authorization: "Bearer " + firstToken))
        api.session.forgetDevice(firstDevice)
        XCTAssertNil(api.session.connection(for: first))
        XCTAssertNil(api.session.connection(for: sameDeviceTab))
        XCTAssertEqual(api.session.activeDeviceIDs, [secondDevice])
        for path in ["/api/connect", "/api/status", "/api/commands"] {
            let req = request(path, api: api, client: first, credential: firstToken, body: "[{\"type\":\"click\"}]")
            XCTAssertEqual(api.handle(req, hasPermission: true) { _ in XCTFail("Revoked input") }.code, 403)
        }
        let status = request("/api/status", api: api, client: second, credential: secondToken)
        XCTAssertEqual(api.handle(status, hasPermission: true) { _ in }.code, 200)
    }

    func testCredentialCannotTakeOverAnotherClientsConnectionOrExecuteItsCommands() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let first = UUID().uuidString, second = UUID().uuidString
        let firstToken = try approved(first, api: &api)
        let secondToken = try approved(second, api: &api)
        let secondDevice = api.session.connection(for: second)?.deviceID
        for path in ["/api/connect", "/api/status", "/api/commands", "/api/disconnect"] {
            let spoof = request(path, api: api, client: second, credential: firstToken, body: "[{\"type\":\"click\"}]")
            XCTAssertEqual(api.handle(spoof, hasPermission: true) { _ in XCTFail("Cross-client input") }.code, 403)
            XCTAssertEqual(api.session.connection(for: second)?.deviceID, secondDevice)
            XCTAssertTrue(api.session.connection(for: second)?.approved ?? false)
        }
        let valid = request("/api/commands", api: api, client: second, credential: secondToken, body: "[{\"type\":\"click\"}]")
        XCTAssertEqual(api.handle(valid, hasPermission: true) { _ in }.code, 200)
        XCTAssertEqual(api.session.activeDeviceIDs.count, 2)
    }

    func testUnauthorizedRequestsCannotRefreshAnotherClientsIdleDeadline() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let first = UUID().uuidString, second = UUID().uuidString, now = Date()
        let firstToken = try approved(first, api: &api, now: now)
        _ = try approved(second, api: &api, now: now.addingTimeInterval(-25))
        let spoof = request("/api/status", api: api, client: second, credential: firstToken)
        XCTAssertEqual(api.handle(spoof, hasPermission: true) { _ in }.code, 403)
        api.session.expire(now: now.addingTimeInterval(6))
        XCTAssertNil(api.session.connection(for: second), "Rejected status must not extend victim heartbeat")
        XCTAssertTrue(api.session.connection(for: first)?.approved ?? false)
    }

    func testQRTokenCannotSendInputAndCredentialHandoffIsPerClient() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let first = UUID().uuidString, second = UUID().uuidString, stranger = UUID().uuidString
        XCTAssertTrue(api.session.connect(first)); XCTAssertTrue(api.session.connect(second))
        let bootstrap = api.session.token
        let pendingStatus = api.handle(request("/api/status", api: api, client: first, credential: bootstrap), hasPermission: true) { _ in }
        XCTAssertNil(try json(pendingStatus)["deviceToken"])
        api.session.approve(first); api.session.approve(second)
        let firstToken = try XCTUnwrap(api.session.connection(for: first)?.deviceToken)
        let secondToken = try XCTUnwrap(api.session.connection(for: second)?.deviceToken)
        for client in [first, second] {
            let input = request("/api/commands", api: api, client: client, credential: bootstrap, body: "[{\"type\":\"click\"}]")
            XCTAssertEqual(api.handle(input, hasPermission: true) { _ in XCTFail("QR authorized control") }.code, 403)
        }
        let strangerStatus = api.handle(request("/api/status", api: api, client: stranger, credential: bootstrap), hasPermission: true) { _ in }
        XCTAssertNotEqual(strangerStatus.code, 200)
        XCTAssertNil(try json(strangerStatus)["deviceToken"])
        let firstStatus = api.handle(request("/api/status", api: api, client: first, credential: bootstrap), hasPermission: true) { _ in }
        let secondStatus = api.handle(request("/api/status", api: api, client: second, credential: bootstrap), hasPermission: true) { _ in }
        XCTAssertEqual(try json(firstStatus)["deviceToken"], firstToken)
        XCTAssertEqual(try json(secondStatus)["deviceToken"], secondToken)
        XCTAssertFalse(String(decoding: firstStatus.body, as: UTF8.self).contains(secondToken))
        XCTAssertFalse(String(decoding: secondStatus.body, as: UTF8.self).contains(firstToken))
    }

    func testTrustedAcknowledgementDoesNotDropOtherClientsUncollectedCredential() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let first = UUID().uuidString, second = UUID().uuidString
        let firstToken = try approved(first, api: &api)
        let secondToken = try approved(second, api: &api)
        let status = request("/api/status", api: api, client: first, credential: firstToken)
        XCTAssertEqual(api.handle(status, hasPermission: true) { _ in }.code, 200)
        XCTAssertNil(api.session.connection(for: first)?.deviceToken)
        XCTAssertEqual(api.session.connection(for: second)?.deviceToken, secondToken)
        let secondStatus = request("/api/status", api: api, client: second, credential: api.session.token)
        XCTAssertEqual(try json(api.handle(secondStatus, hasPermission: true) { _ in })["deviceToken"], secondToken)
        XCTAssertTrue(api.session.connection(for: first)?.approved ?? false)
    }

    func testRotatingLinkPreservesLiveAndPendingPhonesAndUncollectedApproval() throws {
        var api = RemoteAPI(authority: "mac.local:8000")
        let live = UUID().uuidString, handoff = UUID().uuidString, pending = UUID().uuidString, newcomer = UUID().uuidString
        let liveToken = try approved(live, api: &api)
        let handoffToken = try approved(handoff, api: &api)
        XCTAssertTrue(api.session.connect(pending))
        let pendingCode = api.session.connection(for: pending)?.code
        let oldLink = api.session.token, oldCode = api.session.entryCode
        api.session.rotateLink()
        XCTAssertNotEqual(api.session.token, oldLink)
        XCTAssertNotEqual(api.session.entryCode, oldCode)
        XCTAssertEqual(api.session.activeDeviceIDs.count, 2)
        XCTAssertEqual(api.session.connection(for: pending)?.code, pendingCode)
        let liveStatus = request("/api/status", api: api, client: live, credential: liveToken)
        XCTAssertEqual(api.handle(liveStatus, hasPermission: true) { _ in }.code, 200)
        let pendingStatus = request("/api/status", api: api, client: pending, credential: oldLink)
        XCTAssertEqual(try json(api.handle(pendingStatus, hasPermission: true) { _ in })["code"], pendingCode)
        let collect = request("/api/status", api: api, client: handoff, credential: oldLink)
        XCTAssertEqual(try json(api.handle(collect, hasPermission: true) { _ in })["deviceToken"], handoffToken)
        let oldNewcomer = request("/api/connect", api: api, client: newcomer, credential: oldLink)
        XCTAssertEqual(api.handle(oldNewcomer, hasPermission: true) { _ in }.code, 403)
        let freshNewcomer = request("/api/connect", api: api, client: newcomer, credential: api.session.token)
        XCTAssertEqual(api.handle(freshNewcomer, hasPermission: true) { _ in }.code, 200)
        XCTAssertEqual(api.session.pendingDevices.count, 2)
        XCTAssertEqual(api.session.activeDeviceIDs.count, 2)
    }
}
