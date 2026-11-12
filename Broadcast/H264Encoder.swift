import CoreMedia
import CoreVideo
import ImageIO
import VideoToolbox

/// One encoded frame in browser mode.
struct EncodedVideo {
    let avcc: [UInt8]   // 4-byte length-prefixed NAL units, as VideoToolbox makes them (what MP4 wants)
    let isKey: Bool
    let slot: Int64     // 30 fps grid slot it was made for; -1 for filler
    let sps: [UInt8]    // parameter sets, on keyframes only
    let pps: [UInt8]
}

/// Turns ReplayKit frames upright, fits them into one fixed 16:9 frame and encodes them to H.264 in
/// hardware.
///
/// - DLNA mode (v1.1): encodes each new frame as it comes (and the last one at 10 fps when the screen is
///   static), Annex B output for MPEG-TS.
/// - Browser mode (v2.0): keeps only the latest picture and encodes it on a fixed 30 fps grid locked to
///   the host clock, with keyframes exactly where `GOPSchedule` wants them, AVCC output for fMP4.
final class H264Encoder {
    enum Mode { case dlna, browser }

    /// DLNA: (annexB access unit, capture time in seconds, isKeyFrame) — called on a VideoToolbox thread
    var onFrame: (([UInt8], Double, Bool) -> Void)?
    /// Browser: live frames — called on a VideoToolbox thread
    var onVideo: ((EncodedVideo) -> Void)?

    let mode: Mode
    let width: Int
    let height: Int

    /// How a ReplayKit buffer has to be turned to be upright.
    private enum Turn {
        case none, clockwise, counterClockwise, halfTurn

        var angle: CFString? {
            switch self {
            case .none: return nil
            case .clockwise: return kVTRotation_CW90
            case .counterClockwise: return kVTRotation_CCW90
            case .halfTurn: return kVTRotation_180
            }
        }

        var isSideways: Bool { self == .clockwise || self == .counterClockwise }

        init(_ orientation: CGImagePropertyOrientation) {
            switch orientation {
            // Tested on iPhone 13 / iOS 27: ReplayKit's .right needs a counter-clockwise turn.
            case .right, .rightMirrored: self = .counterClockwise
            case .left, .leftMirrored: self = .clockwise
            case .down, .downMirrored: self = .halfTurn
            default: self = .none
            }
        }
    }

    private let queue = DispatchQueue(label: "tvmirror.encoder")
    private let lock = NSLock()
    private var pending = 0
    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var rotation: VTPixelRotationSession?
    private var canvasPool: CVPixelBufferPool?   // width x height: what the TV gets
    private var sidewaysPool: CVPixelBufferPool? // height x width: landscape content before turning
    private var poolFormat: OSType = 0
    private var lastFrame: CVPixelBuffer?
    private var lastEncode: Double = 0
    private var forceKey = true
    private var timer: DispatchSourceTimer?
    private var bitrate: Int

    // browser mode
    private let gridOrigin = H264Encoder.now()
    private var schedule: GOPSchedule?
    private var lastSlot: Int64 = 0
    private var frameCount: Int64 = 0

    init(mode: Mode, width: Int, height: Int, bitrate: Int = Config.bitrate) {
        self.mode = mode
        self.width = width
        self.height = height
        self.bitrate = bitrate
        let t = DispatchSource.makeTimerSource(queue: queue)
        switch mode {
        case .dlna:
            t.schedule(deadline: .now() + 0.1, repeating: 0.1)
            t.setEventHandler { [weak self] in self?.keepAlive() }
        case .browser:
            t.schedule(deadline: .now(), repeating: 1.0 / MirrorTimeline.fps, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.gridTick() }
        }
        t.resume()
        timer = t
    }

    func requestKeyFrame() { queue.async { self.forceKey = true } }

    func submit(_ src: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        lock.lock()
        if pending >= 2 { lock.unlock(); return } // encoder busy: drop frame
        pending += 1
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            guard let frame = self.render(src, turn: Turn(orientation)) else { return }
            self.lastFrame = frame
            if self.mode == .dlna { self.encode(frame) } // browser mode encodes on the grid
        }
    }

    func setBitrate(_ bps: Int) {
        queue.async {
            self.bitrate = bps
            self.applyBitrate()
        }
    }

    /// Browser mode: encode every grid slot from `schedule.start` on, with its keyframes.
    func startLive(schedule: GOPSchedule) {
        queue.async {
            self.schedule = schedule
            self.lastSlot = schedule.start - 1
        }
    }

    func pauseLive() { queue.async { self.schedule = nil } }

    /// Browser mode: `frames` copies of the latest picture (black if none yet), the first a keyframe.
    /// Live encoding is paused. The completion runs on the encoder queue once all frames are encoded.
    func encodeFiller(frames: Int, completion: @escaping ([EncodedVideo]) -> Void) {
        queue.async {
            self.schedule = nil
            if self.session == nil { self.makeSession() }
            guard let session = self.session, let picture = self.lastFrame ?? self.blackFrame() else {
                completion([])
                return
            }
            let collected = Collector()
            for i in 0..<frames {
                self.encodeBrowser(picture, slot: -1, key: i == 0) { collected.add($0) }
            }
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            completion(collected.items)
        }
    }

    /// Index of the 30 fps grid slot at the current host time.
    func currentSlot() -> Int64 { Int64(((Self.now() - gridOrigin) * MirrorTimeline.fps).rounded(.down)) }

    func slotHostTime(_ slot: Int64) -> Double { gridOrigin + Double(slot) / MirrorTimeline.fps }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            schedule = nil
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
            lastFrame = nil
        }
    }

    // MARK: - private (all on `queue`)

    private final class Collector {
        private let lock = NSLock()
        private var list: [EncodedVideo] = []
        func add(_ v: EncodedVideo) { lock.lock(); list.append(v); lock.unlock() }
        var items: [EncodedVideo] { lock.lock(); defer { lock.unlock() }; return list }
    }

    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func keepAlive() {
        guard let frame = lastFrame, Self.now() - lastEncode > 0.1 else { return }
        encode(frame)
    }

    /// Browser mode, 30 times a second: encode the newest slot. Missed slots are skipped (the fMP4
    /// timeline stretches the previous frame), but a skipped keyframe slot still forces a keyframe.
    private func gridTick() {
        guard let schedule, let picture = lastFrame ?? blackFrame() else { return }
        let slot = currentSlot()
        guard slot > lastSlot else { return }
        let key = (lastSlot + 1...slot).contains { schedule.isKey($0) }
        lastSlot = slot
        encodeBrowser(picture, slot: slot, key: key) { [weak self] in self?.onVideo?($0) }
    }

    /// Fits the screen into the fixed output frame (black bars where the shapes differ) and turns it
    /// upright. Scaling happens first, so only the small frame gets rotated.
    private func render(_ src: CVPixelBuffer, turn: Turn) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(src)
        if format != poolFormat { setUp(format: format) }
        if session == nil { makeSession() }
        guard let transfer, let rotation, let canvasPool, let sidewaysPool else { return nil }

        guard let fitted = Self.buffer(from: turn.isSideways ? sidewaysPool : canvasPool),
              VTPixelTransferSessionTransferImage(transfer, from: src, to: fitted) == noErr else { return nil }
        guard let angle = turn.angle else { return fitted }

        guard let upright = Self.buffer(from: canvasPool) else { return nil }
        VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: angle)
        guard VTPixelRotationSessionRotateImage(rotation, fitted, upright) == noErr else { return nil }
        return upright
    }

    private func setUp(format: OSType) {
        poolFormat = format
        canvasPool = Self.pool(width: width, height: height, format: format)
        sidewaysPool = Self.pool(width: height, height: width, format: format)
        lastFrame = nil

        if transfer == nil {
            var t: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
            if let t {
                // Keep the aspect ratio and fill the rest of the frame with black.
                VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            }
            transfer = t
        }
        if rotation == nil {
            var r: VTPixelRotationSession?
            VTPixelRotationSessionCreate(nil, &r)
            rotation = r
        }
    }

    /// A black picture for filler before ReplayKit delivered anything.
    private func blackFrame() -> CVPixelBuffer? {
        if canvasPool == nil {
            poolFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            canvasPool = Self.pool(width: width, height: height, format: poolFormat)
        }
        guard let canvasPool, let buffer = Self.buffer(from: canvasPool) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if CVPixelBufferIsPlanar(buffer) {
            let luma: Int32 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let size = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
                memset(base, plane == 0 ? luma : 128, size)
            }
        } else if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        return buffer
    }

    private func makeSession() {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else {
            log.error("VTCompressionSessionCreate failed: \(status)")
            return
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: Config.fps))
        // Browser mode places every keyframe itself (each fMP4 fragment must start with one).
        let keyInterval = mode == .browser ? Config.fps * 20 : Config.fps * 2
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: keyInterval))
        session = s
        applyBitrate()
        VTCompressionSessionPrepareToEncodeFrames(s)
        forceKey = true
        log.info("Encoder ready \(self.width)x\(self.height), \(self.mode == .browser ? "browser" : "DLNA", privacy: .public) mode")
    }

    private func applyBitrate() {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        if mode == .browser {
            // Cap bursts so a big keyframe does not stall the Wi-Fi: 1.5x the average over any second.
            let limits = [NSNumber(value: Double(bitrate) * 1.5 / 8), NSNumber(value: 1.0)] as CFArray
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        }
    }

    private static func pool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        return p
    }

    private static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var b: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b) == kCVReturnSuccess else { return nil }
        return b
    }

    /// DLNA mode.
    private func encode(_ pixelBuffer: CVPixelBuffer) {
        guard let session else { return }
        let captured = Self.now()
        lastEncode = captured
        var props: CFDictionary?
        if forceKey {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            forceKey = false
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(seconds: captured, preferredTimescale: 1_000_000),
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self,
                  let unit = Self.annexB(from: sample) else { return }
            self.onFrame?(unit.bytes, captured, unit.isKey)
        }
    }

    /// Browser mode: the PTS given to VideoToolbox only has to increase; the TV timeline comes from the slot.
    private func encodeBrowser(_ pixelBuffer: CVPixelBuffer, slot: Int64, key: Bool,
                               deliver: @escaping (EncodedVideo) -> Void) {
        guard let session else { return }
        frameCount += 1
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: frameCount, timescale: CMTimeScale(Config.fps)),
            duration: CMTime(value: 1, timescale: CMTimeScale(Config.fps)),
            frameProperties: props, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, let video = Self.encoded(sample, slot: slot) else { return }
            deliver(video)
        }
    }

    private static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = atts.first else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    private static func parameterSets(of sample: CMSampleBuffer) -> [[UInt8]] {
        guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return [] }
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var sets: [[UInt8]] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let ptr { sets.append(Array(UnsafeBufferPointer(start: ptr, count: size))) }
        }
        return sets
    }

    private static func encoded(_ sample: CMSampleBuffer, slot: Int64) -> EncodedVideo? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let total = CMBlockBufferGetDataLength(block)
        var avcc = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &avcc) == noErr else { return nil }
        let key = isKeyFrame(sample)
        let sets = key ? parameterSets(of: sample) : []
        return EncodedVideo(avcc: avcc, isKey: key, slot: slot,
                            sps: sets.count > 0 ? sets[0] : [], pps: sets.count > 1 ? sets[1] : [])
    }

    /// AVCC (length-prefixed) -> Annex B (start codes), with AUD and SPS/PPS on keyframes.
    static func annexB(from sample: CMSampleBuffer) -> (bytes: [UInt8], isKey: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let isKey = isKeyFrame(sample)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out: [UInt8] = startCode + [0x09, 0xF0] // access unit delimiter
        if isKey {
            for set in parameterSets(of: sample) { out += startCode + set }
        }

        let total = CMBlockBufferGetDataLength(block)
        var avcc = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &avcc) == noErr else { return nil }
        var i = 0
        while i + 4 <= total {
            let len = Int(avcc[i]) << 24 | Int(avcc[i + 1]) << 16 | Int(avcc[i + 2]) << 8 | Int(avcc[i + 3])
            i += 4
            guard len > 0, i + len <= total else { break }
            out += startCode
            out += avcc[i..<(i + len)]
            i += len
        }
        return (out, isKey)
    }
}
