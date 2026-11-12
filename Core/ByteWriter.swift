/// Big-endian byte writer with helpers for ISO base media file format (MP4) boxes.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func u24(_ v: UInt32) { bytes += [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    mutating func u32(_ v: UInt32) {
        bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    mutating func u64(_ v: UInt64) {
        u32(UInt32(v >> 32))
        u32(UInt32(v & 0xFFFF_FFFF))
    }
    mutating func append(_ data: [UInt8]) { bytes += data }
    mutating func zeros(_ count: Int) { bytes += [UInt8](repeating: 0, count: count) }
    mutating func fourCC(_ code: String) {
        let ascii = Array(code.utf8)
        precondition(ascii.count == 4, "four-character code expected: \(code)")
        bytes += ascii
    }

    /// Overwrites four bytes at `offset` (used to fill in sizes and offsets known only later).
    mutating func patchU32(at offset: Int, _ v: UInt32) {
        bytes[offset] = UInt8(v >> 24)
        bytes[offset + 1] = UInt8((v >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((v >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(v & 0xFF)
    }

    /// Writes `size type body`; the size is filled in after the body.
    mutating func box(_ type: String, _ body: (inout ByteWriter) -> Void) {
        let start = bytes.count
        u32(0)
        fourCC(type)
        body(&self)
        patchU32(at: start, UInt32(bytes.count - start))
    }

    /// A box that starts with a version byte and 24 bits of flags.
    mutating func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: (inout ByteWriter) -> Void) {
        box(type) { w in
            w.u8(version)
            w.u24(flags)
            body(&w)
        }
    }
}
