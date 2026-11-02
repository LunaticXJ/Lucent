import SwiftUI

struct CacheSettingsView: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var videoLimitGB = LocalMediaCache.shared.videoLimitGB
    @State private var imageBytes: UInt64 = 0
    @State private var videoBytes: UInt64 = 0
    @State private var busy = false

    private var limits: [Int] {
        #if os(tvOS)
        [0, 1, 2, 5]
        #elseif os(macOS)
        [0, 2, 5, 10, 20, 50, 100]
        #else
        [0, 1, 2, 5, 10, 20, 50]
        #endif
    }

    var body: some View {
        Group {
            if embedded { cacheForm }
            else {
                NavigationStack {
                    cacheForm.toolbar { Button("完成") { dismiss() } }
                }
            }
        }
        .task { refresh() }
    }

    private var cacheForm: some View {
            Form {
                Section("播放缓存") {
                    Picker("容量上限", selection: $videoLimitGB) {
                        ForEach(limits, id: \.self) { value in
                            Text(value == 0 ? "关闭" : "\(value) GB").tag(value)
                        }
                    }
                    .onChange(of: videoLimitGB) { _, value in
                        Task {
                            busy = true
                            await Task.detached(priority: .utility) {
                                LocalMediaCache.shared.setVideoLimitGB(value)
                            }.value
                            busy = false
                            refresh()
                        }
                    }
                    LabeledContent("已使用", value: ByteCountFormatter.string(fromByteCount: Int64(videoBytes), countStyle: .file))
                    Button("清除播放缓存", role: .destructive) {
                        Task {
                            busy = true
                            await Task.detached(priority: .utility) { LocalMediaCache.shared.clearVideo() }.value
                            busy = false
                            refresh()
                        }
                    }
                    .disabled(busy)
                }
                Section("图片缓存") {
                    LabeledContent("已使用", value: ByteCountFormatter.string(fromByteCount: Int64(imageBytes), countStyle: .file))
                    Button("清除图片缓存", role: .destructive) {
                        Task {
                            busy = true
                            await Task.detached(priority: .utility) { LocalMediaCache.shared.clearImages() }.value
                            busy = false
                            refresh()
                        }
                    }
                    .disabled(busy)
                }
                Section {
                    Text("清理缓存不影响已下载影片和已保存的媒体资料。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .modifier(LucentSettingsPageStyle())
            .navigationTitle("缓存与存储")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    private func refresh() {
        Task {
            let sizes = await Task.detached(priority: .utility) { LocalMediaCache.shared.sizes() }.value
            imageBytes = sizes.images
            videoBytes = sizes.video
        }
    }
}
