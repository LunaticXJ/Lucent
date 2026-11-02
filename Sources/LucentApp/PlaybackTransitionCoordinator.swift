import Foundation

/// Owns transition identity and playback intent independently from either engine.
/// Render/audio operations remain in adapters; stale completions cannot commit.
@MainActor
final class PlaybackTransitionCoordinator {
    enum Engine: Sendable { case native, mpv }
    enum Phase: Equatable {
        case idle, preparing, playing, paused, closed
        case handover(UUID, Engine)
    }
    private(set) var phase: Phase = .idle
    private(set) var generation = UUID()
    var landing: Double?
    var wantsPlayback = true
    func begin(target: Engine) -> UUID? {
        if case .handover = phase { return nil }
        guard phase != .closed else { return nil }
        generation = UUID(); landing = nil
        phase = .handover(generation, target)
        return generation
    }
    func finish(_ ticket: UUID) {
        guard generation == ticket else { return }
        landing = nil; phase = wantsPlayback ? .playing : .paused
    }
    func invalidate(closing: Bool = false) {
        generation = UUID(); landing = nil
        phase = closing ? .closed : .preparing
    }
    func setIntent(_ playing: Bool) {
        wantsPlayback = playing
        if case .handover = phase { return }
        guard phase != .closed else { return }
        phase = playing ? .playing : .paused
    }
}
