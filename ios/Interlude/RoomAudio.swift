import AVFoundation
import Combine
import Foundation

@MainActor
final class RoomAudio: ObservableObject {
    @Published private(set) var microphone = false
    @Published private(set) var listening = false
    @Published private(set) var output = "System audio"
    @Published private(set) var input = ""
    @Published private(set) var notice = ""

    var send: ((Data) -> Void)?
    var headphonesDisconnected: (() -> Void)?
    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var speaker: AVAudioPlayerNode?
    private var tapInstalled = false
    private var pending = 0
    private var generation = 0
    private var notifications: [NSObjectProtocol] = []
    private var routeTask: Task<Void, Never>?
    private let voiceFormat = AVAudioFormat(standardFormatWithSampleRate: VoiceFrames.rate, channels: 1)!

    init() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] event in
            Task { @MainActor in self?.routeChanged(event) }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] event in
            let reason = (event.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            Task { @MainActor in
                guard let self, reason == AVAudioSession.InterruptionType.began.rawValue else { return }
                self.stop()
                self.notice = "Audio was interrupted. Enable voice audio or your microphone again when ready."
            }
        })
    }

    deinit {
        for handle in notifications { NotificationCenter.default.removeObserver(handle) }
    }

    func prepareVideo() {
        guard !microphone && !listening else { return }
        do { try configureSession(capture: false); updateRoute() }
        catch { notice = "Unable to activate audio. Check the output in Control Centre." }
    }

    func listen() {
        guard !listening else { return }
        notice = ""
        do {
            try rebuild(capture: false)
            listening = true
        } catch { fail() }
    }

    func enableMicrophone(allowed: @escaping () -> Bool) async {
        guard !microphone, allowed() else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard allowed() else { return }
        notice = ""
        guard granted else { notice = "Enable microphone access for Interlude in Settings."; return }
        do {
            do { try rebuild(capture: true) }
            catch { try rebuild(capture: true, processVoice: false) }
            microphone = true
            listening = true
            updateRoute()
        } catch { fail() }
    }

    func muteMicrophone() {
        guard microphone else { return }
        microphone = false
        do { try rebuild(capture: false) }
        catch { fail() }
    }

    func receive(_ data: Data) {
        guard listening, data.count == VoiceFrames.bytes, pending < 8,
              let speaker, let pcm = AVAudioPCMBuffer(pcmFormat: voiceFormat, frameCapacity: AVAudioFrameCount(VoiceFrames.samples)),
              let samples = pcm.floatChannelData?[0] else { return }
        pcm.frameLength = AVAudioFrameCount(VoiceFrames.samples)
        VoiceFrames.render(data, into: samples)
        pending += 1
        let ticket = generation
        speaker.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, ticket == self.generation else { return }
                self.pending = max(0, self.pending - 1)
            }
        }
        if !speaker.isPlaying { speaker.play() }
    }

    func stop() {
        routeTask?.cancel()
        microphone = false
        listening = false
        disposeEngine()
        prepareVideo()
    }

    private func fail() {
        stop()
        notice = "The audio route could not start. Check your headphones in Control Centre and try again."
    }

    private func configureSession(capture: Bool) throws {
        let lastBluetooth = session.currentRoute.outputs.first { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP }
        if capture {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        } else {
            if session.category == .playAndRecord, session.preferredInput != nil {
                try? session.setPreferredInput(nil)
            }
            try session.setCategory(.playback, mode: .moviePlayback)
        }
        try session.setActive(true)
        if capture, let lastBluetooth {
            let headset = session.availableInputs?.first {
                $0.portType == .bluetoothHFP && $0.portName == lastBluetooth.portName
            }
            if let headset { try session.setPreferredInput(headset) }
        }
    }

    private func rebuild(capture: Bool, processVoice: Bool = true) throws {
        disposeEngine()
        try configureSession(capture: capture)
        let mixer = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine = mixer
        speaker = player
        if capture && processVoice { try mixer.inputNode.setVoiceProcessingEnabled(true) }
        mixer.attach(player)
        mixer.connect(player, to: mixer.mainMixerNode, format: voiceFormat)
        if capture {
            let mic = mixer.inputNode
            let format = mic.outputFormat(forBus: 0)
            guard format.sampleRate >= 8000, format.channelCount > 0 else { throw RoomFailure.noRoute }
            let frames = VoiceFrames()
            let ticket = generation
            mic.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let source = buffer.floatChannelData?[0] else { return }
                frames.capture(UnsafeBufferPointer(start: source, count: Int(buffer.frameLength)), rate: buffer.format.sampleRate) { data in
                    Task { @MainActor in
                        guard let self, ticket == self.generation, self.microphone else { return }
                        self.send?(data)
                    }
                }
            }
            tapInstalled = true
        }
        mixer.prepare()
        try mixer.start()
        updateRoute()
    }

    private func disposeEngine() {
        generation += 1
        pending = 0
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        speaker?.stop()
        engine?.stop()
        speaker = nil
        engine = nil
    }

    private func updateRoute() {
        output = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        if output.isEmpty { output = "System audio" }
        input = microphone ? session.currentRoute.inputs.map(\.portName).joined(separator: ", ") : ""
    }

    private func routeChanged(_ event: Notification) {
        updateRoute()
        guard let reason = (event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
              let change = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }
        if change == .oldDeviceUnavailable,
           let oldRoute = event.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription,
           oldRoute.outputs.contains(where: { [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones].contains($0.portType) }),
           session.currentRoute.outputs.allSatisfy({ [.builtInSpeaker, .builtInReceiver].contains($0.portType) }) {
            stop()
            notice = "Headphones disconnected. Playback paused and voice audio muted."
            headphonesDisconnected?()
            return
        }
        guard listening, [.newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange].contains(change) else { return }
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.listening else { return }
            do { try self.rebuild(capture: self.microphone) }
            catch {
                do { try self.rebuild(capture: self.microphone, processVoice: false) }
                catch { self.fail() }
            }
        }
    }
}
