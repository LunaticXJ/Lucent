import SwiftUI

struct MediaEditView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    private let item: MediaItem
    @State private var title: String
    @State private var isEpisode: Bool
    @State private var series: String
    @State private var season: String
    @State private var number: String
    @State private var year: String
    @State private var introEnd: String
    @State private var creditsStart: String

    init(item: MediaItem) {
        self.item = item
        _title = State(initialValue: item.title)
        _introEnd = State(initialValue: item.skipIntroEnd.map { String(Int($0)) } ?? "")
        _creditsStart = State(initialValue: item.skipCreditsStart.map { String(Int($0)) } ?? "")
        if case .some(.episode(let series, let season, let number, _)) = item.identity {
            _isEpisode = State(initialValue: true)
            _series = State(initialValue: series)
            _season = State(initialValue: String(season))
            _number = State(initialValue: String(number))
            _year = State(initialValue: "")
        } else {
            _isEpisode = State(initialValue: false)
            _series = State(initialValue: "")
            _season = State(initialValue: "1")
            _number = State(initialValue: "1")
            if case .some(.movie(let value)) = item.identity, let value {
                _year = State(initialValue: String(value))
            } else {
                _year = State(initialValue: "")
            }
        }
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if (!introEnd.isEmpty && (Double(introEnd) ?? -1) < 0) ||
            (!creditsStart.isEmpty && (Double(creditsStart) ?? -1) < 0) { return false }
        if !isEpisode { return year.isEmpty || Int(year) != nil }
        return !series.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (Int(season) ?? 0) > 0 && (Int(number) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                Toggle("剧集", isOn: $isEpisode)
                if isEpisode {
                    TextField("剧名", text: $series)
                    TextField("季", text: $season)
                    TextField("集", text: $number)
                } else {
                    TextField("年份（可选）", text: $year)
                }
                TextField("片头结束时间（秒，可选）", text: $introEnd)
                TextField("片尾开始时间（秒，可选）", text: $creditsStart)
            }
            .navigationTitle("编辑资料")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 350, minHeight: 320)
    }

    private func save() {
        let identity: MediaIdentity
        if isEpisode {
            identity = .episode(series: series.trimmingCharacters(in: .whitespacesAndNewlines),
                                season: Int(season) ?? 1, number: Int(number) ?? 1, name: title)
        } else {
            identity = .movie(year: Int(year))
        }
        library.updateDetails(id: item.id, title: title, identity: identity,
                              skipIntroEnd: Double(introEnd), skipCreditsStart: Double(creditsStart))
        dismiss()
    }
}
