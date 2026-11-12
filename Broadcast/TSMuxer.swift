import Foundation

/// Minimal MPEG-TS muxer: one H.264 and one AAC (ADTS) stream, PAT/PMT, PCR on every video frame.
struct TSMuxer {
    private let pmtPID: UInt16 = 0x1000
    private let videoPID: UInt16 = 0x0100
    private let audioPID: UInt16 = 0x0101
    private var counters: [UInt16: UInt8] = [:]
    private var framesSincePSI = 0

    /// - Parameters:
    ///   - annexB: one access unit with start codes (AUD, SPS/PPS on keyframes, slices)
    ///   - pcr90k: stream clock "now"; pts must be a bit ahead of it
    mutating func mux(annexB: [UInt8], pts90k: UInt64, pcr90k: UInt64, isKey: Bool) -> [UInt8] {
        var out: [UInt8] = []
        if isKey || framesSincePSI >= 15 {
            let pat: [UInt8] = [0x00, 0x01, 0xE0 | UInt8(pmtPID >> 8), UInt8(pmtPID & 0xFF)]
            let pmt: [UInt8] = [
                0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), // PCR PID
                0xF0, 0x00,                                         // program info length
                0x1B, 0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00, // H.264
                0x0F, 0xE0 | UInt8(audioPID >> 8), UInt8(audioPID & 0xFF), 0xF0, 0x00, // AAC (ADTS)
            ]
            out += packets(pid: 0, payload: psi(tableID: 0x00, ext: 1, body: pat), pcr: nil, randomAccess: false)
            out += packets(pid: pmtPID, payload: psi(tableID: 0x02, ext: 1, body: pmt), pcr: nil, randomAccess: false)
            framesSincePSI = 0
        }
        framesSincePSI += 1

        var pes: [UInt8] = [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05]
        pes += ptsBytes(pts90k)
        pes += annexB
        out += packets(pid: videoPID, payload: pes, pcr: pcr90k, randomAccess: isKey)
        return out
    }

    /// - Parameters:
    ///   - adts: one AAC frame with its ADTS header
    ///   - pts90k: on the same clock as the video PTS
    mutating func muxAudio(adts: [UInt8], pts90k: UInt64) -> [UInt8] {
        let length = 3 + 5 + adts.count // PES header flags + PTS + payload (audio PES needs a real length)
        var pes: [UInt8] = [0x00, 0x00, 0x01, 0xC0, UInt8(length >> 8), UInt8(length & 0xFF), 0x80, 0x80, 0x05]
        pes += ptsBytes(pts90k)
        pes += adts
        return packets(pid: audioPID, payload: pes, pcr: nil, randomAccess: false)
    }

    private mutating func packets(pid: UInt16, payload: [UInt8], pcr: UInt64?, randomAccess: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity((payload.count / 184 + 2) * 188)
        var offset = 0
        var first = true
        while offset < payload.count || first {
            var af: [UInt8] = []       // adaptation field content (without its length byte)
            var afTotal = 0            // bytes incl. length byte
            if first && (pcr != nil || randomAccess) {
                var flags: UInt8 = randomAccess ? 0x40 : 0
                if pcr != nil { flags |= 0x10 }
                af = [flags]
                if let pcr { af += pcrBytes(pcr) }
                afTotal = af.count + 1
            }
            let remaining = payload.count - offset
            var space = 184 - afTotal
            if remaining < space {
                let stuffing = space - remaining
                if afTotal == 0 {
                    afTotal = stuffing
                    af = stuffing >= 2 ? [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2) : []
                } else {
                    af += [UInt8](repeating: 0xFF, count: stuffing)
                    afTotal += stuffing
                }
                space = remaining
            }
            let take = min(space, remaining)
            let counter = nextCounter(pid)
            out.append(0x47)
            out.append((first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F))
            out.append(UInt8(pid & 0xFF))
            out.append((afTotal > 0 ? 0x30 : 0x10) | counter)
            if afTotal > 0 {
                out.append(UInt8(afTotal - 1))
                out += af
            }
            out += payload[offset..<(offset + take)]
            offset += take
            first = false
        }
        return out
    }

    private mutating func nextCounter(_ pid: UInt16) -> UInt8 {
        let c = counters[pid, default: 0]
        counters[pid] = (c + 1) & 0x0F
        return c
    }

    private func psi(tableID: UInt8, ext: UInt16, body: [UInt8]) -> [UInt8] {
        let length = 5 + body.count + 4
        var s: [UInt8] = [tableID, 0xB0 | UInt8((length >> 8) & 0x0F), UInt8(length & 0xFF),
                          UInt8(ext >> 8), UInt8(ext & 0xFF), 0xC1, 0x00, 0x00]
        s += body
        let crc = Self.crc32(s)
        s += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return [0x00] + s // pointer field
    }

    private func ptsBytes(_ value: UInt64) -> [UInt8] {
        let p = value & 0x1_FFFF_FFFF
        return [UInt8(0x21 | ((p >> 29) & 0x0E)),
                UInt8((p >> 22) & 0xFF),
                UInt8(((p >> 14) & 0xFE) | 1),
                UInt8((p >> 7) & 0xFF),
                UInt8(((p << 1) & 0xFE) | 1)]
    }

    private func pcrBytes(_ value: UInt64) -> [UInt8] {
        let b = value & 0x1_FFFF_FFFF
        return [UInt8((b >> 25) & 0xFF), UInt8((b >> 17) & 0xFF), UInt8((b >> 9) & 0xFF),
                UInt8((b >> 1) & 0xFF), UInt8(((b & 1) << 7) | 0x7E), 0x00]
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }
}
