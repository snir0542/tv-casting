import CryptoKit
import Foundation

/// The bits of RFC 6455 we need: the server handshake and frames in both directions.
/// Messages are small and never fragmented, so continuation frames are not reassembled.
enum WebSocket {
    static let text: UInt8 = 0x1
    static let binary: UInt8 = 0x2
    static let close: UInt8 = 0x8
    static let ping: UInt8 = 0x9
    static let pong: UInt8 = 0xA

    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func acceptKey(for clientKey: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((clientKey + guid).utf8))).base64EncodedString()
    }

    static func handshakeResponse(clientKey: String) -> String {
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptKey(for: clientKey))\r\n\r\n"
    }

    /// A complete, unmasked frame (server to client).
    static func frame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        header(opcode: opcode, length: payload.count, masked: false) + payload
    }

    /// A complete, masked frame (client to server, as the TV remote sends them).
    static func clientFrame(opcode: UInt8, payload: [UInt8], mask: [UInt8]) -> [UInt8] {
        precondition(mask.count == 4)
        var out = header(opcode: opcode, length: payload.count, masked: true) + mask
        out.reserveCapacity(out.count + payload.count)
        for (i, byte) in payload.enumerated() { out.append(byte ^ mask[i & 3]) }
        return out
    }

    private static func header(opcode: UInt8, length: Int, masked: Bool) -> [UInt8] {
        let maskBit: UInt8 = masked ? 0x80 : 0
        var h: [UInt8] = [0x80 | opcode] // FIN
        if length < 126 {
            h.append(maskBit | UInt8(length))
        } else if length < 65536 {
            h += [maskBit | 126, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            h.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { h.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF)) }
        }
        return h
    }

    /// Collects bytes and returns whole frames, masked or not.
    struct Parser {
        private var buffer: [UInt8] = []

        mutating func append(_ bytes: [UInt8]) { buffer += bytes }

        mutating func next() -> (opcode: UInt8, payload: [UInt8])? {
            guard buffer.count >= 2 else { return nil }
            let opcode = buffer[0] & 0x0F
            let masked = buffer[1] & 0x80 != 0
            var length = Int(buffer[1] & 0x7F)
            var pos = 2
            if length == 126 {
                guard buffer.count >= 4 else { return nil }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                pos = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return nil }
                length = 0
                for i in 2..<10 { length = length << 8 | Int(buffer[i]) }
                pos = 10
            }
            let maskLength = masked ? 4 : 0
            let end = pos + maskLength + length
            guard buffer.count >= end else { return nil }
            var payload = Array(buffer[(pos + maskLength)..<end])
            if masked {
                let key = Array(buffer[pos..<(pos + 4)])
                for i in payload.indices { payload[i] ^= key[i & 3] }
            }
            buffer.removeFirst(end)
            return (opcode, payload)
        }
    }

    /// Header fields of an HTTP request head, names lower-cased.
    static func headers(of request: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }
}
