/// Where things land on the TV's media timeline (seconds; 0 = start of the first filler).
///
/// Video frames are made on a 30 fps grid of "slots" locked to the host clock. At a splice, one slot is
/// pinned to the end of the filler; every later slot is 1/30 s further. Host-clock times (audio) map
/// through the same pin, so audio and video stay in sync.
struct MirrorTimeline {
    static let fps = 30.0

    private(set) var videoAt = 0.0
    private(set) var spliceSlot: Int64 = 0
    private(set) var offset = 0.0 // host time minus TV time

    mutating func splice(videoAt: Double, slot: Int64, slotHostTime: Double) {
        self.videoAt = videoAt
        spliceSlot = slot
        offset = slotHostTime - videoAt
    }

    func videoTime(slot: Int64) -> Double { videoAt + Double(slot - spliceSlot) / Self.fps }

    func tvTime(host: Double) -> Double { host - offset }

    static func ticks90k(_ seconds: Double) -> UInt64 { UInt64(max(0, (seconds * 90000).rounded())) }
}

/// Keyframe slots after a splice: the splice slot, a short first GOP (so the first live fragment
/// reaches the TV before the filler runs out), then every `every` slots.
/// Every fMP4 fragment must start with a keyframe, so fragments end right before the next key.
struct GOPSchedule {
    let start: Int64
    let first: Int64
    let every: Int64

    init(start: Int64, first: Int64 = 5, every: Int64 = 15) {
        self.start = start
        self.first = first
        self.every = every
    }

    func isKey(_ slot: Int64) -> Bool {
        let d = slot - start
        if d < 0 { return false }
        if d == 0 { return true }
        return d >= first && (d - first) % every == 0
    }

    func endsFragment(_ slot: Int64) -> Bool { isKey(slot + 1) }
}

enum AudioStamp: Equatable {
    case drop
    /// Put the packet at `time` (48 kHz units); first insert `silenceBefore` silent packets right before it.
    case place(time: UInt64, silenceBefore: Int)
}

/// Gives AAC packets gap-free timestamps that start exactly where the audio filler ended.
/// The TV stalls on holes in a SourceBuffer, so small timing jitter is absorbed and large gaps are
/// filled with silence instead of leaving holes.
struct AudioStamper {
    static let samplesPerPacket: UInt64 = 1024
    static let sampleRate = 48000.0
    private static let frame = Double(samplesPerPacket) / sampleRate
    private static let maxDrift = 0.1

    private var next: UInt64   // timeline position of the next packet, in samples
    private var placedAny = false

    init(startAt seconds: Double) {
        next = UInt64(max(0, (seconds * Self.sampleRate).rounded()))
    }

    mutating func stamp(tvTime: Double) -> AudioStamp {
        let expected = Double(next) / Self.sampleRate
        let early = placedAny ? Self.maxDrift : Self.frame / 2
        if tvTime < expected - early { return .drop }
        var silence = 0
        if placedAny, tvTime > expected + Self.maxDrift {
            silence = Int(((tvTime - expected) / Self.frame).rounded())
            next += UInt64(silence) * Self.samplesPerPacket
        }
        placedAny = true
        let time = next
        next += Self.samplesPerPacket
        return .place(time: time, silenceBefore: silence)
    }
}
