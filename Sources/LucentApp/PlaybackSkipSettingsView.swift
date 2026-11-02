import SwiftUI

struct PlaybackSkipSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let duration: Double
    let currentTime: Double
    let onSave: (Double?, Double?) -> Void
    @State private var intro = ""
    @State private var credits = ""
    @State private var applyToSeason = false
    @State private var error: String?
    private var isEpisode: Bool { item.identity?.seriesName != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("片头结束时间，如 01:30", text: $intro)
                    Button("将当前位置设为片头结束") { intro = time(currentTime) }
                } header: { Text("片头") }
                Section {
                    TextField("片尾时长，如 02:00", text: $credits)
                    Button("从当前位置到结尾设为片尾") { credits = time(max(0, duration - currentTime)) }
                        .disabled(duration <= currentTime)
                } header: { Text("片尾") } footer: { Text("留空使用服务器或章节标记；也可填写秒数。片尾按剩余时长保存。") }
                if isEpisode { Section { Toggle("应用到已入库的本季剧集", isOn: $applyToSeason) } }
                if let error { Section { Text(LocalizedStringKey(error)).foregroundStyle(.red) } }
                Section { Button("清除手动标记", role: .destructive) { intro = ""; credits = "" } }
            }
            .modifier(LucentSettingsPageStyle())
            .lucentTimeInput()
            .navigationTitle("片头片尾")
            .lucentNavigationTitleStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear {
                let current = library.items.first { $0.id == item.id } ?? item
                intro = current.skipIntroEnd.map(time) ?? ""
                credits = (current.skipCreditsDuration ?? current.skipCreditsStart.flatMap { duration > $0 ? duration - $0 : nil }).map(time) ?? ""
            }
        }.tint(.gray)
    }
    private func time(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "" }
        let seconds = Int(value.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private func save() {
        let introEnd = PlaybackSkipRules.parseTime(intro)
        let tail = PlaybackSkipRules.parseTime(credits)
        guard (intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || introEnd != nil),
              (credits.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tail != nil),
              duration <= 0 || (introEnd ?? 0) + (tail ?? 0) < duration else {
            error = "请输入有效时间，片头与片尾不能覆盖整部影片。"; return
        }
        library.updateSkipTimes(id: item.id, introEnd: introEnd, creditsDuration: tail, applyToSeason: applyToSeason)
        onSave(introEnd, tail)
        dismiss()
    }
}
