import Foundation
import Network

/// Talks to the LG TV over its control socket (SSAP, ws://TV:3000), like LG's own remote app:
/// pairing (the TV asks "allow this device?" the first time), opening the player page in the TV
/// browser, and a pointer "click" — the user gesture the page needs to go full screen.
/// All callbacks run on `queue`.
final class LGTVRemote {
    enum Failure: Error, CustomStringConvertible {
        case unreachable, timeout, refused(String)

        var description: String {
            switch self {
            case .unreachable: return "the TV's control port did not answer"
            case .timeout: return "the TV's \"allow this device?\" prompt was not accepted"
            case .refused(let why): return "the TV refused the connection (\(why))"
            }
        }
    }

    private let host: String
    private let queue: DispatchQueue
    private var conn: NWConnection?
    private var registered: ((Result<Void, Failure>) -> Void)?
    private var waiting: [String: (SSAPReply) -> Void] = [:]
    private var nextID = 1
    private var keyName: String { "lgtv.clientKey.\(host)" }

    init(host: String, queue: DispatchQueue) {
        self.host = host
        self.queue = queue
    }

    func connect(controlTimeout: TimeInterval = 5, pairingTimeout: TimeInterval = 60,
                 completion: @escaping (Result<Void, Failure>) -> Void) {
        queue.async {
            guard let url = URL(string: "ws://\(self.host):3000/") else { return completion(.failure(.unreachable)) }
            let c = NWConnection(to: .url(url), using: Self.webSocketParameters())
            self.conn = c
            self.registered = completion
            var ready = false
            c.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    ready = true
                    self.receive(on: c)
                    let key = UserDefaults.standard.string(forKey: self.keyName)
                    if key == nil { log.info("Pairing with the TV: it will ask to allow this device") }
                    self.sendText(SSAP.register(clientKey: key), on: c)
                    self.queue.asyncAfter(deadline: .now() + pairingTimeout) { self.finishRegistering(.failure(.timeout)) }
                case .failed(let error):
                    log.error("TV control socket failed: \(error.localizedDescription, privacy: .public)")
                    self.finishRegistering(.failure(.unreachable))
                case .cancelled:
                    self.finishRegistering(.failure(.unreachable))
                default:
                    break
                }
            }
            c.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + controlTimeout) {
                if !ready {
                    self.finishRegistering(.failure(.unreachable))
                    c.cancel()
                }
            }
        }
    }

    /// Opens `url` in the TV's web browser.
    func open(url: String, completion: @escaping (Bool) -> Void) {
        request(SSAP.openURI, payload: ["target": url]) { reply in
            if case .response = reply { completion(true) } else { completion(false) }
        }
    }

    /// A pointer click in the middle of the TV screen (the page's full-screen gesture).
    /// Tested on the TV: without moving the pointer first, the click missed the page.
    func click() {
        request(SSAP.pointerURI) { [weak self] reply in
            guard let self, case .response(_, let payload) = reply,
                  let socketPath = payload["socketPath"], let url = URL(string: socketPath) else {
                log.error("No pointer socket from the TV")
                return
            }
            let pointer = NWConnection(to: .url(url), using: Self.webSocketParameters())
            pointer.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let steps = SSAP.pointerToCentre + [SSAP.clickCommand]
                    for (i, step) in steps.enumerated() {
                        self.queue.asyncAfter(deadline: .now() + 0.25 * Double(i)) { self.sendText(step, on: pointer) }
                    }
                    // closing the pointer socket at once can drop the click
                    self.queue.asyncAfter(deadline: .now() + 0.25 * Double(steps.count) + 1.5) { pointer.cancel() }
                case .failed:
                    pointer.cancel()
                default:
                    break
                }
            }
            pointer.start(queue: self.queue)
        }
    }

    func close() {
        queue.async {
            self.conn?.cancel()
            self.conn = nil
            self.waiting.removeAll()
        }
    }

    // MARK: - private (on `queue`)

    private func request(_ uri: String, payload: [String: String] = [:], completion: @escaping (SSAPReply) -> Void) {
        queue.async {
            guard let c = self.conn else { return completion(.error(id: "", message: "not connected")) }
            let id = "req_\(self.nextID)"
            self.nextID += 1
            self.waiting[id] = completion
            self.sendText(SSAP.request(id: id, uri: uri, payload: payload), on: c)
        }
    }

    private func finishRegistering(_ result: Result<Void, Failure>) {
        guard let done = registered else { return }
        registered = nil
        done(result)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let text = String(data: data, encoding: .utf8), let reply = SSAP.parse(text) {
                self.handle(reply)
            }
            if error == nil { self.receive(on: c) }
        }
    }

    private func handle(_ reply: SSAPReply) {
        switch reply {
        case .prompt:
            log.info("The TV is asking to allow this device")
        case .registered(let key):
            UserDefaults.standard.set(key, forKey: keyName)
            finishRegistering(.success(()))
        case .error(let id, let message) where id == "register_0":
            finishRegistering(.failure(.refused(message)))
        case .response(let id, _), .error(let id, _):
            waiting.removeValue(forKey: id)?(reply)
        }
    }

    private func sendText(_ text: String, on c: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ssap", metadata: [metadata])
        c.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private static func webSocketParameters() -> NWParameters {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return params
    }
}
