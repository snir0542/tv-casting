import Foundation
import Network

/// Tiny HTTP server on the phone.
/// - `GET /`: the TV player page (browser mode)
/// - `GET /ws`: WebSocket to that page (browser mode)
/// - any other `GET`: an endless MPEG-TS body starting at a keyframe (DLNA mode, v1.1)
final class StreamServer {
    var onNeedKeyFrame: (() -> Void)?
    var onPageSocket: ((PageSocket) -> Void)?

    private final class Client {
        let conn: NWConnection
        var streaming = false
        var synced = false   // has received a keyframe
        var inFlight = 0
        init(_ conn: NWConnection) { self.conn = conn }
    }

    private static let page: Data? = Bundle.main.url(forResource: "player", withExtension: "html")
        .flatMap { try? Data(contentsOf: $0) }

    private let port: UInt16
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]

    init(port: UInt16, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.stateUpdateHandler = { state in log.info("listener: \(String(describing: state), privacy: .public)") }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.clients.values.forEach { $0.conn.cancel() }
            self.clients.removeAll()
        }
    }

    /// DLNA mode. Must be called on `queue`. Audio follows the video's sync state (nothing before the
    /// first keyframe, nothing while resyncing) but does not count toward the video backlog.
    func broadcast(_ ts: Data, isKey: Bool, isAudio: Bool = false) {
        for client in clients.values where client.streaming {
            if !client.synced {
                guard isKey else { continue }
                client.synced = true
            }
            if !isAudio && client.inFlight > Config.maxBacklogFrames { // TV fell behind: drop and resync on next keyframe
                client.synced = false
                onNeedKeyFrame?()
                continue
            }
            let counted = !isAudio
            if counted { client.inFlight += 1 }
            client.conn.send(content: ts, completion: .contentProcessed { [weak client] _ in
                if counted { client?.inFlight -= 1 }
            })
        }
    }

    private func accept(_ conn: NWConnection) {
        let client = Client(conn)
        clients[ObjectIdentifier(client)] = client
        conn.stateUpdateHandler = { [weak self, weak client] state in
            switch state {
            case .failed, .cancelled:
                if let client { self?.remove(client) }
            default: break
            }
        }
        conn.start(queue: queue)
        readRequest(client, buffer: Data())
    }

    private func readRequest(_ client: Client, buffer: Data) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(client, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buf.count > 16_384 {
                self.remove(client)
            } else {
                self.readRequest(client, buffer: buf)
            }
        }
    }

    private func handle(_ client: Client, head: String) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "/") : "/"
        log.info("HTTP \(method, privacy: .public) \(path, privacy: .public) from TV")

        if method == "GET", path == "/ws", let key = WebSocket.headers(of: head)["sec-websocket-key"] {
            return upgrade(client, key: key)
        }
        if method == "GET", path == "/" || path == "/index.html" {
            let body = Self.page ?? Data("player.html is missing from the app".utf8)
            return respond(client, status: "200 OK", type: "text/html; charset=utf-8", body: body)
        }
        if path == "/favicon.ico" {
            return respond(client, status: "404 Not Found", type: "text/plain", body: Data())
        }

        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: video/mpeg\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n"
            + "transferMode.dlna.org: Streaming\r\n"
            + "contentFeatures.dlna.org: \(Config.dlnaFeatures)\r\n\r\n"

        switch method {
        case "GET":
            client.conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            client.streaming = true
            onNeedKeyFrame?()
        case "HEAD":
            client.conn.send(content: Data(header.utf8), completion: .contentProcessed { [weak self, weak client] _ in
                if let client { self?.remove(client) }
            })
        default:
            remove(client)
        }
    }

    private func respond(_ client: Client, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        client.conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self, weak client] _ in
            if let client { self?.remove(client) }
        })
    }

    /// Hands the connection over to a `PageSocket`.
    private func upgrade(_ client: Client, key: String) {
        clients.removeValue(forKey: ObjectIdentifier(client))
        let socket = PageSocket(conn: client.conn)
        client.conn.send(content: Data(WebSocket.handshakeResponse(clientKey: key).utf8),
                         completion: .contentProcessed { _ in })
        socket.start()
        onPageSocket?(socket)
    }

    private func remove(_ client: Client) {
        client.conn.cancel()
        clients.removeValue(forKey: ObjectIdentifier(client))
    }
}

/// The WebSocket to the TV page. All callbacks run on the server queue.
final class PageSocket {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    /// Bytes handed to the network but not yet sent: a growing number means the Wi-Fi cannot keep up.
    private(set) var backlogBytes = 0

    private let conn: NWConnection
    private var parser = WebSocket.Parser()
    private var closed = false

    init(conn: NWConnection) { self.conn = conn }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        read()
    }

    func send(binary: [UInt8]) { send(frame: WebSocket.frame(opcode: WebSocket.binary, payload: binary)) }

    func send(text: String) { send(frame: WebSocket.frame(opcode: WebSocket.text, payload: Array(text.utf8))) }

    /// Sends a close frame, then drops the connection once it is out.
    func close() {
        guard !closed else { return }
        let c = conn
        c.send(content: Data(WebSocket.frame(opcode: WebSocket.close, payload: [])),
               completion: .contentProcessed { _ in c.cancel() })
    }

    private func send(frame: [UInt8]) {
        guard !closed else { return }
        let count = frame.count
        backlogBytes += count
        conn.send(content: Data(frame), completion: .contentProcessed { [weak self] _ in self?.backlogBytes -= count })
    }

    private func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.parser.append([UInt8](data)) }
            while let frame = self.parser.next() {
                switch frame.opcode {
                case WebSocket.text: self.onText?(String(decoding: frame.payload, as: UTF8.self))
                case WebSocket.ping: self.send(frame: WebSocket.frame(opcode: WebSocket.pong, payload: frame.payload))
                case WebSocket.close:
                    self.conn.cancel()
                    return
                default: break
                }
            }
            if done || error != nil {
                self.conn.cancel()
                return
            }
            self.read()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?()
    }
}
