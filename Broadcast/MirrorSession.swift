import Foundation

/// Browser mode: carries out `MirrorLogic`'s decisions with the encoders, the TV page socket and the
/// TV remote. Everything runs on `queue` (the network queue).
///
/// Timeline (see the design doc): the page first gets filler (the frozen screen + silence) from TV
/// time 0 — the TV starts only with > 3 s buffered. When the page says "golive", the next 30 fps slot is
/// pinned to the end of the filler and live video/audio continue there, gap-free.
final class MirrorSession {
    var onFallback: ((String) -> Void)?
    var onStop: ((String) -> Void)?

    private enum Mode { case idle, filler, live }

    private let queue: DispatchQueue
    private let encoder: H264Encoder
    private let remote: LGTVRemote
    private let pageURL: String
    private let logic = MirrorLogic()
    private var socket: PageSocket?
    private var ticker: DispatchSourceTimer?
    private var ended = false

    private var mode = Mode.idle
    private var fillerGeneration = 0
    private var needVideoInit = true
    private var videoConfig: FMP4VideoConfig?
    private var videoNext: UInt64 = 0      // next video decode time on the TV timeline (90 kHz)
    private var audioNext: UInt64 = 0      // next audio decode time on the TV timeline (48 kHz)
    private var timeline = MirrorTimeline()
    private var gop = GOPSchedule(start: 0)
    private var stamper = AudioStamper(startAt: 0)
    private var videoSeq: UInt32 = 0
    private var audioSeq: UInt32 = 0
    private var pendingVideo: [EncodedVideo] = []
    private var pendingAudio: [(time: UInt64, data: [UInt8])] = []
    private var fullscreen = false
    private var clicks = 0

    private static let videoTick: UInt64 = 3000 // one 30 fps frame at 90 kHz
    private static let audioTick: UInt64 = 1024 // one AAC frame at 48 kHz
    private static let audioPacketsPerFragment = 5
    private static let clickDelay = 8.0

    init(queue: DispatchQueue, encoder: H264Encoder, remote: LGTVRemote, pageURL: String) {
        self.queue = queue
        self.encoder = encoder
        self.remote = remote
        self.pageURL = pageURL
    }

    /// Pairs with the TV and opens the page in its browser.
    func start() {
        queue.async {
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.ticker = t
            self.remote.connect { [weak self] result in
                guard let self, !self.ended else { return }
                switch result {
                case .success:
                    log.info("Opening \(self.pageURL, privacy: .public) in the TV browser")
                    self.remote.open(url: self.pageURL) { [weak self] ok in
                        guard let self else { return }
                        self.run(ok ? self.logic.browserOpened(now: Self.now())
                                    : self.logic.controlFailed("the TV did not open its browser"))
                    }
                case .failure(let failure):
                    self.run(self.logic.controlFailed("TV control: \(failure)"))
                }
            }
        }
    }

    /// Ends the session: tells the page, closes the connections. Call on `queue`.
    func stop() {
        guard !ended else { return }
        sendJSON(["type": "bye"])
        finish()
    }

    /// A new page connection (on `queue`); a reload replaces the old one.
    func attach(_ socket: PageSocket) {
        guard !ended else { return socket.close() }
        self.socket?.close()
        self.socket = socket
        socket.onText = { [weak self, weak socket] text in
            guard let self, let socket, socket === self.socket else { return }
            self.pageMessage(text)
        }
        socket.onClose = { [weak self, weak socket] in
            guard let self, let socket, socket === self.socket else { return }
            self.socket = nil
            self.mode = .idle
            self.encoder.pauseLive()
            log.info("TV page disconnected")
            self.run(self.logic.pageClosed(now: Self.now()))
        }
    }

    /// Live video from the encoder (on `queue`).
    func handleVideo(_ frame: EncodedVideo) {
        guard mode == .live, frame.slot >= gop.start else { return }
        if frame.isKey, let first = pendingVideo.first { flushVideo(nextSlot: frame.slot, firstSlot: first.slot) }
        if pendingVideo.isEmpty, !frame.isKey { return } // a fragment must start with a keyframe
        pendingVideo.append(frame)
        if gop.endsFragment(frame.slot), let first = pendingVideo.first {
            flushVideo(nextSlot: frame.slot + 1, firstSlot: first.slot)
        }
    }

    /// Live audio from the AAC encoder (on `queue`): raw AAC frame + host-clock time.
    func handleAudio(_ packet: [UInt8], host: Double) {
        guard mode == .live else { return }
        switch stamper.stamp(tvTime: timeline.tvTime(host: host)) {
        case .drop:
            return
        case .place(let time, let silence):
            if silence > 0, let silent = AACEncoder.silentPacket {
                for k in 0..<silence {
                    pendingAudio.append((time - UInt64(silence - k) * Self.audioTick, silent))
                }
            }
            pendingAudio.append((time, packet))
        }
        if pendingAudio.count >= Self.audioPacketsPerFragment { flushAudio() }
    }

    // MARK: - page messages and actions

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func pageMessage(_ text: String) {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = m["type"] as? String else { return }
        let now = Self.now()
        switch type {
        case "hello":
            log.info("TV page connected: \(m["ua"] as? String ?? "", privacy: .public)")
            fullscreen = false
            clicks = 0
            run(logic.pageHello(mse: m["mse"] as? Bool ?? false, now: now))
            // Not right away: while the TV browser's own bar still has focus, a click can hit it and
            // reload the page (seen on the TV). A click ~10 s after opening worked.
            queue.asyncAfter(deadline: .now() + Self.clickDelay) { [weak self] in self?.clickForFullscreen() }
        case "golive":
            run(logic.pageGoLive(videoEnd: m["v"] as? Double ?? 0, audioEnd: m["a"] as? Double ?? 0, now: now))
        case "underrun":
            log.info("TV ran out of video: refilling")
            run(logic.pageUnderrun(bufferedEnd: m["end"] as? Double ?? 0, now: now))
        case "stuck":
            log.info("TV player stuck (\(m["why"] as? String ?? "", privacy: .public)): restarting it")
            run(logic.pageStuck(now: now))
        case "error":
            log.error("TV page error: \(m["what"] as? String ?? "", privacy: .public)")
            run(logic.pageError(m["what"] as? String ?? "unknown", now: now))
        case "fullscreen":
            fullscreen = m["on"] as? Bool ?? false
        default:
            break
        }
    }

    /// The page can only go full screen after a user gesture; a remote click is one.
    private func clickForFullscreen() {
        guard !ended, socket != nil, !fullscreen, clicks < 2 else { return }
        clicks += 1
        remote.click()
        queue.asyncAfter(deadline: .now() + Self.clickDelay) { [weak self] in self?.clickForFullscreen() }
    }

    private func tick() {
        guard !ended else { return }
        let now = Self.now()
        if let socket {
            let seconds = Double(socket.backlogBytes) * 8 / Double(max(logic.bitrate, 1))
            run(logic.sendBacklog(seconds: seconds, now: now))
        }
        run(logic.tick(now: now))
    }

    private func run(_ actions: [MirrorAction]) {
        for action in actions {
            guard !ended else { return }
            switch action {
            case .sendConfig(let lead):
                sendJSON(["type": "config", "lead": lead, "video": videoCodec(), "audio": "mp4a.40.2"])
            case .sendInit:
                needVideoInit = true
                socket?.send(binary: [1] + FMP4.audioInit(FMP4AudioConfig(
                    sampleRate: 48000, channels: 2, audioSpecificConfig: FMP4.aacLC48kStereoASC)))
            case .sendFiller(let at, let seconds):
                sendFiller(fromStart: at == 0, seconds: seconds)
            case .goLive:
                goLive()
            case .setBitrate(let bps):
                log.info("Bitrate \(bps / 1000) kbps")
                encoder.setBitrate(bps)
            case .reopenPage:
                remote.open(url: pageURL) { _ in }
            case .fallback(let reason):
                sendJSON(["type": "bye"])
                finish()
                onFallback?(reason)
            case .stop(let reason):
                finish()
                onStop?(reason)
            }
        }
    }

    private func finish() {
        ended = true
        ticker?.cancel()
        ticker = nil
        mode = .idle
        encoder.pauseLive()
        socket?.close()
        socket = nil
        remote.close()
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        socket?.send(text: String(decoding: data, as: UTF8.self))
    }

    private func videoCodec() -> String {
        if let sps = videoConfig?.sps, sps.count > 3 {
            return String(format: "avc1.%02x%02x%02x", sps[1], sps[2], sps[3])
        }
        return encoder.height >= 1080 ? "avc1.4d4028" : "avc1.4d401f" // Main 4.0 / 3.1
    }

    // MARK: - filler and splice

    /// Filler from TV time 0 (new timeline) or right after what was already sent (refill).
    private func sendFiller(fromStart: Bool, seconds: Double) {
        mode = .filler
        encoder.pauseLive()
        pendingVideo = []
        pendingAudio = []
        if fromStart {
            videoNext = 0
            audioNext = 0
        }
        let frames = Int((seconds * MirrorTimeline.fps).rounded())
        let packets = Int((seconds * 48000 / Double(Self.audioTick)).rounded(.up))
        let videoStart = videoNext
        let audioStart = audioNext
        videoNext += UInt64(frames) * Self.videoTick
        audioNext += UInt64(packets) * Self.audioTick

        if let silent = AACEncoder.silentPacket {
            audioSeq += 1
            let samples = Array(repeating: FMP4Sample(data: silent, duration: UInt32(Self.audioTick), isSync: true),
                                count: packets)
            socket?.send(binary: [1] + FMP4.fragment(sequence: audioSeq, baseTime: audioStart, samples: samples))
        }

        fillerGeneration += 1
        let generation = fillerGeneration
        encoder.encodeFiller(frames: frames) { [weak self] encoded in
            self?.queue.async {
                guard let self, !self.ended, generation == self.fillerGeneration, !encoded.isEmpty else { return }
                self.sendVideo(encoded, durations: Array(repeating: UInt32(Self.videoTick), count: encoded.count),
                               baseTime: videoStart)
            }
        }
    }

    private func goLive() {
        guard mode == .filler else { return }
        let slot = encoder.currentSlot() + 1
        timeline.splice(videoAt: Double(videoNext) / 90000, slot: slot, slotHostTime: encoder.slotHostTime(slot))
        gop = GOPSchedule(start: slot)
        stamper = AudioStamper(startAt: Double(audioNext) / 48000)
        pendingVideo = []
        pendingAudio = []
        mode = .live
        encoder.startLive(schedule: gop)
    }

    // MARK: - fragments

    /// Sends the frames as one fragment, with a new init segment first if the parameter sets changed.
    private func sendVideo(_ frames: [EncodedVideo], durations: [UInt32], baseTime: UInt64) {
        guard let socket, let first = frames.first else { return }
        if first.isKey, !first.sps.isEmpty, !first.pps.isEmpty {
            let config = FMP4VideoConfig(width: encoder.width, height: encoder.height, sps: first.sps, pps: first.pps)
            if needVideoInit || config != videoConfig {
                videoConfig = config
                needVideoInit = false
                socket.send(binary: [0] + FMP4.videoInit(config))
            }
        }
        guard !needVideoInit else { return } // the TV cannot decode anything before an init segment
        videoSeq += 1
        var samples: [FMP4Sample] = []
        for (frame, duration) in zip(frames, durations) {
            samples.append(FMP4Sample(data: frame.avcc, duration: duration, isSync: frame.isKey))
        }
        socket.send(binary: [0] + FMP4.fragment(sequence: videoSeq, baseTime: baseTime, samples: samples))
    }

    /// One fragment from the pending live frames. Durations come from slot numbers, so skipped slots
    /// stretch the previous frame instead of leaving a hole, and the fragment starts exactly where the
    /// previous one ended.
    private func flushVideo(nextSlot: Int64, firstSlot: Int64) {
        let frames = pendingVideo
        pendingVideo = []
        var durations: [UInt32] = []
        for (i, frame) in frames.enumerated() {
            let next = i + 1 < frames.count ? frames[i + 1].slot : nextSlot
            durations.append(UInt32(max(1, next - frame.slot)) * UInt32(Self.videoTick))
        }
        let slotStart = MirrorTimeline.ticks90k(timeline.videoTime(slot: firstSlot))
        if slotStart > videoNext { durations[0] += UInt32(min(slotStart - videoNext, 90000)) }
        let base = videoNext
        videoNext = base + durations.reduce(0) { $0 + UInt64($1) }
        sendVideo(frames, durations: durations, baseTime: base)
    }

    private func flushAudio() {
        guard let socket, let first = pendingAudio.first, let last = pendingAudio.last else { return }
        audioSeq += 1
        let samples = pendingAudio.map { FMP4Sample(data: $0.data, duration: UInt32(Self.audioTick), isSync: true) }
        socket.send(binary: [1] + FMP4.fragment(sequence: audioSeq, baseTime: first.time, samples: samples))
        audioNext = last.time + Self.audioTick
        pendingAudio = []
    }
}
