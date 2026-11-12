/// Fragmented MP4 for the TV browser's Media Source Extensions.
///
/// Each track gets its own init segment (one track, ID 1) because the page feeds video and audio into
/// separate SourceBuffers. Fragments use `default-base-is-moof` and a 64-bit `tfdt`, the same layout
/// as ffmpeg's `frag_keyframe+empty_moov+default_base_moof`, which the LG TV plays.
struct FMP4VideoConfig: Equatable {
    var width: Int
    var height: Int
    var sps: [UInt8] // without start code or length prefix
    var pps: [UInt8]
}

struct FMP4AudioConfig: Equatable {
    var sampleRate: Int
    var channels: Int
    var audioSpecificConfig: [UInt8]
}

struct FMP4Sample {
    var data: [UInt8]     // video: AVCC (4-byte length-prefixed NAL units); audio: one raw AAC frame
    var duration: UInt32  // in the track's timescale
    var isSync: Bool
}

enum FMP4 {
    static let videoTimescale: UInt32 = 90000
    /// AudioSpecificConfig for AAC-LC, 48 kHz, stereo: object type 2, frequency index 3, channels 2.
    static let aacLC48kStereoASC: [UInt8] = [0x11, 0x90]

    private static let syncFlags: UInt32 = 0x0200_0000    // depends on no other sample
    private static let nonSyncFlags: UInt32 = 0x0101_0000 // depends on others, not a sync sample
    private static let identityMatrix: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]

    static func videoInit(_ c: FMP4VideoConfig) -> [UInt8] {
        var w = ByteWriter()
        ftyp(&w, brands: ["isom", "iso6", "iso2", "avc1", "mp41"])
        moov(&w, timescale: videoTimescale, handler: "vide", handlerName: "VideoHandler",
             width: c.width, height: c.height, isAudio: false) { w in
            w.box("avc1") { e in
                e.zeros(6)                    // reserved
                e.u16(1)                      // data reference index
                e.zeros(16)                   // pre-defined + reserved
                e.u16(UInt16(c.width))
                e.u16(UInt16(c.height))
                e.u32(0x0048_0000)            // 72 dpi
                e.u32(0x0048_0000)
                e.u32(0)                      // reserved
                e.u16(1)                      // frame count
                e.zeros(32)                   // compressor name
                e.u16(0x0018)                 // depth
                e.u16(0xFFFF)                 // pre-defined
                e.box("avcC") { a in a.append(avcC(sps: c.sps, pps: c.pps)) }
            }
        }
        return w.bytes
    }

    static func audioInit(_ c: FMP4AudioConfig) -> [UInt8] {
        var w = ByteWriter()
        ftyp(&w, brands: ["isom", "iso6", "iso2", "mp41"])
        moov(&w, timescale: UInt32(c.sampleRate), handler: "soun", handlerName: "SoundHandler",
             width: 0, height: 0, isAudio: true) { w in
            w.box("mp4a") { e in
                e.zeros(6)                    // reserved
                e.u16(1)                      // data reference index
                e.zeros(8)                    // reserved
                e.u16(UInt16(c.channels))
                e.u16(16)                     // sample size
                e.u16(0)                      // pre-defined
                e.u16(0)                      // reserved
                e.u32(UInt32(c.sampleRate) << 16)
                e.fullBox("esds", version: 0, flags: 0) { d in d.append(esDescriptor(c)) }
            }
        }
        return w.bytes
    }

    /// One `moof` + `mdat` for track 1. `baseTime` is the first sample's decode time in the track's timescale.
    static func fragment(sequence: UInt32, baseTime: UInt64, samples: [FMP4Sample]) -> [UInt8] {
        var w = ByteWriter()
        var dataOffsetAt = 0
        w.box("moof") { m in
            m.fullBox("mfhd", version: 0, flags: 0) { $0.u32(sequence) }
            m.box("traf") { t in
                t.fullBox("tfhd", version: 0, flags: 0x02_0000) { $0.u32(1) } // default-base-is-moof
                t.fullBox("tfdt", version: 1, flags: 0) { $0.u64(baseTime) }
                // data offset + per-sample duration, size and flags
                t.fullBox("trun", version: 0, flags: 0x00_0701) { r in
                    r.u32(UInt32(samples.count))
                    dataOffsetAt = r.bytes.count
                    r.u32(0)
                    for s in samples {
                        r.u32(s.duration)
                        r.u32(UInt32(s.data.count))
                        r.u32(s.isSync ? syncFlags : nonSyncFlags)
                    }
                }
            }
        }
        w.patchU32(at: dataOffsetAt, UInt32(w.bytes.count + 8)) // first sample byte, counted from the moof start
        w.box("mdat") { m in
            for s in samples { m.append(s.data) }
        }
        return w.bytes
    }

    // MARK: - pieces

    private static func ftyp(_ w: inout ByteWriter, brands: [String]) {
        w.box("ftyp") { f in
            f.fourCC("isom")
            f.u32(0x200)
            for b in brands { f.fourCC(b) }
        }
    }

    private static func moov(_ w: inout ByteWriter, timescale: UInt32, handler: String, handlerName: String,
                             width: Int, height: Int, isAudio: Bool, sampleEntry: (inout ByteWriter) -> Void) {
        w.box("moov") { m in
            m.fullBox("mvhd", version: 0, flags: 0) { h in
                h.u32(0); h.u32(0)             // creation, modification time
                h.u32(1000)                    // movie timescale
                h.u32(0)                       // duration: unknown (live)
                h.u32(0x0001_0000)             // rate 1.0
                h.u16(0x0100)                  // volume 1.0
                h.zeros(10)
                for v in identityMatrix { h.u32(v) }
                h.zeros(24)                    // pre-defined
                h.u32(2)                       // next track ID
            }
            m.box("trak") { t in
                t.fullBox("tkhd", version: 0, flags: 0x00_0003) { h in // enabled, in movie
                    h.u32(0); h.u32(0)
                    h.u32(1)                   // track ID
                    h.u32(0)                   // reserved
                    h.u32(0)                   // duration
                    h.zeros(8)
                    h.u16(0)                   // layer
                    h.u16(0)                   // alternate group
                    h.u16(isAudio ? 0x0100 : 0)
                    h.u16(0)
                    for v in identityMatrix { h.u32(v) }
                    h.u32(UInt32(width) << 16)
                    h.u32(UInt32(height) << 16)
                }
                t.box("mdia") { md in
                    md.fullBox("mdhd", version: 0, flags: 0) { h in
                        h.u32(0); h.u32(0)
                        h.u32(timescale)
                        h.u32(0)
                        h.u16(0x55C4)          // language "und"
                        h.u16(0)
                    }
                    md.fullBox("hdlr", version: 0, flags: 0) { h in
                        h.u32(0)
                        h.fourCC(handler)
                        h.zeros(12)
                        h.append(Array(handlerName.utf8) + [0])
                    }
                    md.box("minf") { mi in
                        if isAudio {
                            mi.fullBox("smhd", version: 0, flags: 0) { $0.u16(0); $0.u16(0) }
                        } else {
                            mi.fullBox("vmhd", version: 0, flags: 1) { $0.zeros(8) }
                        }
                        mi.box("dinf") { d in
                            d.fullBox("dref", version: 0, flags: 0) { r in
                                r.u32(1)
                                r.fullBox("url ", version: 0, flags: 1) { _ in } // media in this file
                            }
                        }
                        mi.box("stbl") { s in
                            s.fullBox("stsd", version: 0, flags: 0) { d in
                                d.u32(1)
                                sampleEntry(&d)
                            }
                            s.fullBox("stts", version: 0, flags: 0) { $0.u32(0) }
                            s.fullBox("stsc", version: 0, flags: 0) { $0.u32(0) }
                            s.fullBox("stsz", version: 0, flags: 0) { $0.u32(0); $0.u32(0) }
                            s.fullBox("stco", version: 0, flags: 0) { $0.u32(0) }
                        }
                    }
                }
            }
            m.box("mvex") { mv in
                mv.fullBox("trex", version: 0, flags: 0) { x in
                    x.u32(1)                   // track ID
                    x.u32(1)                   // sample description index
                    x.u32(0); x.u32(0); x.u32(0) // default duration, size, flags (set per sample)
                }
            }
        }
    }

    private static func avcC(sps: [UInt8], pps: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        let profile = sps.count > 1 ? sps[1] : 0x4D
        w.u8(1)
        w.u8(profile)
        w.u8(sps.count > 2 ? sps[2] : 0)
        w.u8(sps.count > 3 ? sps[3] : 0x28)
        w.u8(0xFF)                             // 4-byte NAL lengths
        w.u8(0xE1)                             // one SPS
        w.u16(UInt16(sps.count))
        w.append(sps)
        w.u8(1)                                // one PPS
        w.u16(UInt16(pps.count))
        w.append(pps)
        if [100, 110, 122, 144].contains(profile) { // High profiles: 4:2:0, 8-bit, no SPS extensions
            w.append([0xFD, 0xF8, 0xF8, 0x00])
        }
        return w.bytes
    }

    /// MPEG-4 ES descriptor for AAC (ISO/IEC 14496-1).
    private static func esDescriptor(_ c: FMP4AudioConfig) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }
        var config = ByteWriter()
        config.u8(0x40)                        // object type: MPEG-4 audio
        config.u8(0x15)                        // stream type audio, upstream 0, reserved 1
        config.u24(0)                          // buffer size
        config.u32(128_000)                    // max bitrate
        config.u32(128_000)                    // average bitrate
        let decoderConfig = descriptor(0x04, config.bytes + descriptor(0x05, c.audioSpecificConfig))
        let slConfig = descriptor(0x06, [0x02])
        return descriptor(0x03, [0x00, 0x01, 0x00] + decoderConfig + slConfig) // ES_ID 1, no flags
    }
}
