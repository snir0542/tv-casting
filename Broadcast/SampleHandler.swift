import CoreMedia
import Foundation
import ImageIO
import os
import ReplayKit

/// ReplayKit broadcast extension: screen + app audio -> TV.
///
/// Browser mode (v2.0, ~1 s delay): H.264 + AAC -> fragmented MP4 -> WebSocket -> the TV's web browser,
/// which the extension opens itself over the TV's control socket. If that cannot start, DLNA mode
/// (v1.1, ~10 s delay): H.264 + AAC -> MPEG-TS over HTTP, played by the TV's media player.
final class SampleHandler: RPBroadcastSampleHandler {
    private let netQueue = DispatchQueue(label: "tvmirror.net")
    private var server: StreamServer?
    private var audio: AACEncoder?
    private var ip = ""

    // the encoder is replaced on fallback while ReplayKit keeps submitting frames
    private let encoderLock = NSLock()
    private var currentEncoder: H264Encoder?
    private var encoder: H264Encoder? {
        get { encoderLock.lock(); defer { encoderLock.unlock() }; return currentEncoder }
        set { encoderLock.lock(); currentEncoder = newValue; encoderLock.unlock() }
    }

    // on netQueue
    private var session: MirrorSession?
    private var dlna: DLNAController?
    private var muxer = TSMuxer()
    private var startTime: Double = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let ip = NetworkInfo.wifiIPv4() else {
            return fail("האייפון לא מחובר ל-Wi-Fi")
        }
        self.ip = ip

        let server = StreamServer(port: Config.httpPort, queue: netQueue)
        do {
            try server.start()
        } catch {
            return fail("לא ניתן לפתוח פורט \(Config.httpPort): \(error.localizedDescription)")
        }
        let audio = AACEncoder()
        audio.onPacket = { [weak self] packet, pts in
            self?.netQueue.async { self?.session?.handleAudio(packet, host: pts) }
        }
        audio.onFrame = { [weak self] adts, pts in
            self?.netQueue.async { self?.deliverAudio(adts, at: pts) }
        }
        self.server = server
        self.audio = audio
        audio.start()
        netQueue.async { self.startBrowserMode() }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            encoder?.submit(pixelBuffer, orientation: Self.orientation(of: sampleBuffer))
        case .audioApp:
            audio?.submit(sampleBuffer)
        default:
            break // the microphone is not mirrored
        }
    }

    /// ReplayKit always delivers the screen as a portrait buffer; this attachment says how the phone is held.
    private static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else { return .up }
        return orientation
    }

    override func broadcastFinished() {
        audio?.stop()
        let dlna: DLNAController? = netQueue.sync {
            session?.stop()
            session = nil
            return self.dlna
        }
        encoder?.stop()
        server?.stop()
        guard let dlna else { return }
        let done = DispatchSemaphore(value: 0)
        Task { await dlna.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    // MARK: - modes (on netQueue)

    private func startBrowserMode() {
        let available = os_proc_available_memory()
        let full = available >= Config.minMemoryFor1080p
        let encoder = H264Encoder(mode: .browser, width: full ? 1920 : 1280, height: full ? 1080 : 720,
                                  bitrate: 3_000_000)
        let remote = LGTVRemote(host: Config.tvHost, queue: netQueue)
        let session = MirrorSession(queue: netQueue, encoder: encoder, remote: remote,
                                    pageURL: "http://\(ip):\(Config.httpPort)/")
        encoder.onVideo = { [weak self] frame in
            self?.netQueue.async { self?.session?.handleVideo(frame) }
        }
        session.onFallback = { [weak self] reason in self?.startDLNAMode(because: reason) }
        session.onStop = { [weak self] reason in self?.fail(reason) }
        server?.onPageSocket = { [weak self] socket in self?.session?.attach(socket) }
        self.encoder = encoder
        self.session = session
        log.info("Browser mode, \(encoder.width)x\(encoder.height) (\(available / 1_048_576) MB free)")
        session.start()
    }

    private func startDLNAMode(because reason: String) {
        log.error("Browser mode failed: \(reason, privacy: .public). Using DLNA.")
        session = nil
        server?.onPageSocket = nil
        guard let dlna = DLNAController() else {
            return fail("tvControlURL לא הוגדר ב-Config.swift")
        }
        let old = encoder
        let encoder = H264Encoder(mode: .dlna, width: Config.outputWidth, height: Config.outputHeight)
        server?.onNeedKeyFrame = { [weak encoder] in encoder?.requestKeyFrame() }
        encoder.onFrame = { [weak self] bytes, captured, isKey in
            self?.netQueue.async { self?.deliverVideo(bytes, captured: captured, isKey: isKey) }
        }
        self.encoder = encoder
        old?.stop()
        self.dlna = dlna
        let url = "http://\(ip):\(Config.httpPort)/screen.ts"
        log.info("Streaming at \(url, privacy: .public)")
        Task { await dlna.play(streamURL: url) }
    }

    // MARK: - DLNA mode (on netQueue)

    private func deliverVideo(_ bytes: [UInt8], captured: Double, isKey: Bool) {
        guard dlna != nil else { return }
        let clock = clock90k(captured)
        let ts = muxer.mux(annexB: bytes, pts90k: clock + Config.ptsDelay90k, pcr90k: clock, isKey: isKey)
        server?.broadcast(Data(ts), isKey: isKey)
    }

    private func deliverAudio(_ adts: [UInt8], at hostSeconds: Double) {
        guard dlna != nil else { return }
        let ts = muxer.muxAudio(adts: adts, pts90k: clock90k(hostSeconds) + Config.ptsDelay90k)
        server?.broadcast(Data(ts), isKey: false, isAudio: true)
    }

    /// Video and audio share one 90 kHz clock derived from the host clock. It starts at 1 s so that
    /// samples up to a second older than the first one delivered still get a valid timestamp.
    private func clock90k(_ hostSeconds: Double) -> UInt64 {
        if startTime == 0 { startTime = hostSeconds }
        return UInt64(max(0, hostSeconds - startTime + 1) * 90_000)
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        finishBroadcastWithError(NSError(domain: "TVMirror", code: 1,
                                         userInfo: [NSLocalizedFailureReasonErrorKey: message]))
    }
}
