import Foundation
import XCTest
@testable import MirrorCore

final class SSAPTests: XCTestCase {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testRegisterWithoutKeyAsksForPrompt() {
        let msg = object(SSAP.register(clientKey: nil))
        XCTAssertEqual(msg["type"] as? String, "register")
        let payload = msg["payload"] as? [String: Any] ?? [:]
        XCTAssertEqual(payload["pairingType"] as? String, "PROMPT")
        XCTAssertNil(payload["client-key"])
        let manifest = payload["manifest"] as? [String: Any] ?? [:]
        let signatures = manifest["signatures"] as? [[String: Any]] ?? []
        XCTAssertEqual((signatures.first?["signature"] as? String)?.isEmpty, false)
        XCTAssertTrue((manifest["permissions"] as? [String] ?? []).contains("LAUNCH"))
    }

    func testRegisterWithKey() {
        let payload = object(SSAP.register(clientKey: "abc"))["payload"] as? [String: Any] ?? [:]
        XCTAssertEqual(payload["client-key"] as? String, "abc")
    }

    func testRequest() {
        let msg = object(SSAP.request(id: "open_1", uri: SSAP.openURI, payload: ["target": "http://x:8090/"]))
        XCTAssertEqual(msg["type"] as? String, "request")
        XCTAssertEqual(msg["id"] as? String, "open_1")
        XCTAssertEqual(msg["uri"] as? String, "ssap://system.launcher/open")
        XCTAssertEqual((msg["payload"] as? [String: Any])?["target"] as? String, "http://x:8090/")
    }

    func testParsesRepliesSeenFromTheTV() {
        XCTAssertEqual(SSAP.parse(#"{"type":"response","id":"register_0","payload":{"pairingType":"PROMPT","returnValue":true}}"#),
                       .prompt)
        XCTAssertEqual(SSAP.parse(#"{"type":"registered","id":"register_0","payload":{"client-key":"k123"}}"#),
                       .registered(clientKey: "k123"))
        XCTAssertEqual(SSAP.parse(#"{"type":"response","id":"open_1","payload":{"returnValue":true}}"#),
                       .response(id: "open_1", payload: ["returnValue": "true"]))
        XCTAssertEqual(
            SSAP.parse(#"{"type":"response","id":"pointer_1","payload":{"returnValue":true,"socketPath":"ws://192.168.1.122:3000/resources/46055f/netinput.pointer.sock"}}"#),
            .response(id: "pointer_1", payload: ["returnValue": "true",
                                                 "socketPath": "ws://192.168.1.122:3000/resources/46055f/netinput.pointer.sock"]))
        XCTAssertEqual(SSAP.parse(#"{"type":"error","id":"x","error":"401 insufficient permissions","payload":{}}"#),
                       .error(id: "x", message: "401 insufficient permissions"))
        XCTAssertNil(SSAP.parse("not json"))
    }

    func testPointerPath() {
        XCTAssertEqual(SSAP.pointerPath(fromSocketPath: "ws://192.168.1.122:3000/resources/46055f/netinput.pointer.sock"),
                       "/resources/46055f/netinput.pointer.sock")
        XCTAssertNil(SSAP.pointerPath(fromSocketPath: ""))
    }
}
