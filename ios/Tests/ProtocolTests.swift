import AVFoundation
import Foundation

@main
enum ProtocolTests {
    static func main() throws {
        var gate = RoomBufferGate()
        precondition(!gate.update(true, at: 0))
        precondition(!gate.update(false, at: 500))
        precondition(!gate.update(true, at: 600))
        precondition(gate.update(true, at: 1_800))
        precondition(gate.update(false, at: 2_000))
        precondition(gate.update(true, at: 2_600))
        precondition(gate.update(false, at: 2_700))
        precondition(!gate.update(false, at: 3_400))
        var drift = RoomDriftCorrection()
        precondition(!drift.shouldSeek(drift: 0.9, playing: true, explicit: false, ready: true, at: 0))
        precondition(!drift.shouldSeek(drift: 2, playing: true, explicit: false, ready: false, at: 0))
        precondition(drift.shouldSeek(drift: 2, playing: true, explicit: false, ready: true, at: 1))
        precondition(!drift.shouldSeek(drift: 2, playing: true, explicit: false, ready: true, at: 1_000))
        precondition(drift.shouldSeek(drift: 2, playing: true, explicit: true, ready: false, at: 1_000))

        precondition(PlaybackFailure.prefersCompatibility("Episode.MKV"))
        precondition(PlaybackFailure.prefersCompatibility("sample.webm"))
        precondition(!PlaybackFailure.prefersCompatibility("sample.mp4"))
        precondition(!PlaybackFailure.prefersCompatibility("playlist.m3u8"))
        let unsupported = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decoderNotFound.rawValue)
        precondition(PlaybackFailure(error: unsupported, status: nil, local: true).canTryAnotherDecoder)
        precondition(PlaybackFailure(error: unsupported, status: 403, local: false) == .access)
        let offline = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: unsupported.code, userInfo: [NSUnderlyingErrorKey: offline])
        precondition(PlaybackFailure(error: wrapped, status: nil, local: false) == .connection)
        print("Playback format selection and failure classification passed.")

        let now: Int64 = 1_800_000_000_000
        let code = RoomInvite(room: "12345678-1234-1234-1234-123456789012", role: "offer", expires: now + 1000,
                              sdp: "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n",
                              ice: [.init(mid: "0", index: 0, sdp: "candidate:test")])
        let encoded = try code.encode()
        let decoded = try RoomInvite.decode(encoded, now: now)
        precondition(decoded == code)
        precondition((try? RoomInvite.decode(encoded, now: now + 2000)) == nil)
        precondition((try? RoomInvite.decode(encoded + "!", now: now)) == nil)

        for rate in [8_000.0, 16_000.0, 24_000.0, 44_100.0, 48_000.0] {
            let samples = Array(repeating: Float(-0.5), count: Int(rate / 25))
            let packetizer = VoiceFrames()
            var packets: [Data] = []
            samples.withUnsafeBufferPointer { packetizer.capture($0, rate: rate) { packets.append($0) } }
            precondition(packets.count == 2 && packets.allSatisfy { $0.count == VoiceFrames.bytes })
            var rendered = Array(repeating: Float(0), count: VoiceFrames.samples)
            rendered.withUnsafeMutableBufferPointer { VoiceFrames.render(packets[0], into: $0.baseAddress!) }
            precondition(rendered.allSatisfy { abs($0 + 0.5) < 0.001 })
        }
        print("Room code round-trip, expiry and five PCM sample rates passed.")

        let wire: [String: Any] = ["kind": "tv", "id": 1396, "name": "Breaking Bad", "year": "2008", "season": 2, "episode": 3]
        let shared = RoomTitle.read(wire)
        precondition(shared?.playback.id == "tv:1396:2:3")
        precondition(shared?.playback.episode?.number == 3)
        precondition(RoomTitle.read(wire.merging(["episode": 0]) { _, new in new }) == nil)
        precondition(RoomTitle.read(wire.merging(["kind": "file"]) { _, new in new }) == nil)
        print("Shared movie and episode identifiers validated.")

        let srt = "1\r\n00:00:01,000 --> 00:00:08,000\r\n<i>First</i>\r\n\r\n2\r\n00:00:03,000 --> 00:00:06,000\r\nSecond\r\n"
        let captions = try ExternalCaptions(name: "sample.srt", text: srt)
        precondition(captions.text(at: 0.9).isEmpty)
        precondition(captions.text(at: 3) == "First\nSecond")
        precondition(captions.text(at: 6) == "First" && captions.text(at: 8).isEmpty)
        let webVTT = try ExternalCaptions(name: "sample.vtt", text: "WEBVTT\n\n00:01.000 --> 00:02.000 align:center\nReady.\n")
        precondition(webVTT.text(at: 1.5) == "Ready.")

        let chapters: [VideoChapter] = [.init(title: "Opening credits", start: 20), .init(title: "Part 1", start: 60), .init(title: "End credits", start: 3_450)]
        let timeline = PlaybackTimeline(chapters: chapters, duration: 3_600, community: nil)
        precondition(timeline.intro?.end == 60 && timeline.advanceAtCredits)
        let withStinger = PlaybackTimeline(chapters: chapters + [.init(title: "Epilogue", start: 3_540)], duration: 3_600, community: nil)
        precondition(withStinger.credits?.end == 3_540 && !withStinger.advanceAtCredits)
        let otherCut = PlaybackTimeline.Community(intro: .init(start: 30, end: 70), recap: .init(start: 0, end: 40),
                                                  outro: .init(start: 3_150, end: 3_300), postCredits: nil)
        let mismatched = PlaybackTimeline(duration: 3_600, community: otherCut)
        precondition(mismatched.intro == nil && mismatched.recap == nil)
        let recap = PlaybackTimeline.Community(intro: nil, recap: .init(start: 0, end: 28), outro: nil, postCredits: nil)
        precondition(PlaybackTimeline(chapters: chapters, duration: 3_600, community: recap).recap?.end == 20)
        let chapterRecap = PlaybackTimeline(chapters: chapters + [.init(title: "Previously on Interlude", start: 0)], duration: 3_600, community: nil)
        precondition(chapterRecap.recap?.end == 20)
        print("SRT, WebVTT, overlapping captions, intro and credits safeguards passed.")

        if let path = CommandLine.arguments.dropFirst().first {
            let code = try String(contentsOfFile: path, encoding: .utf8)
            let profile = try ProfileFile.decode(code)
            precondition(profile.history.entries.first?.time == 123.5)
            precondition(profile.history.removals?["movie:40"] == 1_777_000_000_001)
            precondition(profile.list.first?.title == "Épisode test")
            precondition(profile.themes.active.accent == "#fbe44a")
            let roundTrip = try ProfileFile.decode(profile.encode())
            precondition(roundTrip.history.entries.first?.playback.episode?.number == 3)
            print("Windows profile code, resume, list, theme, and re-export passed.")
        }
        let poster = "https://image.tmdb.org/t/p/w500/qJ2tW6WMUDux911r6m7haRef0WH.jpg"
        let card = ArtworkRequest(poster, size: CGSize(width: 110, height: 165), scale: 3)
        precondition(card?.fetchURL.absoluteString == "https://image.tmdb.org/t/p/w342/qJ2tW6WMUDux911r6m7haRef0WH.jpg")
        precondition(card?.url.absoluteString == poster)
        precondition(card?.smallerURL?.absoluteString == "https://image.tmdb.org/t/p/w185/qJ2tW6WMUDux911r6m7haRef0WH.jpg")
        let hero = ArtworkRequest("https://image.tmdb.org/t/p/original/b.jpg", size: CGSize(width: 430, height: 600), scale: 3)
        precondition(hero?.fetchURL.absoluteString == "https://image.tmdb.org/t/p/w1280/b.jpg")
        let tvmaze = "https://static.tvmaze.com/uploads/images/medium_portrait/610/1525272.jpg"
        precondition(ArtworkRequest(tvmaze, size: CGSize(width: 100, height: 150), scale: 2)?.fetchURL.absoluteString == tvmaze)
        precondition(ArtworkRequest("http://image.tmdb.org/t/p/w500/a.jpg", size: CGSize(width: 100, height: 150), scale: 2) == nil)
        precondition(ArtworkRequest(poster, size: .zero, scale: 2) == nil)
        print("Artwork renditions passed.")
    }
}
