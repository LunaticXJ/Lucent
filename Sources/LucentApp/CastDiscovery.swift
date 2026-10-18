import Combine
import Foundation
import VLCKit

#if !os(tvOS)
@MainActor
final class CastDiscovery: ObservableObject {
    @Published private(set) var renderers: [VLCRendererItem] = []
    private var discoverers: [VLCRendererDiscoverer] = []
    private var timer: Timer?

    func start() {
        guard discoverers.isEmpty else { return }
        for description in VLCRendererDiscoverer.list() ?? [] {
            guard let discoverer = VLCRendererDiscoverer(name: description.name),
                  discoverer.start() else { continue }
            discoverers.append(discoverer)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        discoverers.forEach { $0.stop() }
        discoverers.removeAll()
        renderers = []
    }

    private func refresh() {
        let found = discoverers.flatMap(\.renderers).filter { $0.type.lowercased() == "chromecast" }
        if found.map(\.name) != renderers.map(\.name) { renderers = found }
    }
}
#else
@MainActor
final class CastDiscovery: ObservableObject {
    func start() {}
    func stop() {}
}
#endif
