import SwiftUI

struct MetadataMatchView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var token = ""
    @State private var query = ""
    @State private var results: [TMDBSearchResult] = []
    @State private var searching = false
    @State private var errorMessage: String?

    private var television: Bool { item.identity?.seriesName != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("TMDB API 读取令牌") {
                    SecureField("读取令牌", text: $token)
                    Text("令牌仅保存在本机钥匙串。影片资料由 TMDB 提供。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("查找") {
                    TextField("片名", text: $query)
                    Button("搜索") { search() }
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty || searching)
                    if searching { ProgressView() }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                Section("结果") {
                    ForEach(results) { result in
                        Button {
                            library.applyMetadata(id: item.id,
                                                  title: television ? item.title : result.displayTitle,
                                                  metadata: result.metadata)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(result.displayTitle).font(.headline)
                                if let year = result.year { Text(year).foregroundStyle(.secondary) }
                                if let overview = result.overview {
                                    Text(overview).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("匹配在线资料")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .task {
            query = item.identity?.seriesName ?? item.title
            token = (try? KeychainPasswordStore.metadataToken()) ?? ""
        }
    }

    private func search() {
        searching = true
        errorMessage = nil
        Task {
            do {
                try KeychainPasswordStore.setMetadataToken(token)
                results = try await TMDBService.search(title: query, television: television, token: token)
                if results.isEmpty { errorMessage = "没有找到匹配结果，请尝试修改片名。" }
            } catch {
                errorMessage = error.localizedDescription
            }
            searching = false
        }
    }
}
