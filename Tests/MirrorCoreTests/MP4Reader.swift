/// Just enough MP4 reading for the tests.
enum MP4 {
    struct Box {
        let type: String
        let size: Int
        let payload: [UInt8] // everything after the 8-byte header
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) << 32 | UInt64(u32(b, i + 4)) }

    /// Consecutive boxes filling `bytes`.
    static func boxes(_ bytes: [UInt8]) -> [Box] {
        var out: [Box] = []
        var i = 0
        while i + 8 <= bytes.count {
            let size = Int(u32(bytes, i))
            guard size >= 8, i + size <= bytes.count else { break }
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            out.append(Box(type: type, size: size, payload: Array(bytes[(i + 8)..<(i + size)])))
            i += size
        }
        return out
    }

    /// Payload of the first box of this type anywhere in `bytes` (found by its four-character code).
    static func payload(of type: String, in bytes: [UInt8]) -> [UInt8]? {
        let code = Array(type.utf8)
        guard bytes.count >= 8 else { return nil }
        for i in 4...(bytes.count - 4) where Array(bytes[i..<(i + 4)]) == code {
            let size = Int(u32(bytes, i - 4))
            guard size >= 8, i - 4 + size <= bytes.count else { continue }
            return Array(bytes[(i + 4)..<(i - 4 + size)])
        }
        return nil
    }

    static func contains(_ type: String, in bytes: [UInt8]) -> Bool { payload(of: type, in: bytes) != nil }
}
