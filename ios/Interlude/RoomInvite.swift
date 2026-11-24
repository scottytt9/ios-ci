import Foundation
import InterludeZlib

enum RoomFailure: LocalizedError {
    case invalid, expired, noRoute, state

    var errorDescription: String? {
        switch self {
        case .invalid: return "Paste the full Interlude room code."
        case .expired: return "This code expired. Create a new invite."
        case .noRoute: return "No connection route was found. Check Wi-Fi or your TURN settings."
        case .state: return "This reply does not match your active invite."
        }
    }
}

struct RoomInvite: Codable, Equatable {
    struct Route: Codable, Equatable {
        let mid: String
        let index: Int32
        let sdp: String
    }

    static let lifetime: Int64 = 15 * 60 * 1000
    private static let prefix = "INTERLUDE1:"
    private static let maxPayload = 48_000
    let room: String
    let role: String
    let expires: Int64
    let sdp: String
    let ice: [Route]

    static func wallClock() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func uptime() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    static func isRoomID(_ value: String) -> Bool {
        value == value.lowercased() && UUID(uuidString: value) != nil
    }

    func encode() throws -> String {
        let json = try JSONEncoder().encode(self)
        guard json.count <= Self.maxPayload else { throw RoomFailure.invalid }
        let compressed = try Self.gzip(json, reading: false)
        let payload = compressed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let code = Self.prefix + payload
        guard code.utf8.count <= 24_000 else { throw RoomFailure.invalid }
        return code
    }

    static func decode(_ input: String, now: Int64 = wallClock()) throws -> Self {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(prefix), value.utf8.count <= 24_000 else { throw RoomFailure.invalid }
        var payload = String(value.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let invite = try? JSONDecoder().decode(Self.self, from: gzip(data, reading: true)),
              isRoomID(invite.room), ["offer", "answer"].contains(invite.role),
              invite.sdp.hasPrefix("v=0"), invite.sdp.contains("m=application"),
              !invite.sdp.contains("\nm=video"), !invite.sdp.contains("\nm=audio"),
              invite.ice.count <= 64, invite.ice.allSatisfy({ route in
                  route.mid.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil &&
                  (0...4).contains(route.index) && route.sdp.hasPrefix("candidate:") && route.sdp.utf8.count <= 1000
              }) else { throw RoomFailure.invalid }
        guard invite.expires >= now, invite.expires <= now + lifetime + 120_000 else { throw RoomFailure.expired }
        return invite
    }

    static func gzip(_ data: Data, reading: Bool, limit: Int = maxPayload) throws -> Data {
        var stream = z_stream()
        let version = zlibVersion()
        let size = Int32(MemoryLayout<z_stream>.size)
        let initResult = reading ? inflateInit2_(&stream, 31, version, size)
            : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, version, size)
        guard initResult == Z_OK else { throw RoomFailure.invalid }
        defer {
            if reading { inflateEnd(&stream) } else { deflateEnd(&stream) }
        }
        let capacity = reading ? limit + 1 : Int(compressBound(uLong(data.count))) + 64
        var output = Data(count: capacity)
        let status = output.withUnsafeMutableBytes { dest in
            data.withUnsafeBytes { source in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = dest.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(capacity)
                return reading ? inflate(&stream, Z_FINISH) : deflate(&stream, Z_FINISH)
            }
        }
        let count = Int(stream.total_out)
        guard status == Z_STREAM_END, !reading || count <= limit else { throw RoomFailure.invalid }
        output.count = count
        return output
    }
}
