import Foundation

struct ExternalCaptions {
    struct Cue { let start: Double; let end: Double; let text: String }
    let name: String
    private let cues: [Cue]
    private let ends: [Double]

    init(name: String, text: String) throws {
        self.name = name
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blank = normalized.replacingOccurrences(of: "\n[ \t]+\n", with: "\n\n", options: .regularExpression)
        var found: [Cue] = []
        for block in blank.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }),
                  !lines[0].hasPrefix("NOTE"), lines[0] != "STYLE", lines[0] != "REGION" else { continue }
            let timing = lines[index].components(separatedBy: "-->")
            guard timing.count == 2, let start = Self.timestamp(timing[0]),
                  let first = timing[1].split(whereSeparator: \.isWhitespace).first,
                  let end = Self.timestamp(String(first)), end > start else { continue }
            let caption = lines.dropFirst(index + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty { found.append(Cue(start: start, end: end, text: String(caption.prefix(1000)))) }
            if found.count >= 50_000 { break }
        }
        guard !found.isEmpty else { throw CaptionError.format }
        cues = found.sorted { $0.start < $1.start }
        var latest = 0.0
        ends = cues.map { latest = max(latest, $0.end); return latest }
    }

    static func importFile(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024 else { throw CaptionError.size }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw CaptionError.format }
        return try Self(name: url.lastPathComponent, text: text)
    }

    func text(at time: Double) -> String {
        var lo = 0, hi = cues.count
        while lo < hi {
            let i = (lo + hi) / 2
            if cues[i].start <= time { lo = i + 1 } else { hi = i }
        }
        var i = lo - 1
        var lines: [String] = []
        while i >= 0 && ends[i] > time && lines.count < 6 {
            if cues[i].end > time { lines.append(cues[i].text) }
            i -= 1
        }
        return lines.reversed().joined(separator: "\n")
    }

    private static func timestamp(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts[parts.count - 1]), (0..<60).contains(seconds),
              let minutes = Int(parts[parts.count - 2]), (0..<60).contains(minutes) else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) ?? -1 : 0
        guard (0..<1000).contains(hours) else { return nil }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    enum CaptionError: LocalizedError {
        case format, size
        var errorDescription: String? {
            self == .size ? "Choose a subtitle file smaller than 8 MB." : "Choose an SRT or WebVTT subtitle file with readable cues."
        }
    }
}

struct CaptionStyle: Codable, Equatable {
    var font = "sans"
    var size = 26.0
    var opacity = 55.0
    var outline = 1.5
    var shadow = 2.0
    var bottom = 7.0
    var color = "#FFFFFF"

    static func load() -> Self {
        UserDefaults.standard.data(forKey: "caption-style").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "caption-style") }
    }
}
