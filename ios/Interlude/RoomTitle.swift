import Foundation

struct RoomTitle: Codable, Equatable {
    let kind: String
    let id: Int
    let name: String
    let year: String?
    let season: Int?
    let episode: Int?

    static func read(_ value: Any?) -> Self? {
        guard let value = value as? [String: Any], let bytes = try? JSONSerialization.data(withJSONObject: value),
              let title = try? JSONDecoder().decode(Self.self, from: bytes), title.valid else { return nil }
        return title
    }

    init?(_ playback: HistoryEntry.Playback) {
        guard let id = playback.media.id, playback.media.provider != "tvmaze" else { return nil }
        kind = playback.media.kind
        self.id = id
        name = String(playback.media.title.prefix(200))
        year = playback.media.year
        season = playback.episode?.season
        episode = playback.episode?.number
        guard valid else { return nil }
    }

    private var valid: Bool {
        guard (kind == "movie" || kind == "tv"), (1...2_147_483_647).contains(id),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 200,
              year == nil || year == "" || year?.range(of: "^[0-9]{4}$", options: .regularExpression) != nil else { return false }
        return kind == "movie" || ((0...999).contains(season ?? -1) && (1...9999).contains(episode ?? 0))
    }

    var playback: HistoryEntry.Playback {
        let media = HistoryEntry.Playback.Media(key: "\(kind):\(id)", kind: kind, title: name, year: year, id: id,
            description: nil, genres: nil, poster: nil, backdrop: nil, imdbId: nil, runtime: nil)
        guard kind == "tv", let season, let episode else { return .init(id: media.key, media: media, label: nil, episode: nil) }
        return .init(id: "\(media.key):\(season):\(episode)", media: media, label: "S\(season) E\(episode)",
                     episode: .init(season: season, number: episode, title: nil))
    }
}
