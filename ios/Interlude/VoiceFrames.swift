import Foundation

/// The room wire format is 20 ms of mono 16 kHz signed PCM, little endian.
final class VoiceFrames {
    static let rate: Double = 16_000
    static let samples = 320
    static let bytes = 640
    private var phase: Double = 0
    private var sum: Float = 0
    private var count = 0
    private var pending: [UInt8] = []

    func capture(_ input: UnsafeBufferPointer<Float>, rate: Double, send: (Data) -> Void) {
        guard rate.isFinite, rate >= 8_000 else { return }
        for sample in input {
            sum += sample.isFinite ? sample : 0
            count += 1
            phase += Self.rate
            guard phase >= rate else { continue }
            let level = max(-1, min(1, sum / Float(count)))
            let word = UInt16(bitPattern: Int16((level * 32767).rounded()))
            sum = 0
            count = 0
            while phase >= rate {
                phase -= rate
                pending.append(UInt8(truncatingIfNeeded: word))
                pending.append(UInt8(truncatingIfNeeded: word >> 8))
                if pending.count == Self.bytes {
                    send(Data(pending))
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    static func render(_ data: Data, into target: UnsafeMutablePointer<Float>) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.bytes else { return }
        for index in 0..<samples {
            let bits = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
            target[index] = Float(Int16(bitPattern: bits)) / 32768
        }
    }
}
