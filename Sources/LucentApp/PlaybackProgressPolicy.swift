import Foundation

/// Separate persistent resume state from the live transport/handover clock.
struct PlaybackProgressPolicy: Sendable {
    static let minimumKey = "lucent.player.minimumResumePercent"
    static let completionKey = "lucent.player.completedPercent"
    var minimumPercent: Double
    var completedPercent: Double
    init(minimumPercent: Double = 5, completedPercent: Double = 90) {
        self.completedPercent = completedPercent.isFinite ? min(99, max(50, completedPercent)) : 90
        self.minimumPercent = minimumPercent.isFinite ? min(self.completedPercent - 1, max(0, minimumPercent)) : 5
    }
    static var current: Self {
        Self(minimumPercent: UserDefaults.standard.object(forKey: minimumKey) as? Double ?? 5,
             completedPercent: UserDefaults.standard.object(forKey: completionKey) as? Double ?? 90)
    }
    enum State: Equatable { case unavailable, beginning, resumable(Double), completed }
    func state(position: Double, duration: Double?) -> State {
        guard position.isFinite, position >= 0, let duration, duration.isFinite, duration > 0 else { return .unavailable }
        let position = min(position, duration)
        let percentage = position / duration * 100
        if percentage >= completedPercent { return .completed }
        if position > 0, percentage >= minimumPercent { return .resumable(position) }
        return .beginning
    }
    func resumePosition(position: Double, duration: Double?, watched: Bool) -> Double {
        guard !watched else { return 0 }
        switch state(position: position, duration: duration) {
        case .resumable(let seconds): return seconds
        case .unavailable: return position.isFinite ? max(0, position) : 0 // Existing checkpoint; do not discard on failed duration probe.
        case .beginning, .completed: return 0
        }
    }
    func isCompleted(position: Double, duration: Double?) -> Bool { state(position: position, duration: duration) == .completed }
}

import SwiftUI
struct PlaybackProgressSettings: View {
    @AppStorage(PlaybackProgressPolicy.minimumKey) private var minimum = 5.0
    @AppStorage(PlaybackProgressPolicy.completionKey) private var completed = 90.0
    @AppStorage("lucent.player.nextEpisodePrompt") private var nextPrompt = true
    var body: some View {
        Form {
            Section {
                Picker("开始记忆进度", selection: $minimum) {
                    ForEach([0.0, 1, 2, 3, 5, 10], id: \.self) { Text("\(Int($0))%").tag($0) }
                }
                Picker("视为播放完成", selection: $completed) {
                    ForEach([80.0, 85, 90, 95, 98], id: \.self) { Text("\(Int($0))%").tag($0) }
                }
            } footer: { Text("低于开始比例时不保存续播点；达到完成比例后标记已看完，下次从头播放。") }
            Section {
                Toggle("片尾提示下一集", isOn: $nextPrompt)
            } footer: { Text("达到完成比例后显示提示，当前影片继续播放。") }
        }
            .modifier(LucentSettingsPageStyle())
        .navigationTitle("进度记忆")
        .tint(.gray)
    }
}
