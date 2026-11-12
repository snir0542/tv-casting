import Foundation
import Network

/// Tiny HTTP server: every GET gets an endless MPEG-TS body (starting at a keyframe).
final class StreamServer {
    var onNeedKeyFrame: (() -> Void)?

    private final class Client {
        let conn: NWConnection
        var streaming = false
        var synced = false   // has received a keyframe
        var inFlight = 0
        init(_ conn: NWConnection) { self.conn = conn }
    }

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

    /// Must be called on `queue`. Audio follows the video's sync state (nothing before the first
    /// keyframe, nothing while resyncing) but does not count toward the video backlog.
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
        let method = head.split(separator: " ").first.map(String.init) ?? ""
        log.info("HTTP \(method, privacy: .public) from TV")
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

    private func remove(_ client: Client) {
        client.conn.cancel()
        clients.removeValue(forKey: ObjectIdentifier(client))
    }
}
