import Combine
import Foundation

final class CameraPhoneDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Server: Identifiable {
        let id: String
        let name: String
        let host: String
        let port: Int
    }

    @Published var servers: [Server] = []
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    override init() { super.init(); browser.delegate = self }

    func start() { browser.searchForServices(ofType: "_wirecamera._tcp.", inDomain: "local.") }
    func stop() { browser.stop(); services.forEach { $0.stop() }; services.removeAll() }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) { services.removeAll { $0 == service }; servers.removeAll { $0.id == service.name } }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
        servers.removeAll { $0.id == sender.name }
        servers.append(Server(id: sender.name, name: sender.name, host: host.hasSuffix(".") ? String(host.dropLast()) : host, port: sender.port))
    }
}
