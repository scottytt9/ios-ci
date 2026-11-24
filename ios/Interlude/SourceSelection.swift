import Foundation

enum QualityProfile: String, CaseIterable, Identifiable {
    case uhd4k = "4k"
    case balanced1080p = "1080p"
    case dataSaver = "saver"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .uhd4k: return "Best 4K HDR"
        case .balanced1080p: return "Balanced 1080p"
        case .dataSaver: return "Data Saver"
        }
    }
    var summary: String {
        switch self {
        case .uhd4k: return "Prioritises 4K, Dolby Vision, HDR & Atmos"
        case .balanced1080p: return "Fast-starting Full HD streams"
        case .dataSaver: return "Compact 720p/HEVC streams for cellular"
        }
    }

    static var current: QualityProfile {
        get { QualityProfile(rawValue: UserDefaults.standard.string(forKey: "quality-profile") ?? "") ?? .balanced1080p }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "quality-profile") }
    }
}

struct ReleaseMeta {
    let cleanTitle: String
    let resolution: String
    let badges: [String]
}

enum SourceSelection {
    static func parseMeta(_ raw: String) -> ReleaseMeta {
        let base = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? raw
        let noExt = base.replacingOccurrences(of: "\\.(mkv|mp4|avi|mov|m4v|webm)$", with: "", options: [.regularExpression, .caseInsensitive])
        let label = raw.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        func has(_ pattern: String) -> Bool { label.range(of: "\\b(?:\(pattern))\\b", options: .regularExpression) != nil }

        var badges: [String] = []
        var res = ""
        if has("2160p|4k|uhd") { res = "4K UHD"; badges.append(res) }
        else if has("1080p|1080i") { res = "1080p"; badges.append(res) }
        else if has("720p") { res = "720p"; badges.append(res) }
        if has("dv|dovi|dolby vision") { badges.append("Dolby Vision") }
        else if has("hdr10|hdr10plus|hdr") { badges.append("HDR") }
        if has("atmos") { badges.append("Atmos") }
        else if has("truehd|dts|dtshd|ddp5|eac3|ac3|5 1|7 1") { badges.append("5.1") }
        if has("remux") { badges.append("Remux") }
        else if has("h265|x265|hevc|av1") { badges.append("HEVC") }

        let spaced = noExt.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
        let cutPattern = "(?i)\\b(2160p|4k|uhd|1080p|1080i|720p|480p|web[-. ]?dl|webrip|bluray|bdrip|remux|hdr10\\+?|hdr|dovi|dolby|x264|x265|h\\.?264|h\\.?265|hevc|av1|aac|ddp|eac3|atmos|truehd|dts|10bit)\\b.*$"
        let cut = spaced.replacingOccurrences(of: cutPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "(-[")))
        let clean = cut.count >= 2 ? cut : spaced.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReleaseMeta(cleanTitle: clean.isEmpty ? raw : clean, resolution: res, badges: Array(badges.prefix(4)))
    }

    static func rank(_ name: String, profile: QualityProfile = .current) -> Int {
        let label = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        func has(_ pattern: String) -> Bool { label.range(of: "\\b(?:\(pattern))\\b", options: .regularExpression) != nil }
        if has("cam|camrip|hdcam|telesync|hdts|telecine|sample|trailer|extras") { return -1 }
        let uhd = has("2160p|4k|uhd")
        let fhd = has("1080p|1080i")
        let hd = has("720p")
        var resolution: Int
        switch profile {
        case .uhd4k:
            resolution = uhd ? 50 : fhd ? 38 : hd ? 22 : 10
            if has("dv|dovi|dolby vision|hdr10|hdr") { resolution += 6 }
            if has("atmos|remux") { resolution += 4 }
        case .dataSaver:
            resolution = hd ? 46 : fhd ? 34 : uhd ? 16 : 24
            if has("h265|x265|hevc|av1") { resolution += 6 }
        case .balanced1080p:
            resolution = fhd ? 40 : uhd ? 32 : hd ? 24 : 12
        }
        return resolution + (has("web|bluray|bdrip|webdl|webrip") ? 4 : 0) + (has("h264|x264|avc") ? 2 : 0)
    }

    static func best(_ files: [SourceVideo], for selection: HistoryEntry.Playback) -> SourceVideo? {
        files.filter { $0.matches(selection) && rank($0.title) >= 0 }
            .max { rank($0.title) < rank($1.title) }
    }

    static func cached(for selection: HistoryEntry.Playback) async throws -> SourceVideo? {
        let releases = try await TorrentSources.lookup(selection)
        let candidates = releases.filter { $0.cached == true }.map { release in
            (release: release, score: rank([release.name, release.filename ?? "", release.description].joined(separator: " ")))
        }
        guard let release = candidates.filter({ $0.score >= 0 }).max(by: { $0.score < $1.score })?.release else { return nil }
        try Task.checkCancellation()
        let ready = try await TorrentSources.add(release).filter { rank($0.title) >= 0 }
        if let match = best(ready, for: selection) { return match }
        let filename = release.filename.flatMap { $0.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last?.lowercased() }
        let named = ready.filter { $0.title.lowercased() == filename }
        if named.count == 1 { return named.first }
        if let index = release.index, let match = ready.first(where: { $0.file == index }) { return match }
        return selection.media.kind == "movie" && ready.count == 1 ? ready.first : nil
    }

    static func match(_ files: [SourceVideo], source: RoomSource, for selection: HistoryEntry.Playback?) -> SourceVideo? {
        let targetName = source.filename?.lowercased()
        let targetRelease = source.release?.lowercased()
        if let hash = source.hash {
            let byHash = files.filter { $0.hash?.lowercased() == hash }
            if !byHash.isEmpty {
                if let targetName, let exact = byHash.first(where: { $0.title.lowercased() == targetName }) { return exact }
                if let selection, let matched = best(byHash, for: selection) { return matched }
                if byHash.count == 1 { return byHash.first }
            }
        }
        if let targetName, let exact = files.first(where: { $0.title.lowercased() == targetName }) { return exact }
        if let targetRelease {
            let byRelease = files.filter { $0.collection.lowercased() == targetRelease }
            if !byRelease.isEmpty {
                if let selection, let matched = best(byRelease, for: selection) { return matched }
                if byRelease.count == 1 { return byRelease.first }
            }
        }
        return nil
    }

    static func resolve(source: RoomSource, for selection: HistoryEntry.Playback?) async throws -> (SourceVideo, URL)? {
        guard let key = TorBox.key() else { return nil }
        if let files = try? await TorBox.library(key: key),
           let file = match(files, source: source, for: selection),
           let url = try? await TorBox.url(for: file) {
            return (file, url)
        }
        try Task.checkCancellation()
        guard let hash = source.hash else { return nil }
        let release = TorrentRelease(hash: hash, index: nil, filename: source.filename, name: source.displayName, description: "", cached: true)
        let ready = try await TorrentSources.add(release)
        let picked = match(ready, source: source, for: selection)
            ?? selection.flatMap { best(ready, for: $0) }
            ?? ready.first
        guard let picked else { return nil }
        return (picked, try await TorBox.url(for: picked))
    }

    static func resolve(_ selection: HistoryEntry.Playback, maySearch: Bool, preferredSource: RoomSource? = nil) async throws -> (SourceVideo, URL)? {
        if let preferredSource, let matched = try? await resolve(source: preferredSource, for: selection) { return matched }
        let remembered = SourceVideo.remembered(for: selection.id) ?? SourceVideo.reference(for: selection)
        if let remembered, let url = try? await TorBox.url(for: remembered) { return (remembered, url) }
        try Task.checkCancellation()
        guard let key = TorBox.key() else { return nil }
        if let files = try? await TorBox.library(key: key), let file = best(files, for: selection),
           let url = try? await TorBox.url(for: file) { return (file, url) }
        try Task.checkCancellation()
        guard maySearch, selection.media.kind == "movie" || selection.episode != nil,
              let file = try await cached(for: selection) else { return nil }
        return (file, try await TorBox.url(for: file))
    }
}
