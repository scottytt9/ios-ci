import Foundation
import LiveKit
import Observation

@MainActor
@Observable
final class HostedVoice: NSObject, RoomDelegate {
    private(set) var joined = false
    private(set) var microphone = false
    var volume = 1.0 { didSet { applyVolume() } }
    @ObservationIgnored private var room: Room?

    func join(url: String, token: String, key: String) async throws {
        guard room == nil else { return }
        let active = Room(delegate: self, roomOptions: RoomOptions(encryptionOptions: .sharedKey(key)))
        room = active
        do {
            try await active.connect(url: url, token: token)
            guard room === active else { await active.disconnect(); return }
            joined = true
            applyVolume()
        } catch {
            if room === active { leave() }
            throw Failure.unavailable
        }
    }

    func setMicrophone(_ enabled: Bool) async throws {
        guard let active = room, joined else { return }
        do {
            _ = try await active.localParticipant.setMicrophone(enabled: enabled)
            if room === active { microphone = enabled }
        } catch { throw Failure.microphone }
    }

    func leave() {
        let active = room
        room = nil
        joined = false
        microphone = false
        if let active { Task { await active.disconnect() } }
    }

    private func applyVolume() {
        guard let room else { return }
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                (publication.track as? RemoteAudioTrack)?.volume = volume
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            if self.room === room { (publication.track as? RemoteAudioTrack)?.volume = volume }
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in if self.room === room { leave() } }
    }

    enum Failure: LocalizedError {
        case unavailable, microphone
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Voice is unavailable. Playback sync is still connected."
            case .microphone: return "Couldn’t open the microphone. Check microphone access in Settings."
            }
        }
    }
}
