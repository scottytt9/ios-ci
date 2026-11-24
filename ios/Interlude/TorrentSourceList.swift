import SwiftUI

@MainActor
struct TorrentSourceList: View {
    let selection: HistoryEntry.Playback
    let play: (SourceVideo, URL) -> Void
    @State private var manifest = ""
    @State private var connected = TorBox.key(account: TorrentSources.account) != nil
    @State private var releases: [TorrentRelease] = []
    @State private var files: [SourceVideo] = []
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        List {
            if busy { ProgressView() }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            if connected {
                if !files.isEmpty {
                    Section("Choose a video") {
                        ForEach(files) { file in Button(file.title) { run { play(file, try await TorBox.url(for: file)) } } }
                        Button("Back to results") { files = [] }
                    }
                } else {
                    let ordered = releases.sorted { a, b in
                        let ca = a.cached == true ? 1 : 0
                        let cb = b.cached == true ? 1 : 0
                        if ca != cb { return ca > cb }
                        return SourceSelection.rank("\(a.name) \(a.filename ?? "") \(a.description)")
                            > SourceSelection.rank("\(b.name) \(b.filename ?? "") \(b.description)")
                    }
                    ForEach(ordered) { release in
                        let meta = SourceSelection.parseMeta("\(release.name) \(release.filename ?? "") \(release.description)")
                        Button { run { try await open(release) } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(meta.cleanTitle).font(.headline).lineLimit(2)
                                    Spacer(minLength: 6)
                                    Text(release.cached == true ? "⚡ Instant" : release.cached == false ? "Download" : "Check")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background((release.cached == true ? Color.green : Color.secondary).opacity(0.2), in: Capsule())
                                        .foregroundStyle(release.cached == true ? Color.green : Color.secondary)
                                }
                                if !meta.badges.isEmpty {
                                    HStack(spacing: 5) {
                                        ForEach(meta.badges, id: \.self) { badge in
                                            Text(badge)
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.primary.opacity(0.1), in: Capsule())
                                        }
                                    }
                                }
                                if !release.description.isEmpty {
                                    Text(release.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Search again") { run { try await search() } }
                    Button("Replace add-on URL") {
                        connected = false; releases = []; message = ""
                    }
                }
            } else {
                Section("Stream add-on") {
                    SecureField("HTTPS manifest.json URL", text: $manifest).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Connect and search") {
                        run {
                            try await TorrentSources.connect(manifest.trimmingCharacters(in: .whitespacesAndNewlines))
                            manifest = ""
                            connected = true
                            try await search()
                        }
                    }.disabled(manifest.isEmpty)
                }
            }
        }
        .disabled(busy)
        .navigationTitle("Find torrents")
        .onAppear { if connected && releases.isEmpty { run { try await search() } } }
    }

    private func search() async throws {
        releases = try await TorrentSources.lookup(selection)
        message = releases.isEmpty ? "No torrent hashes were returned for this title." : ""
    }

    private func open(_ result: TorrentRelease) async throws {
        let ready = try await TorrentSources.add(result)
        guard !ready.isEmpty else {
            message = "Added to TorBox. Open it from your library when it’s ready."
            return
        }
        let main = ready.filter { $0.title.range(of: "(?:^|[ ._/-])(?:sample|trailer|extras)(?:[ ._/-]|$)", options: [.regularExpression, .caseInsensitive]) == nil }
        let matching = main.filter { $0.matches(selection) }
        let named = result.filename.map { name in main.filter { $0.title == (name as NSString).lastPathComponent } } ?? []
        let choices = !matching.isEmpty ? matching : !named.isEmpty ? named : main
        if choices.count == 1, let file = choices.first { play(file, try await TorBox.url(for: file)) }
        else if !choices.isEmpty { files = choices }
        else { message = "This torrent contains no main video. Choose another result." }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = ""
        Task {
            defer { busy = false }
            do { try await work() }
            catch { message = error.localizedDescription }
        }
    }
}
