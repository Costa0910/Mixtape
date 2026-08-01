import Foundation

/// Finds Snag Macs advertising `_snag._tcp` on the local network, so the user can
/// tap their Mac instead of typing an IP address.
@MainActor
final class BonjourBrowser: NSObject, ObservableObject {
    struct Mac: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let host: String
        let port: Int
        var address: String { "\(host):\(port)" }
    }

    @Published var found: [Mac] = []

    private let browser = NetServiceBrowser()
    private var resolving: Set<NetService> = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        found = []
        browser.searchForServices(ofType: "_snag._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
    }

    fileprivate func add(_ mac: Mac) {
        guard !found.contains(where: { $0.host == mac.host && $0.port == mac.port }) else { return }
        found.append(mac)
    }

    fileprivate func finishResolving(name: String, type: String, domain: String) {
        guard let service = resolving.first(where: {
            $0.name == name && $0.type == type && $0.domain == domain
        }) else { return }
        resolving.remove(service)
    }
}

extension BonjourBrowser: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ b: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            service.delegate = self
            resolving.insert(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let ip = Self.firstIPv4(sender.addresses)
        let host = ip ?? sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""
        guard !host.isEmpty else { return }
        let name = sender.name, type = sender.type, domain = sender.domain, port = sender.port
        let mac = Mac(name: name, host: host, port: port)
        Task { @MainActor in
            add(mac)
            finishResolving(name: name, type: type, domain: domain)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let name = sender.name, type = sender.type, domain = sender.domain
        Task { @MainActor in finishResolving(name: name, type: type, domain: domain) }
    }

    /// Pull the first IPv4 dotted-quad out of a service's resolved sockaddr list.
    nonisolated static func firstIPv4(_ addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        for data in addresses {
            let host = data.withUnsafeBytes { raw -> String? in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                      sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var addr = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buf)
            }
            if let host { return host }
        }
        return nil
    }
}
