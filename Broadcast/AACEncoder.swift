import AVFoundation
import CoreMedia

/// Encodes ReplayKit app audio to AAC-LC (48 kHz stereo) and hands out ADTS frames on one continuous
/// timeline. Silence fills every gap: the TV paces playback on the audio track and stalls when it stops.
final class AACEncoder {
    /// (ADTS frame, presentation time in host-clock seconds) — called on the encoder queue
    var onFrame: (([UInt8], Double) -> Void)?

    private static let rate = Config.audioSampleRate
    private static let channels = 2
    private static let framesPerPacket = 1024
    /// Silence is added only once real audio is this late, so it never covers real audio.
    private static let silenceLag = 0.2
    /// Timing differences smaller than this are treated as continuous audio.
    private static let tolerance = 0.01

    private let queue = DispatchQueue(label: "tvmirror.audio")
    private let pcmFormat: AVAudioFormat
    private let encoder: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private var resamplerRate: Double = 0
    private var fifo: [Int16] = []        // interleaved stereo samples waiting to be encoded
    private var anchor: Double = 0        // host time of timeline frame 0
    private var queuedFrames: Int64 = 0   // timeline frames put into the FIFO (real audio + silence)
    private var packetsOut: Int64 = 0
    private var timer: DispatchSourceTimer?

    init() {
        let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.rate,
                                channels: AVAudioChannelCount(Self.channels), interleaved: true)!
        var aac = AudioStreamBasicDescription(
            mSampleRate: Self.rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.channels), mBitsPerChannel: 0, mReserved: 0)
        let encoder = AVAudioFormat(streamDescription: &aac).flatMap { AVAudioConverter(from: pcm, to: $0) }
        encoder?.bitRate = Config.audioBitrate
        pcmFormat = pcm
        self.encoder = encoder
        if encoder == nil { log.error("AAC encoder unavailable") }
    }

    /// Starts the timeline now; silence is produced until app audio arrives.
    func start() {
        queue.async {
            self.anchor = Self.hostNow()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.05, repeating: 0.05)
            t.setEventHandler { [weak self] in self?.fillSilence() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            onFrame = nil
        }
    }

    /// Called on ReplayKit's thread with `.audioApp` buffers.
    func submit(_ sampleBuffer: CMSampleBuffer) {
        guard let input = Self.stereoInt16(sampleBuffer) else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let now = Self.hostNow()
        if !pts.isFinite || abs(pts - now) > 2 { pts = now } // not on the host clock: treat as just captured
        queue.async { self.append(input.samples, rate: input.rate, at: pts) }
    }

    // MARK: - private (all on `queue`)

    private static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func append(_ samples: [Int16], rate: Double, at pts: Double) {
        guard timer != nil else { return } // not started, or already stopped
        let pcm = rate == Self.rate ? samples : resample(samples, from: rate)
        let frames = pcm.count / Self.channels
        guard frames > 0 else { return }

        var offset = Int64(((pts - anchor) * Self.rate).rounded()) - queuedFrames // > 0 gap, < 0 overlap
        if abs(Double(offset)) < Self.tolerance * Self.rate { offset = 0 }
        if offset > 0 { appendSilence(Int(offset)) }
        let skip = offset < 0 ? min(frames, Int(-offset)) : 0
        if skip < frames {
            fifo.append(contentsOf: pcm[(skip * Self.channels)...])
            queuedFrames += Int64(frames - skip)
        }
        encodeAvailable()
    }

    private func fillSilence() {
        let target = Int64(((Self.hostNow() - Self.silenceLag - anchor) * Self.rate).rounded())
        guard target > queuedFrames else { return }
        appendSilence(Int(target - queuedFrames))
        encodeAvailable()
    }

    private func appendSilence(_ frames: Int) {
        fifo.append(contentsOf: repeatElement(Int16(0), count: frames * Self.channels))
        queuedFrames += Int64(frames)
    }

    private func encodeAvailable() {
        let count = Self.framesPerPacket * Self.channels
        guard let encoder else { fifo.removeAll(); return }
        while fifo.count >= count {
            guard let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(Self.framesPerPacket)),
                  let dst = input.int16ChannelData?[0] else { return }
            fifo.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: count) }
            input.frameLength = AVAudioFrameCount(Self.framesPerPacket)
            fifo.removeFirst(count)

            let output = AVAudioCompressedBuffer(format: encoder.outputFormat, packetCapacity: 4,
                                                 maximumPacketSize: max(encoder.maximumOutputPacketSize, 2048))
            var supplied = false
            var error: NSError?
            let status = encoder.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                log.error("AAC encode failed: \(error?.localizedDescription ?? "?", privacy: .public)")
                packetsOut += 1 // keep later packets on the timeline
                continue
            }
            emit(output)
        }
    }

    private func emit(_ buffer: AVAudioCompressedBuffer) {
        guard buffer.packetCount > 0, let descriptions = buffer.packetDescriptions else { return }
        let base = buffer.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(buffer.packetCount) {
            let d = descriptions[i]
            let payload = UnsafeBufferPointer(start: base + Int(d.mStartOffset), count: Int(d.mDataByteSize))
            let pts = anchor + Double(packetsOut * Int64(Self.framesPerPacket)) / Self.rate
            packetsOut += 1
            onFrame?(Self.adtsHeader(payloadLength: payload.count) + payload, pts)
        }
    }

    private func resample(_ samples: [Int16], from rate: Double) -> [Int16] {
        if resampler == nil || resamplerRate != rate {
            guard let from = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                           channels: AVAudioChannelCount(Self.channels), interleaved: true)
            else { return [] }
            resampler = AVAudioConverter(from: from, to: pcmFormat)
            resamplerRate = rate
        }
        guard let resampler else { return [] }
        let frames = samples.count / Self.channels
        guard let input = AVAudioPCMBuffer(pcmFormat: resampler.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let src = input.int16ChannelData?[0],
              let output = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                            frameCapacity: AVAudioFrameCount(Double(frames) * Self.rate / rate) + 64),
              let dst = output.int16ChannelData?[0] else { return [] }
        samples.withUnsafeBufferPointer { src.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(frames)
        var supplied = false
        var error: NSError?
        _ = resampler.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: dst, count: Int(output.frameLength) * Self.channels))
    }

    /// ReplayKit app audio is 16-bit PCM (sometimes big-endian) or 32-bit float, mono or stereo,
    /// interleaved or not. Returns interleaved native-endian stereo Int16 and the sample rate.
    private static func stereoInt16(_ sampleBuffer: CMSampleBuffer) -> (samples: [Int16], rate: Double)? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = Int(asbd.mChannelsPerFrame)
        let bits = Int(asbd.mBitsPerChannel)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard frames > 0, channels > 0, (bits == 16 && !isFloat) || (bits == 32 && isFloat) else { return nil }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard listSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &block) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        func sample(_ frame: Int, _ channel: Int) -> Int16 {
            let c = min(channel, channels - 1) // mono: same sample on both sides
            let (index, position) = planar ? (c, frame) : (0, frame * channels + c)
            guard index < buffers.count, let data = buffers[index].mData else { return 0 }
            if isFloat {
                var pattern = data.load(fromByteOffset: position * 4, as: UInt32.self)
                if bigEndian { pattern = pattern.byteSwapped }
                let x = Float32(bitPattern: pattern)
                return x.isFinite ? Int16(max(-1, min(1, x)) * 32767) : 0
            }
            let value = data.load(fromByteOffset: position * 2, as: Int16.self)
            return bigEndian ? value.byteSwapped : value
        }

        var out = [Int16](repeating: 0, count: frames * Self.channels)
        for f in 0..<frames {
            out[f * 2] = sample(f, 0)
            out[f * 2 + 1] = sample(f, 1)
        }
        return (out, asbd.mSampleRate)
    }

    /// 7-byte ADTS header (no CRC) for one AAC-LC frame, 48 kHz stereo.
    private static func adtsHeader(payloadLength: Int) -> [UInt8] {
        let length = payloadLength + 7
        let profile: UInt8 = 1       // AAC LC (audio object type 2) minus 1
        let frequencyIndex: UInt8 = 3 // 48 kHz
        let channelConfig: UInt8 = 2  // stereo
        return [
            0xFF, 0xF1, // syncword, MPEG-4, layer 0, no CRC
            (profile << 6) | (frequencyIndex << 2) | (channelConfig >> 2),
            ((channelConfig & 0x03) << 6) | UInt8((length >> 11) & 0x03),
            UInt8((length >> 3) & 0xFF),
            (UInt8(length & 0x07) << 5) | 0x1F,
            0xFC,
        ]
    }
}
