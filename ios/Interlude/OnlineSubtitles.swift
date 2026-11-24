import Foundation

struct OnlineSubtitle: Identifiable, Hashable, Sendable {
    let id: String
    let lang: String
    let label: String
    let url: URL
}

enum OnlineSubtitles {
    enum Failure: LocalizedError {
        case missingSelection, missingImdb, unsupportedKind, episodeRequired, invalidResponse, unsupportedURL, tooManyRedirects, tooLarge, unreadable

        var errorDescription: String? {
            switch self {
            case .missingSelection: return "No title is selected for online subtitles."
            case .missingImdb: return "No IMDb ID is available for online subtitles."
            case .unsupportedKind: return "Online subtitles are only available for movies and TV shows."
            case .episodeRequired: return "Choose an episode first."
            case .invalidResponse: return "OpenSubtitles didn’t return a valid subtitle list."
            case .unsupportedURL: return "Unsupported subtitle URL."
            case .tooManyRedirects: return "Too many subtitle redirects."
            case .tooLarge: return "Subtitle file is too large."
            case .unreadable: return "Couldn’t read those subtitles."
            }
        }
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        private var hops = 0

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            hops += 1
            guard hops <= 2, OnlineSubtitles.allowedURL(request.url) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    static func allowedURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty else { return false }
        return host == "strem.io" || host.hasSuffix(".strem.io")
            || host == "opensubtitles.org" || host.hasSuffix(".opensubtitles.org")
    }

    static func lookup(for selection: HistoryEntry.Playback?) async throws -> [OnlineSubtitle] {
        guard let selection else { throw Failure.missingSelection }
        let media = selection.media
        guard media.kind == "movie" || media.kind == "tv" else { throw Failure.unsupportedKind }
        guard let imdb = try await Catalogue.imdb(media),
              imdb.range(of: "^tt[0-9]{7,12}$", options: .regularExpression) != nil else {
            throw Failure.missingImdb
        }
        let route: String
        if media.kind == "movie" {
            route = "movie/\(imdb)"
        } else {
            guard let episode = selection.episode, episode.number >= 1 else { throw Failure.episodeRequired }
            route = "series/\(imdb):\(episode.season):\(episode.number)"
        }
        guard let endpoint = URL(string: "https://opensubtitles-v3.strem.io/subtitles/\(route).json") else {
            throw Failure.invalidResponse
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 4 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        let rows = root["subtitles"] as? [[String: Any]] ?? []
        var result: [OnlineSubtitle] = []
        var counts: [String: Int] = [:]
        for row in rows {
            if result.count >= 28 { break }
            guard let raw = (row["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: raw),
                  allowedURL(url) else { continue }
            let langRaw = (row["lang"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "und"
            let lang = langRaw.isEmpty ? "und" : langRaw
            let nextCount = (counts[lang] ?? 0) + 1
            if nextCount > 4 { continue }
            counts[lang] = nextCount
            let id = (row["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(lang)-\(nextCount)"
            let base = languageLabel(lang)
            let label = nextCount > 1 ? "\(base) #\(nextCount)" : base
            result.append(OnlineSubtitle(id: id, lang: lang, label: label, url: url))
        }
        var english: [OnlineSubtitle] = []
        var other: [OnlineSubtitle] = []
        for item in result {
            if item.lang == "eng" || item.lang == "en" { english.append(item) }
            else { other.append(item) }
        }
        return english + other
    }

    static func download(_ url: URL) async throws -> String {
        guard allowedURL(url) else { throw Failure.unsupportedURL }
        let guardDelegate = RedirectGuard()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw Failure.tooManyRedirects
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              allowedURL(http.url ?? url) else {
            throw Failure.unreadable
        }
        guard data.count <= 4 * 1024 * 1024 else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw Failure.unreadable
        }
        return text
    }

    private static func languageLabel(_ code: String) -> String {
        switch code {
        case "eng", "en": return "English"
        case "spa", "es": return "Spanish"
        case "fre", "fra", "fr": return "French"
        case "ger", "deu", "de": return "German"
        case "ita", "it": return "Italian"
        case "por", "pt": return "Portuguese"
        case "pob", "pt-br": return "Portuguese (BR)"
        case "dut", "nld", "nl": return "Dutch"
        case "jpn", "ja": return "Japanese"
        case "kor", "ko": return "Korean"
        case "chi", "zho", "zh": return "Chinese"
        case "ara", "ar": return "Arabic"
        case "rus", "ru": return "Russian"
        case "pol", "pl": return "Polish"
        case "tur", "tr": return "Turkish"
        case "swe", "sv": return "Swedish"
        case "nor", "no": return "Norwegian"
        case "dan", "da": return "Danish"
        case "fin", "fi": return "Finnish"
        case "hin", "hi": return "Hindi"
        case "ind", "id": return "Indonesian"
        case "vie", "vi": return "Vietnamese"
        case "ukr", "uk": return "Ukrainian"
        default: return code.uppercased()
        }
    }
}
