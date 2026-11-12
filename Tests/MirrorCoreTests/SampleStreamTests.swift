#if canImport(VideoToolbox) && canImport(AVFoundation)
import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import MirrorCore

/// Writes a short stream the way the extension does — real VideoToolbox H.264 (Main, no reordering)
/// and AAC, packed by `FMP4`: 4 s of filler from TV time 0, then 10 s of "live" frames spliced in at
/// 4 s with the short first GOP. CI uploads it (env SAMPLE_OUT) so it can be checked with ffprobe and
/// replayed on the TV with `tools/browser_test.py --sample`.
final class SampleStreamTests: XCTestCase {
    private let width = 1920, height = 1080
    private let fillerFrames = 120, liveFrames = 300

    func testWriteSampleStream() throws {
        let encoded = try encodeVideo()
        XCTAssertEqual(encoded.count, fillerFrames + liveFrames)
        let first = try XCTUnwrap(encoded.first)
        XCTAssertTrue(first.isKey)
        XCTAssertFalse(first.sps.isEmpty)

        // video: filler = one fragment at 0; live = fragments starting at each scheduled keyframe
        var videoFrags: [UInt8] = []
        var base: UInt64 = 0
        var seq: UInt32 = 0
        var groups: [[Frame]] = [Array(encoded[0..<fillerFrames])]
        for frame in encoded[fillerFrames...] {
            if frame.isKey || groups.count == 1 { groups.append([frame]) } else { groups[groups.count - 1].append(frame) }
        }
        for group in groups {
            XCTAssertTrue(group[0].isKey, "every fragment must start with a keyframe")
            seq += 1
            let samples = group.map { FMP4Sample(data: $0.avcc, duration: 3000, isSync: $0.isKey) }
            videoFrags += FMP4.fragment(sequence: seq, baseTime: base, samples: samples)
            base += UInt64(group.count) * 3000
        }
        XCTAssertEqual(base, UInt64(fillerFrames + liveFrames) * 3000)
        let videoInit = FMP4.videoInit(FMP4VideoConfig(width: width, height: height, sps: first.sps, pps: first.pps))

        // audio: silence during the filler, then a beep every second
        let packets = try encodeAudio(seconds: Double(fillerFrames + liveFrames) / 30)
        var audioFrags: [UInt8] = []
        var aBase: UInt64 = 0
        for chunk in stride(from: 0, to: packets.count, by: 23) {
            let part = packets[chunk..<min(chunk + 23, packets.count)]
            seq += 1
            audioFrags += FMP4.fragment(sequence: seq, baseTime: aBase,
                                        samples: part.map { FMP4Sample(data: $0, duration: 1024, isSync: true) })
            aBase += UInt64(part.count) * 1024
        }
        let audioInit = FMP4.audioInit(FMP4AudioConfig(sampleRate: 48000, channels: 2,
                                                       audioSpecificConfig: FMP4.aacLC48kStereoASC))

        guard let out = ProcessInfo.processInfo.environment["SAMPLE_OUT"], !out.isEmpty else { return }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(videoInit).write(to: dir.appendingPathComponent("video.init"))
        try Data(videoFrags).write(to: dir.appendingPathComponent("video.frags"))
        try Data(audioInit).write(to: dir.appendingPathComponent("audio.init"))
        try Data(audioFrags).write(to: dir.appendingPathComponent("audio.frags"))
        print("sample stream written to \(out): \(groups.count) video fragments, \(packets.count) AAC frames")
    }

    // MARK: - video

    private struct Frame {
        let index: Int
        let avcc: [UInt8]
        let isKey: Bool
        let sps: [UInt8]
        let pps: [UInt8]
    }

    private func encodeVideo() throws -> [Frame] {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw XCTSkip("no H.264 encoder here (\(status))") }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse) // offline: no dropped frames
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 600))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 4_000_000))
        VTCompressionSessionPrepareToEncodeFrames(session)
        defer { VTCompressionSessionInvalidate(session) }

        let lock = NSLock()
        var frames: [Frame] = []
        let gop = GOPSchedule(start: Int64(fillerFrames))
        for i in 0..<(fillerFrames + liveFrames) {
            let buffer = try picture(index: i)
            let key = i == 0 || (i >= fillerFrames && gop.isKey(Int64(i)))
            let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(
                session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(i), timescale: 30),
                duration: CMTime(value: 1, timescale: 30), frameProperties: props, infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample, let frame = Self.frame(sample, index: i) else { return }
                lock.lock()
                frames.append(frame)
                lock.unlock()
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return frames.sorted { $0.index < $1.index }
    }

    /// Gray for the filler; a white bar moving across for "live".
    private func picture(index: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &created)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        memset(luma, index < fillerFrames ? 70 : 30, rowBytes * height)
        if index >= fillerFrames {
            let x0 = ((index - fillerFrames) * 16) % (width - 120)
            for y in 0..<height { memset(luma + y * rowBytes + x0, 235, 120) }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }

    private static func frame(_ sample: CMSampleBuffer, index: Int) -> Frame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr
        else { return nil }
        var key = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first {
            key = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }
        var sets: [[UInt8]] = []
        if key, let fmt = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    sets.append(Array(UnsafeBufferPointer(start: ptr, count: size)))
                }
            }
        }
        return Frame(index: index, avcc: bytes, isKey: key,
                     sps: sets.count > 0 ? sets[0] : [], pps: sets.count > 1 ? sets[1] : [])
    }

    // MARK: - audio

    private func encodeAudio(seconds: Double) throws -> [[UInt8]] {
        let pcm = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2,
                                              interleaved: true))
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let aac = try XCTUnwrap(AVAudioFormat(streamDescription: &asbd))
        let converter = try XCTUnwrap(AVAudioConverter(from: pcm, to: aac))
        converter.bitRate = 128_000
        var packets: [[UInt8]] = []
        let total = Int(seconds * 48000 / 1024)
        var n = 0
        while packets.count < total, n < total + 16 {
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024))
            let samples = try XCTUnwrap(input.int16ChannelData?[0])
            for f in 0..<1024 {
                let t = Double(n * 1024 + f) / 48000
                let beep = t >= 4 && t.truncatingRemainder(dividingBy: 1) < 0.2
                let v = beep ? Int16(8000 * sin(2 * Double.pi * 880 * t)) : 0
                samples[2 * f] = v
                samples[2 * f + 1] = v
            }
            input.frameLength = 1024
            n += 1
            let output = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 4,
                                                 maximumPacketSize: max(converter.maximumOutputPacketSize, 2048))
            var supplied = false
            var error: NSError?
            _ = converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            let base = output.data.assumingMemoryBound(to: UInt8.self)
            for i in 0..<Int(output.packetCount) {
                guard let d = output.packetDescriptions?[i] else { continue }
                packets.append(Array(UnsafeBufferPointer(start: base + Int(d.mStartOffset), count: Int(d.mDataByteSize))))
            }
        }
        XCTAssertGreaterThan(packets.count, total - 8)
        return packets
    }
}
#endif
