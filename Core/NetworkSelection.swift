struct LocalNetworkAddress: Hashable {
    let interface: String
    let address: String
}

struct NetworkSelection {
    private(set) var preferredInterface: String?

    init(preferredInterface: String? = nil) {
        self.preferredInterface = preferredInterface.flatMap { $0.isEmpty ? nil : $0 }
    }

    // Save the interface, not its DHCP address. An absent preferred interface
    // must wait rather than silently moving the receiver to a different LAN.
    func resolve(_ available: [LocalNetworkAddress], currentAddress: String = "") -> LocalNetworkAddress? {
        let candidates = available.filter { preferredInterface == nil || $0.interface == preferredInterface }
        if let current = candidates.first(where: { $0.address == currentAddress }) { return current }
        return candidates.sorted {
            $0.address == $1.address ? $0.interface < $1.interface : $0.address < $1.address
        }.first
    }

    @discardableResult
    mutating func select(_ address: String, from available: [LocalNetworkAddress]) -> LocalNetworkAddress? {
        guard let selected = available.first(where: { $0.address == address }) else { return nil }
        preferredInterface = selected.interface
        return selected
    }
}
