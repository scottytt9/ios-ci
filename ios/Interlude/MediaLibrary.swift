import Foundation
import Security

enum LibraryError: LocalizedError {
    case key, storage, response, link, history, responseHint(String)
    var errorDescription: String? {
        switch self {
        case .key: return "Enter your TorBox API key."
        case .storage: return "The iPhone Keychain could not save the TorBox key."
        case .response: return "TorBox could not complete the request. Check your key and the file's download status."
        case .link: return "A valid HTTPS video link was not available."
        case .history: return "Choose a watch-history JSON file exported by Interlude."
        case .responseHint(let input): return "Check the \(input.lowercased()) and try again."
        }
    }
}

enum TorBoxSource: String, Codable {
    case torrents, usenet, webdl

    var idParameter: String {
        switch self {
        case .torrents: "torrent_id"
        case .usenet: "usenet_id"
        case .webdl: "web_id"
        }
    }
}

struct SourceVideo: Identifiable, Codable {
    let title: String
    let collection: String
    let download: Int
    let file: Int
    let source: TorBoxSource
    var hash: String? = nil
    var id: String { "file:\(source.rawValue):\(download):\(file)" }
    private static let associationKey = "torbox-playback-files"

    static func remembered(for id: String) -> SourceVideo? {
        guard let data = UserDefaults.standard.dictionary(forKey: associationKey)?[id] as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func reference(for playback: HistoryEntry.Playback) -> SourceVideo? {
        let parts = playback.id.split(separator: ":")
        guard parts.count == 4, parts[0] == "file", let source = TorBoxSource(rawValue: String(parts[1])),
              let download = Int(parts[2]), let file = Int(parts[3]), download >= 0, file >= 0 else { return nil }
        return SourceVideo(title: playback.media.title, collection: "", download: download, file: file, source: source)
    }

    func remember(for id: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        var associations = UserDefaults.standard.dictionary(forKey: Self.associationKey) ?? [:]
        associations[id] = data
        UserDefaults.standard.set(associations, forKey: Self.associationKey)
    }

    static func forgetAssociations() { UserDefaults.standard.removeObject(forKey: associationKey) }
    var playback: HistoryEntry.Playback {
        .init(id: id, media: .init(key: id, kind: "file", title: title, year: nil, id: nil, description: nil,
            genres: nil, poster: nil, backdrop: nil, imdbId: nil, runtime: nil), label: nil, episode: nil)
    }

    func matches(_ selected: HistoryEntry.Playback) -> Bool {
        if id == selected.id { return true }
        guard selected.media.kind == "movie" || selected.episode != nil else { return false }
        func words(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ").lowercased()
        }
        let name = words(selected.media.title)
        let filename = words((title as NSString).deletingPathExtension)
        let folder = words(collection)
        guard !name.isEmpty, filename.range(of: "(?:^| )(?:sample|trailer|extras)(?: |$)", options: .regularExpression) == nil else { return false }
        if let episode = selected.episode {
            let tag = "(?:^| )(?:s0*\(episode.season) *e0*\(episode.number)|0*\(episode.season)x0*\(episode.number))(?: |$)"
            return (filename.hasPrefix(name + " ") || folder == name || folder.hasPrefix(name + " ")) &&
                filename.range(of: tag, options: .regularExpression) != nil
        }
        if filename == name { return true }
        guard filename.hasPrefix(name + " ") else { return false }
        let suffix = filename.dropFirst(name.count + 1)
        if let year = selected.media.year, !year.isEmpty, suffix.hasPrefix(year + " ") || suffix == year { return true }
        return suffix.range(of: "^(?:[0-9]{3,4}p|4k|uhd|bluray|web dl|web rip)(?: |$)", options: .regularExpression) != nil
    }
}

struct TorBox {
    private static let host = "api.torbox.app"
    private static let service = "app.interlude.ios"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private static let http: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func key(account: String = "TorBox") -> String? {
        var result: CFTypeRef?
        let fields = query(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, b in b }
        guard SecItemCopyMatching(fields as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String, account: String = "TorBox") throws {
        let data = Data(key.utf8)
        let query = query(account)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw LibraryError.storage }
        let fields = query.merging([
            kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, b in b }
        guard SecItemAdd(fields as CFDictionary, nil) == errSecSuccess else { throw LibraryError.storage }
    }

    static func remove(account: String = "TorBox") { SecItemDelete(query(account) as CFDictionary) }

    static func library(key: String, torrent: Int? = nil) async throws -> [SourceVideo] {
        guard !key.isEmpty, key.utf8.count < 2048, !key.contains(where: \.isWhitespace) else { throw LibraryError.key }
        if let torrent { return try await files(key: key, source: .torrents, download: torrent) }
        async let torrents = try? files(key: key, source: .torrents)
        async let usenet = try? files(key: key, source: .usenet)
        async let web = try? files(key: key, source: .webdl)
        let results = await [torrents, usenet, web].compactMap { $0 }
        guard !results.isEmpty else { throw LibraryError.response }
        return results.flatMap { $0 }
    }

    private static func files(key: String, source: TorBoxSource, download: Int? = nil) async throws -> [SourceVideo] {
        let query: [URLQueryItem] = download.map {
            [.init(name: "id", value: String($0)), .init(name: "bypass_cache", value: "true"), .init(name: "files", value: "true")]
        } ?? [
            URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "files", value: "true"),
        ]
        let data = try await request("/\(source.rawValue)/mylist", key: key, query: query)
        let rows: Any = try payload(data)
        let torrents = rows as? [[String: Any]] ?? (rows as? [String: Any]).map { [$0] } ?? []
        let formats = ["mp4", "m4v", "mov", "mkv", "webm", "ts", "m2ts", "avi"]
        return torrents.flatMap { torrent -> [SourceVideo] in
            guard let id = torrent["id"] as? Int, id >= 0, let files = torrent["files"] as? [[String: Any]],
                  torrent["download_finished"] as? Bool == true || torrent["download_present"] as? Bool == true ||
                    ["cached", "completed", "seeding"].contains(torrent["download_state"] as? String ?? "") else { return [] }
            let rawHash = (torrent["hash"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hash = rawHash.flatMap { $0.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil ? $0 : nil }
            return files.compactMap { file in
                guard let fileID = file["id"] as? Int, fileID >= 0,
                      let name = (file["short_name"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? file["name"] as? String,
                      let basename = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last,
                      formats.contains((String(basename) as NSString).pathExtension.lowercased()) else { return nil }
                return SourceVideo(title: String(basename), collection: torrent["name"] as? String ?? "", download: id, file: fileID, source: source, hash: hash)
            }
        }
    }

    static func url(for item: SourceVideo) async throws -> URL {
        guard let key = key() else { throw LibraryError.key }
        let data = try await request("/\(item.source.rawValue)/requestdl", key: key, query: [
            .init(name: "token", value: key), .init(name: item.source.idParameter, value: String(item.download)),
            .init(name: "file_id", value: String(item.file)), .init(name: "redirect", value: "false"), .init(name: "zip_link", value: "false"),
        ])
        let value: String = try payload(data)
        guard let url = playbackURL(value), let host = url.host?.lowercased(),
              host == "tb-cdn.st" || host.hasSuffix(".tb-cdn.st") || host.hasSuffix(".torbox.app") else { throw LibraryError.link }
        return url
    }

    static func playbackURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func request(_ route: String, key: String, query: [URLQueryItem] = [], body: Data? = nil,
                        contentType: String = "application/json") async throws -> Data {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.path = "/v1/api" + route
        url.queryItems = query
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await http.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 12_000_000 else { throw LibraryError.response }
            return data
        } catch { throw LibraryError.response }
    }

    static func payload<T>(_ data: Data) throws -> T {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["success"] as? Bool == true, let payload = object["data"] as? T else { throw LibraryError.response }
        return payload
    }
}
