import Foundation

struct CatalogueTitle: Identifiable {
    let media: HistoryEntry.Playback.Media
    var id: String { media.key }
    let seasons: [Int]
    let cast: [CatalogueActor]
    let related: [CatalogueTitle]
    let reviews: [CatalogueReview]
    let tagline: String?
    let director: String?
    let status: String?
    let trailer: String?
    let logo: String?
    let collectionID: Int?
    let collectionName: String?

    init(snapshot: HistoryEntry.Playback.Media) {
        media = snapshot
        seasons = []
        cast = []
        related = []
        reviews = []
        tagline = nil
        director = nil
        status = nil
        trailer = nil
        logo = nil
        collectionID = nil
        collectionName = nil
    }

    init?(_ row: [String: Any], kind forced: String? = nil) {
        let kind = forced ?? row["media_type"] as? String ?? ""
        guard (kind == "movie" || kind == "tv"), let id = row["id"] as? Int, id > 0,
              row["adult"] as? Bool != true, let name = row[kind == "movie" ? "title" : "name"] as? String, !name.isEmpty else { return nil }
        let date = row[kind == "movie" ? "release_date" : "first_air_date"] as? String ?? ""
        let genres = (row["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        let external = row["external_ids"] as? [String: Any]
        let runtime = (row["runtime"] as? Double) ?? (row["episode_run_time"] as? [Double])?.first
        media = .init(key: "\(kind):\(id)", kind: kind, title: name, year: String(date.prefix(4)), id: id,
            description: row["overview"] as? String, genres: genres, poster: Self.image(row["poster_path"], size: "w500"),
            backdrop: Self.image(row["backdrop_path"], size: "w1280"), imdbId: external?["imdb_id"] as? String ?? row["imdb_id"] as? String,
            runtime: runtime, rating: row["vote_average"] as? Double, releaseDate: date)
        seasons = (row["seasons"] as? [[String: Any]] ?? []).compactMap { $0["season_number"] as? Int }.sorted()
        let credits = row["credits"] as? [String: Any]
        var seen = Set<Int>()
        cast = (credits?["cast"] as? [[String: Any]] ?? []).prefix(18).compactMap {
            guard let id = $0["id"] as? Int, id > 0, seen.insert(id).inserted, let name = $0["name"] as? String else { return nil }
            return CatalogueActor(id: id, name: name, role: $0["character"] as? String, photo: Self.image($0["profile_path"], size: "w185"))
        }
        let recommendations = row["recommendations"] as? [String: Any]
        related = Array((recommendations?["results"] as? [[String: Any]] ?? []).prefix(16)).compactMap { Self($0, kind: kind) }
        let reviewRows = row["reviews"] as? [String: Any]
        reviews = (reviewRows?["results"] as? [[String: Any]] ?? []).prefix(8).compactMap {
            guard let id = $0["id"] as? String, let author = $0["author"] as? String, let content = $0["content"] as? String else { return nil }
            return .init(id: id, author: author, text: String(content.prefix(8000)))
        }
        let rawTagline = (row["tagline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        tagline = rawTagline?.isEmpty == false ? rawTagline : nil
        let rawStatus = (row["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        status = rawStatus?.isEmpty == false ? rawStatus : nil
        if kind == "movie" {
            let dirs = (credits?["crew"] as? [[String: Any]] ?? [])
                .filter { ($0["job"] as? String) == "Director" }
                .compactMap { $0["name"] as? String }
            director = dirs.isEmpty ? nil : dirs.joined(separator: ", ")
        } else {
            let creators = (row["created_by"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            director = creators.isEmpty ? nil : creators.joined(separator: ", ")
        }
        trailer = Self.bestTrailer(in: row)
        logo = Self.bestLogo(in: (row["images"] as? [String: Any])?["logos"] as? [[String: Any]])
        let franchise = row["belongs_to_collection"] as? [String: Any]
        if let cid = franchise?["id"] as? Int, cid > 0, let cname = franchise?["name"] as? String, !cname.isEmpty {
            collectionID = cid
            collectionName = cname
        } else {
            collectionID = nil
            collectionName = nil
        }
    }

    static func bestLogo(in logos: [[String: Any]]?) -> String? {
        guard let logos else { return nil }
        var bestPath: String?
        var bestScore = -1.0
        for item in logos {
            guard let path = item["file_path"] as? String, path.hasPrefix("/"), path.lowercased().hasSuffix(".png") else { continue }
            let lang = (item["iso_639_1"] as? String)?.lowercased()
            if let lang, !lang.isEmpty, lang != "en", lang != "null" { continue }
            let score = (lang == "en" ? 10.0 : 0.0) + (item["vote_average"] as? Double ?? 0)
            if score > bestScore {
                bestScore = score
                bestPath = path
            }
        }
        return bestPath.flatMap { image($0, size: "w500") }
    }

    private static func bestTrailer(in row: [String: Any]) -> String? {
        let videos = (row["videos"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        var bestKey: String?
        var bestScore = -1
        for video in videos {
            guard (video["site"] as? String) == "YouTube",
                  let key = video["key"] as? String,
                  key.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil else { continue }
            let kind = video["type"] as? String ?? ""
            let official = (video["official"] as? Bool) == true
            var score = kind == "Trailer" ? 70 : kind == "Teaser" ? 30 : 10
            if official { score += 30 }
            if score > bestScore {
                bestScore = score
                bestKey = key
            }
        }
        return bestKey
    }

    func playback(season: Int? = nil, episode: CatalogueEpisode? = nil) -> HistoryEntry.Playback {
        guard let season, let episode else { return .init(id: id, media: media, label: nil, episode: nil) }
        return .init(id: "\(id):\(season):\(episode.id)", media: media, label: "S\(season) E\(episode.id) · \(episode.name)",
                     episode: .init(season: season, number: episode.id, title: episode.name))
    }

    static func image(_ raw: Any?, size: String) -> String? {
        guard let path = raw as? String, path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        return "https://image.tmdb.org/t/p/\(size)\(path)"
    }
}

struct CatalogueEpisode: Identifiable { let id: Int; let name: String; let overview: String; let still: String?; let runtime: Int? }
struct CatalogueGenre: Identifiable { let id: Int; let name: String }
struct CatalogueActor: Identifiable { let id: Int; let name: String; let role: String?; let photo: String? }
struct CatalogueReview: Identifiable { let id: String; let author: String; let text: String }
struct CataloguePerson { let biography: String; let titles: [CatalogueTitle] }
struct CatalogueCollection { let id: Int; let name: String; let overview: String; let backdrop: String?; let parts: [CatalogueTitle] }
struct CatalogueEpisodeCredits { let guestStars: [CatalogueActor]; let cast: [CatalogueActor] }

enum Catalogue {
    enum Shelf: String, CaseIterable, Identifiable {
        case trending = "For You", movies = "Movies", shows = "TV Shows", topRated = "Top Rated", recommended = "Recommended"
        var id: String { rawValue }
        var kind: String? {
            switch self {
            case .movies, .topRated: return "movie"
            case .shows: return "tv"
            default: return nil
            }
        }
    }

    struct Page { let titles: [CatalogueTitle]; let people: [CatalogueActor]; let more: Bool }
    static let account = "TMDB"
    private static let http = URLSession(configuration: .ephemeral)

    static func feed(shelf: Shelf, query: String, genre: Int?, page: Int, seed: HistoryEntry.Playback.Media?) async throws -> Page {
        var parameters = [URLQueryItem(name: "page", value: String(page)), .init(name: "include_adult", value: "false")]
        let route: String
        let kind: String?
        if !query.isEmpty {
            kind = shelf == .topRated ? "movie" : shelf.kind
            route = "search/\(kind ?? "multi")"
            parameters.append(.init(name: "query", value: query))
        } else if shelf == .topRated {
            kind = "movie"
            route = genre == nil ? "movie/top_rated" : "discover/movie"
            if let genre {
                parameters.append(.init(name: "with_genres", value: String(genre)))
                parameters.append(.init(name: "sort_by", value: "vote_average.desc"))
                parameters.append(.init(name: "vote_count.gte", value: "150"))
            }
        } else if let kindValue = shelf.kind {
            kind = kindValue
            route = genre == nil ? "\(kindValue)/popular" : "discover/\(kindValue)"
            if let genre { parameters.append(.init(name: "with_genres", value: String(genre))) }
        } else if shelf == .recommended, let seed, let id = seed.id {
            kind = seed.kind
            route = "\(seed.kind)/\(id)/recommendations"
        } else {
            kind = nil
            route = "trending/all/week"
        }
        let response = try await request(route, parameters: parameters)
        let rawRows = response["results"] as? [[String: Any]] ?? []
        let titles = rawRows.compactMap { CatalogueTitle($0, kind: kind) }
        let people: [CatalogueActor] = (!query.isEmpty && kind == nil) ? Array(rawRows.compactMap { row -> CatalogueActor? in
            guard (row["media_type"] as? String) == "person", let id = row["id"] as? Int, id > 0,
                  let name = row["name"] as? String, !name.isEmpty else { return nil }
            return CatalogueActor(id: id, name: name, role: row["known_for_department"] as? String,
                                  photo: CatalogueTitle.image(row["profile_path"], size: "w185"))
        }.prefix(12)) : []
        return .init(titles: titles, people: people, more: page < min(response["total_pages"] as? Int ?? 1, 500))
    }

    static func genres(kind: String) async throws -> [CatalogueGenre] {
        let response = try await request("genre/\(kind)/list")
        return (response["genres"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? Int, let name = $0["name"] as? String else { return nil }
            return .init(id: id, name: name)
        }
    }

    static func details(_ title: CatalogueTitle) async throws -> CatalogueTitle {
        guard let id = title.media.id else { return title }
        let row = try await request("\(title.media.kind)/\(id)", parameters: [
            .init(name: "append_to_response", value: "credits,recommendations,external_ids,videos,images"),
            .init(name: "include_image_language", value: "en,null"),
        ])
        return CatalogueTitle(row, kind: title.media.kind) ?? title
    }

    static func collection(id: Int) async throws -> CatalogueCollection {
        let row = try await request("collection/\(id)")
        let rawParts = (row["parts"] as? [[String: Any]] ?? []).compactMap { CatalogueTitle($0, kind: "movie") }
            .sorted { ($0.media.releaseDate ?? "9999") < ($1.media.releaseDate ?? "9999") }
        return CatalogueCollection(
            id: row["id"] as? Int ?? id,
            name: row["name"] as? String ?? "Collection",
            overview: row["overview"] as? String ?? "",
            backdrop: CatalogueTitle.image(row["backdrop_path"], size: "w1280"),
            parts: rawParts
        )
    }

    static func episodeCredits(showID: Int, season: Int, episode: Int) async throws -> CatalogueEpisodeCredits {
        let row = try await request("tv/\(showID)/season/\(season)/episode/\(episode)/credits")
        func mapActors(_ rows: [[String: Any]]?, limit: Int) -> [CatalogueActor] {
            var seen = Set<Int>()
            return (rows ?? []).prefix(limit).compactMap {
                guard let id = $0["id"] as? Int, id > 0, seen.insert(id).inserted,
                      let name = $0["name"] as? String, !name.isEmpty else { return nil }
                return CatalogueActor(id: id, name: name, role: $0["character"] as? String,
                                      photo: CatalogueTitle.image($0["profile_path"], size: "w185"))
            }
        }
        return CatalogueEpisodeCredits(
            guestStars: mapActors(row["guest_stars"] as? [[String: Any]], limit: 14),
            cast: mapActors(row["cast"] as? [[String: Any]], limit: 18)
        )
    }

    static func logoURL(kind: String, id: Int) async throws -> String? {
        guard (kind == "movie" || kind == "tv"), id > 0 else { return nil }
        let row = try await request("\(kind)/\(id)/images", parameters: [.init(name: "include_image_language", value: "en,null")])
        return CatalogueTitle.bestLogo(in: row["logos"] as? [[String: Any]])
    }

    static func person(_ actor: CatalogueActor) async throws -> CataloguePerson {
        let row = try await request("person/\(actor.id)", parameters: [.init(name: "append_to_response", value: "combined_credits")])
        let credits = (row["combined_credits"] as? [String: Any])?["cast"] as? [[String: Any]] ?? []
        var known = Set<String>()
        let ordered = credits.compactMap { CatalogueTitle($0) }.filter { known.insert($0.id).inserted }
            .sorted { ($0.media.releaseDate ?? "") > ($1.media.releaseDate ?? "") }
        return CataloguePerson(biography: row["biography"] as? String ?? "", titles: Array(ordered.prefix(250)))
    }

    static func episodes(_ title: CatalogueTitle, season: Int) async throws -> [CatalogueEpisode] {
        guard let id = title.media.id else { return [] }
        let row = try await request("tv/\(id)/season/\(season)")
        return (row["episodes"] as? [[String: Any]] ?? []).compactMap {
            guard let number = $0["episode_number"] as? Int, let name = $0["name"] as? String, number > 0 else { return nil }
            return .init(id: number, name: name, overview: $0["overview"] as? String ?? "",
                         still: CatalogueTitle.image($0["still_path"], size: "w300"),
                         runtime: $0["runtime"] as? Int)
        }
    }

    static func connect(_ key: String) async throws {
        guard !key.isEmpty, key.utf8.count < 2048, !key.contains(where: \.isWhitespace) else { throw Failure.credentials }
        _ = try await request("authentication", key: key)
        try TorBox.save(key, account: account)
    }

    static func imdb(_ item: HistoryEntry.Playback.Media) async throws -> String? {
        if let existing = item.imdbId, !existing.isEmpty { return existing }
        guard let id = item.id, item.kind == "movie" || item.kind == "tv" else { return nil }
        return try await request("\(item.kind)/\(id)/external_ids")["imdb_id"] as? String
    }

    static func nextEpisode(after playback: HistoryEntry.Playback) async throws -> HistoryEntry.Playback? {
        guard let id = playback.media.id, let current = playback.episode, playback.media.kind == "tv", current.season > 0 else { return nil }
        let season = try await request("tv/\(id)/season/\(current.season)")
        if let choice = nextRow(season, after: current.number) { return episode(playback.media, number: current.season, row: choice) }
        let series = try await request("tv/\(id)")
        let all = (series["seasons"] as? [[String: Any]] ?? []).compactMap { $0["season_number"] as? Int }.sorted()
        guard let number = all.first(where: { $0 > current.season }) else { return nil }
        let next = try await request("tv/\(id)/season/\(number)")
        return nextRow(next, after: 0).map { episode(playback.media, number: number, row: $0) }
    }

    private static func nextRow(_ response: [String: Any], after: Int) -> [String: Any]? {
        let today = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return (response["episodes"] as? [[String: Any]] ?? []).first {
            ($0["episode_number"] as? Int ?? 0) > after && ($0["air_date"] as? String).map { !$0.isEmpty && $0 <= today } == true
        }
    }

    private static func episode(_ media: HistoryEntry.Playback.Media, number: Int, row: [String: Any]) -> HistoryEntry.Playback {
        let index = row["episode_number"] as? Int ?? 1
        let title = row["name"] as? String
        return .init(id: "\(media.key):\(number):\(index)", media: media, label: "S\(number) E\(index)" + (title.map { " · " + $0 } ?? ""),
                     episode: .init(season: number, number: index, title: title))
    }

    private static func request(_ route: String, parameters: [URLQueryItem] = [], key supplied: String? = nil) async throws -> [String: Any] {
        guard let key = supplied ?? TorBox.key(account: account) else { throw Failure.credentials }
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.themoviedb.org"
        url.path = "/3/" + route
        let apiKey = key.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil
        url.queryItems = apiKey ? parameters + [.init(name: "api_key", value: key)] : parameters
        guard let address = url.url else { throw Failure.response }
        var request = URLRequest(url: address, timeoutInterval: 12)
        if !apiKey { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await http.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.response }
        if response.statusCode == 401 || response.statusCode == 403 { throw Failure.credentials }
        guard response.statusCode == 200, data.count <= 8_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.response }
        return object
    }

    enum Failure: LocalizedError {
        case credentials, response
        var errorDescription: String? { self == .credentials ? "Enter a valid TMDB key or read access token." : "Unable to load the catalogue. Try again." }
    }
}
