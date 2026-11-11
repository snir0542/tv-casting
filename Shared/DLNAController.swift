import Foundation

/// Minimal UPnP AVTransport client: tells the TV which URL to play.
final class DLNAController {
    private let controlURL: URL

    init?(urlString: String = Config.tvControlURL) {
        guard let url = URL(string: urlString), url.host != nil, url.port != nil else { return nil }
        controlURL = url
    }

    func play(streamURL: String) async {
        _ = await send("Stop", [("InstanceID", "0")])
        let setResult = await send("SetAVTransportURI", [
            ("InstanceID", "0"),
            ("CurrentURI", streamURL),
            ("CurrentURIMetaData", Self.didl(streamURL)),
        ])
        log.info("SetAVTransportURI -> \(setResult.code)")
        try? await Task.sleep(nanoseconds: 400_000_000)
        let play = await send("Play", [("InstanceID", "0"), ("Speed", "1")])
        log.info("Play -> \(play.code)")
    }

    func stop() async {
        _ = await send("Stop", [("InstanceID", "0")])
    }

    /// Used by the app's "test connection" button (also triggers the Local Network permission prompt).
    func check() async -> String {
        let r = await send("GetTransportInfo", [("InstanceID", "0")])
        if r.code == 200 {
            let state = r.body.range(of: "<CurrentTransportState>")
                .flatMap { start in r.body[start.upperBound...].range(of: "<").map { String(r.body[start.upperBound..<$0.lowerBound]) } }
            return "✅ הטלוויזיה עונה (state: \(state ?? "?"))"
        }
        return "❌ אין תשובה תקינה (\(r.code)): \(r.body.prefix(200))"
    }

    private func send(_ action: String, _ args: [(String, String)]) async -> (code: Int, body: String) {
        let argXML = args.map { "<\($0.0)>\(Self.escape($0.1))</\($0.0)>" }.joined()
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(Config.avTransportService)\">\(argXML)</u:\(action)></s:Body></s:Envelope>"

        var req = URLRequest(url: controlURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(Config.avTransportService)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(body.utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(decoding: data, as: UTF8.self)
            if code != 200 { log.error("\(action, privacy: .public) failed \(code): \(text, privacy: .public)") }
            return (code, text)
        } catch {
            log.error("\(action, privacy: .public) error: \(error.localizedDescription, privacy: .public)")
            return (-1, error.localizedDescription)
        }
    }

    static func didl(_ url: String) -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>iPhone</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"\(Config.protocolInfo)\">\(escape(url))</res></item></DIDL-Lite>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
