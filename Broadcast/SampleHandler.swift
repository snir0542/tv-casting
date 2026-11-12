import CoreMedia
import Foundation
import ImageIO
import ReplayKit

/// ReplayKit broadcast extension: screen + app audio -> H.264 + AAC -> MPEG-TS -> HTTP -> TV (via DLNA).
final class SampleHandler: RPBroadcastSampleHandler {
    private let netQueue = DispatchQueue(label: "tvmirror.net")
    private var server: StreamServer?
    private var encoder: H264Encoder?
    private var audio: AACEncoder?
    private var dlna: DLNAController?
    private var muxer = TSMuxer()
    private var startTime: Double = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let dlna = DLNAController() else {
            return fail("tvControlURL לא הוגדר ב-Config.swift")
        }
        guard let ip = NetworkInfo.wifiIPv4() else {
            return fail("האייפון לא מחובר ל-Wi-Fi")
        }

        let server = StreamServer(port: Config.httpPort, queue: netQueue)
        let encoder = H264Encoder()
        let audio = AACEncoder()
        server.onNeedKeyFrame = { [weak encoder] in encoder?.requestKeyFrame() }
        encoder.onFrame = { [weak self] bytes, captured, isKey in
            self?.netQueue.async { self?.deliverVideo(bytes, captured: captured, isKey: isKey) }
        }
        audio.onFrame = { [weak self] adts, pts in
            self?.netQueue.async { self?.deliverAudio(adts, at: pts) }
        }

        do {
            try server.start()
        } catch {
            return fail("לא ניתן לפתוח פורט \(Config.httpPort): \(error.localizedDescription)")
        }

        self.server = server
        self.encoder = encoder
        self.audio = audio
        self.dlna = dlna
        audio.start()

        let url = "http://\(ip):\(Config.httpPort)/screen.ts"
        log.info("Streaming at \(url, privacy: .public)")
        Task { await dlna.play(streamURL: url) }
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
        encoder?.stop()
        server?.stop()
        let dlna = self.dlna
        let done = DispatchSemaphore(value: 0)
        Task { await dlna?.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    // on netQueue
    private func deliverVideo(_ bytes: [UInt8], captured: Double, isKey: Bool) {
        let clock = clock90k(captured)
        let ts = muxer.mux(annexB: bytes, pts90k: clock + Config.ptsDelay90k, pcr90k: clock, isKey: isKey)
        server?.broadcast(Data(ts), isKey: isKey)
    }

    // on netQueue
    private func deliverAudio(_ adts: [UInt8], at hostSeconds: Double) {
        let ts = muxer.muxAudio(adts: adts, pts90k: clock90k(hostSeconds) + Config.ptsDelay90k)
        server?.broadcast(Data(ts), isKey: false, isAudio: true)
    }

    /// Video and audio share one 90 kHz clock derived from the host clock. It starts at 1 s so that
    /// samples up to a second older than the first one delivered still get a valid timestamp.
    // on netQueue
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
