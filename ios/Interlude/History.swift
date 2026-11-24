import Observation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct HistoryEntry: Codable, Identifiable {
    struct Playback: Codable {
        struct Media: Codable {
            let key: String
            let kind: String
            let title: String
            let year: String?
            let id: Int?
            let description: String?
            let genres: [String]?
            let poster: String?
            let backdrop: String?
            let imdbId: String?
            let runtime: Double?
            var rating: Double? = nil
            var genre: String? = nil
            var releaseDate: String? = nil
            var provider: String? = nil
        }
        struct Episode: Codable { let season: Int; let number: Int; let title: String? }
        let id: String
        let media: Media
        let label: String?
        let episode: Episode?
    }
    let playback: Playback
    let time: Double
    let duration: Double
    let updated: Int64
    let complete: Bool
    let modified: Int64?
    let seriesOverride: Int64?
    var importedFromStremio: ImportedHistory? = nil
    var id: String { playback.id }
    var changed: Int64 { modified ?? updated }
}

struct ImportedHistory: Codable {
    let title: String
    let importedAt: Int64
    let watchedDate: String?
    let imdbRating: Double?
    let reportedPercent: Double?
}

struct HistoryFile: FileDocument, Codable {
    static var readableContentTypes: [UTType] { [.json] }
    var format = "interlude-watch-history"
    var version = 1
    var entries: [HistoryEntry]
    var removals: [String: Int64]?

    init(entries: [HistoryEntry] = [], removals: [String: Int64]? = nil) {
        self.entries = entries
        self.removals = removals
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= 8 * 1024 * 1024 else { throw ProfileError.history }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard isValid else { throw ProfileError.history }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(self))
    }
}

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private(set) var list: [HistoryEntry.Playback.Media] = []
    private(set) var themes = ProfileThemes()
    private var removals: [String: Int64] = [:]
    private let key = "watch-history-v1"
    private let persistence = DispatchQueue(label: "app.interlude.profile")

    init() {
        if let data = UserDefaults.standard.data(forKey: "profile-v1"), let profile = try? JSONDecoder().decode(ProfileFile.self, from: data) {
            list = profile.list
            themes = profile.themes
            entries = profile.history.entries.sorted { $0.updated > $1.updated }
            removals = profile.history.removals ?? [:]
        } else if let data = UserDefaults.standard.data(forKey: key), let file = try? JSONDecoder().decode(HistoryFile.self, from: data) {
            entries = file.entries.sorted { $0.updated > $1.updated }
            removals = file.removals ?? [:]
        }
    }

    var document: HistoryFile { HistoryFile(entries: entries, removals: removals) }
    var profile: ProfileFile { ProfileFile(history: document, list: list, themes: themes) }

    func apply(_ profile: ProfileFile) {
        list = profile.list
        themes = profile.themes
        merge(profile.history)
    }

    func selectTheme(_ id: String) {
        themes.selected = id
        save()
    }

    func saveTheme(name: String, background: String, accent: String) {
        let theme = ProfileTheme(id: "custom-" + UUID().uuidString.lowercased(), name: name, background: background, accent: accent)
        themes.custom.append(theme)
        selectTheme(theme.id)
    }

    func deleteTheme(_ id: String) {
        themes.custom.removeAll { $0.id == id }
        if themes.selected == id { themes.selected = ProfileTheme.presets[0].id }
        save()
    }

    func toggleSaved(_ media: HistoryEntry.Playback.Media) {
        if list.contains(where: { $0.key == media.key }) { list.removeAll { $0.key == media.key } }
        else { list.insert(media, at: 0) }
        save()
    }

    func setWatched(_ playback: HistoryEntry.Playback, complete: Bool) {
        setWatched([playback], complete: complete)
    }

    func isWatched(_ playback: HistoryEntry.Playback) -> Bool {
        let prior = entries.first { $0.id == playback.id }
        if prior?.complete == true { return true }
        return completedSeries(for: playback).map { prior?.seriesOverride != $0.updated } ?? false
    }

    private func completedSeries(for playback: HistoryEntry.Playback) -> HistoryEntry? {
        guard playback.media.kind == "tv", playback.id != playback.media.key else { return nil }
        return entries.first { $0.id == playback.media.key && $0.complete }
    }

    func setWatched(_ items: [HistoryEntry.Playback], complete: Bool) {
        let now = RoomInvite.wallClock()
        var edits: [HistoryEntry] = []
        var deleted: [String: Int64] = [:]
        let priorEntries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { newer, _ in newer })
        for playback in items {
            let prior = priorEntries[playback.id]
            let show = completedSeries(for: playback)
            let modified = max(now, (prior?.changed ?? 0) + 1, (removals[playback.id] ?? 0) + 1)
            if !complete && show == nil && (prior?.duration ?? 0) == 0 {
                if prior != nil { deleted[playback.id] = modified }
                continue
            }
            let duration = prior?.duration ?? 0
            let at = prior?.time ?? 0
            edits.append(HistoryEntry(playback: prior?.playback ?? playback, time: !complete && duration > 0 && at >= duration * 0.95 ? 0 : at,
                duration: duration, updated: now, complete: complete, modified: modified, seriesOverride: complete ? nil : show?.updated,
                importedFromStremio: prior?.importedFromStremio))
        }
        merge(HistoryFile(entries: edits, removals: deleted))
    }

    func merge(_ file: HistoryFile) {
        for (id, time) in file.removals ?? [:] { removals[id] = max(removals[id] ?? 0, time) }
        var table: [String: HistoryEntry] = [:]
        for entry in entries + file.entries where entry.changed > (removals[entry.id] ?? 0) {
            if entry.changed > (table[entry.id]?.changed ?? 0) { table[entry.id] = entry }
        }
        entries = table.values.sorted { $0.updated > $1.updated }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        removals[entry.id] = max(RoomInvite.wallClock(), entry.changed + 1)
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func record(playback: HistoryEntry.Playback, time: Double, duration: Double, complete: Bool) {
        guard duration.isFinite, duration > 0, time.isFinite, time >= 0 else { return }
        let prior = entries.first { $0.id == playback.id }
        let now = RoomInvite.wallClock()
        let entry = HistoryEntry(playback: playback, time: time, duration: duration, updated: now,
                                 complete: complete || prior?.complete == true,
                                 modified: max(now, (prior?.changed ?? 0) + 1, (removals[playback.id] ?? 0) + 1),
                                 seriesOverride: complete ? nil : prior?.seriesOverride, importedFromStremio: prior?.importedFromStremio)
        if let index = entries.firstIndex(where: { $0.id == playback.id }) { entries.remove(at: index) }
        let index = entries.firstIndex { $0.updated <= now } ?? entries.endIndex
        entries.insert(entry, at: index)
        save()
    }

    private func save() {
        let snapshot = profile
        persistence.async {
            if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: "profile-v1") }
        }
    }

    func flush() { persistence.sync {} }
}
