import XCTest
@testable import MirrorCore

final class WebSocketTests: XCTestCase {
    func testAcceptKeyFromRFC6455() {
        XCTAssertEqual(WebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testHandshakeResponse() {
        let r = WebSocket.handshakeResponse(clientKey: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(r.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        XCTAssertTrue(r.hasSuffix("\r\n\r\n"))
    }

    func testServerFrameHeaders() {
        XCTAssertEqual(WebSocket.frame(opcode: 0x2, payload: []), [0x82, 0x00])
        XCTAssertEqual(Array(WebSocket.frame(opcode: 0x1, payload: [UInt8](repeating: 0, count: 125)).prefix(2)),
                       [0x81, 125])
        XCTAssertEqual(Array(WebSocket.frame(opcode: 0x2, payload: [UInt8](repeating: 0, count: 126)).prefix(4)),
                       [0x82, 126, 0x00, 0x7E])
        XCTAssertEqual(Array(WebSocket.frame(opcode: 0x2, payload: [UInt8](repeating: 0, count: 65535)).prefix(4)),
                       [0x82, 126, 0xFF, 0xFF])
        let big = WebSocket.frame(opcode: 0x2, payload: [UInt8](repeating: 7, count: 65536))
        XCTAssertEqual(Array(big.prefix(10)), [0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0])
        XCTAssertEqual(big.count, 10 + 65536)
    }

    func testParsesMaskedHelloFromRFC6455() {
        var p = WebSocket.Parser()
        p.append([0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58])
        let f = p.next()
        XCTAssertEqual(f?.opcode, 0x1)
        XCTAssertEqual(f.map { String(decoding: $0.payload, as: UTF8.self) }, "Hello")
        XCTAssertNil(p.next())
    }

    func testParserWaitsForCompleteFrames() {
        var p = WebSocket.Parser()
        let bytes: [UInt8] = [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]
        for b in bytes.dropLast() {
            p.append([b])
            XCTAssertNil(p.next())
        }
        p.append([bytes.last!])
        XCTAssertEqual(p.next().map { String(decoding: $0.payload, as: UTF8.self) }, "Hello")
    }

    func testClientFrameRoundTripsThroughParser() {
        let payload = [UInt8](repeating: 0x5A, count: 70_000)
        let frame = WebSocket.clientFrame(opcode: 0x2, payload: payload, mask: [1, 2, 3, 4])
        XCTAssertEqual(frame[1] & 0x80, 0x80) // masked
        var p = WebSocket.Parser()
        p.append(frame + WebSocket.clientFrame(opcode: 0x1, payload: Array("hi".utf8), mask: [9, 9, 9, 9]))
        let first = p.next()
        XCTAssertEqual(first?.opcode, 0x2)
        XCTAssertEqual(first?.payload, payload)
        XCTAssertEqual(p.next().map { String(decoding: $0.payload, as: UTF8.self) }, "hi")
        XCTAssertNil(p.next())
    }

    func testParsesUnmaskedServerFrames() {
        var p = WebSocket.Parser()
        p.append(WebSocket.frame(opcode: 0x1, payload: Array("{\"a\":1}".utf8)))
        XCTAssertEqual(p.next().map { String(decoding: $0.payload, as: UTF8.self) }, "{\"a\":1}")
    }

    func testHeaders() {
        let h = WebSocket.headers(of: "GET /ws HTTP/1.1\r\nHost: x\r\nSec-WebSocket-Key: abc==\r\nUpgrade: websocket")
        XCTAssertEqual(h["sec-websocket-key"], "abc==")
        XCTAssertEqual(h["upgrade"], "websocket")
        XCTAssertNil(h["get /ws http/1.1"])
    }
}
