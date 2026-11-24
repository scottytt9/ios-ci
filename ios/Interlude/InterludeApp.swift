import AVKit
import MediaPlayer
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
@MainActor
struct InterludeApp: App {
    @State private var playback = Playback()

    var body: some Scene {
        WindowGroup {
            InterludeView(playback: playback, room: playback.room, audio: playback.audio, history: playback.history)
        }
    }
}

@MainActor
private struct InterludeView: View {
    private enum Page: Hashable { case discover, search, library, profile }

    let playback: Playback
    let room: WatchRoom
    @ObservedObject var audio: RoomAudio
    let history: HistoryStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connections = PlaybackConnections()
    @State private var page: Page = .discover
    @State private var playerOpen = false
    @State private var showConnections = false
    @State private var link = ""
    @State private var files = false
    @State private var library = false
    @State private var downloads = false
    @State private var roomPage = false
    @State private var roomSelection: WatchRoom.Snapshot?
    @State private var settings = false
    @State private var episodesSheet = false
    @State private var insightSheet = false
    @State private var startsInSubtitles = false
    @State private var changeSourceAfterSettings = false
    @State private var importingCaptions = false
    @State private var replaceSource = false
    @State private var pendingResume: HistoryEntry.Playback?
    @State private var quickPlayID: UUID?
    @State private var quickPlay: Task<Void, Never>?
    @State private var quickSelection: HistoryEntry.Playback?
    @State private var pendingJoin: String?
    @State private var hostAfterOpening = false
    @State private var openRoomAfterLibrary = false
    @State private var openRoomAfterSettings = false
    @State private var nextAfterSettings: HistoryEntry.Playback?
    @State private var fullscreen = false
    @State private var showLink = false
    @StateObject private var pictureInPicture = VideoPictureInPicture()
    @State private var message = ""
    @State private var micBusy = false

    var body: some View {
        withPlaybackSheets(playerLayout)
            .preferredColorScheme(history.themes.active.scheme)
            .tint(ProfileTheme.color(history.themes.active.accent))
            .onAppear {
                pictureInPicture.onRestore = {
                    playerOpen = true
                }
            }
    }

    private var playerLayout: some View {
        ZStack {
            // Keep TabView persistently mounted so fullscreen/minimize NEVER destroys NavigationStacks!
            tabs
                .opacity(playerOpen && playback.hasVideo ? 0 : 1)
                .allowsHitTesting(!(playerOpen && playback.hasVideo))

            if playback.hasVideo {
                Group {
                    if fullscreen {
                        videoPlayer
                            .background(Color.black.ignoresSafeArea())
                            .persistentSystemOverlays(.hidden)
                    } else {
                        playerSheet
                    }
                }
                .opacity(playerOpen ? 1 : 0)
                .scaleEffect(playerOpen ? 1 : 0.985)
                .allowsHitTesting(playerOpen)
                .zIndex(playerOpen ? 2 : -1)
            }
        }
        .animation(.spring(duration: 0.28, bounce: 0.1), value: playerOpen)
        .overlay(alignment: .top) {
            if !roomPage, quickPlayID == nil, let offer = room.offer, let title = offer.title, !library, !settings {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(room.friend.isEmpty ? "Your friend" : room.friend) \(room.hosts ? "suggested" : "started") \(title.name)\(title.episode.map { " · S\(title.season ?? 0) E\($0)" } ?? "")",
                          systemImage: "person.2.wave.2")
                        .font(.subheadline.weight(.semibold)).lineLimit(3)
                    HStack {
                        Button("Watch together") { room.dismissOffer(offer.media); openShared(offer) }.buttonStyle(.borderedProminent)
                        Button("Not now") { room.dismissOffer(offer.media) }.buttonStyle(.bordered)
                    }
                }
                .padding(12).background(.regularMaterial, in: .rect(cornerRadius: 16))
                .padding(.horizontal, 12).padding(.top, 5)
                .shadow(color: .black.opacity(0.25), radius: 9, y: 4)
            }
        }
        .onAppear { connections.refresh() }
    }

    private var tabs: some View {
        TabView(selection: $page) {
            browsing(CataloguePage(history: history, connected: connections.connected.contains(.tmdb),
                                   openConnections: openConnections, openRoom: showRoom, play: openSelection)
                .id(connections.revisions[.tmdb, default: 0]))
                .tabItem { Label("Home", systemImage: "house") }.tag(Page.discover)

            browsing(CataloguePage(history: history, connected: connections.connected.contains(.tmdb), searchOnly: true,
                                   openConnections: openConnections, openRoom: showRoom, play: openSelection)
                .id(connections.revisions[.tmdb, default: 0]))
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Page.search)

            browsing(HistoryPage(store: history, play: openSelection, downloads: { downloads = true },
                                 openFile: { importingCaptions = false; files = true },
                                 openLink: { showLink = true }))
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(Page.library)

            browsing(ProfilePage(store: history, connections: connections, showConnections: $showConnections))
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(Page.profile)
        }
        .overlay(alignment: .top) {
            if quickPlayID != nil, let selection = quickSelection {
                HStack(spacing: 12) {
                    CatalogueImage(selection.media.poster, cornerRadius: 6).frame(width: 34, height: 50)
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text("Finding a ready source").font(.subheadline.weight(.medium))
                        Text(selection.label ?? selection.media.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Sources") {
                        pendingResume = selection
                        cancelQuickPlay()
                        library = true
                    }
                    Button("Cancel", systemImage: "xmark") {
                        cancelQuickPlay()
                        pendingJoin = nil
                        hostAfterOpening = false
                    }.labelStyle(.iconOnly)
                }.padding(12).background(.regularMaterial, in: .rect(cornerRadius: 16)).padding(.horizontal)
            }
        }
        .onChange(of: page) { _, _ in cancelQuickPlay() }
        .onChange(of: connections.revisions[.torbox, default: 0]) { _, _ in cancelQuickPlay() }
    }

    private func browsing<Content: View>(_ content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if playback.hasVideo && !playerOpen {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Button {
                            playerOpen = true
                        } label: {
                            HStack(spacing: 10) {
                                let media = playback.selection?.media
                                CatalogueImage(media?.backdrop ?? media?.poster, cornerRadius: 7).frame(width: 54, height: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(playback.selection?.media.title ?? playback.title)
                                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if let label = playback.selection?.label {
                                        Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityHint("Opens the player")
                        Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                            playback.action(playback.isPlaying ? "pause" : "play")
                        }.labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 36, height: 36).disabled(!playback.error.isEmpty)
                        Button("Close player", systemImage: "xmark") {
                            playback.closeVideo()
                        }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary).frame(width: 32, height: 36)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    if playback.duration > 0 {
                        GeometryReader { geo in
                            let ratio = max(0, min(1, playback.time / playback.duration))
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.secondary.opacity(0.25))
                                Rectangle().fill(Color.accentColor).frame(width: geo.size.width * ratio)
                            }
                        }.frame(height: 2.5)
                    }
                }
                .background(.regularMaterial, in: .rect(cornerRadius: 14))
                .clipShape(.rect(cornerRadius: 14))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
    }

    private var playerSheet: some View {
        let media = playback.selection?.media
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        if let art = media?.backdrop ?? media?.poster {
                            CatalogueImage(art, cornerRadius: 18)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .blur(radius: 26)
                                .opacity(0.32)
                                .scaleEffect(1.06)
                        }
                        videoPlayer
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .background(.black)
                            .clipShape(.rect(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.42), radius: 16, y: 6)
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(media?.title ?? playback.title).font(.title2.bold()).lineLimit(2)
                            if let episode = playback.selection?.label {
                                Text(episode).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor).lineLimit(2)
                            }
                            let metaParts: [String] = [
                                media?.year,
                                media?.rating.flatMap { $0 > 0 ? String(format: "★ %.1f", $0) : nil },
                                media?.runtime.map { $0 >= 60 ? "\(Int($0) / 60)h \(Int($0) % 60)m" : "\(Int($0))m" }
                            ].compactMap { $0 }.filter { !$0.isEmpty }
                            if !metaParts.isEmpty {
                                Text(metaParts.joined(separator: "  ·  "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("Change source", systemImage: "arrow.triangle.2.circlepath", action: changeSource)
                            Button("Playback settings", systemImage: "gearshape") { showPlaybackSettings() }
                            Divider()
                            Button("Close player", systemImage: "xmark", role: .destructive) {
                                playerOpen = false
                                fullscreen = false
                                playback.closeVideo()
                            }
                        } label: { Label("Playback options", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                        .buttonStyle(.bordered)
                    }
                    if let description = media?.description, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if media?.id != nil, (media?.kind == "movie" || media?.kind == "tv") {
                                Button {
                                    playback.endBoost()
                                    insightSheet = true
                                } label: {
                                    Label("InSight", systemImage: "sparkles")
                                }
                            }
                            if media?.kind == "tv" {
                                Button {
                                    playback.endBoost()
                                    episodesSheet = true
                                } label: {
                                    Label("Episodes", systemImage: "list.bullet.rectangle")
                                }
                            }
                            Button {
                                _ = playback.whatDidTheySay()
                            } label: {
                                Label("−10s CC", systemImage: "text.bubble")
                            }
                            Button {
                                playback.setEnhanceDialogue(!playback.enhanceDialogue)
                            } label: {
                                Label(playback.enhanceDialogue ? "Voice On" : "Voice+", systemImage: "waveform")
                            }
                            Button { showPlaybackSettings(subtitles: true) } label: {
                                Label("Subtitles", systemImage: "captions.bubble")
                            }
                            Button(action: changeSource) {
                                Label("Sources", systemImage: "tray.full")
                            }
                            Button { showPlaybackSettings() } label: {
                                Label("Settings", systemImage: "slider.horizontal.3")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if showLink {
                        HStack {
                            TextField("Direct HTTPS video link", text: $link).textContentType(.URL)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(openLinkedVideo)
                            Button("Open", action: openLinkedVideo).buttonStyle(.borderedProminent)
                                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    PlayerRoomControls(room: room, audio: audio, playback: playback, showRoom: { roomPage = true }, openShared: openShared)
                    if !message.isEmpty { Text(message).foregroundStyle(.orange).font(.callout) }
                }
                .padding()
            }
            .background(ProfileTheme.color(history.themes.active.background))
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Minimize", systemImage: "chevron.down") {
                        setFullscreen(false)
                        playerOpen = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Open video", systemImage: "folder") { openVideoActions }
                }
            }
        }
    }

    private func cancelQuickPlay() {
        quickPlay?.cancel()
        quickPlay = nil
        quickPlayID = nil
        quickSelection = nil
    }

    private func openSelection(_ selection: HistoryEntry.Playback, _ together: Bool) {
        openAutomatically(selection, together: together)
    }

    private func openShared(_ share: WatchRoom.Snapshot) {
        roomPage = false
        guard let selection = share.title?.playback else { return }
        if playback.selection?.id == selection.id && playback.hasVideo && playback.error.isEmpty {
            if !room.hosts { room.link() }
            roomPage = false
            playerOpen = true
        } else {
            openAutomatically(selection, join: room.hosts ? nil : share.media, preferredSource: room.hosts ? nil : share.source)
        }
    }

    private func openAutomatically(_ selection: HistoryEntry.Playback, together: Bool = false, join: String? = nil, preferredSource: RoomSource? = nil) {
        cancelQuickPlay()
        hostAfterOpening = together
        pendingJoin = join
        guard connections.connected.contains(.torbox) else {
            pendingResume = selection
            library = true
            return
        }
        let ticket = UUID()
        quickPlayID = ticket
        quickSelection = selection
        quickPlay = Task {
            let result = try? await SourceSelection.resolve(selection, maySearch: connections.connected.contains(.addon), preferredSource: preferredSource)
            guard !Task.isCancelled, quickPlayID == ticket else { return }
            quickPlayID = nil
            quickPlay = nil
            quickSelection = nil
            if let (video, url) = result {
                selectVideo(video, url, selection: selection, fromPicker: false)
            } else {
                pendingResume = selection
                library = true
            }
        }
    }

    private var openVideoActions: some View {
        Group {
            Button("Files", systemImage: "folder") { importingCaptions = false; files = true }
            Button("Downloads", systemImage: "tray.full") { downloads = true }
            Button("Video link", systemImage: "link") { showLink.toggle(); if playback.hasVideo { playerOpen = true } }
        }
    }

    private func setFullscreen(_ next: Bool) {
        playback.endBoost()
        fullscreen = next
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let mask: UIInterfaceOrientationMask = next ? .landscape : .allButUpsideDown
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }

    private var videoPlayer: some View {
        VideoPlayerView(
            playback: playback,
            pictureInPicture: pictureInPicture,
            fullscreen: fullscreen,
            toggleFullscreen: { setFullscreen(!fullscreen) },
            minimize: {
                if fullscreen { setFullscreen(false) }
                else { playerOpen = false }
            },
            openSettings: { showPlaybackSettings() },
            openSubtitles: { showPlaybackSettings(subtitles: true) },
            playNext: openNext,
            roomControls: room.connected,
            voiceAvailable: room.voiceReady,
            microphoneOn: room.relayed ? room.hostedVoice.microphone : audio.microphone,
            microphoneBusy: micBusy,
            toggleMicrophone: togglePlayerMicrophone,
            openRoom: showRoom,
            changeSource: changeSource,
            openEpisodes: playback.selection?.media.kind == "tv" ? {
                playback.endBoost()
                episodesSheet = true
            } : nil,
            openInSight: (playback.selection?.media.id != nil && (playback.selection?.media.kind == "movie" || playback.selection?.media.kind == "tv")) ? {
                playback.endBoost()
                insightSheet = true
            } : nil
        )
    }

    private func showPlaybackSettings(subtitles: Bool = false) {
        playback.endBoost()
        importingCaptions = false
        startsInSubtitles = subtitles
        settings = true
    }

    private func togglePlayerMicrophone() {
        guard room.connected, room.voiceReady, !micBusy else { return }
        micBusy = true
        Task {
            defer { micBusy = false }
            do {
                if room.relayed {
                    if !room.hostedVoice.joined { try await room.joinHostedVoice() }
                    try await room.hostedVoice.setMicrophone(!room.hostedVoice.microphone)
                } else if audio.microphone { audio.muteMicrophone() }
                else { await audio.enableMicrophone { room.connected && room.voiceReady } }
            } catch {
                message = error.localizedDescription
                showRoom()
            }
        }
    }

    private func openNext() {
        guard let following = playback.nextEpisode, !room.connected || room.hosts else { return }
        playback.cancelNext()
        openAutomatically(following)
    }

    private func openConnections() {
        playerOpen = false
        page = .profile
        showConnections = true
    }

    private func showRoom() {
        roomPage = true
    }

    private func changeSource() {
        if playback.selection == nil {
            if playback.usesFileSource {
                importingCaptions = false
                files = true
            } else {
                setFullscreen(false)
                playerOpen = true
                showLink = true
            }
            return
        }
        pendingResume = playback.selection
        replaceSource = true
        library = true
    }

    private func selectVideo(_ video: SourceVideo, _ url: URL) {
        selectVideo(video, url, selection: pendingResume ?? video.playback, fromPicker: library)
    }

    private func selectVideo(_ video: SourceVideo, _ url: URL, selection: HistoryEntry.Playback, fromPicker: Bool) {
        let replacing = replaceSource
        let associated = replacing ? playback.selection : selection
        if let associated { video.remember(for: associated.id) }
        playback.open(url, title: replacing ? playback.title : selection.label ?? selection.media.title,
                      source: replacing ? playback.selection : selection, joinMedia: pendingJoin,
                      startPaused: hostAfterOpening && !room.connected, replacing: replacing, torboxVideo: video)
        if replacing {
            if room.connected {
                room.shareSource(hash: video.hash, filename: video.title, release: video.collection, url: nil)
                playback.publish()
            }
        } else if room.hosts || !room.connected {
            room.setLocalSource(RoomSource(id: UUID().uuidString.lowercased(), hash: video.hash, filename: video.title, release: video.collection, url: nil))
        }
        if !replacing, pendingJoin == nil, let title = associated.flatMap(RoomTitle.init) { room.suggest(title) }
        message = ""
        roomPage = false
        playerOpen = true
        if fromPicker {
            openRoomAfterLibrary = hostAfterOpening
            library = false
        } else {
            downloads = false
            if hostAfterOpening { showRoom() }
            pendingResume = nil
            pendingJoin = nil
            hostAfterOpening = false
        }
    }

    private func withPlaybackSheets<V: View>(_ view: V) -> some View {
        view
        .task(id: playback.hasVideo || room.connected) {
            guard playback.hasVideo || room.connected else { return }
            while !Task.isCancelled {
                playback.tick()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        .onChange(of: room.incomingSource) { _, incoming in
            guard let incoming else { return }
            followRoomSource(incoming)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.endBoost() }
            if phase == .background {
                playback.save()
                history.flush()
                audio.muteMicrophone()
                Task { try? await room.hostedVoice.setMicrophone(false) }
            }
        }
        .sheet(isPresented: $roomPage, onDismiss: {
            if let share = roomSelection {
                roomSelection = nil
                openShared(share)
            }
        }) {
            NavigationStack {
                RoomPage(room: room, audio: audio, playback: playback) { share in
                    roomSelection = share
                    roomPage = false
                }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { roomPage = false } } }
            }
            .presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $files, allowedContentTypes: importingCaptions ? [.data] : [.movie, .mpeg4Movie, .quickTimeMovie, .data]) { result in
            let subtitle = importingCaptions
            importingCaptions = false
            switch result {
            case .success(let url):
                message = ""
                if subtitle {
                    Task { do { try await playback.importCaptions(url) } catch { message = error.localizedDescription } }
                } else {
                    playback.open(url, title: url.deletingPathExtension().lastPathComponent)
                    playerOpen = true
                }
            case .failure: message = subtitle ? "Couldn’t open this subtitle file." : "Couldn’t open this video from Files."
            }
        }
        .sheet(isPresented: $library, onDismiss: {
            pendingResume = nil
            pendingJoin = nil
            hostAfterOpening = false
            replaceSource = false
            if openRoomAfterLibrary { openRoomAfterLibrary = false; showRoom() }
        }) {
            TorBoxLibrary(store: history, connections: connections, resume: pendingResume, sourcePicker: true, select: selectVideo)
        }
        .sheet(isPresented: $downloads) {
            TorBoxLibrary(store: history, connections: connections, resume: nil, sourcePicker: false, modal: true,
                          openConnections: { downloads = false; openConnections() }, select: selectVideo)
        }
        .alert("Open video link", isPresented: $showLink) {
            TextField("https://…", text: $link)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Open", action: openLinkedVideo)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste a direct HTTPS video or HLS stream link.")
        }
        .sheet(isPresented: $settings, onDismiss: {
            if openRoomAfterSettings { openRoomAfterSettings = false; showRoom() }
            else if importingCaptions { files = true }
            else if let next = nextAfterSettings {
                nextAfterSettings = nil
                openAutomatically(next)
            }
            else if changeSourceAfterSettings { changeSourceAfterSettings = false; changeSource() }
        }) {
            PlayerSettings(playback: playback, room: room, watchTogether: {
                openRoomAfterSettings = true
                settings = false
            }, playNext: {
                settings = false
                if let following = playback.nextEpisode {
                    playback.cancelNext()
                    nextAfterSettings = following
                }
            }, importCaptions: {
                importingCaptions = true
                settings = false
            }, sources: {
                changeSourceAfterSettings = true
                settings = false
            }, startsInSubtitles: startsInSubtitles)
        }
        .sheet(isPresented: $episodesSheet) {
            if let selection = playback.selection, selection.media.kind == "tv" {
                InPlayerEpisodesSheet(
                    media: selection.media,
                    currentSeason: selection.episode?.season,
                    currentNumber: selection.episode?.number
                ) { chosen in
                    episodesSheet = false
                    openSelection(chosen, false)
                }
            }
        }
        .sheet(isPresented: $insightSheet) {
            InSightSheet(playback: playback)
        }
    }

    private func followRoomSource(_ source: RoomSource) {
        room.acknowledgeSource(source.id)
        let currentSelection = playback.selection
        let currentTitle = playback.title.isEmpty ? source.displayName : playback.title
        if let rawURL = source.url, let url = TorBox.playbackURL(rawURL) {
            playback.open(url, title: currentTitle, source: currentSelection, replacing: true)
            if room.hosts { playback.publish() }
            return
        }
        message = "Switching to friend’s source…"
        Task {
            let resolved = try? await SourceSelection.resolve(source: source, for: currentSelection)
            guard let (video, url) = resolved else {
                message = "Your friend switched source to \(source.displayName). Open Change source to match."
                return
            }
            if let currentSelection { video.remember(for: currentSelection.id) }
            message = ""
            playback.open(url, title: currentTitle, source: currentSelection, replacing: true, torboxVideo: video)
            if room.hosts { playback.publish() }
        }
    }

    private func openLinkedVideo() {
        guard let url = TorBox.playbackURL(link) else { message = "Enter an HTTPS link to a video or HLS stream."; return }
        let switching = playback.hasVideo && room.connected
        let label = url.lastPathComponent.isEmpty ? "Online video" : url.lastPathComponent
        message = ""
        link = ""
        showLink = false
        playback.open(url, title: switching ? (playback.title.isEmpty ? label : playback.title) : label,
                      source: switching ? playback.selection : nil, replacing: switching)
        if switching {
            room.shareSource(hash: nil, filename: label, release: nil, url: url.absoluteString)
            playback.publish()
        }
        playerOpen = true
    }
}

@MainActor
private struct PlayerRoomControls: View {
    let room: WatchRoom
    @ObservedObject var audio: RoomAudio
    let playback: Playback
    let showRoom: () -> Void
    let openShared: (WatchRoom.Snapshot) -> Void

    var body: some View {
        Button(action: showRoom) {
            HStack {
                Label("Watch Together", systemImage: "person.2.wave.2")
                Spacer()
                if room.connected { Text("Connected").foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(12)
            .background(.thinMaterial, in: .rect(cornerRadius: 11))
        }.buttonStyle(.plain)

        if room.connected, !room.hosts, room.linked.isEmpty, let share = room.snapshot {
            if playback.hasVideo, !share.media.isEmpty {
                Button("Sync this video") { room.link() }.buttonStyle(.borderedProminent)
            }
            if let title = share.title {
                Button("Open \(title.name)") { openShared(share) }.buttonStyle(.borderedProminent)
            }
        }
        if room.state == .disconnected {
            Text("Room connection lost. Playback paused.").foregroundStyle(.secondary).font(.callout)
        } else if room.connected, room.waitingMedia != nil || (!room.linked.isEmpty && room.snapshot?.hold != nil) {
            Text("Waiting for playback to buffer…").foregroundStyle(.secondary).font(.callout)
        }
        if !audio.notice.isEmpty { Text(audio.notice).foregroundStyle(.secondary).font(.callout) }
    }
}

struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.prioritizesVideoDevices = true
        picker.accessibilityLabel = "Audio output"
        return picker
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

@MainActor
private struct InPlayerEpisodesSheet: View {
    let media: HistoryEntry.Playback.Media
    let currentSeason: Int?
    let currentNumber: Int?
    let choose: (HistoryEntry.Playback) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var details: CatalogueTitle?
    @State private var season = 1
    @State private var episodes: [CatalogueEpisode] = []
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List {
                if let seasons = details?.seasons, seasons.count > 1 {
                    Picker("Season", selection: $season) {
                        ForEach(seasons, id: \.self) { number in
                            Text("Season \(number)").tag(number)
                        }
                    }
                    .onChange(of: season) { _, next in
                        Task { await loadEpisodes(season: next) }
                    }
                }
                if loading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading episodes…").foregroundStyle(.secondary)
                    }
                } else if !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.orange)
                        Button("Try again") { Task { await load() } }
                    }
                } else if episodes.isEmpty {
                    ContentUnavailableView("No episodes available", systemImage: "tv",
                                           description: Text("Episode listings aren’t available for this video."))
                } else {
                    ForEach(episodes) { episode in
                        let playing = season == currentSeason && episode.id == currentNumber
                        Button {
                            guard let details else { return }
                            choose(details.playback(season: season, episode: episode))
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("E\(episode.id) · \(episode.name)")
                                        .font(.body.weight(playing ? .bold : .medium))
                                        .foregroundStyle(playing ? Color.accentColor : .primary)
                                    if !episode.overview.isEmpty {
                                        Text(episode.overview)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                                if playing {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(media.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = ""
        do {
            let loaded = try await Catalogue.details(CatalogueTitle(snapshot: media))
            details = loaded
            let target = loaded.seasons.contains(currentSeason ?? 0)
                ? (currentSeason ?? loaded.seasons.first ?? 1)
                : (loaded.seasons.first ?? 1)
            season = target
            episodes = loaded.seasons.isEmpty ? [] : try await Catalogue.episodes(loaded, season: target)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func loadEpisodes(season number: Int) async {
        guard let details else { return }
        loading = true
        error = ""
        do {
            episodes = try await Catalogue.episodes(details, season: number)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
