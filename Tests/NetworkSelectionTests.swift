import XCTest
@testable import CouchWebCore

final class NetworkSelectionTests: XCTestCase {
    private let ethernet = LocalNetworkAddress(interface: "en0", address: "10.0.0.2")
    private let wifi = LocalNetworkAddress(interface: "en1", address: "192.168.1.3")

    func testSelectedInterfaceSurvivesRestartWithAnotherNetworkAvailable() {
        var selection = NetworkSelection()
        XCTAssertEqual(selection.select(wifi.address, from: [ethernet, wifi]), wifi)
        let restarted = NetworkSelection(preferredInterface: selection.preferredInterface)
        XCTAssertEqual(restarted.resolve([ethernet, wifi]), wifi)
    }

    func testDHCPAddressChangesStayOnTheSelectedInterface() {
        let selection = NetworkSelection(preferredInterface: wifi.interface)
        let renewed = LocalNetworkAddress(interface: wifi.interface, address: "192.168.1.8")
        XCTAssertEqual(selection.resolve([ethernet, renewed], currentAddress: wifi.address), renewed)
    }

    func testMissingPreferredInterfaceWaitsAndRecoversWithoutSwitchingLANs() {
        let selection = NetworkSelection(preferredInterface: wifi.interface)
        XCTAssertNil(selection.resolve([ethernet], currentAddress: wifi.address))
        XCTAssertNil(selection.resolve([]))
        XCTAssertEqual(selection.resolve([ethernet, wifi]), wifi)
    }

    func testUserCanExplicitlyChooseAnotherAvailableNetworkWhileWaiting() {
        var selection = NetworkSelection(preferredInterface: wifi.interface)
        XCTAssertNil(selection.resolve([ethernet]))
        XCTAssertEqual(selection.select(ethernet.address, from: [ethernet]), ethernet)
        XCTAssertEqual(selection.preferredInterface, ethernet.interface)
        XCTAssertEqual(selection.resolve([ethernet, wifi]), ethernet)
        XCTAssertNil(selection.select("192.168.99.99", from: [ethernet, wifi]))
        XCTAssertEqual(selection.preferredInterface, ethernet.interface)
    }

    func testFirstLaunchUsesStableFallbackAndKeepsAnAvailableCurrentAddress() {
        let selection = NetworkSelection()
        XCTAssertEqual(selection.resolve([wifi, ethernet]), ethernet)
        XCTAssertEqual(selection.resolve([ethernet, wifi], currentAddress: wifi.address), wifi)
        XCTAssertNil(selection.resolve([]))
        let aliases = [wifi, LocalNetworkAddress(interface: wifi.interface, address: "192.168.1.4")]
        let preferred = NetworkSelection(preferredInterface: wifi.interface)
        XCTAssertEqual(preferred.resolve(aliases, currentAddress: aliases[1].address), aliases[1])
    }
}
