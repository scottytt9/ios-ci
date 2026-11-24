import Foundation

struct VideoChapter: Identifiable {
    let title: String
    let start: Double
    var id: Double { start }
}

struct PlaybackTimeline {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        enum CodingKeys: String, CodingKey { case start = "start_sec", end = "end_sec" }

        func fitted(to duration: Double) -> Self? {
            guard start >= 0, end - start >= 2, end <= duration + 8, start < duration else { return nil }
            return .init(start: start, end: min(end, duration))
        }
    }

    struct Community: Decodable {
        let intro: Segment?
        let recap: Segment?
        let outro: Segment?
        let postCredits: Segment?
        enum CodingKeys: String, CodingKey { case intro, recap, outro, postCredits = "post_credits" }
    }

    let intro: Segment?
    let recap: Segment?
    let credits: Segment?
    let advanceAtCredits: Bool

    private static let opening = "^(?:(?:intro(?:duction)?|opening)(?: (?:credits|theme|sequence))?|title sequence|op)$"
    private static let summary = "^(?:recap|previously on(?: .+)?|previous episode recap|last time(?: on .+)?)$"
    private static let ending = "^(?:(?:(?:end|ending|closing|final) )?credits(?: roll)?|outro|ending theme|ed)$"
    private static let session = URLSession(configuration: .ephemeral)

    init(chapters: [VideoChapter] = [], duration: Double, community: Community?) {
        guard duration.isFinite, duration > 0 else { intro = nil; recap = nil; credits = nil; advanceAtCredits = false; return }
        let ordered = chapters.filter { $0.start >= 0 && $0.start < duration }.sorted { $0.start < $1.start }
        func matches(_ chapter: VideoChapter, _ pattern: String) -> Bool {
            let name = chapter.title.precomposedStringWithCompatibilityMapping.lowercased()
                .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return name.range(of: pattern, options: .regularExpression) != nil
        }
        func chapterInterval(_ pattern: String) -> Segment? {
            for index in ordered.indices.dropLast() where matches(ordered[index], pattern) {
                let segment = Segment(start: ordered[index].start, end: ordered[index + 1].start)
                if segment.end > segment.start + 1 { return segment }
            }
            return nil
        }
        var chapterCredits: Segment?
        var after: VideoChapter?
        if let index = ordered.firstIndex(where: { matches($0, Self.ending) }) {
            after = ordered.dropFirst(index + 1).first { !matches($0, Self.ending) }
            chapterCredits = Segment(start: ordered[index].start, end: after?.start ?? duration)
        }
        let matching = community?.outro.map { abs((community?.postCredits?.end ?? $0.end) - duration) <= 8 } ?? true
        func fitted(_ segment: Segment?) -> Segment? {
            guard matching, let segment = segment?.fitted(to: duration), segment.end - segment.start <= 300 else { return nil }
            return segment
        }
        let introSegment = chapterInterval(Self.opening) ?? fitted(community?.intro)
        intro = introSegment
        let recapSegment = chapterInterval(Self.summary) ?? fitted(community?.recap)
        if let recapSegment, let introSegment, introSegment.start > recapSegment.start {
            let end = min(recapSegment.end, introSegment.start)
            recap = end > recapSegment.start + 1 ? Segment(start: recapSegment.start, end: end) : nil
        } else { recap = recapSegment }
        credits = chapterCredits ?? (matching ? community?.outro?.fitted(to: duration) : nil)
        advanceAtCredits = credits.map {
            after == nil && community?.postCredits == nil && duration - $0.end <= 8 && $0.start >= duration * 0.55 && duration - $0.start <= 900
        } ?? false
    }

    static func lookup(imdb: String, season: Int?, episode: Int?) async throws -> Community? {
        guard imdb.range(of: "^tt[0-9]{7,8}$", options: .regularExpression) != nil,
              var url = URLComponents(string: "https://api.introdb.app/segments") else { return nil }
        var fields = [URLQueryItem(name: "imdb_id", value: imdb)]
        if let season, let episode, season > 0 && episode > 0 {
            fields += [.init(name: "season", value: String(season)), .init(name: "episode", value: String(episode))]
        } else if season == nil && episode == nil { fields.append(.init(name: "is_movie", value: "true")) }
        else { return nil }
        url.queryItems = fields
        guard let address = url.url else { return nil }
        let (data, response) = try await session.data(for: URLRequest(url: address, timeoutInterval: 4))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536 else { return nil }
        return try JSONDecoder().decode(Community.self, from: data)
    }
}
