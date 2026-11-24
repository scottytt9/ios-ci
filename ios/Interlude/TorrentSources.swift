import Foundation

struct TorrentRelease: Identifiable {
    let hash: String
    let index: Int?
    let filename: String?
    let name: String
    let description: String
    var cached: Bool? = nil
    var id: String { hash + ":" + (index.map { String($0) } ?? filename ?? "") }
}

enum TorrentSources {
    static let account = "Stream add-on"
    private static let http = URLSession(configuration: .ephemeral, delegate: TorBox.NoRedirect(), delegateQueue: nil)

    static func connect(_ raw: String) async throws {
        guard let address = manifest(raw)?.url else { throw Error.invalidManifest }
        let response = try await json(address)
        let supported = (response["resources"] as? [Any] ?? []).contains {
            $0 as? String == "stream" || ($0 as? [String: Any])?["name"] as? String == "stream"
        }
        guard supported else { throw Error.invalidManifest }
        try TorBox.save(raw, account: account)
    }

    static func lookup(_ selection: HistoryEntry.Playback) async throws -> [TorrentRelease] {
        guard let raw = TorBox.key(account: account), var address = manifest(raw) else { throw Error.invalidManifest }
        guard let imdb = try await Catalogue.imdb(selection.media), imdb.range(of: "^tt[0-9]{7,12}$", options: .regularExpression) != nil else { throw Error.title }
        let path: String
        if selection.media.kind == "movie" { path = "movie/\(imdb).json" }
        else if let episode = selection.episode { path = "series/\(imdb):\(episode.season):\(episode.number).json" }
        else { throw Error.title }
        address.percentEncodedPath = String(address.percentEncodedPath.dropLast("manifest.json".count)) + "stream/" + path
        guard let url = address.url else { throw Error.invalidManifest }
        let response = try await json(url)
        var seen = Set<String>()
        var releases: [TorrentRelease] = []
        for stream in response["streams"] as? [[String: Any]] ?? [] {
            guard let hash = (stream["infoHash"] as? String)?.lowercased(), hash.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { continue }
            let hints = stream["behaviorHints"] as? [String: Any]
            let candidate = TorrentRelease(hash: hash, index: stream["fileIdx"] as? Int, filename: hints?["filename"] as? String,
                name: String((stream["name"] as? String ?? "Torrent source").prefix(120)),
                description: String((stream["description"] as? String ?? stream["title"] as? String ?? "").prefix(320)))
            if seen.insert(candidate.id).inserted { releases.append(candidate) }
            if releases.count >= 60 { break }
        }
        guard let key = TorBox.key(), !releases.isEmpty else { return releases }
        if let cached = try? await cache(releases, key: key) {
            releases = releases.enumerated().sorted {
                let a = cached.contains($0.element.hash), b = cached.contains($1.element.hash)
                return a == b ? $0.offset < $1.offset : a && !b
            }.map { index, item in
                var value = item; value.cached = cached.contains(item.hash); return value
            }
        }
        return releases
    }

    static func add(_ item: TorrentRelease) async throws -> [SourceVideo] {
        guard let key = TorBox.key() else { throw LibraryError.key }
        let boundary = UUID().uuidString
        let body = "--\(boundary)\r\nContent-Disposition: form-data; name=\"magnet\"\r\n\r\nmagnet:?xt=urn:btih:\(item.hash)\r\n" +
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"add_only_if_cached\"\r\n\r\n\(item.cached == false ? "false" : "true")\r\n--\(boundary)--\r\n"
        let response = try await TorBox.request("/torrents/createtorrent", key: key, body: Data(body.utf8), contentType: "multipart/form-data; boundary=\(boundary)")
        let payload: [String: Any] = try TorBox.payload(response)
        guard item.cached != false, let id = payload["torrent_id"] as? Int ?? payload["id"] as? Int else { return [] }
        for delay in [0, 250, 500, 850, 1200] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            if let files = try? await TorBox.library(key: key, torrent: id), !files.isEmpty { return files }
        }
        return []
    }

    private static func cache(_ items: [TorrentRelease], key: String) async throws -> Set<String> {
        let query: [URLQueryItem] = [.init(name: "format", value: "list"), .init(name: "list_files", value: "false")]
        let body = try JSONEncoder().encode(["hashes": Array(Set(items.map(\.hash)))])
        let data = try await TorBox.request("/torrents/checkcached", key: key, query: query, body: body)
        let payload: Any = try TorBox.payload(data)
        if let list = payload as? [Any] {
            return Set(list.compactMap {
                if let hash = $0 as? String { return hash.lowercased() }
                guard let row = $0 as? [String: Any], row["cached"] as? Bool != false else { return nil }
                return (row["hash"] as? String)?.lowercased()
            })
        }
        if let object = payload as? [String: Any] {
            return Set(object.compactMap { key, value in
                value is NSNull || value as? Bool == false || (value as? [String: Any])?["cached"] as? Bool == false ? nil : key.lowercased()
            })
        }
        if payload is NSNull { return [] }
        throw Error.provider
    }

    private static func manifest(_ text: String) -> URLComponents? {
        guard text.utf8.count <= 2048, var value = URLComponents(string: text),
              value.host != nil, value.user == nil, value.password == nil, value.fragment == nil,
              value.percentEncodedPath.hasSuffix("/manifest.json") else { return nil }
        if value.scheme == "stremio" { value.scheme = "https" }
        return value.scheme == "https" ? value : nil
    }

    private static func json(_ url: URL) async throws -> [String: Any] {
        do {
            let (data, response) = try await http.data(for: URLRequest(url: url, timeoutInterval: 12))
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 3_000_000,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Error.provider }
            return body
        } catch { throw Error.provider }
    }

    enum Error: LocalizedError {
        case invalidManifest, title, provider
        var errorDescription: String? {
            switch self {
            case .invalidManifest: return "Enter the HTTPS manifest.json address for an add-on with stream results."
            case .title: return "The selected movie or episode has no usable source ID."
            case .provider: return "The stream add-on could not complete the request."
            }
        }
    }
}
