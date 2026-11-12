import XCTest
@testable import MirrorCore

final class FMP4Tests: XCTestCase {
    private let sps: [UInt8] = [0x67, 0x4D, 0x40, 0x28, 0xAA, 0xBB]
    private let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]

    func testVideoInitStructure() {
        let bytes = FMP4.videoInit(FMP4VideoConfig(width: 1920, height: 1080, sps: sps, pps: pps))
        let top = MP4.boxes(bytes)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov"])
        XCTAssertEqual(top.reduce(0) { $0 + $1.size }, bytes.count)
        XCTAssertEqual(MP4.boxes(top[1].payload).map(\.type), ["mvhd", "trak", "mvex"])
        for type in ["tkhd", "mdhd", "hdlr", "vmhd", "dref", "stsd", "avc1", "stts", "stsc", "stsz", "stco", "trex"] {
            XCTAssertTrue(MP4.contains(type, in: bytes), "missing \(type)")
        }

        XCTAssertEqual(MP4.payload(of: "avcC", in: bytes),
                       [1, 0x4D, 0x40, 0x28, 0xFF, 0xE1, 0, 6] + sps + [1, 0, 4] + pps)
        let mdhd = MP4.payload(of: "mdhd", in: bytes)!
        XCTAssertEqual(MP4.u32(mdhd, 12), 90000)
        let tkhd = MP4.payload(of: "tkhd", in: bytes)!
        XCTAssertEqual(MP4.u32(tkhd, 12), 1) // track ID
        XCTAssertEqual(MP4.u32(tkhd, 76), 1920 << 16)
        XCTAssertEqual(MP4.u32(tkhd, 80), 1080 << 16)
        let avc1 = MP4.payload(of: "avc1", in: bytes)!
        XCTAssertEqual(MP4.u16(avc1, 24), 1920)
        XCTAssertEqual(MP4.u16(avc1, 26), 1080)
        let hdlr = MP4.payload(of: "hdlr", in: bytes)!
        XCTAssertEqual(String(decoding: hdlr[8..<12], as: UTF8.self), "vide")
        let trex = MP4.payload(of: "trex", in: bytes)!
        XCTAssertEqual(MP4.u32(trex, 4), 1) // track ID
    }

    func testHighProfileAvcCHasChromaFields() {
        let high: [UInt8] = [0x67, 0x64, 0x00, 0x28, 0x01]
        let bytes = FMP4.videoInit(FMP4VideoConfig(width: 1280, height: 720, sps: high, pps: pps))
        let avcC = MP4.payload(of: "avcC", in: bytes)!
        XCTAssertEqual(Array(avcC.suffix(4)), [0xFD, 0xF8, 0xF8, 0x00])
    }

    func testAudioInitStructure() {
        let bytes = FMP4.audioInit(FMP4AudioConfig(sampleRate: 48000, channels: 2,
                                                   audioSpecificConfig: FMP4.aacLC48kStereoASC))
        XCTAssertEqual(MP4.boxes(bytes).map(\.type), ["ftyp", "moov"])
        XCTAssertTrue(MP4.contains("smhd", in: bytes))
        let mdhd = MP4.payload(of: "mdhd", in: bytes)!
        XCTAssertEqual(MP4.u32(mdhd, 12), 48000)
        let mp4a = MP4.payload(of: "mp4a", in: bytes)!
        XCTAssertEqual(MP4.u16(mp4a, 16), 2)          // channels
        XCTAssertEqual(MP4.u32(mp4a, 24), 48000 << 16) // sample rate 16.16
        let esds = MP4.payload(of: "esds", in: bytes)!
        // DecoderSpecificInfo: tag 5, length 2, the ASC
        let dsi: [UInt8] = [0x05, 0x02, 0x11, 0x90]
        XCTAssertNotNil(esds.firstRange(of: dsi))
        let hdlr = MP4.payload(of: "hdlr", in: bytes)!
        XCTAssertEqual(String(decoding: hdlr[8..<12], as: UTF8.self), "soun")
    }

    func testFragmentLayout() {
        let s1 = FMP4Sample(data: [UInt8](repeating: 1, count: 10), duration: 3000, isSync: true)
        let s2 = FMP4Sample(data: [UInt8](repeating: 2, count: 5), duration: 3001, isSync: false)
        let bytes = FMP4.fragment(sequence: 7, baseTime: 123_456_789_012, samples: [s1, s2])

        let top = MP4.boxes(bytes)
        XCTAssertEqual(top.map(\.type), ["moof", "mdat"])
        XCTAssertEqual(top.reduce(0) { $0 + $1.size }, bytes.count)

        XCTAssertEqual(MP4.u32(MP4.payload(of: "mfhd", in: bytes)!, 4), 7)
        let tfhd = MP4.payload(of: "tfhd", in: bytes)!
        XCTAssertEqual(MP4.u32(tfhd, 0) & 0xFF_FFFF, 0x02_0000) // default-base-is-moof
        XCTAssertEqual(MP4.u32(tfhd, 4), 1)
        let tfdt = MP4.payload(of: "tfdt", in: bytes)!
        XCTAssertEqual(tfdt[0], 1) // version 1: 64-bit time
        XCTAssertEqual(MP4.u64(tfdt, 4), 123_456_789_012)

        let trun = MP4.payload(of: "trun", in: bytes)!
        XCTAssertEqual(MP4.u32(trun, 0) & 0xFF_FFFF, 0x00_0701)
        XCTAssertEqual(MP4.u32(trun, 4), 2)
        let dataOffset = Int(MP4.u32(trun, 8))
        XCTAssertEqual(dataOffset, top[0].size + 8)
        XCTAssertEqual([MP4.u32(trun, 12), MP4.u32(trun, 16), MP4.u32(trun, 20)], [3000, 10, 0x0200_0000])
        XCTAssertEqual([MP4.u32(trun, 24), MP4.u32(trun, 28), MP4.u32(trun, 32)], [3001, 5, 0x0101_0000])
        XCTAssertEqual(Array(bytes[dataOffset...]), s1.data + s2.data)
    }

    func testEmptyFragmentIsStillValid() {
        let bytes = FMP4.fragment(sequence: 1, baseTime: 0, samples: [])
        XCTAssertEqual(MP4.boxes(bytes).map(\.type), ["moof", "mdat"])
    }
}
