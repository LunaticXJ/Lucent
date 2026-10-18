import Foundation

struct TMDBSearchResult: Decodable, Identifiable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let voteAverage: Double?
    let releaseDate: String?
    let firstAirDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }

    var displayTitle: String { title ?? name ?? "未知标题" }
    var year: String? { (releaseDate ?? firstAirDate)?.prefix(4).description }
    var metadata: MediaMetadata {
        MediaMetadata(providerID: id, summary: overview, posterPath: posterPath, rating: voteAverage)
    }
}

enum TMDBService {
    private struct SearchResponse: Decodable { let results: [TMDBSearchResult] }
    struct Person: Decodable, Identifiable {
        let id: Int
        let name: String
        let character: String?
    }
    struct Video: Decodable, Identifiable {
        let id: String
        let key: String
        let name: String
        let site: String
        let type: String
        var externalURL: URL? {
            guard site.caseInsensitiveCompare("YouTube") == .orderedSame,
                  key.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil else { return nil }
            return URL(string: "https://www.youtube.com/watch?v=\(key)")
        }
    }
    struct Extras: Decodable {
        struct Credits: Decodable { let cast: [Person] }
        struct Videos: Decodable { let results: [Video] }
        let credits: Credits?
        let videos: Videos?
    }

    static func search(title: String, television: Bool, token: String) async throws -> [TMDBSearchResult] {
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(television ? "tv" : "movie")")!
        components.queryItems = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw TMDBError.requestFailed
        }
        return try JSONDecoder().decode(SearchResponse.self, from: data).results
    }

    static func extras(id: Int, television: Bool, token: String) async throws -> Extras {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(television ? "tv" : "movie")/\(id)")!
        components.queryItems = [URLQueryItem(name: "append_to_response", value: "credits,videos"),
                                 URLQueryItem(name: "language", value: "zh-CN")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw TMDBError.requestFailed }
        return try JSONDecoder().decode(Extras.self, from: data)
    }
}

private enum TMDBError: LocalizedError {
    case requestFailed
    var errorDescription: String? { "无法获取 TMDB 资料，请检查令牌和网络连接。" }
}
