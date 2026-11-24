import Observation
import Foundation
import WebRTC

struct RoomNetwork {
    var lan = false
    var relay = ""
    var username = ""
    var password = ""

    func servers() throws -> [RTCIceServer] {
        if lan { return [] }
        let base = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let url = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return base }
        guard url.range(of: "^turns?:[^/\\s]+$", options: .regularExpression) != nil,
              !username.isEmpty, !password.isEmpty else {
            throw NSError(domain: "Interlude.Room", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a TURN URL, username and password."])
        }
        return base + [RTCIceServer(urlStrings: [url], username: username, credential: password)]
    }
}

struct RoomSource: Equatable, Sendable {
    let id: String
    let hash: String?
    let filename: String?
    let release: String?
    let url: String?

    var displayName: String { filename ?? release ?? "a new source" }

    var dictionary: [String: Any] {
        var dict: [String: Any] = ["id": id]
        if let hash { dict["hash"] = hash }
        if let filename { dict["filename"] = filename }
        if let release { dict["release"] = release }
        if let url { dict["url"] = url }
        return dict
    }

    static func clean(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return "" }
        return trimmed.utf16.count <= limit ? trimmed : ""
    }

    static func read(_ value: Any?) -> RoomSource? {
        guard let dict = value as? [String: Any],
              let rawID = dict["id"] as? String else { return nil }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard RoomInvite.isRoomID(id) else { return nil }
        let rawHash = (dict["hash"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash = rawHash.flatMap { $0.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil ? $0 : nil }
        let filename = (dict["filename"] as? String).map { clean($0, limit: 260) }.flatMap { $0.isEmpty ? nil : $0 }
        let release = (dict["release"] as? String).map { clean($0, limit: 260) }.flatMap { $0.isEmpty ? nil : $0 }
        let url: String? = (dict["url"] as? String).flatMap { raw in
            let cleaned = clean(raw, limit: 1024)
            guard !cleaned.isEmpty, let parsed = TorBox.playbackURL(cleaned), let host = parsed.host?.lowercased(),
                  host != "tb-cdn.st", !host.hasSuffix(".tb-cdn.st"), !host.hasSuffix(".torbox.app") else { return nil }
            return parsed.absoluteString
        }
        guard hash != nil || filename != nil || release != nil || url != nil else { return nil }
        return RoomSource(id: id, hash: hash, filename: filename, release: release, url: url)
    }
}

@MainActor
@Observable
final class WatchRoom: NSObject {
    struct Snapshot {
        let media: String
        let time: Double
        let playing: Bool
        let clock: Int64
        let title: RoomTitle?
        let source: RoomSource?
        let hold: String?
        let intent: Bool?
        let seek: Int?
    }

    struct Activity: Identifiable {
        let id = UUID()
        let author: String?
        let text: String
        let own: Bool
    }

    enum State: Equatable {
        case idle, gathering, invite, reply, connecting, waiting, connected, disconnected

        var label: String {
            switch self {
            case .idle: return "Create an invite or join with a friend’s code."
            case .gathering: return "Finding connection routes…"
            case .invite: return "Share the invite privately, then paste your friend’s reply."
            case .reply: return "Share this reply with the host."
            case .connecting: return "Connecting to your friend…"
            case .waiting: return "Share the invite privately. Your friend joins in one step."
            case .connected: return "Connected privately"
            case .disconnected: return "The connection dropped. Create a new invite if it does not reconnect."
            }
        }
    }

    struct ReactionBurst: Identifiable, Equatable {
        let id = UUID()
        let emoji: String
        let author: String
        let own: Bool
    }

    struct ChatToast: Identifiable, Equatable {
        let id = UUID()
        let author: String
        let text: String
    }

    static let reactionEmojis = ["🔥", "😂", "😱", "😭", "❤️", "👏"]

    private(set) var friend = ""
    private(set) var activity: [Activity] = []
    private(set) var latestReaction: ReactionBurst?
    private(set) var latestChat: ChatToast?
    private(set) var suggestion: Snapshot?
    private(set) var incomingSource: RoomSource?
    private var localSource: RoomSource?
    private var seenSourceId = ""
    private var dismissed = ""
    private var publishedMedia = ""
    var displayName = UserDefaults.standard.string(forKey: "interlude-room-name") ?? "" {
        didSet { UserDefaults.standard.set(displayName, forKey: "interlude-room-name") }
    }
    var offer: Snapshot? {
        guard connected, let value = hosts ? suggestion : snapshot, value.title != nil,
              !value.media.isEmpty, value.media != linked, value.media != dismissed else { return nil }
        return value
    }
    func dismissOffer(_ media: String) { dismissed = media }

    func acknowledgeSource(_ id: String) {
        if incomingSource?.id == id { incomingSource = nil }
    }

    func setLocalSource(_ source: RoomSource?) {
        localSource = source
        if let source { seenSourceId = source.id }
    }

    func shareSource(hash: String?, filename: String?, release: String?, url: String?) {
        let id = UUID().uuidString.lowercased()
        let raw: [String: Any] = [
            "id": id,
            "hash": hash ?? "",
            "filename": filename ?? "",
            "release": release ?? "",
            "url": url ?? "",
        ]
        guard let built = RoomSource.read(raw) else { return }
        localSource = built
        seenSourceId = built.id
        guard connected else { return }
        addActivity("You switched source to \(built.displayName).")
        if !hosts {
            let media = !linked.isEmpty ? linked : (snapshot?.media.isEmpty == false ? snapshot!.media : UUID().uuidString.lowercased())
            send(["kind": "control", "action": "source", "media": media, "time": 0, "source": built.dictionary])
        }
    }

    static func clean(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return "" }
        return trimmed.utf16.count <= limit ? trimmed : ""
    }

    private func addActivity(_ text: String, author: String? = nil, own: Bool = false) {
        activity = Array(activity.suffix(39)) + [.init(author: author, text: text, own: own)]
    }

    func chat(_ value: String) -> Bool {
        let text = Self.clean(value, limit: 240)
        guard connected, !text.isEmpty else { return false }
        send(["kind": "party-chat", "text": text])
        let author = displayName.isEmpty ? (hosts ? "Host" : "You") : displayName
        addActivity(text, author: author, own: true)
        return true
    }

    @discardableResult
    func react(_ emoji: String) -> Bool {
        let clean = String(emoji.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
        guard connected, !clean.isEmpty else { return false }
        send(["kind": "party-chat", "text": "[react:\(clean)]"])
        let author = displayName.isEmpty ? (hosts ? "Host" : "You") : displayName
        latestReaction = ReactionBurst(emoji: clean, author: author, own: true)
        return true
    }

    func suggest(_ title: RoomTitle) {
        guard connected, !hosts, snapshot?.title?.playback.id != title.playback.id,
              let bytes = try? JSONEncoder().encode(title), let object = try? JSONSerialization.jsonObject(with: bytes) else { return }
        send(["kind": "party-suggest", "media": UUID().uuidString.lowercased(), "title": object])
        addActivity("You suggested \(title.name).")
    }

    private(set) var state: State = .idle
    private(set) var code = ""
    private(set) var hosts = false
    private(set) var voiceReady = false
    private(set) var snapshot: Snapshot?
    private(set) var linked = ""
    private(set) var waitingMedia: String?
    private(set) var language: String?
    var followCaptions = false
    let audio: RoomAudio
    let hostedVoice = HostedVoice()
    var control: ((String, Double, String) -> Void)?
    var playback: ((Snapshot?) -> Void)?
    var caption: ((String) -> Void)?
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onBuffer: ((String, Bool) -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    private var peer: RTCPeerConnection?
    private var data: RTCDataChannel?
    private var voice: RTCDataChannel?
    private var routes: [RoomInvite.Route] = []
    private var identity: (room: String, expires: Int64)?
    private var lastPing: Int64 = 0
    private var bestRoundTrip: Int64 = .max
    private var clockOffset: Int64 = 0
    private var lastCaption = "off"
    private var connectionTimer: Task<Void, Never>?
    private var relaySocket: URLSessionWebSocketTask?
    private var relayReader: Task<Void, Never>?
    private var relayPing: Task<Void, Never>?
    private var relayReconnect: Task<Void, Never>?
    private var relayTarget: RoomRelay?
    private var relayReconnectAttempt = 0
    private static let relayBackoffMs: [UInt64] = [1_500, 3_000, 5_000, 8_000]
    private var hostedVoiceKey: String?
    private var voiceRequest: String?
    private var voiceReply: CheckedContinuation<(String, String), Error>?
    private var voiceTimeout: Task<Void, Never>?
    private static let relaySession = URLSession(configuration: .ephemeral)
    var relayed: Bool { relaySocket != nil }

    init(audio: RoomAudio) {
        self.audio = audio
        super.init()
        audio.send = { [weak self] packet in self?.sendVoice(packet) }
    }

    var connected: Bool { state == .connected }

    func begin(network: RoomNetwork, invitation: String? = nil, relayEndpoint: String = "", voiceHostingKey: String = "") async throws {
        if invitation.map(RoomRelay.isInvite) == true ||
            (invitation == nil && !relayEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            startRelay(try RoomRelay(endpoint: relayEndpoint, incoming: invitation, hostingKey: voiceHostingKey), host: invitation == nil)
            return
        }
        let incoming = try invitation.map { try RoomInvite.decode($0) }
        if let incoming, incoming.role != "offer" { throw RoomFailure.invalid }
        let servers = try network.servers()
        close()
        hosts = incoming == nil
        state = .gathering
        let session = (room: incoming?.room ?? UUID().uuidString.lowercased(),
                       expires: incoming?.expires ?? RoomInvite.wallClock() + RoomInvite.lifetime)
        identity = session
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = servers
        guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            close()
            throw RoomFailure.noRoute
        }
        peer = connection
        do {
            if let incoming {
                try await setRemote(incoming, on: connection)
            } else {
                let voiceOptions = RTCDataChannelConfiguration()
                voiceOptions.isOrdered = false
                voiceOptions.maxRetransmits = 0
                guard let reliable = connection.dataChannel(forLabel: "interlude", configuration: RTCDataChannelConfiguration()),
                      let pcm = connection.dataChannel(forLabel: "interlude-voice", configuration: voiceOptions) else { throw RoomFailure.noRoute }
                bind(reliable)
                bind(pcm)
            }
            let description = try await localDescription(on: connection, offer: incoming == nil)
            try await setDescription(description, on: connection, remote: false)
            for _ in 0..<60 {
                if connection.iceGatheringState == .complete && (!routes.isEmpty || connection.localDescription?.sdp.contains("a=candidate:") == true) { break }
                try await Task.sleep(for: .milliseconds(200))
                guard peer === connection else { return }
            }
            guard peer === connection else { return }
            guard let sdp = connection.localDescription?.sdp, !routes.isEmpty || sdp.contains("a=candidate:") else { throw RoomFailure.noRoute }
            code = try RoomInvite(room: session.room, role: incoming == nil ? "offer" : "answer", expires: session.expires,
                                  sdp: sdp, ice: routes.filter { !sdp.contains("a=" + $0.sdp) }).encode()
            if !connected { state = incoming == nil ? .invite : .reply }
        } catch {
            if peer === connection { close() }
            throw error
        }
    }

    func accept(_ value: String) async throws {
        let reply = try RoomInvite.decode(value)
        guard let peer, let identity, hosts, state == .invite,
              reply.role == "answer", reply.room == identity.room, reply.expires == identity.expires else { throw RoomFailure.state }
        state = .connecting
        do { try await setRemote(reply, on: peer) }
        catch {
            if self.peer === peer { state = .disconnected }
            throw error
        }
        connectionTimer?.cancel()
        connectionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(22))
            guard !Task.isCancelled, let self, self.peer === peer, !self.connected else { return }
            self.state = .disconnected
        }
    }

    func close() {
        leaveHostedVoice()
        hostedVoiceKey = nil
        connectionTimer?.cancel()
        relayReconnect?.cancel()
        relayReconnect = nil
        relayTarget = nil
        relayReconnectAttempt = 0
        relayPing?.cancel()
        relayPing = nil
        relayReader?.cancel()
        relayReader = nil
        relaySocket?.cancel(with: .normalClosure, reason: nil)
        relaySocket = nil
        peer?.delegate = nil
        data?.delegate = nil
        voice?.delegate = nil
        peer?.close()
        peer = nil
        data = nil
        voice = nil
        voiceReady = false
        identity = nil
        routes = []
        code = ""
        snapshot = nil
        friend = ""
        activity = []
        latestReaction = nil
        suggestion = nil
        incomingSource = nil
        localSource = nil
        seenSourceId = ""
        dismissed = ""
        publishedMedia = ""
        linked = ""
        waitingMedia = nil
        language = nil
        hosts = false
        lastPing = 0
        clockOffset = 0
        bestRoundTrip = .max
        state = .idle
        audio.stop()
    }

    func heartbeat() {
        guard connected, !hosts, RoomInvite.uptime() - lastPing > 4_000 else { return }
        lastPing = RoomInvite.uptime()
        send(["kind": "ping", "ping": lastPing])
    }

    func publish(media: String, time: Double, playing: Bool, title: RoomTitle?, hold: String?, intent: Bool, seek: Int) {
        guard connected, hosts else { return }
        if !media.isEmpty, media != publishedMedia, let title { addActivity("You opened \(title.name).") }
        publishedMedia = media
        var message: [String: Any] = ["kind": "state", "media": media, "time": Int64(max(0, time) * 1000),
                                      "playing": playing, "clock": RoomInvite.uptime(), "intent": intent, "seek": seek]
        if let title, let bytes = try? JSONEncoder().encode(title), let object = try? JSONSerialization.jsonObject(with: bytes) { message["title"] = object }
        if !media.isEmpty, let localSource { message["source"] = localSource.dictionary }
        if let hold { message["hold"] = hold }
        send(message)
    }

    func request(_ action: String, time: Double = 0) {
        guard connected, !hosts, !linked.isEmpty, linked == snapshot?.media else { return }
        send(["kind": "control", "action": action, "media": linked, "time": Int64(max(0, time) * 1000)])
    }

    func link() {
        guard connected, !hosts, let snapshot, !snapshot.media.isEmpty else { return }
        linked = snapshot.media
        playback?(snapshot)
    }

    func reportBuffer(_ waiting: Bool) {
        guard connected, !hosts, !linked.isEmpty else { return }
        send(["kind": "buffer", "media": linked, "waiting": waiting])
    }

    func unlink() {
        reportBuffer(false)
        linked = ""
    }

    func target(_ snapshot: Snapshot) -> Double {
        guard snapshot.playing, bestRoundTrip != .max else { return snapshot.time }
        return snapshot.time + min(2.5, max(0, Double(RoomInvite.uptime() + clockOffset - snapshot.clock) / 1000))
    }

    func announceCaption(_ value: String) {
        guard value != lastCaption else { return }
        lastCaption = value
        send(["kind": "subtitles", "lang": value])
    }

    private func bind(_ channel: RTCDataChannel) {
        if channel.label == "interlude", data == nil { data = channel }
        else if channel.label == "interlude-voice", voice == nil { voice = channel }
        else { channel.close(); return }
        channel.delegate = self
        channelState(channel)
    }

    private func channelState(_ channel: RTCDataChannel) {
        if channel === voice { voiceReady = channel.readyState == .open }
        if channel === data {
            if channel.readyState == .open && state != .connected {
                didConnect()
            } else if channel.readyState == .closed {
                disconnect()
            }
        }
    }

    private func didConnect() {
        guard !connected else { return }
        connectionTimer?.cancel()
        state = .connected
        send(["kind": "subtitles", "lang": lastCaption])
        let name = Self.clean(displayName, limit: 32)
        send(["kind": "party-profile", "name": name.isEmpty ? (hosts ? "Host" : "Friend") : name])
        publishedMedia = ""
        heartbeat()
        onConnect?()
    }

    private func startRelay(_ relay: RoomRelay, host: Bool) {
        close()
        hostedVoiceKey = relay.voiceKey
        hosts = host
        relayTarget = host ? nil : relay
        relayReconnectAttempt = 0
        openRelay(relay, host: host)
    }

    private func openRelay(_ relay: RoomRelay, host: Bool) {
        connectionTimer?.cancel()
        relayPing?.cancel()
        relayPing = nil
        relayReader?.cancel()
        relayReader = nil
        relaySocket?.cancel(with: .normalClosure, reason: nil)
        lastPing = 0
        state = .connecting
        let socket = Self.relaySession.webSocketTask(with: relay.url)
        socket.maximumMessageSize = 4096
        relaySocket = socket
        socket.resume()
        connectionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled, self?.relaySocket === socket { socket.cancel(with: .goingAway, reason: nil) }
        }
        relayPing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let self, self.relaySocket === socket else { return }
                let failed: Bool = await withCheckedContinuation { continuation in
                    socket.sendPing { error in continuation.resume(returning: error != nil) }
                }
                if failed, self.relaySocket === socket {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        relayReader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, relaySocket === socket else { return }
                    guard case .string(let text) = message else { continue }
                    switch text {
                    case "{\"kind\":\"relay-waiting\"}":
                        leaveHostedVoice()
                        voiceReady = false
                        connectionTimer?.cancel()
                        if connected { disconnect() }
                        state = .waiting
                        code = relay.code
                    case "{\"kind\":\"relay-ready\"}":
                        relayReconnectAttempt = 0
                        relayReconnect?.cancel()
                        relayReconnect = nil
                        didConnect()
                    case "{\"kind\":\"relay-ended\"}":
                        relayTarget = nil
                        relayPing?.cancel()
                        relayPing = nil
                        socket.cancel(with: .normalClosure, reason: nil)
                        code = ""
                        disconnect()
                        return
                    default:
                        if connected {
                            let data = Data(text.utf8)
                            if !receiveVoice(data) { receive(data) }
                        }
                    }
                }
            } catch {
                guard let self, relaySocket === socket else { return }
                relayPing?.cancel()
                relayPing = nil
                connectionTimer?.cancel()
                relaySocket = nil
                if !host, let target = relayTarget, relayReconnectAttempt < Self.relayBackoffMs.count {
                    let delayMs = Self.relayBackoffMs[relayReconnectAttempt]
                    relayReconnectAttempt += 1
                    leaveHostedVoice()
                    voiceReady = false
                    waitingMedia = nil
                    state = .connecting
                    relayReconnect?.cancel()
                    relayReconnect = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(delayMs))
                        guard !Task.isCancelled, let self, self.relayTarget?.url == target.url else { return }
                        self.openRelay(target, host: false)
                    }
                    return
                }
                code = ""
                disconnect()
            }
        }
    }

    private func disconnect() {
        let wasConnected = connected
        if !friend.isEmpty { addActivity("\(friend) left the room.") }
        friend = ""
        suggestion = nil
        incomingSource = nil
        localSource = nil
        seenSourceId = ""
        dismissed = ""
        leaveHostedVoice()
        if relayed { voiceReady = false }
        waitingMedia = nil
        state = .disconnected
        audio.stop()
        if wasConnected { onDisconnect?() }
    }

    func joinHostedVoice() async throws {
        guard connected, voiceReady, let key = hostedVoiceKey, let socket = relaySocket, !hostedVoice.joined else { return }
        let access: (String, String) = try await withCheckedThrowingContinuation { continuation in
            finishVoiceRequest(nil)
            let request = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            voiceReply = continuation
            voiceRequest = request
            send(["kind": "voice-token-request", "request": request])
            voiceTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { self?.finishVoiceRequest(nil) }
            }
        }
        guard relaySocket === socket, connected else { return }
        try await hostedVoice.join(url: access.0, token: access.1, key: key)
    }

    func leaveHostedVoice() {
        finishVoiceRequest(nil)
        if hostedVoice.joined { audio.prepareVideo() }
        hostedVoice.leave()
    }

    private func receiveVoice(_ data: Data) -> Bool {
        guard data.count <= 4096, let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = message["kind"] as? String else { return false }
        if kind == "relay-features" {
            voiceReady = hostedVoiceKey != nil && message["voice"] as? Bool == true
            return true
        }
        guard kind == "voice-token" || kind == "voice-unavailable" else { return false }
        guard let request = voiceRequest, message["request"] as? String == request else { return true }
        if let url = message["url"] as? String,
           url.range(of: "^wss://[a-z0-9-]+\\.livekit\\.cloud$", options: .regularExpression) != nil,
           let token = message["token"] as? String, token.utf8.count <= 2048 {
            finishVoiceRequest((url, token))
        } else { finishVoiceRequest(nil) }
        return true
    }

    private func finishVoiceRequest(_ access: (String, String)?) {
        let reply = voiceReply
        voiceReply = nil
        voiceRequest = nil
        voiceTimeout?.cancel()
        voiceTimeout = nil
        if let access { reply?.resume(returning: access) }
        else { reply?.resume(throwing: HostedVoice.Failure.unavailable) }
    }

    private func send(_ value: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: value), payload.count <= 4096 else { return }
        if let relaySocket {
            relaySocket.send(.string(String(decoding: payload, as: UTF8.self))) { _ in }
            return
        }
        guard let data, data.readyState == .open, data.bufferedAmount < 16_384 else { return }
        _ = data.sendData(RTCDataBuffer(data: payload, isBinary: false))
    }

    private func sendVoice(_ packet: Data) {
        guard let voice, voice.readyState == .open, connected, voice.bufferedAmount < 2_560 else { return }
        _ = voice.sendData(RTCDataBuffer(data: packet, isBinary: true))
    }

    private func receive(_ buffer: RTCDataBuffer, channel: RTCDataChannel) {
        if channel === voice, buffer.isBinary { audio.receive(buffer.data); return }
        if channel === data, !buffer.isBinary { receive(buffer.data) }
    }

    private func receive(_ payload: Data) {
        guard payload.count <= 4096,
              let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let kind = message["kind"] as? String else { return }
        let media = message["media"] as? String ?? ""
        let millis = (message["time"] as? NSNumber)?.doubleValue ?? 0
        let time = min(86_400, max(0, millis.isFinite ? millis / 1000 : 0))
        switch kind {
        case "party-profile" where connected:
            let name = Self.clean(message["name"] as? String ?? "", limit: 32)
            guard !name.isEmpty else { return }
            if friend.isEmpty { addActivity("\(name) joined the room.") }
            friend = name
        case "party-chat" where connected:
            let text = Self.clean(message["text"] as? String ?? "", limit: 240)
            let author = friend.isEmpty ? "Friend" : friend
            if text.hasPrefix("[react:") && text.hasSuffix("]") {
                let start = text.index(text.startIndex, offsetBy: 7)
                let end = text.index(before: text.endIndex)
                let emoji = start < end ? String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                if !emoji.isEmpty, emoji.count <= 8 {
                    latestReaction = ReactionBurst(emoji: emoji, author: author, own: false)
                }
            } else if !text.isEmpty {
                addActivity(text, author: author)
                latestChat = ChatToast(author: author, text: text)
            }
        case "party-suggest" where connected && hosts:
            guard RoomInvite.isRoomID(media), suggestion?.media != media, let title = RoomTitle.read(message["title"]) else { return }
            suggestion = Snapshot(media: media, time: 0, playing: false, clock: 0, title: title, source: nil, hold: nil, intent: nil, seek: nil)
            addActivity("\(friend.isEmpty ? "Your friend" : friend) suggested \(title.name).")
        case "ping" where hosts:
            if let ping = message["ping"] as? Int64 {
                send(["kind": "pong", "ping": ping, "clock": RoomInvite.uptime()])
            }
        case "pong" where !hosts:
            let roundTrip = RoomInvite.uptime() - lastPing
            if let ping = message["ping"] as? Int64, ping == lastPing, let clock = message["clock"] as? Int64,
               (0..<2500).contains(roundTrip), clock >= 0, clock < Int64.max / 2,
               bestRoundTrip == .max || roundTrip <= bestRoundTrip + 150 {
                let firstSync = bestRoundTrip == .max
                let estimate = clock - lastPing - roundTrip / 2
                clockOffset = firstSync ? estimate : clockOffset + (estimate - clockOffset) / 4
                bestRoundTrip = min(bestRoundTrip, roundTrip)
                if firstSync, !linked.isEmpty, let snapshot, linked == snapshot.media {
                    playback?(snapshot)
                }
            }
        case "state" where !hosts:
            guard media.isEmpty || RoomInvite.isRoomID(media),
                  let playing = message["playing"] as? Bool, let clock = message["clock"] as? Int64,
                  clock >= 0, clock < Int64.max / 2 else { return }
            let hold = message["hold"] as? String
            let source = RoomSource.read(message["source"])
            let value = Snapshot(media: media, time: time, playing: playing, clock: clock, title: RoomTitle.read(message["title"]),
                                 source: source,
                                 hold: hold == "host" || hold == "guest" ? hold : nil,
                                 intent: message["intent"] as? Bool, seek: (message["seek"] as? Int).flatMap { (0...2_147_483_647).contains($0) ? $0 : nil })
            if snapshot?.media != media && linked != media {
                linked = ""
                playback?(nil)
            }
            if !media.isEmpty, snapshot?.media != media, let title = value.title {
                addActivity("\(friend.isEmpty ? "Your friend" : friend) opened \(title.name).")
            }
            snapshot = value
            if let source, source.id != seenSourceId, !linked.isEmpty && linked == media {
                seenSourceId = source.id
                addActivity("\(friend.isEmpty ? "Your friend" : friend) switched source to \(source.displayName).")
                incomingSource = source
            }
            if !linked.isEmpty && linked == media { playback?(value) }
        case "buffer" where hosts:
            guard RoomInvite.isRoomID(media), let waiting = message["waiting"] as? Bool else { return }
            if waiting && waitingMedia != media { waitingMedia = media; onBuffer?(media, true) }
            else if !waiting && waitingMedia == media { waitingMedia = nil; onBuffer?(media, false) }
        case "control" where hosts:
            if RoomInvite.isRoomID(media), let action = message["action"] as? String {
                if action == "source", let source = RoomSource.read(message["source"]), source.id != seenSourceId {
                    seenSourceId = source.id
                    localSource = source
                    addActivity("\(friend.isEmpty ? "Your friend" : friend) switched source to \(source.displayName).")
                    incomingSource = source
                } else if ["play", "pause", "seek"].contains(action) {
                    control?(action, time, media)
                }
            }
        case "subtitles":
            if let value = message["lang"] as? String,
               value.range(of: "^[A-Za-z0-9-]{1,32}$", options: .regularExpression) != nil {
                language = value
                if followCaptions { caption?(value) }
            }
        default: break
        }
    }

    private func localDescription(on connection: RTCPeerConnection, offer: Bool) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            let done: (RTCSessionDescription?, Error?) -> Void = { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? RoomFailure.noRoute) }
            }
            if offer { connection.offer(for: constraints, completionHandler: done) }
            else { connection.answer(for: constraints, completionHandler: done) }
        }
    }

    private func setDescription(_ description: RTCSessionDescription, on connection: RTCPeerConnection, remote: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done: (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            if remote { connection.setRemoteDescription(description, completionHandler: done) }
            else { connection.setLocalDescription(description, completionHandler: done) }
        }
    }

    private func setRemote(_ invite: RoomInvite, on connection: RTCPeerConnection) async throws {
        try await setDescription(RTCSessionDescription(type: invite.role == "offer" ? .offer : .answer, sdp: invite.sdp),
                                 on: connection, remote: true)
        for route in invite.ice where !invite.sdp.contains("a=" + route.sdp) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.add(RTCIceCandidate(sdp: route.sdp, sdpMLineIndex: route.index, sdpMid: route.mid)) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
    }
}

extension WatchRoom: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let mid = candidate.sdpMid else { return }
        let value = RoomInvite.Route(mid: mid, index: candidate.sdpMLineIndex, sdp: candidate.sdp)
        Task { @MainActor in
            guard peer === peerConnection, routes.count < 64, !routes.contains(value) else { return }
            routes.append(value)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in if peer === peerConnection { bind(dataChannel) } }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            guard peer === peerConnection else { return }
            if newState == .failed || newState == .disconnected || newState == .closed {
                disconnect()
            } else if newState == .connected || newState == .completed, let data { channelState(data) }
        }
    }
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in channelState(dataChannel) }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor in receive(buffer, channel: dataChannel) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}
