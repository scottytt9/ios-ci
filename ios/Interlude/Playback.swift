import AVFoundation
import MediaPlayer
import Observation
import Foundation

enum SleepTimerOption: String, CaseIterable, Identifiable {
    case off, m15, m30, m45, m60, endOfEpisode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .m15: return "15 minutes"
        case .m30: return "30 minutes"
        case .m45: return "45 minutes"
        case .m60: return "60 minutes"
        case .endOfEpisode: return "End of episode"
        }
    }
    var minutes: Int? {
        switch self {
        case .m15: return 15
        case .m30: return 30
        case .m45: return 45
        case .m60: return 60
        case .off, .endOfEpisode: return nil
        }
    }
}

@MainActor
@Observable
final class Playback {
    let player = AVPlayer()
    let history = HistoryStore()
    let audio = RoomAudio()
    @ObservationIgnored lazy var room = WatchRoom(audio: audio)
    private(set) var hasVideo = false
    private(set) var title = ""
    private(set) var time = 0.0
    private(set) var bufferedTime = 0.0
    private(set) var duration = 0.0 { didSet { if oldValue != duration { cachedTimeline = nil } } }
    private(set) var isPlaying = false
    private(set) var videoFill = false
    private(set) var captions: [AVMediaSelectionOption] = []
    private(set) var selectedCaption: AVMediaSelectionOption?
    private(set) var audioTracks: [AVMediaSelectionOption] = []
    private(set) var selectedAudio: AVMediaSelectionOption?
    private(set) var importedCaptionName: String?
    private(set) var captionText = ""
    private(set) var captionOffset = 0.0
    private(set) var captionStyle = CaptionStyle.load()
    private(set) var filmVolume: Double = 1
    private(set) var chapters: [VideoChapter] = [] { didSet { cachedTimeline = nil } }
    private(set) var nextEpisode: HistoryEntry.Playback?
    private(set) var nextCountdown: Int?
    var autoNext = UserDefaults.standard.object(forKey: "auto-next") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoNext, forKey: "auto-next") }
    }
    var autoSkipIntro = UserDefaults.standard.bool(forKey: "auto-skip-intro") {
        didSet { UserDefaults.standard.set(autoSkipIntro, forKey: "auto-skip-intro") }
    }
    var communityTimings = UserDefaults.standard.object(forKey: "community-timings") as? Bool ?? true {
        didSet {
            cachedTimeline = nil
            UserDefaults.standard.set(communityTimings, forKey: "community-timings")
        }
    }
    private(set) var error = ""
    private(set) var compatibility: CompatibilityPlayer?
    private(set) var compatibilityAudio: [CompatibilityPlayer.Track] = []
    private(set) var compatibilityCaptions: [CompatibilityPlayer.Track] = []
    private(set) var compatibilityAudioID: Int32 = -1
    private(set) var compatibilityCaptionID: Int32 = -1
    private(set) var retrying = false
    private(set) var opening = false
    private(set) var boosting = false
    private(set) var speed: Float = 1
    private var captionGroup: AVMediaSelectionGroup?
    private var audioGroup: AVMediaSelectionGroup?
    private var importedCaptions: ExternalCaptions?
    @ObservationIgnored private var captionObserver: Any?
    private var community: PlaybackTimeline.Community? { didSet { cachedTimeline = nil } }
    @ObservationIgnored private var cachedTimeline: PlaybackTimeline?
    private var timingPending = false
    private var automationTask: Task<Void, Never>?
    private var nextJob: Task<Void, Never>?
    private var nextDeadline: Int64?
    private var nextCancelled = false
    private var introSkipped = false
    @ObservationIgnored private var scopedURL: URL?
    private var source: HistoryEntry.Playback?
    private var seekRequest = 0
    var subtitlesEnabled: Bool { importedCaptionName != nil || selectedCaption != nil || compatibilityCaptionID >= 0 }
    private var pendingRoomMedia: String?
    private var playAfterPeerBuffer: Bool?
    private var guestBuffer = RoomBufferGate()
    private var hostBuffer = RoomBufferGate()
    private var driftCorrection = RoomDriftCorrection()
    private var remoteMedia = ""
    private var remoteSeek: Int?
    private var seekSequence = 0
    private var lastBufferReport: (media: String, waiting: Bool, clock: Int64)?
    private var media = ""
    private var lastPublish: Int64 = 0
    private var lastSave: Int64 = 0
    private var seeking = false
    private var generation = 0
    private(set) var finished = false
    @ObservationIgnored private var endToken: NSObjectProtocol?
    @ObservationIgnored private var failedToken: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var videoURL: URL?
    private var torboxVideo: SourceVideo?
    private var initialPosition: Double?
    private var wantsPlayback = false
    private var compatibilityStarted: Int64?
    private var compatibilityTrackRefresh: Int64 = 0
    private var restoredCompatibilityCaptions = false
    private var restoredCompatibilityAudio = false
    private var captionPreference = UserDefaults.standard.string(forKey: "subtitle-language")
    private var audioPreference = UserDefaults.standard.string(forKey: "audio-language")
    private(set) var sleepOption: SleepTimerOption = .off
    private(set) var sleepDeadline: Int64?
    private(set) var sleepRemainingLabel: String?
    private(set) var resumedFrom: Double?
    private(set) var enhanceDialogue = UserDefaults.standard.bool(forKey: "enhance-dialogue")
    @ObservationIgnored private var tempSubtitleTask: Task<Void, Never>?
    @ObservationIgnored private var imageGenerator: AVAssetImageGenerator?
    @ObservationIgnored private var imageGeneratorAsset: AVAsset?

    init() {
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.allowsExternalPlayback = true
        setupRemoteCommands()
        room.control = { [weak self] action, time, media in
            guard let self, self.media == media else { return }
            self.perform(action, time: time)
        }
        room.playback = { [weak self] in self?.updateFromHost($0) }
        room.caption = { [weak self] in self?.matchCaption($0) }
        room.onDisconnect = { [weak self] in
            self?.playAfterPeerBuffer = nil
            self?.guestBuffer = RoomBufferGate()
            self?.hostBuffer = RoomBufferGate()
            self?.remoteMedia = ""
            self?.lastBufferReport = nil
            self?.pauseTransport()
        }
        room.onBuffer = { [weak self] id, waiting in
            guard let self, self.media == id else { return }
            if waiting, self.playAfterPeerBuffer == nil {
                self.playAfterPeerBuffer = self.wantsPlayback && !self.finished
                self.pauseTransport()
            } else if !waiting, let resume = self.playAfterPeerBuffer {
                self.playAfterPeerBuffer = nil
                if resume { self.playTransport() }
            }
            self.publish()
        }
        room.onConnect = { [weak self] in
            guard let self else { return }
            self.endBoost()
            self.setSpeed(1)
            if self.room.hosts { self.publish() }
            else { self.pauseTransport() }
        }
        audio.headphonesDisconnected = { [weak self] in
            guard let self else { return }
            self.room.unlink()
            self.pauseTransport()
            self.publish()
        }
    }

    deinit {
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        if let failedToken { NotificationCenter.default.removeObserver(failedToken) }
        if let captionObserver { player.removeTimeObserver(captionObserver) }
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    var selection: HistoryEntry.Playback? { source }
    var usesFileSource: Bool { videoURL?.isFileURL == true }
    var sourceDescription: String? {
        if let torboxVideo { return torboxVideo.title }
        if let videoURL { return videoURL.isFileURL ? "From Files" : "HTTPS video" }
        return nil
    }

    func open(_ url: URL, title: String, source: HistoryEntry.Playback? = nil, joinMedia: String? = nil,
              startPaused: Bool = false, replacing: Bool = false, torboxVideo: SourceVideo? = nil) {
        let keptTime = time
        let keptPlaying = isPlaying
        save()
        endBoost()
        tempSubtitleTask?.cancel(); tempSubtitleTask = nil
        imageGenerator = nil; imageGeneratorAsset = nil
        automationTask?.cancel()
        nextJob?.cancel(); nextJob = nil
        player.pause()
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        compatibility?.stop()
        compatibility = nil
        compatibilityStarted = nil
        compatibilityAudio = []
        compatibilityCaptions = []
        compatibilityAudioID = -1
        compatibilityCaptionID = -1
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.isFileURL && url.startAccessingSecurityScopedResource() ? url : nil
        if !replacing { room.unlink() }
        videoURL = url
        self.torboxVideo = torboxVideo
        retrying = false
        self.source = source
        pendingRoomMedia = joinMedia
        guestBuffer = RoomBufferGate()
        hostBuffer = RoomBufferGate()
        if !replacing {
            playAfterPeerBuffer = nil
            remoteMedia = ""
            seekSequence = 0
        }
        self.title = title
        if !replacing { media = UUID().uuidString.lowercased() }
        error = ""
        duration = 0
        time = replacing ? keptTime : 0
        finished = false
        seeking = false
        lastSave = 0
        captionGroup = nil
        audioGroup = nil
        captions = []
        audioTracks = []
        selectedAudio = nil
        selectedCaption = nil
        if !replacing { clearImportedCaptions(); captionOffset = 0 }
        community = nil
        chapters = []
        if !replacing {
            nextEpisode = nil; nextCancelled = false; introSkipped = false
            if sleepOption == .endOfEpisode {
                sleepOption = .off
                sleepDeadline = nil
                sleepRemainingLabel = nil
            }
        }
        nextCountdown = nil
        nextDeadline = nil
        if !room.hostedVoice.joined { audio.prepareVideo() }
        generation += 1
        let ticket = generation
        let resume = source.flatMap { selected in
            history.entries.first { $0.id == selected.id && !$0.complete && $0.time > 1 }?.time
        }
        let position = replacing ? keptTime : (joinMedia == nil ? resume ?? 0 : 0)
        if !replacing { resumedFrom = (joinMedia == nil && position >= 5) ? position : nil }
        time = position
        initialPosition = position > 0 ? position : nil
        wantsPlayback = !startPaused && (!replacing || keptPlaying) && playAfterPeerBuffer == nil && (!room.connected || room.hosts)
        if PlaybackFailure.prefersCompatibility(torboxVideo?.title ?? url.lastPathComponent) {
            useCompatibility(url, position: position)
            loadAutomation(nil, source: source, ticket: ticket)
            publish()
            return
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        hasVideo = true
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, ticket == self.generation else { return }
                self.didFinish()
            }
        }
        failedToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let cause = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, ticket == self.generation, self.player.currentItem === item else { return }
                self.nativeFailed(item, cause: cause)
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let ready = item.status == .readyToPlay
            Task { @MainActor in
                guard let self, ticket == self.generation, self.player.currentItem === item else { return }
                if failed { self.nativeFailed(item, cause: item.error) }
                if ready {
                    if let position = self.initialPosition {
                        self.initialPosition = nil
                        self.seek(position)
                        if self.wantsPlayback { self.player.play() }
                    }
                    self.linkReadyVideo()
                }
            }
        }
        if wantsPlayback && initialPosition == nil { player.play() }
        publish()
        Task {
            let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard ticket == generation, player.currentItem === item else { return }
            captionGroup = group
            captions = group?.options ?? []
            selectedCaption = group.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
            restoreCaptions()
        }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  ticket == generation, player.currentItem === item else { return }
            audioGroup = group
            audioTracks = group.options
            selectedAudio = item.currentMediaSelection.selectedMediaOption(in: group)
            restoreAudio()
        }
        loadAutomation(item, source: source, ticket: ticket)
    }

    private func removeItemObservers() {
        statusObservation = nil
        if let endToken { NotificationCenter.default.removeObserver(endToken); self.endToken = nil }
        if let failedToken { NotificationCenter.default.removeObserver(failedToken); self.failedToken = nil }
    }

    private func nativeFailed(_ item: AVPlayerItem, cause: Error?) {
        guard let url = videoURL else { return }
        let status = item.errorLog()?.events.reversed().map(\.errorStatusCode).first { (400...599).contains($0) }
        let failure = PlaybackFailure(error: cause, status: status, local: url.isFileURL)
        if failure.canTryAnotherDecoder {
            removeItemObservers()
            player.pause()
            player.replaceCurrentItem(with: nil)
            let position = initialPosition ?? time
            initialPosition = nil
            seeking = false
            captionGroup = nil
            audioGroup = nil
            if let captionObserver { player.removeTimeObserver(captionObserver); self.captionObserver = nil }
            captions = []
            audioTracks = []
            selectedCaption = nil
            selectedAudio = nil
            useCompatibility(url, position: position)
            loadAutomation(nil, source: source, ticket: generation)
        } else {
            error = failure.message(local: url.isFileURL, compatibility: false)
            publish()
        }
    }

    private func useCompatibility(_ url: URL, position: Double) {
        let fallback = CompatibilityPlayer(url: url, position: position, play: wantsPlayback, rate: speed, volume: filmVolume)
        compatibility = fallback
        initialPosition = nil
        compatibilityStarted = RoomInvite.uptime()
        compatibilityTrackRefresh = 0
        restoredCompatibilityCaptions = false
        restoredCompatibilityAudio = false
        hasVideo = true
        fallback.start()
    }

    func retry() async {
        guard !retrying, let previous = videoURL else { return }
        retrying = true
        let ticket = generation
        defer { if ticket == generation { retrying = false } }
        do {
            let url: URL
            if let torboxVideo { url = try await TorBox.url(for: torboxVideo) }
            else { url = previous }
            guard !Task.isCancelled, ticket == generation else { return }
            let shouldPlay = wantsPlayback
            open(url, title: title, source: source, joinMedia: pendingRoomMedia,
                 startPaused: !shouldPlay, replacing: true, torboxVideo: torboxVideo)
            if shouldPlay && (!room.connected || room.hosts) && playAfterPeerBuffer == nil { playTransport() }
        } catch {
            guard !Task.isCancelled, ticket == generation else { return }
            self.error = "TorBox couldn’t open this file again. Check that it’s ready or choose another source."
        }
    }

    private func linkReadyVideo() {
        if let pending = pendingRoomMedia, room.snapshot?.media == pending {
            pendingRoomMedia = nil
            room.link()
        }
    }

    private func didFinish() {
        guard !finished else { return }
        finished = true
        wantsPlayback = false
        if sleepOption == .endOfEpisode {
            sleepOption = .off
            sleepDeadline = nil
            sleepRemainingLabel = nil
            nextCancelled = true
        }
        let length = compatibility?.duration ?? player.currentItem?.duration.seconds ?? 0
        if length.isFinite && length > 0 { duration = length }
        if duration > 0 { time = duration }
        save()
        publish()
    }

    private var transportPlaying: Bool {
        if let compatibility { return compatibility.playing }
        return player.timeControlStatus == .playing
    }

    private func playTransport() {
        wantsPlayback = true
        if let compatibility { compatibility.play() }
        else if initialPosition == nil { player.play() }
    }

    private func pauseTransport() {
        wantsPlayback = false
        if let compatibility { compatibility.pause() }
        else { player.pause() }
    }

    func tick() {
        let waiting = hasVideo && error.isEmpty && (compatibility.map { !$0.ready || $0.waiting } ??
            (player.currentItem?.status == .unknown || player.reasonForWaitingToPlay == .toMinimizeStalls))
        if opening != waiting { opening = waiting }
        if room.connected { room.heartbeat() }
        guard hasVideo else { return }
        let now = RoomInvite.uptime()
        if let compatibility {
            let wasReady = compatibility.ready
            compatibility.update()
            if !wasReady && compatibility.ready {
                compatibilityStarted = nil
                let vlcChapters = compatibility.chapters
                if !vlcChapters.isEmpty && chapters.isEmpty { chapters = vlcChapters }
                linkReadyVideo()
            }
            if compatibility.failed || (compatibilityStarted.map { now - $0 > 30_000 } == true) {
                if error.isEmpty {
                    error = PlaybackFailure(error: nil, status: nil, local: videoURL?.isFileURL == true)
                        .message(local: videoURL?.isFileURL == true, compatibility: true)
                    compatibility.stop()
                }
            } else if compatibility.ended {
                didFinish()
            }
            if compatibility.ready && error.isEmpty && now - compatibilityTrackRefresh >= 1_000 {
                compatibilityTrackRefresh = now
                let audio = compatibility.audioTracks, captions = compatibility.captionTracks
                if compatibilityAudio != audio { compatibilityAudio = audio }
                if compatibilityCaptions != captions { compatibilityCaptions = captions }
                if compatibilityAudioID != compatibility.audioTrack { compatibilityAudioID = compatibility.audioTrack }
                if compatibilityCaptionID != compatibility.captionTrack { compatibilityCaptionID = compatibility.captionTrack }
                if !restoredCompatibilityCaptions && !captions.isEmpty {
                    restoredCompatibilityCaptions = true
                    restoreCaptions()
                }
                if !restoredCompatibilityAudio && !audio.isEmpty {
                    restoredCompatibilityAudio = true
                    restoreAudio()
                }
            }
        }
        let current = compatibility?.time ?? player.currentTime().seconds
        let length = compatibility?.duration ?? player.currentItem?.duration.seconds ?? 0
        if !finished, error.isEmpty, current.isFinite, !seeking, initialPosition == nil,
           compatibility?.ready != false, compatibility?.seekPending != true, max(0, current) != time { time = max(0, current) }
        let total = length.isFinite ? max(0, length) : 0
        if !finished && error.isEmpty && total != duration { duration = total }
        if compatibility == nil, let ranges = player.currentItem?.loadedTimeRanges {
            var furthest = time
            for value in ranges {
                let range = value.timeRangeValue
                let start = range.start.seconds, end = (range.start + range.duration).seconds
                if start.isFinite && end.isFinite && start <= time + 1 && end > furthest { furthest = end }
            }
            if abs(bufferedTime - furthest) > 0.4 { bufferedTime = furthest }
        } else if compatibility != nil {
            if bufferedTime != time { bufferedTime = time }
        }
        if compatibility != nil && importedCaptions != nil { refreshCaption(at: time) }
        let playing = error.isEmpty && (playAfterPeerBuffer ?? wantsPlayback)
        if playing != isPlaying { isPlaying = playing }
        updateNowPlayingInfo()
        if room.connected, !room.hosts, !room.linked.isEmpty {
            let recovering = room.snapshot?.hold == "guest" && (room.snapshot?.intent ?? wantsPlayback)
            let needsPlayback = room.snapshot?.playing == true || recovering
            let stalled = !finished && needsPlayback && (!error.isEmpty || (compatibility?.waiting ??
                (player.currentItem?.status != .readyToPlay || !seeking && player.currentItem?.isPlaybackBufferEmpty == true ||
                 player.reasonForWaitingToPlay == .toMinimizeStalls)))
            let waiting = guestBuffer.update(stalled, at: now)
            if lastBufferReport?.media != room.linked || lastBufferReport?.waiting != waiting || now - (lastBufferReport?.clock ?? 0) >= 1800 {
                lastBufferReport = (room.linked, waiting, now)
                room.reportBuffer(waiting)
            }
        } else {
            if lastBufferReport != nil { guestBuffer = RoomBufferGate() }
            lastBufferReport = nil
        }
        if room.connected, now - lastPublish >= 750 { publish() }
        if error.isEmpty && transportPlaying && now - lastSave >= 5000 { save() }
        if let deadline = sleepDeadline {
            if now >= deadline {
                sleepDeadline = nil
                sleepOption = .off
                sleepRemainingLabel = nil
                pauseTransport()
                publish()
            } else {
                updateSleepLabel(now: now)
            }
        }
        runAutomation(now: now)
    }

    func action(_ action: String, time: Double = 0) {
        endBoost()
        if room.connected && !room.hosts { room.request(action, time: time) }
        else { perform(action, time: time) }
    }

    func setSpeed(_ value: Float) {
        guard !boosting, !room.connected || value == 1 else { return }
        speed = value
        compatibility?.setRate(value)
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
    }

    func startBoost() {
        guard !boosting, wantsPlayback, !room.connected, !finished, error.isEmpty,
              compatibility?.ready ?? (player.currentItem?.status == .readyToPlay) else { return }
        boosting = true
        if let compatibility { compatibility.setRate(2) }
        else { player.defaultRate = 2; player.play() }
    }

    func endBoost() {
        guard boosting else { return }
        boosting = false
        if let compatibility { compatibility.setRate(speed) }
        else {
            player.defaultRate = speed
            if wantsPlayback { player.play() }
        }
    }

    func selectCaption(_ track: AVMediaSelectionOption?, announce: Bool = true) {
        clearImportedCaptions()
        if let captionGroup { player.currentItem?.select(track, in: captionGroup) }
        selectedCaption = track
        if announce {
            tempSubtitleTask?.cancel(); tempSubtitleTask = nil
            let language = track.map(captionLanguage) ?? "off"
            rememberCaptionLanguage(language)
            room.announceCaption(language)
        }
    }

    func selectAudio(_ track: AVMediaSelectionOption) {
        guard let audioGroup else { return }
        player.currentItem?.select(track, in: audioGroup)
        selectedAudio = track
        rememberAudioLanguage(captionLanguage(track))
    }

    func selectCompatibilityAudio(_ id: Int32) {
        compatibility?.selectAudio(id)
        compatibilityAudioID = id
        if let name = compatibilityAudio.first(where: { $0.id == id })?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            rememberAudioLanguage(Self.normalizedTrackLanguage(from: name) ?? name)
        }
    }

    func selectCompatibilityCaption(_ id: Int32, announce: Bool = true) {
        clearImportedCaptions()
        compatibility?.selectCaption(id)
        compatibilityCaptionID = id
        if announce {
            tempSubtitleTask?.cancel(); tempSubtitleTask = nil
            let language = id < 0 ? "off" : "und"
            rememberCaptionLanguage(language)
            room.announceCaption(language)
        }
    }

    func setVolume(_ value: Double) {
        filmVolume = max(0, min(compatibility != nil ? 2 : 1, value))
        player.volume = Float(min(1, filmVolume))
        compatibility?.setVolume(filmVolume)
    }

    func toggleVideoFill(_ fill: Bool? = nil) {
        videoFill = fill ?? !videoFill
        compatibility?.setFillScreen(videoFill)
    }

    func closeVideo() {
        save()
        endBoost()
        tempSubtitleTask?.cancel(); tempSubtitleTask = nil
        imageGenerator = nil; imageGeneratorAsset = nil
        automationTask?.cancel()
        nextJob?.cancel(); nextJob = nil
        player.pause()
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        compatibility?.stop()
        compatibility = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        clearImportedCaptions()
        room.unlink()
        hasVideo = false
        isPlaying = false
        finished = false
        title = ""
        time = 0
        bufferedTime = 0
        duration = 0
        error = ""
        source = nil
        nextEpisode = nil
        nextCountdown = nil
        sleepOption = .off
        sleepDeadline = nil
        sleepRemainingLabel = nil
        resumedFrom = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func setupRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.action("play") }
            return .success
        }
        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.action("pause") }
            return .success
        }
        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.action(self.isPlaying ? "pause" : "play")
            }
            return .success
        }
        commands.skipForwardCommand.isEnabled = true
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.duration > 0 else { return }
                self.action("seek", time: min(self.duration, self.time + 10))
            }
            return .success
        }
        commands.skipBackwardCommand.isEnabled = true
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.duration > 0 else { return }
                self.action("seek", time: max(0, self.time - 10))
            }
            return .success
        }
        commands.changePlaybackPositionCommand.isEnabled = true
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = positionEvent.positionTime
            Task { @MainActor in self?.action("seek", time: target) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard hasVideo, !title.isEmpty else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: selection?.media.title ?? title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(boosting ? 2 : speed) : 0.0,
        ]
        if let label = selection?.label { info[MPMediaItemPropertyArtist] = label }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepOption = option
        let now = RoomInvite.uptime()
        sleepDeadline = option.minutes.map { now + Int64($0) * 60_000 }
        updateSleepLabel(now: now)
    }

    private func updateSleepLabel(now: Int64) {
        let next: String?
        if sleepOption == .endOfEpisode {
            next = "End"
        } else if let deadline = sleepDeadline {
            let mins = max(1, Int((deadline - now + 59_999) / 60_000))
            next = "\(mins)m"
        } else {
            next = nil
        }
        if sleepRemainingLabel != next { sleepRemainingLabel = next }
    }

    func dismissResumePrompt() {
        resumedFrom = nil
    }

    func startOver() {
        resumedFrom = nil
        action("seek", time: 0)
    }

    func setEnhanceDialogue(_ enabled: Bool) {
        enhanceDialogue = enabled
        UserDefaults.standard.set(enabled, forKey: "enhance-dialogue")
        let session = AVAudioSession.sharedInstance()
        if !room.hostedVoice.joined && !room.connected {
            try? session.setCategory(.playback, mode: enabled ? .spokenAudio : .moviePlayback)
            try? session.setActive(true)
        }
        if compatibility != nil {
            let targetVol = enabled ? max(filmVolume, 1.25) : min(filmVolume, 1.0)
            setVolume(targetVol)
        }
    }

    func whatDidTheySay() -> String {
        guard hasVideo else { return "−10s" }
        let target = max(0, time - 10)
        action("seek", time: target)
        guard !subtitlesEnabled else { return "−10s" }

        var enabledTemp = false
        if let compatibility {
            let pick = compatibilityCaptions.first { $0.name.localizedCaseInsensitiveContains("eng") } ?? compatibilityCaptions.first
            if let pick {
                selectCompatibilityCaption(pick.id, announce: false)
                enabledTemp = true
            }
        } else if let option = captions.first(where: { captionLanguage($0).lowercased().hasPrefix("en") }) ?? captions.first {
            selectCaption(option, announce: false)
            enabledTemp = true
        }

        if enabledTemp {
            tempSubtitleTask?.cancel()
            tempSubtitleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(14))
                guard let self, !Task.isCancelled else { return }
                if self.compatibility != nil { self.selectCompatibilityCaption(-1, announce: false) }
                else { self.selectCaption(nil, announce: false) }
            }
            return "−10s · Subtitles on (14s)"
        }
        return "−10s"
    }

    func recentCaptionContext() -> String {
        guard let importedCaptions else { return captionText }
        var lines: [String] = []
        let now = time - captionOffset
        var probe = max(0, now - 25)
        while probe <= now + 10 {
            let text = importedCaptions.text(at: probe)
            if !text.isEmpty && lines.last != text { lines.append(text) }
            probe += 2.5
        }
        return lines.joined(separator: " ")
    }

    func scrubThumbnail(at seconds: Double) async -> CGImage? {
        guard compatibility == nil, let asset = player.currentItem?.asset, seconds.isFinite else { return nil }
        let generator: AVAssetImageGenerator
        if imageGeneratorAsset === asset, let existing = imageGenerator {
            generator = existing
        } else {
            let fresh = AVAssetImageGenerator(asset: asset)
            fresh.appliesPreferredTrackTransform = true
            fresh.maximumSize = CGSize(width: 320, height: 180)
            fresh.requestedTimeToleranceBefore = CMTime(seconds: 0.6, preferredTimescale: 600)
            fresh.requestedTimeToleranceAfter = CMTime(seconds: 0.6, preferredTimescale: 600)
            imageGenerator = fresh
            imageGeneratorAsset = asset
            generator = fresh
        }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        return try? await generator.image(at: target).image
    }

    func currentFrameImage() async -> CGImage? {
        guard compatibility == nil, let asset = player.currentItem?.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        return try? await generator.image(at: target).image
    }

    func importCaptions(_ url: URL) async throws {
        let token = generation
        let track = try await Task.detached(priority: .userInitiated) { try ExternalCaptions.importFile(url) }.value
        guard token == generation, hasVideo else { return }
        applyExternalCaptions(track)
    }

    func loadExternalCaptions(name: String, text: String) async throws {
        let token = generation
        let track = try await Task.detached(priority: .userInitiated) { try ExternalCaptions(name: name, text: text) }.value
        guard token == generation, hasVideo else { return }
        applyExternalCaptions(track)
    }

    private func applyExternalCaptions(_ track: ExternalCaptions) {
        if let captionGroup { player.currentItem?.select(nil, in: captionGroup) }
        compatibility?.selectCaption(-1)
        compatibilityCaptionID = -1
        selectedCaption = nil
        importedCaptions = track
        importedCaptionName = track.name
        captionOffset = 0
        room.announceCaption("und")
        refreshCaption(at: compatibility?.time ?? player.currentTime().seconds)
        observeImportedCaptions()
    }

    private func observeImportedCaptions() {
        if compatibility == nil && captionObserver == nil {
            captionObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] clock in
                Task { @MainActor in self?.refreshCaption(at: clock.seconds) }
            }
        }
    }

    func setCaptionOffset(_ value: Double) {
        captionOffset = min(60, max(-60, value))
        if importedCaptions == nil { compatibility?.setSubtitleDelay(captionOffset) }
        refreshCaption(at: compatibility?.time ?? player.currentTime().seconds)
    }

    func setCaptionStyle(_ style: CaptionStyle) {
        captionStyle = style
        style.save()
    }

    private func clearImportedCaptions() {
        importedCaptions = nil
        importedCaptionName = nil
        captionText = ""
        if let captionObserver { player.removeTimeObserver(captionObserver); self.captionObserver = nil }
    }

    private func refreshCaption(at position: Double) {
        let value = position.isFinite ? importedCaptions?.text(at: position - captionOffset) ?? "" : ""
        if captionText != value { captionText = value }
    }

    private func captionLanguage(_ track: AVMediaSelectionOption) -> String {
        track.extendedLanguageTag ?? track.locale?.language.languageCode?.identifier ?? "und"
    }

    private func rememberCaptionLanguage(_ language: String) {
        guard language != "und" else { return }
        captionPreference = language
        UserDefaults.standard.set(language, forKey: "subtitle-language")
    }

    private func rememberAudioLanguage(_ language: String) {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != "und" else { return }
        audioPreference = normalized
        UserDefaults.standard.set(normalized, forKey: "audio-language")
    }

    private func restoreAudio() {
        guard let pref = audioPreference, !pref.isEmpty else { return }
        if let compatibility {
            let names = candidateTrackNames(for: pref)
            if let track = compatibility.audioTracks.first(where: { track in
                names.contains { name in track.name.localizedCaseInsensitiveContains(name) && name.count > 1 }
            }) {
                compatibility.selectAudio(track.id)
                compatibilityAudioID = track.id
            }
            return
        }
        let tag = pref.lowercased().split(separator: "-").first
        let names = candidateTrackNames(for: pref)
        if let audioGroup,
           let option = audioTracks.first(where: { option in
               let code = captionLanguage(option).lowercased().split(separator: "-").first
               if let tag, code == tag { return true }
               return names.contains { option.displayName.localizedCaseInsensitiveContains($0) && $0.count > 2 }
           }) {
            player.currentItem?.select(option, in: audioGroup)
            selectedAudio = option
        }
    }

    private func candidateTrackNames(for language: String) -> [String] {
        [language,
         Locale(identifier: "en").localizedString(forLanguageCode: language),
         Locale.current.localizedString(forLanguageCode: language)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedTrackLanguage(from label: String) -> String? {
        let lower = label.lowercased()
        let map: [(String, String)] = [
            ("english", "en"), ("spanish", "es"), ("french", "fr"), ("german", "de"),
            ("italian", "it"), ("portuguese", "pt"), ("japanese", "ja"), ("korean", "ko"),
            ("chinese", "zh"), ("arabic", "ar"), ("russian", "ru"), ("hindi", "hi"),
            ("polish", "pl"), ("turkish", "tr"), ("dutch", "nl"), ("swedish", "sv")
        ]
        return map.first { lower.contains($0.0) }?.1
    }

    private func restoreCaptions() {
        if importedCaptions != nil {
            if let captionGroup { player.currentItem?.select(nil, in: captionGroup) }
            compatibility?.selectCaption(-1)
            compatibilityCaptionID = -1
            selectedCaption = nil
            observeImportedCaptions()
            room.announceCaption("und")
            return
        }
        if room.connected && room.followCaptions, let language = room.language {
            matchCaption(language)
            return
        }
        if let captionPreference { matchCaption(captionPreference) }
        room.announceCaption(selectedCaption.map(captionLanguage) ?? (compatibilityCaptionID >= 0 ? "und" : "off"))
    }

    func matchCaption(_ language: String) {
        if let compatibility {
            if language == "off" { selectCompatibilityCaption(-1, announce: false); return }
            let names = [language, Locale(identifier: "en").localizedString(forLanguageCode: language),
                         Locale.current.localizedString(forLanguageCode: language)].compactMap { $0 }
            if let track = compatibility.captionTracks.first(where: { track in
                names.contains { name in track.name.localizedCaseInsensitiveContains(name) && name.count > 2 }
            }) { selectCompatibilityCaption(track.id, announce: false) }
            return
        }
        if language == "off" { selectCaption(nil, announce: false); return }
        let tag = language.lowercased().split(separator: "-").first
        if let option = captions.first(where: {
            let code = captionLanguage($0)
            return code.lowercased().split(separator: "-").first == tag
        }) { selectCaption(option, announce: false) }
    }

    private var timeline: PlaybackTimeline {
        let duration = duration, chapters = chapters
        let markers = communityTimings ? community : nil
        if let cachedTimeline { return cachedTimeline }
        let resolved = PlaybackTimeline(chapters: chapters, duration: duration, community: markers)
        cachedTimeline = resolved
        return resolved
    }
    var timelineSegments: PlaybackTimeline { timeline }
    var introTarget: Double? {
        recapTarget == nil ? target(in: timeline.intro) : nil
    }

    var recapTarget: Double? { target(in: timeline.recap) }

    private func target(in segment: PlaybackTimeline.Segment?) -> Double? {
        guard let segment, time >= segment.start, time < segment.end - 0.5, !finished else { return nil }
        return segment.end
    }

    var offersNextEpisode: Bool {
        guard nextEpisode != nil, sleepOption != .endOfEpisode, (!room.connected || room.hosts) else { return false }
        if finished { return true }
        guard !nextCancelled, let credits = timeline.credits else { return false }
        return time >= credits.start && (timeline.advanceAtCredits || time < credits.end)
    }

    func skipSegment() {
        if let target = recapTarget { action("seek", time: target) }
        else { skipIntro() }
    }

    func skipIntro() {
        if let at = introTarget {
            introSkipped = true
            action("seek", time: at)
        }
    }

    func cancelNext() {
        nextCancelled = true
        nextJob?.cancel(); nextJob = nil
        nextCountdown = nil
        nextDeadline = nil
    }

    func updateCommunityTimings(_ enabled: Bool) {
        communityTimings = enabled
        if hasVideo { loadAutomation(player.currentItem, source: source, ticket: generation) }
    }

    private func loadAutomation(_ item: AVPlayerItem?, source: HistoryEntry.Playback?, ticket: Int) {
        automationTask?.cancel()
        timingPending = communityTimings && source != nil
        automationTask = Task {
            let groups: [AVTimedMetadataGroup]
            if let item {
                groups = (try? await item.asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
            } else { groups = [] }
            var markers: [VideoChapter] = []
            for group in groups {
                let name = group.items.first { $0.commonKey == .commonKeyTitle }
                let title = try? await name?.load(.stringValue)
                let seconds = group.timeRange.start.seconds
                if seconds.isFinite, !markers.contains(where: { $0.start == seconds }) {
                    markers.append(.init(title: title ?? "Chapter \(markers.count + 1)", start: seconds))
                }
            }
            guard !Task.isCancelled, ticket == generation else { return }
            chapters = markers.sorted { $0.start < $1.start }
            if let source {
                if communityTimings, let imdb = try? await Catalogue.imdb(source.media) {
                    let fetched = try? await PlaybackTimeline.lookup(imdb: imdb, season: source.episode?.season, episode: source.episode?.number)
                    if !Task.isCancelled, ticket == generation { community = fetched }
                }
                guard !Task.isCancelled, ticket == generation else { return }
                timingPending = false
                let following = try? await Catalogue.nextEpisode(after: source)
                if !Task.isCancelled, ticket == generation { nextEpisode = following }
            } else { timingPending = false }
        }
    }

    private func runAutomation(now: Int64) {
        guard !room.connected || room.hosts else { return }
        let advancing = error.isEmpty && transportPlaying && !seeking && playAfterPeerBuffer == nil
        if autoSkipIntro, !introSkipped, advancing, introTarget != nil { skipIntro() }
        let plan = timeline
        let atCredits = !timingPending && plan.advanceAtCredits && plan.credits.map { time >= $0.start } == true
        guard autoNext, sleepOption != .endOfEpisode, !nextCancelled, let episode = nextEpisode, finished || (advancing && atCredits) else {
            nextDeadline = nil
            if nextCountdown != nil { nextCountdown = nil }
            nextJob?.cancel(); nextJob = nil
            return
        }
        guard nextJob == nil else { return }
        let deadline = nextDeadline ?? now + 5000
        nextDeadline = deadline
        let seconds = Int(max(0, deadline - now + 999) / 1000)
        if nextCountdown != seconds { nextCountdown = seconds }
        guard seconds == 0 else { return }
        nextJob = Task {
            let ticket = generation
            let resolved = try? await SourceSelection.resolve(episode, maySearch: TorBox.key(account: TorrentSources.account) != nil)
            guard !Task.isCancelled, ticket == generation, !nextCancelled else { return }
            nextJob = nil
            nextCountdown = nil
            nextCancelled = true
            guard let (file, url) = resolved, !Task.isCancelled,
                  ticket == generation, autoNext, finished || (timeline.credits.map { time >= $0.start } == true && transportPlaying) else { return }
            if !finished { history.record(playback: source ?? episode, time: time, duration: duration, complete: true) }
            open(url, title: episode.label ?? episode.media.title, source: episode, torboxVideo: file)
        }
    }

    private func readySources(for episode: HistoryEntry.Playback) async -> [SourceVideo] {
        guard let key = TorBox.key(), let files = try? await TorBox.library(key: key) else { return [] }
        return files.filter { $0.matches(episode) }
    }

    func save() {
        guard let source, time > 0 || finished else { return }
        lastSave = RoomInvite.uptime()
        history.record(playback: source, time: time, duration: duration, complete: finished)
    }

    func publish() {
        guard room.connected, room.hosts else { return }
        lastPublish = RoomInvite.uptime()
        let intent = hasVideo && !finished && error.isEmpty && (playAfterPeerBuffer ?? wantsPlayback)
        let stalled = compatibility?.waiting ?? (player.reasonForWaitingToPlay == .toMinimizeStalls)
        let waiting = hostBuffer.update(intent && stalled, at: lastPublish)
        let hold = playAfterPeerBuffer != nil ? "guest" : intent && waiting ? "host" : nil
        room.publish(media: media, time: time, playing: hold == nil && intent, title: source.flatMap(RoomTitle.init),
                     hold: hold, intent: intent, seek: seekSequence)
    }

    private func perform(_ action: String, time: Double) {
        guard hasVideo else { return }
        if playAfterPeerBuffer != nil, action == "play" || action == "pause" {
            playAfterPeerBuffer = action == "play"
            publish()
            return
        }
        switch action {
        case "play":
            if finished { seek(0) }
            finished = false
            playTransport()
        case "pause":
            pauseTransport()
            save()
        case "seek":
            seek(time)
        default: return
        }
        publish()
    }

    private func updateFromHost(_ snapshot: WatchRoom.Snapshot?) {
        guard hasVideo else { return }
        guard let snapshot else {
            remoteMedia = ""
            pauseTransport()
            return
        }
        let newMedia = remoteMedia != snapshot.media
        let explicit = newMedia || (snapshot.seek != nil && snapshot.seek != remoteSeek)
        if newMedia { driftCorrection = RoomDriftCorrection() }
        remoteMedia = snapshot.media
        remoteSeek = snapshot.seek
        let target = room.target(snapshot)
        let recovering = snapshot.hold == "guest" && (snapshot.intent ?? wantsPlayback)
        if (explicit || snapshot.hold == nil), !seeking || explicit {
            let ready = compatibility.map { $0.ready && !$0.waiting && !$0.seekPending } ??
                (player.currentItem?.status == .readyToPlay && player.reasonForWaitingToPlay != .toMinimizeStalls)
            if driftCorrection.shouldSeek(drift: abs(time - target), playing: snapshot.playing,
                                          explicit: explicit, ready: ready, at: RoomInvite.uptime()) { seek(target) }
        }
        let shouldPlay = snapshot.playing || recovering
        if shouldPlay != wantsPlayback {
            if shouldPlay {
                finished = false
                playTransport()
            } else { pauseTransport() }
        }
    }

    private func seek(_ target: Double) {
        guard target.isFinite else { return }
        let value = max(0, duration > 0 ? min(target, duration) : target)
        if room.connected && room.hosts { seekSequence = (seekSequence + 1) % 2_147_483_647 }
        time = value
        if let compatibility { compatibility.seek(value); return }
        if player.currentItem?.status != .readyToPlay { initialPosition = value; return }
        let when = CMTime(seconds: value, preferredTimescale: 1000)
        seeking = true
        seekRequest &+= 1
        let ticket = generation
        let request = seekRequest
        let tolerance = room.connected ? CMTime.zero : CMTime(seconds: 0.18, preferredTimescale: 1000)
        player.seek(to: when, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self, ticket == self.generation, request == self.seekRequest else { return }
                self.seeking = false
            }
        }
    }
}
