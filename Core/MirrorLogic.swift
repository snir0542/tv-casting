/// Numbers that shape a browser-mode session (defaults from the design; measured on the LG TV).
struct MirrorTuning {
    var fillerSeconds = 4.0        // the TV starts only with > 3 s buffered
    var startLead = 1.0            // filler left when live joins = the delay
    var maxLead = 2.0
    var leadStep = 0.5
    var startBitrate = 3_000_000
    var minBitrate = 2_000_000
    var maxBitrate = 8_000_000
    var bitrateStep = 1_000_000
    var rampInterval = 10.0        // smooth seconds before each bitrate step up
    var pageTimeout = 15.0         // start-up: page must connect / start playing within this
    var reconnectTimeout = 10.0    // a closed page may come back within this
    var maxBacklog = 1.0           // send backlog (seconds of data) that halves the bitrate
    var smoothBacklog = 0.5        // backlog above this is "not smooth"
    var maxStuckInARow = 2         // stuck restarts before the page is reopened
}

enum MirrorAction: Equatable {
    case sendConfig(lead: Double)
    case sendInit                                  // both init segments
    case sendFiller(at: Double, seconds: Double)   // TV time where the filler starts
    case goLive(videoAt: Double, audioAt: Double)  // splice live in at these TV times
    case setBitrate(Int)
    case reopenPage
    case fallback(reason: String)                  // start-up failure: switch to DLNA
    case stop(reason: String)                      // end the broadcast
}

/// The browser-mode session as a state machine. It only decides; `MirrorSession` (in the extension)
/// does the work. Every input returns the actions to take, in order.
final class MirrorLogic {
    let tuning: MirrorTuning
    private(set) var lead: Double
    private(set) var bitrate: Int
    private(set) var isLive = false
    private(set) var hasPlayed = false

    private var openedAt: Double?
    private var helloAt: Double?
    private var closedAt: Double?
    private var smoothSince: Double?
    private var stuckInARow = 0
    private var finished = false

    init(tuning: MirrorTuning = MirrorTuning()) {
        self.tuning = tuning
        lead = tuning.startLead
        bitrate = tuning.startBitrate
    }

    func browserOpened(now: Double) -> [MirrorAction] {
        openedAt = now
        return []
    }

    func pageHello(mse: Bool, now: Double) -> [MirrorAction] {
        guard !finished else { return [] }
        closedAt = nil
        guard mse else { return fail("The TV browser cannot play this stream (no Media Source Extensions)") }
        helloAt = now
        isLive = false
        smoothSince = nil
        return [.sendConfig(lead: lead), .setBitrate(bitrate), .sendInit,
                .sendFiller(at: 0, seconds: tuning.fillerSeconds)]
    }

    func pageGoLive(videoEnd: Double, audioEnd: Double, now: Double) -> [MirrorAction] {
        guard !finished, helloAt != nil, !isLive else { return [] }
        isLive = true
        hasPlayed = true
        stuckInARow = 0
        smoothSince = now
        return [.goLive(videoAt: videoEnd, audioAt: audioEnd)]
    }

    func pageUnderrun(bufferedEnd: Double, now: Double) -> [MirrorAction] {
        guard !finished, isLive else { return [] }
        isLive = false
        smoothSince = nil
        lead = min(tuning.maxLead, lead + tuning.leadStep)
        return [.sendConfig(lead: lead)] + lowerBitrate()
            + [.sendFiller(at: bufferedEnd, seconds: tuning.fillerSeconds)]
    }

    func pageStuck(now: Double) -> [MirrorAction] {
        guard !finished else { return [] }
        isLive = false
        smoothSince = nil
        stuckInARow += 1
        if stuckInARow > tuning.maxStuckInARow {
            stuckInARow = 0
            return [.reopenPage]
        }
        return [.sendInit, .sendFiller(at: 0, seconds: tuning.fillerSeconds)]
    }

    func pageError(_ what: String, now: Double) -> [MirrorAction] {
        guard !finished, !hasPlayed else { return [] }
        return fail("TV player error: \(what)")
    }

    func sendBacklog(seconds: Double, now: Double) -> [MirrorAction] {
        guard !finished, isLive else { return [] }
        if seconds > tuning.maxBacklog {
            smoothSince = now
            return lowerBitrate()
        }
        if seconds > tuning.smoothBacklog { smoothSince = now }
        return []
    }

    func pageClosed(now: Double) -> [MirrorAction] {
        guard !finished else { return [] }
        closedAt = now
        isLive = false
        smoothSince = nil
        return []
    }

    func controlFailed(_ reason: String) -> [MirrorAction] {
        guard !finished, !hasPlayed else { return [] }
        return fail(reason)
    }

    func tick(now: Double) -> [MirrorAction] {
        guard !finished else { return [] }
        if let closedAt, now - closedAt >= tuning.reconnectTimeout {
            finished = true
            return [.stop(reason: "The TV browser was closed")]
        }
        if !hasPlayed {
            if helloAt == nil, closedAt == nil, let openedAt, now - openedAt >= tuning.pageTimeout {
                return fail("The TV browser did not open the page")
            }
            if let helloAt, now - helloAt >= tuning.pageTimeout {
                return fail("The TV did not start playing")
            }
        }
        if isLive, let since = smoothSince, now - since >= tuning.rampInterval, bitrate < tuning.maxBitrate {
            bitrate = min(tuning.maxBitrate, bitrate + tuning.bitrateStep)
            smoothSince = now
            return [.setBitrate(bitrate)]
        }
        return []
    }

    private func lowerBitrate() -> [MirrorAction] {
        let lowered = max(tuning.minBitrate, bitrate / 2)
        guard lowered != bitrate else { return [] }
        bitrate = lowered
        return [.setBitrate(bitrate)]
    }

    private func fail(_ reason: String) -> [MirrorAction] {
        finished = true
        return [.fallback(reason: reason)]
    }
}
