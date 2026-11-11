import CoreMedia
import CoreVideo
import VideoToolbox

/// Scales ReplayKit frames down and encodes them to H.264 (Annex B) in hardware.
/// Re-encodes the last frame when the screen is static so the TV never starves.
final class H264Encoder {
    /// (annexB access unit, capture time in seconds, isKeyFrame) — called on a VideoToolbox thread
    var onFrame: (([UInt8], Double, Bool) -> Void)?

    private let queue = DispatchQueue(label: "tvmirror.encoder")
    private let lock = NSLock()
    private var pending = 0
    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var outW = 0, outH = 0
    private var lastFrame: CVPixelBuffer?
    private var lastEncode: Double = 0
    private var forceKey = true
    private var timer: DispatchSourceTimer?

    init() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.keepAlive() }
        t.resume()
        timer = t
    }

    func requestKeyFrame() { queue.async { self.forceKey = true } }

    func submit(_ src: CVPixelBuffer) {
        lock.lock()
        if pending >= 2 { lock.unlock(); return } // encoder busy: drop frame
        pending += 1
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            guard let scaled = self.scale(src) else { return }
            self.lastFrame = scaled
            self.encode(scaled)
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
            lastFrame = nil
        }
    }

    // MARK: - private (all on `queue`)

    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func keepAlive() {
        guard let frame = lastFrame, Self.now() - lastEncode > 0.1 else { return }
        encode(frame)
    }

    private func scale(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let factor = min(1.0, Double(Config.maxLongEdge) / Double(max(w, h)))
        let ow = Int(Double(w) * factor) & ~1
        let oh = Int(Double(h) * factor) & ~1
        if session == nil || ow != outW || oh != outH {
            setup(width: ow, height: oh, format: CVPixelBufferGetPixelFormatType(src))
        }
        guard let pool, let transfer else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess, let dst else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr else { return nil }
        return dst
    }

    private func setup(width: Int, height: Int, format: OSType) {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        pool = nil
        lastFrame = nil
        outW = width
        outH = height

        if transfer == nil {
            var t: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
            transfer = t
        }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p

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
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: Config.bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: Config.fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: Config.fps * 2))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        forceKey = true
        log.info("Encoder ready \(width)x\(height)")
    }

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

    /// AVCC (length-prefixed) -> Annex B (start codes), with AUD and SPS/PPS on keyframes.
    static func annexB(from sample: CMSampleBuffer) -> (bytes: [UInt8], isKey: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }

        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first {
            isKey = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }

        let startCode: [UInt8] = [0, 0, 0, 1]
        var out: [UInt8] = startCode + [0x09, 0xF0] // access unit delimiter

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr {
                    out += startCode
                    out += UnsafeBufferPointer(start: ptr, count: size)
                }
            }
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
