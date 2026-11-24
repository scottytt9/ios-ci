struct RoomBufferGate {
    private(set) var holding = false
    private var changedAt: Int64?

    mutating func update(_ waiting: Bool, at now: Int64) -> Bool {
        if waiting == holding {
            changedAt = nil
        } else if let changedAt {
            if now - changedAt >= (waiting ? 1_200 : 700) {
                holding = waiting
                self.changedAt = nil
            }
        } else {
            changedAt = now
        }
        return holding
    }
}

struct RoomDriftCorrection {
    private var lastSeek: Int64?

    mutating func shouldSeek(drift: Double, playing: Bool, explicit: Bool, ready: Bool, at now: Int64) -> Bool {
        guard drift.isFinite, drift > (explicit || !playing ? 0.25 : 1.4),
              explicit || (ready && lastSeek.map { now - $0 >= 3_000 } != false) else { return false }
        lastSeek = now
        return true
    }
}
