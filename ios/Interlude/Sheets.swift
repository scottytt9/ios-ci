import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct RoomPage: View {
    @Bindable var room: WatchRoom
    @ObservedObject var audio: RoomAudio
    let playback: Playback
    var openTitle: (WatchRoom.Snapshot) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var draft = ""
    @State private var network = RoomNetwork()
    @AppStorage("interlude-room-relay") private var relayEndpoint = ""
    @AppStorage("interlude-voice-host-key") private var voiceHostingKey = ""
    @State private var working = false
    @State private var error = ""

    var body: some View {
        Form {
                Section { Text(room.state.label) }
                if room.state == .idle || room.state == .disconnected {
                    Section {
                        TextField("Display name", text: $room.displayName).textContentType(.nickname)
                            .textInputAutocapitalization(.words)
                        Button("Create invite") { run { try await room.begin(network: network, relayEndpoint: relayEndpoint, voiceHostingKey: voiceHostingKey) } }
                            .disabled(WatchRoom.clean(room.displayName, limit: 32).isEmpty)
                        codeEditor
                        Button("Join with invite") { run { try await room.begin(network: network, invitation: code) } }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || WatchRoom.clean(room.displayName, limit: 32).isEmpty)
                    }
                    Section {
                        DisclosureGroup("Advanced network settings") {
                            TextField("Room relay (workers.dev)", text: $relayEndpoint).textInputAutocapitalization(.never)
                                .autocorrectionDisabled().keyboardType(.URL)
                            if !relayEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                SecureField("Voice hosting key", text: $voiceHostingKey).textInputAutocapitalization(.never)
                            }
                            if relayEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Toggle("Same Wi-Fi only", isOn: $network.lan)
                            }
                            if relayEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !network.lan {
                                TextField("TURN server (optional)", text: $network.relay).textInputAutocapitalization(.never).autocorrectionDisabled()
                                if !network.relay.isEmpty {
                                    TextField("TURN username", text: $network.username).textInputAutocapitalization(.never)
                                    SecureField("TURN password", text: $network.password)
                                }
                            }
                        }
                    }
                }
                if !room.code.isEmpty && !room.connected {
                    Section(room.hosts ? "Invite" : "Reply") {
                        ShareLink(item: room.code) { Label(room.hosts ? "Share invite" : "Share reply", systemImage: "square.and.arrow.up") }
                        Button("Copy code") { UIPasteboard.general.string = room.code }
                    }
                }
                if room.state == .invite {
                    Section("Friend’s reply") {
                        codeEditor
                        Button("Connect") { run { try await room.accept(code) } }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if room.connected {
                    if !room.friend.isEmpty { activityFeed }
                    if room.hosts, let share = room.offer, let title = share.title {
                        Section { Button("Watch \(title.name) together") { room.dismissOffer(share.media); openTitle(share) } }
                    }
                    if !room.hosts, room.linked.isEmpty, let share = room.snapshot, let title = share.title {
                        Section { Button("Open \(title.name)") { openTitle(share) } }
                    }
                    if !room.hosts, playback.hasVideo, room.snapshot?.media.isEmpty == false, room.linked.isEmpty {
                        Section { Button("Sync this video") { room.link(); dismiss() } }
                    }
                    if room.relayed && room.voiceReady {
                        Section("Private voice") {
                            if room.hostedVoice.joined {
                                Button(room.hostedVoice.microphone ? "Mute microphone" : "Turn on microphone") {
                                    run { try await room.hostedVoice.setMicrophone(!room.hostedVoice.microphone) }
                                }
                                Slider(value: Binding(get: { room.hostedVoice.volume }, set: { room.hostedVoice.volume = $0 })) {
                                    Text("Voice volume")
                                }
                                LabeledContent("Audio output") { AudioRoutePicker().frame(width: 34, height: 30) }
                                Button("Leave voice") { room.leaveHostedVoice() }
                            } else {
                                Button("Join voice", systemImage: "headphones") { run { try await room.joinHostedVoice() } }
                            }
                        }
                    }
                    if !room.relayed { Section("Voice audio") {
                        HStack {
                            LabeledContent("Output", value: audio.output)
                            AudioRoutePicker().frame(width: 34, height: 30)
                        }
                        if !audio.input.isEmpty { LabeledContent("Microphone", value: audio.input) }
                        if !audio.listening { Button("Enable voice audio") { audio.listen() }.disabled(!room.voiceReady) }
                        Button(audio.microphone ? "Mute microphone" : "Turn on microphone") {
                            if audio.microphone { audio.muteMicrophone() }
                            else {
                                run { await audio.enableMicrophone { room.connected && room.voiceReady } }
                            }
                        }.disabled(!room.voiceReady)
                        if audio.microphone {
                            Text("Some Bluetooth headsets switch to call-quality audio while the mic is on.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !audio.notice.isEmpty { Text(audio.notice).font(.footnote) }
                    } }
                    Section {
                        Toggle("Follow friend’s subtitle language", isOn: $room.followCaptions)
                            .onChange(of: room.followCaptions) { _, follow in
                                if follow, let language = room.language { playback.matchCaption(language) }
                            }
                    }
                }
                if room.state != .idle {
                    Section { Button("Leave room", role: .destructive) { room.close(); code = ""; error = "" } }
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.orange) } }
        }
        .disabled(working)
        .navigationTitle("Watch Together")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var activityFeed: some View {
        Section("Room with \(room.friend)") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(room.activity) { item in
                            VStack(alignment: item.own ? .trailing : .leading, spacing: 3) {
                                if let author = item.author { Text(author).font(.caption.bold()).foregroundStyle(.secondary) }
                                Text(item.text).font(item.author == nil ? .footnote : .body)
                            }
                            .padding(item.author == nil ? 2 : 8)
                            .background(item.author == nil ? Color.clear : Color.accentColor.opacity(item.own ? 0.18 : 0.09),
                                        in: .rect(cornerRadius: 10))
                            .frame(maxWidth: .infinity, alignment: item.author == nil ? .center : item.own ? .trailing : .leading)
                            .id(item.id)
                        }
                    }
                }
                .frame(height: 156)
                .onAppear { if let id = room.activity.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                .onChange(of: room.activity.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            HStack(spacing: 6) {
                ForEach(WatchRoom.reactionEmojis, id: \.self) { emoji in
                    Button(emoji) { room.react(emoji) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            HStack {
                TextField("Message", text: $draft).submitLabel(.send).onSubmit(sendMessage)
                Button("Send", action: sendMessage).buttonStyle(.borderedProminent)
                    .disabled(WatchRoom.clean(draft, limit: 240).isEmpty)
            }
        }
    }

    private func sendMessage() {
        if room.chat(draft) { draft = "" }
    }

    private var codeEditor: some View {
        TextEditor(text: $code).font(.caption.monospaced()).frame(minHeight: 64)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityLabel("Interlude room code")
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        error = ""
        Task {
            defer { working = false }
            do { try await operation() }
            catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
struct TorBoxLibrary: View {
    let store: HistoryStore
    @ObservedObject var connections: PlaybackConnections
    let resume: HistoryEntry.Playback?
    let sourcePicker: Bool
    var modal = false
    var openConnections: () -> Void = {}
    var select: (SourceVideo, URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var videos: [SourceVideo] = []
    @State private var enteredKey = ""
    @State private var working = false
    @State private var message = ""
    @State private var showAll = false
    @State private var refreshing = false
    @State private var query = ""

    private var matches: [SourceVideo] { resume.map { selection in videos.filter { $0.matches(selection) } } ?? [] }

    var body: some View {
        let matching = matches
        let pool = resume == nil || showAll || matching.isEmpty ? videos : matching
        let filtered = query.isEmpty ? pool : pool.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.collection.localizedCaseInsensitiveContains(query)
        }
        NavigationStack {
            List {
                if connections.connected.contains(.torbox) {
                    if let resume { Text("Choose the video for \(resume.label ?? resume.media.title).").foregroundStyle(.secondary) }
                    if let resume, resume.media.kind == "movie" || resume.episode != nil {
                        NavigationLink("Find torrents") { TorrentSourceList(selection: resume, play: select) }
                    }
                    if working || refreshing { ProgressView() }
                    if !working && !refreshing && message.isEmpty && videos.isEmpty {
                        Text("No ready videos in your TorBox library.").foregroundStyle(.secondary)
                    }
                    if resume != nil && !videos.isEmpty {
                        if matching.isEmpty { Text("No clear match. Choose the correct cut from your library.").foregroundStyle(.secondary) }
                        else { Toggle("Show all videos", isOn: $showAll) }
                    }
                    if !query.isEmpty && filtered.isEmpty { ContentUnavailableView.search(text: query) }
                    let ranked = filtered.sorted { SourceSelection.rank($0.title) > SourceSelection.rank($1.title) }
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { index, item in
                        let meta = SourceSelection.parseMeta(item.title)
                        HStack {
                            Button {
                                perform { select(item, try await TorBox.url(for: item)) }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(meta.cleanTitle).font(.headline).lineLimit(2)
                                    if !meta.badges.isEmpty || (index == 0 && resume != nil) {
                                        HStack(spacing: 5) {
                                            if index == 0 && resume != nil {
                                                Text("Best match")
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Color.accentColor.opacity(0.22), in: Capsule())
                                                    .foregroundStyle(Color.accentColor)
                                            }
                                            ForEach(meta.badges, id: \.self) { badge in
                                                Text(badge)
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Color.primary.opacity(0.1), in: Capsule())
                                            }
                                        }
                                    }
                                    if !item.collection.isEmpty { Text(item.collection).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            let saved = store.list.contains(where: { $0.key == item.id })
                            Button { store.toggleSaved(item.playback.media) } label: { Image(systemName: saved ? "bookmark.fill" : "bookmark") }
                                .buttonStyle(.borderless).accessibilityLabel(saved ? "Remove from My List" : "Save to My List")
                        }
                    }
                } else if sourcePicker {
                    SecureField("TorBox API key", text: $enteredKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Connect TorBox") {
                        perform {
                            try await connections.connect(.torbox, input: enteredKey)
                            enteredKey = ""
                        }
                    }.disabled(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Text("Connect TorBox to browse your ready downloads.").foregroundStyle(.secondary)
                    Button("Open Connections", action: openConnections)
                }
                if !message.isEmpty { Text(message).foregroundStyle(.orange) }
            }
            .disabled(working)
            .navigationTitle(sourcePicker ? "Playback sources" : "Downloads")
            .searchable(text: $query, prompt: "Filter files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sourcePicker || modal { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
            .task(id: connections.revisions[.torbox, default: 0]) {
                await refresh()
            }
            .refreshable { await refresh() }
        }
    }

    private func refresh() async {
        guard let key = TorBox.key() else { videos = []; refreshing = false; return }
        refreshing = true
        defer { if !Task.isCancelled { refreshing = false } }
        do {
            let files = try await TorBox.library(key: key)
            if !Task.isCancelled { videos = files; message = "" }
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        message = ""
        Task {
            defer { working = false }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }
}

@MainActor
struct HistoryPage: View {
    let store: HistoryStore
    let play: (HistoryEntry.Playback, Bool) -> Void
    let downloads: () -> Void
    var openFile: (() -> Void)? = nil
    var openLink: (() -> Void)? = nil
    private enum ViewMode: String, CaseIterable { case saved = "My List", history = "History" }
    @State private var mode = ViewMode.saved
    @State private var importing = false
    @State private var exporting = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ContinueWatchingShelf(history: store) { play($0, false) }
                    HStack(spacing: 10) {
                        Picker("Library view", selection: $mode) {
                            ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        Button("Downloads", systemImage: "tray.full", action: downloads)
                            .labelStyle(.iconOnly).buttonStyle(.bordered)
                    }.padding(.horizontal)
                    if mode == .saved { savedGrid }
                    else { historyList }
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
                }.padding(.vertical)
            }
            .navigationTitle("Library")
            .background(ProfileTheme.color(store.themes.active.background))
            .toolbar {
                Menu {
                    Button("Downloads", systemImage: "tray.full", action: downloads)
                    if let openFile { Button("Open from Files", systemImage: "folder", action: openFile) }
                    if let openLink { Button("Open video link", systemImage: "link", action: openLink) }
                    Divider()
                    Button("Import history", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Export history", systemImage: "square.and.arrow.up") { exporting = true }
                } label: { Label("Library options", systemImage: "ellipsis.circle") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], onCompletion: importHistory)
        .fileExporter(isPresented: $exporting, document: store.document, contentType: .json, defaultFilename: "interlude-history.json") { result in
            switch result {
            case .success: message = "Watch history exported."
            case .failure: message = "Couldn’t export watch history."
            }
        }
    }

    private var savedGrid: some View {
        Group {
            if store.list.isEmpty {
                ContentUnavailableView("Your list is empty", systemImage: "bookmark", description: Text("Save a title from its details page."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], alignment: .leading, spacing: 18) {
                    ForEach(store.list, id: \.key) { item in
                        if item.id != nil && item.provider != "tvmaze" && (item.kind == "movie" || item.kind == "tv") {
                            NavigationLink {
                                CatalogueDetail(item: CatalogueTitle(snapshot: item), history: store, play: play)
                            } label: { poster(item) }.buttonStyle(.plain)
                        } else {
                            Button { play(.init(id: item.key, media: item, label: nil, episode: nil), false) } label: { poster(item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }.padding(.horizontal)
    }

    private func poster(_ item: HistoryEntry.Playback.Media) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CatalogueImage(item.poster).aspectRatio(2.0 / 3, contentMode: .fit)
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { Button("Remove from My List", systemImage: "bookmark.slash", role: .destructive) { store.toggleSaved(item) } }
    }

    private var historyList: some View {
        Group {
            if store.entries.isEmpty {
                ContentUnavailableView("No watch history", systemImage: "clock")
            } else {
                ForEach(store.entries) { entry in
                    let pct: Double = (!entry.complete && entry.duration > 0 && entry.time > 2)
                        ? min(1, max(0.03, entry.time / entry.duration)) : 0
                    HStack(spacing: 12) {
                        Button { play(entry.playback, false) } label: {
                            HStack(spacing: 12) {
                                ZStack(alignment: .bottom) {
                                    CatalogueImage(entry.playback.media.backdrop ?? entry.playback.media.poster, cornerRadius: 8)
                                        .frame(width: 92, height: 54)
                                    if pct > 0 {
                                        GeometryReader { g in
                                            ZStack(alignment: .leading) {
                                                Rectangle().fill(.white.opacity(0.3))
                                                Rectangle().fill(Color.accentColor).frame(width: g.size.width * pct)
                                            }
                                        }.frame(height: 3)
                                    }
                                }
                                .frame(width: 92, height: 54)
                                .clipShape(.rect(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.playback.media.title).font(.headline).lineLimit(1)
                                    Text(entry.playback.label ?? (entry.complete ? "Watched" : "In progress"))
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            Button(entry.complete ? "Play again" : "Resume", systemImage: "play.fill") { play(entry.playback, false) }
                            Button("Remove", systemImage: "trash", role: .destructive) { store.remove(entry) }
                        } label: { Label("History actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly).frame(width: 40, height: 44) }
                    }.padding(.horizontal)
                }
            }
        }
    }

    private func importHistory(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 8 * 1024 * 1024 else { throw LibraryError.history }
                let data = try Data(contentsOf: url)
                let file = try JSONDecoder().decode(HistoryFile.self, from: data)
                guard file.isValid else { throw LibraryError.history }
                store.merge(file)
                message = "Watch history imported."
            } catch { message = "Choose a watch-history JSON file exported by Interlude." }
        case .failure: message = "Couldn’t open this watch-history file."
        }
    }
}
