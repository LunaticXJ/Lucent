import SwiftUI

struct PlaybackSkipSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    let duration: Double
    let currentTime: Double
    let onSave: (Double?, Double?) -> Void
    @State private var intro = 0
    @State private var credits = 0
    @State private var applyToSeason = false
    @State private var error: String?
    private var isEpisode: Bool { item.identity?.seriesName != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            timePicker("片头结束时间", seconds: $intro)
            Button("将当前位置设为片头结束") { intro = wholeSeconds(currentTime) }

            timePicker("片尾时长", seconds: $credits)
            Button("从当前位置到结尾设为片尾") { credits = wholeSeconds(duration - currentTime) }
                .disabled(duration <= currentTime)
            Text("设为 0 分 0 秒时使用服务器或章节标记。")
                .font(.system(size: PlayerControlStyle.scaled(12))).foregroundStyle(.secondary)
            if isEpisode { Toggle("应用到已入库的本季剧集", isOn: $applyToSeason) }
            if let error { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
            Button("清除手动标记", role: .destructive) { intro = 0; credits = 0; error = nil }
            Button("保存") { save() }
        }
        .font(.system(size: PlayerControlStyle.scaled(14)))
        .onAppear {
            let current = library.items.first { $0.id == item.id } ?? item
            intro = current.skipIntroEnd.map(wholeSeconds) ?? 0
            credits = (current.skipCreditsDuration ?? current.skipCreditsStart.flatMap { duration > $0 ? duration - $0 : nil }).map(wholeSeconds) ?? 0
        }
    }
    private func timePicker(_ title: LocalizedStringKey, seconds: Binding<Int>) -> some View {
        let minutes = Binding(
            get: { seconds.wrappedValue / 60 },
            set: { seconds.wrappedValue = $0 * 60 + seconds.wrappedValue % 60 }
        )
        let remainder = Binding(
            get: { seconds.wrappedValue % 60 },
            set: { seconds.wrappedValue = seconds.wrappedValue / 60 * 60 + $0 }
        )
        let maximumMinute = max(minutes.wrappedValue, duration > 0 ? wholeSeconds(duration) / 60 : 60)
        return LabeledContent(title) {
            HStack {
                Picker("分钟", selection: minutes) {
                    ForEach(0...maximumMinute, id: \.self) { Text("\($0) 分").tag($0) }
                }
                Picker("秒", selection: remainder) {
                    ForEach(0..<60, id: \.self) { Text("\($0) 秒").tag($0) }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func wholeSeconds(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(value.rounded())
    }

    private func save() {
        let introEnd = intro > 0 ? Double(intro) : nil
        let tail = credits > 0 ? Double(credits) : nil
        guard duration <= 0 || (introEnd ?? 0) + (tail ?? 0) < duration else {
            error = "请输入有效时间，片头与片尾不能覆盖整部影片。"; return
        }
        library.updateSkipTimes(id: item.id, introEnd: introEnd, creditsDuration: tail, applyToSeason: applyToSeason)
        onSave(introEnd, tail)
        error = nil
    }
}
