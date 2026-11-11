import CoreMedia
import Foundation
import ReplayKit

/// ReplayKit broadcast extension: screen -> H.264 -> MPEG-TS -> HTTP -> TV (via DLNA).
final class SampleHandler: RPBroadcastSampleHandler {
    private let netQueue = DispatchQueue(label: "tvmirror.net")
    private var server: StreamServer?
    private var encoder: H264Encoder?
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
        server.onNeedKeyFrame = { [weak encoder] in encoder?.requestKeyFrame() }
        encoder.onFrame = { [weak self] bytes, captured, isKey in
            self?.netQueue.async { self?.deliver(bytes, captured: captured, isKey: isKey) }
        }

        do {
            try server.start()
        } catch {
            return fail("לא ניתן לפתוח פורט \(Config.httpPort): \(error.localizedDescription)")
        }

        self.server = server
        self.encoder = encoder
        self.dlna = dlna

        let url = "http://\(ip):\(Config.httpPort)/screen.ts"
        log.info("Streaming at \(url, privacy: .public)")
        Task { await dlna.play(streamURL: url) }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder?.submit(pixelBuffer)
    }

    override func broadcastFinished() {
        encoder?.stop()
        server?.stop()
        let dlna = self.dlna
        let done = DispatchSemaphore(value: 0)
        Task { await dlna?.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    // on netQueue
    private func deliver(_ bytes: [UInt8], captured: Double, isKey: Bool) {
        if startTime == 0 { startTime = captured }
        let clock = UInt64(max(0, captured - startTime) * 90_000) + 90_000
        let ts = muxer.mux(annexB: bytes, pts90k: clock + Config.ptsDelay90k, pcr90k: clock, isKey: isKey)
        server?.broadcast(Data(ts), isKey: isKey)
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        finishBroadcastWithError(NSError(domain: "TVMirror", code: 1,
                                         userInfo: [NSLocalizedFailureReasonErrorKey: message]))
    }
}
