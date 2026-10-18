import Combine
import Foundation

final class SMBDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var hosts: [String] = []
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 === service }
        if let host = service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
            hosts.removeAll { $0 == host }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostname = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !hostname.isEmpty, !hosts.contains(hostname) else { return }
        hosts.append(hostname)
        hosts.sort()
    }
}
