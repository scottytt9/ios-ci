import Foundation
import SwiftUI

struct ProfileTheme: Codable, Identifiable {
    let id: String
    let name: String
    let background: String
    let accent: String

    static let presets = [
        Self(id: "interlude", name: "Interlude", background: "#000000", accent: "#ecf841"),
        Self(id: "oled", name: "Blackout", background: "#000000", accent: "#f0f0f0"),
        Self(id: "midnight", name: "Midnight", background: "#111728", accent: "#92baff"),
        Self(id: "plum", name: "Aubergine", background: "#1c1423", accent: "#e7b1ec"),
        Self(id: "ember", name: "Ember", background: "#201512", accent: "#ffab79"),
        Self(id: "daylight", name: "Daylight", background: "#f5f1e8", accent: "#285b9c"),
        Self(id: "crimson", name: "Crimson", background: "#0f090b", accent: "#ff4560"),
        Self(id: "cyber", name: "Synthwave", background: "#0b091a", accent: "#00f0ff"),
        Self(id: "emerald", name: "Forest", background: "#081410", accent: "#34d399"),
        Self(id: "gold", name: "A24 Gold", background: "#100e09", accent: "#f5c451"),
        Self(id: "rose", name: "Sakura", background: "#181016", accent: "#fb7185"),
        Self(id: "nord", name: "Nordic", background: "#1a202c", accent: "#88c0d0")
    ]

    static func channels(_ hex: String) -> [Double] {
        let number = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return [16, 8, 0].map { Double((number >> $0) & 255) / 255 }
    }

    static func color(_ hex: String) -> Color {
        let rgb = channels(hex)
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    var scheme: ColorScheme {
        let rgb = Self.channels(background).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722 < 0.179 ? .dark : .light
    }

    var icon: String? {
        let current = Self.channels(accent)
        let variants: [(String?, String)] = [(nil, "#ecf841"), ("IconMono", "#f0f0f0"), ("IconBlue", "#92baff"),
                        ("IconPlum", "#e7b1ec"), ("IconEmber", "#ffab79"), ("IconGold", "#fbe44a")]
        func distance(_ hex: String) -> Double {
            zip(current, Self.channels(hex)).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
        }
        return variants.min { distance($0.1) < distance($1.1) }?.0
    }
}

struct ProfileThemes: Codable {
    var selected = "interlude"
    var custom: [ProfileTheme] = []
    var available: [ProfileTheme] { ProfileTheme.presets + custom }
    var active: ProfileTheme { available.first { $0.id == selected } ?? ProfileTheme.presets[0] }

    static func isColor(_ value: String) -> Bool {
        value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }
}

enum ProfileError: LocalizedError {
    case invalid, size, history
    var errorDescription: String? {
        switch self {
        case .size: return "This profile is too large to copy as a code."
        case .invalid: return "Paste a complete Interlude profile code."
        case .history: return "Choose a watch history file exported by Interlude."
        }
    }
}

struct ProfileFile: Codable {
    private static let prefix = "INTERLUDE-PROFILE1:"
    private static let codeLimit = 3 * 1024 * 1024
    private static let dataLimit = 8 * 1024 * 1024
    var format = "interlude-profile"
    var version = 1
    let history: HistoryFile
    let list: [HistoryEntry.Playback.Media]
    let themes: ProfileThemes

    func encode() throws -> String {
        let json = try JSONEncoder().encode(self)
        guard json.count <= Self.dataLimit else { throw ProfileError.size }
        let payload = try RoomInvite.gzip(json, reading: false).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard payload.utf8.count + Self.prefix.count <= Self.codeLimit else { throw ProfileError.size }
        return Self.prefix + payload
    }

    static func decode(_ input: String) throws -> Self {
        guard input.utf8.count <= codeLimit + 4096 else { throw ProfileError.size }
        let code = input.filter { !$0.isWhitespace }
        guard code.hasPrefix(prefix), code.utf8.count <= codeLimit else { throw ProfileError.invalid }
        let raw = code.dropFirst(prefix.count)
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ProfileError.invalid
        }
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let json = try? RoomInvite.gzip(data, reading: true, limit: dataLimit),
              let profile = try? JSONDecoder().decode(Self.self, from: json), profile.format == "interlude-profile", profile.version == 1,
              profile.history.isValid, profile.list.allSatisfy({ validID($0.key) }),
              profile.themes.custom.allSatisfy({ $0.id.hasPrefix("custom-") && !$0.name.isEmpty && $0.name.utf16.count <= 48 &&
                  ProfileThemes.isColor($0.background) && ProfileThemes.isColor($0.accent) }) else { throw ProfileError.invalid }
        return profile
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^(?:movie:[0-9]+|(?:tv|tvmaze):[0-9]+(?::[0-9]+:[0-9]+)?|file:(?:torrents|usenet|webdl):[0-9]+:[0-9]+)$",
                    options: .regularExpression) != nil && value.utf8.count <= 100
    }
}

extension HistoryFile {
    var isValid: Bool {
        let timestamps: Range<Int64> = 1..<8_640_000_000_000_000
        return format == "interlude-watch-history" && version == 1 && entries.allSatisfy {
            ProfileFile.validID($0.id) && ProfileFile.validID($0.playback.media.key) && timestamps.contains($0.updated) &&
            timestamps.contains($0.changed) && (0...1_000_000).contains($0.time) && (0...1_000_000).contains($0.duration)
        } && (removals ?? [:]).allSatisfy { ProfileFile.validID($0.key) && timestamps.contains($0.value) }
    }
}
