import Foundation
import Network

/// The monitor is advisory; HTTP/CloudKit also receive their own cellular restrictions.
final class NetworkUsagePolicy: @unchecked Sendable {
    static let shared = NetworkUsagePolicy()
    static let changed = Notification.Name("LucentNetworkUsageChanged")
    static let playbackKey = "lucent.network.cellularPlayback"
    static let syncKey = "lucent.network.cellularSync"
    static let downloadKey = "lucent.network.cellularDownloads"
    enum Route: Sendable, Equatable { case unknown, offline, wifi, cellular, wired }
    private let lock = NSLock()
    private var routeStorage: Route = .unknown
    private let monitor = NWPathMonitor()
    var route: Route { lock.withLock { routeStorage } }
    static var allowsSync: Bool { UserDefaults.standard.bool(forKey: syncKey) }
    static var allowsDownloads: Bool { UserDefaults.standard.bool(forKey: downloadKey) }
    static func syncPermitted(on route: Route, allowed: Bool) -> Bool {
        route == .wifi || route == .wired || (route == .cellular && allowed)
    }
    static func playbackNeedsConfirmation(on route: Route, remote: Bool, approved: Bool) -> Bool {
        remote && route == .cellular && !approved
    }
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let route: Route
            if path.status != .satisfied { route = .offline }
            else if path.usesInterfaceType(.cellular) { route = .cellular }
            else if path.usesInterfaceType(.wifi) { route = .wifi }
            else { route = .wired }
            let changed = self.lock.withLock { () -> Bool in
                guard self.routeStorage != route else { return false }; self.routeStorage = route; return true
            }
            if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
        }
        monitor.start(queue: DispatchQueue(label: "Lucent.NetworkUsage"))
    }
    func readyRoute() async -> Route {
        for _ in 0..<40 {
            let current = route
            if current != .unknown { return current }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return .unknown }
        }
        return route
    }
    func requireDownloadAllowed() throws {
        let route = route
        if route == .unknown { throw NetworkUsageError.determining }
        if route == .cellular && !Self.allowsDownloads { throw NetworkUsageError.downloadsRestricted }
    }
    static func notifySettingsChanged() { NotificationCenter.default.post(name: changed, object: nil) }
}

enum NetworkUsageError: LocalizedError {
    case downloadsRestricted, determining
    var errorDescription: String? {
        switch self {
        case .downloadsRestricted: "当前为移动网络，已暂停下载。可连接 Wi-Fi，或在设置的移动网络中允许下载。"
        case .determining: "正在确认网络类型，请稍后再试。"
        }
    }
}

extension MediaItem {
    func requiresRemotePlayback(hasDownload: Bool) -> Bool {
        if hasDownload { return false }
        switch location {
        case .bookmark, .folderFile: return false
        case .remote(let url): return !url.isFileURL
        default: return true
        }
    }
}
