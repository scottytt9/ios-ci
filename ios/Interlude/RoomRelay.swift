import CryptoKit
import Foundation

struct RoomRelay {
    let url: URL
    let code: String
    let voiceKey: String?
    static let prefix = "INTERLUDE-R2:"
    static func isInvite(_ value: String) -> Bool {
        #if canImport(interlude_ffiFFI)
        return isRelayInvite(value: value)
        #else
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix(prefix) || text.hasPrefix("INTERLUDE-R1:")
        #endif
    }
    private static let domain = "[a-z0-9][a-z0-9-]{0,62}\\.[a-z0-9][a-z0-9-]{0,62}\\.workers\\.dev"
    private static let token = "[a-f0-9]{32}"

    init(endpoint: String, incoming: String?, hostingKey: String = "") throws {
        #if canImport(interlude_ffiFFI)
        do {
            let session: FfiRelaySession
            if let incoming {
                session = try joinRelayInvite(value: incoming)
            } else {
                session = try hostRelayRoom(address: endpoint, hostingKey: hostingKey)
            }
            guard let parsed = URL(string: session.url) else {
                throw Self.failure("Enter a valid Interlude relay invite.")
            }
            url = parsed
            code = session.code
            voiceKey = session.voiceKey
            return
        } catch {
            throw Self.failure(InterludeCoreBridge.errorMessage(error, fallback: "Enter a valid Interlude relay invite."))
        }
        #else
        if let incoming {
            let parts = incoming.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
            let voice = parts.count == 5 && parts[0] == "INTERLUDE-R2" && Self.matches(parts[4], "[a-f0-9]{64}")
            let legacy = parts.count == 4 && parts[0] == "INTERLUDE-R1"
            guard voice || legacy, Self.matches(parts[1], Self.domain),
                  Self.matches(parts[2], Self.token), Self.matches(parts[3], Self.token),
                  let url = URL(string: "wss://\(parts[1])/rooms/\(parts[2])?role=guest&key=\(parts[3])" + (voice ? "&voice=1" : "")) else {
                throw Self.failure("Enter a valid Interlude relay invite.")
            }
            self.url = url
            code = ""
            voiceKey = voice ? String(parts[4]) : nil
        } else {
            var host = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if host.hasPrefix("https://") { host.removeFirst(8) }
            if host.hasSuffix("/") { host.removeLast() }
            guard Self.matches(host[...], Self.domain) else { throw Self.failure("Enter your relay’s workers.dev address.") }
            let secret = Self.randomToken()
            let guest = Self.randomToken()
            let room = SHA256.hash(data: Data(secret.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            let serviceKey = hostingKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let root = "wss://\(host)/rooms/\(room)?role=host&key=\(secret)&invite=\(guest)"
            if serviceKey.isEmpty {
                guard let url = URL(string: root) else { throw Self.failure("Enter your relay’s workers.dev address.") }
                self.url = url
                code = "INTERLUDE-R1:\(host):\(room):\(guest)"
                voiceKey = nil
                return
            }
            guard Self.matches(serviceKey[...], "[a-f0-9]{64}") else { throw Self.failure("Enter the 64-character voice hosting key.") }
            let signature = HMAC<SHA256>.authenticationCode(for: Data("interlude-voice:\(room)".utf8),
                                                            using: SymmetricKey(data: Data(serviceKey.utf8)))
            let proof = signature.map { String(format: "%02x", $0) }.joined()
            var bytes = [UInt8](repeating: 0, count: 32)
            var random = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &random) }
            let key = bytes.map { String(format: "%02x", $0) }.joined()
            guard let url = URL(string: root + "&voice=1&proof=" + proof) else {
                throw Self.failure("Enter your relay’s workers.dev address.")
            }
            self.url = url
            code = "\(Self.prefix)\(host):\(room):\(guest):\(key)"
            voiceKey = key
        }
        #endif
    }

    private static func matches(_ text: Substring, _ pattern: String) -> Bool {
        String(text).range(of: "\\A\(pattern)\\z", options: .regularExpression) != nil
    }

    private static func randomToken() -> String { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Interlude.RoomRelay", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
