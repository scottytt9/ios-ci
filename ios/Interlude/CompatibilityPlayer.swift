import MobileVLCKit
import UIKit

@MainActor
final class CompatibilityPlayer {
    struct Track: Identifiable, Equatable {
        let id: Int32
        let name: String
    }

    let surface = UIView()
    private let engine = VLCMediaPlayer()
    private var started = false
    private(set) var ready = false
    private(set) var wantsPlayback: Bool
    private var pendingSeek: Double?
    private var seekRetries = 0
    private var volume: Double
    private var rate: Float
    private var fillScreen = false

    init(url: URL, position: Double, play: Bool, rate: Float, volume: Double) {
        self.volume = volume
        self.rate = rate
        wantsPlayback = play
        pendingSeek = position > 0 ? position : nil
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching": 2500,
            "file-caching": 1000,
            "clock-jitter": 0,
            "clock-synchro": 0,
        ])
        engine.media = media
        surface.backgroundColor = .black
        surface.isUserInteractionEnabled = false
    }

    func start() {
        guard !started else { return }
        started = true
        engine.drawable = surface
        engine.audio?.volume = 0
        engine.play()
    }

    func stop() {
        engine.stop()
        engine.drawable = nil
    }

    var time: Double { Double(engine.time.value?.int64Value ?? 0) / 1000 }
    var duration: Double { Double(engine.media?.length.value?.int64Value ?? 0) / 1000 }
    var ended: Bool { engine.state == .ended }
    var failed: Bool { engine.state == .error }
    var playing: Bool { ready && wantsPlayback && engine.isPlaying }
    var waiting: Bool { !failed && !ended && (!ready || wantsPlayback && (engine.state == .buffering || engine.state == .opening)) }
    var seekPending: Bool { pendingSeek != nil }

    func update() {
        if !ready && (engine.state == .playing || engine.isPlaying && engine.hasVideoOut) {
            ready = true
            if !wantsPlayback { engine.pause() }
            engine.audio?.volume = Int32((volume * 100).rounded())
            engine.rate = rate
            applyFill()
        }
        if let pendingSeek, ready {
            if engine.isSeekable {
                engine.time = VLCTime(int: Int32(min(pendingSeek * 1000, Double(Int32.max))))
                self.pendingSeek = nil
                seekRetries = 0
            } else {
                seekRetries += 1
                if seekRetries > 20 {
                    self.pendingSeek = nil
                    seekRetries = 0
                }
            }
        }
    }

    func play() {
        wantsPlayback = true
        if ready {
            engine.play()
            engine.rate = rate
        }
    }

    func pause() {
        wantsPlayback = false
        if ready { engine.pause() }
    }

    func seek(_ seconds: Double) {
        pendingSeek = seconds
        seekRetries = 0
        update()
    }

    func setRate(_ value: Float) {
        rate = value
        if ready { engine.rate = value }
    }

    func setVolume(_ value: Double) {
        volume = max(0, min(2, value))
        if ready { engine.audio?.volume = Int32((volume * 100).rounded()) }
    }

    func setSubtitleDelay(_ seconds: Double) {
        engine.currentVideoSubTitleDelay = Int((seconds * 1_000_000).rounded())
    }

    func setFillScreen(_ fill: Bool) {
        fillScreen = fill
        if ready { applyFill() }
    }

    private func applyFill() {
        if fillScreen, surface.bounds.width > 0, surface.bounds.height > 0 {
            let ratio = "\(Int(surface.bounds.width)):\(Int(surface.bounds.height))"
            ratio.withCString { engine.videoCropGeometry = UnsafeMutablePointer(mutating: $0) }
        } else {
            engine.videoCropGeometry = nil
        }
    }

    var chapters: [VideoChapter] {
        guard let list = engine.chapterDescriptions(ofTitle: 0) as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { index, entry in
            guard let offsetMs = entry[VLCChapterDescriptionTimeOffset] as? NSNumber else { return nil }
            let start = offsetMs.doubleValue / 1000
            let name = (entry[VLCChapterDescriptionName] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(index + 1)"
            return VideoChapter(title: name, start: max(0, start))
        }
    }

    var audioTracks: [Track] { tracks(engine.audioTrackIndexes, engine.audioTrackNames) }
    var captionTracks: [Track] { tracks(engine.videoSubTitlesIndexes, engine.videoSubTitlesNames) }
    var audioTrack: Int32 { engine.currentAudioTrackIndex }
    var captionTrack: Int32 { engine.currentVideoSubTitleIndex }
    func selectAudio(_ id: Int32) { engine.currentAudioTrackIndex = id }
    func selectCaption(_ id: Int32) { engine.currentVideoSubTitleIndex = id }

    private func tracks(_ ids: [Any], _ names: [Any]) -> [Track] {
        zip(ids, names).compactMap { id, name in
            guard let number = id as? NSNumber, number.int32Value >= 0, let label = name as? String else { return nil }
            return Track(id: number.int32Value, name: label)
        }
    }
}
