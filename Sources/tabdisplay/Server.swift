import Foundation
import Network

/// Port `httpPort` serves the viewer page; port `wsPort` is a WebSocket carrying
/// video (binary, Mac -> tablet) and input/control (text JSON, tablet -> Mac).
/// Both listen on 127.0.0.1 only: the tablet reaches them through `adb reverse`, and nobody
/// else on the network can watch the screen or drive the mouse.
final class StreamServer {
    var onKeyframeNeeded: (() -> Void)?
    var onInput: (([String: Any]) -> Void)?
    var onViewersChanged: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?

    private let queue = DispatchQueue(label: "server", qos: .userInteractive)
    private let html: Data
    private var httpListener: NWListener!
    private var wsListener: NWListener!
    private var clients: [ObjectIdentifier: Client] = [:]
    private var configJSON: String?

    private final class Client {
        let connection: NWConnection
        var inFlight = 0
        var waitingForKeyframe = true
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(httpPort: UInt16, wsPort: UInt16, html: Data) throws {
        self.html = html

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // don't let Nagle hold small packets back

        let httpParams = NWParameters(tls: nil, tcp: tcp)
        httpParams.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: httpPort)!)
        httpListener = try NWListener(using: httpParams)
        httpListener.newConnectionHandler = { [weak self] in self?.serveHTTP($0) }

        let wsParams = NWParameters(tls: nil, tcp: tcp)
        wsParams.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: wsPort)!)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        wsParams.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        wsListener = try NWListener(using: wsParams)
        wsListener.newConnectionHandler = { [weak self] in self?.accept($0) }

        for (listener, port) in [(httpListener!, httpPort), (wsListener!, wsPort)] {
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.onFailure?("Port \(port) is unavailable (\(error.localizedDescription)). Is another TabDisplay running?")
                }
            }
        }
    }

    func start() {
        httpListener.start(queue: queue)
        wsListener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.httpListener.cancel()
            self.wsListener.cancel()
            for client in self.clients.values { client.connection.cancel() }
            self.clients.removeAll()
        }
    }

    func setConfig(codec: String, width: Int, height: Int) {
        queue.async {
            self.configJSON = #"{"type":"config","codec":"\#(codec)","width":\#(width),"height":\#(height)}"#
            for client in self.clients.values { self.sendText(self.configJSON!, to: client) }
        }
    }

    /// Frame wire format: [flags u8: bit0 = keyframe][timestamp µs, i64 big-endian][Annex B bytes]
    func broadcast(_ annexB: Data, isKey: Bool, timestamp: Int64) {
        var packet = Data(capacity: annexB.count + 9)
        packet.append(isKey ? 1 : 0)
        withUnsafeBytes(of: timestamp.bigEndian) { packet.append(contentsOf: $0) }
        packet.append(annexB)

        queue.async {
            var needKey = false
            for client in self.clients.values {
                if client.waitingForKeyframe && !isKey { needKey = true; continue }
                // Slow link: drop instead of queueing, so latency never builds up.
                // Skipping a delta frame breaks the chain, so wait for the next keyframe.
                if client.inFlight > 3 && !isKey {
                    client.waitingForKeyframe = true
                    needKey = true
                    continue
                }
                client.waitingForKeyframe = false
                client.inFlight += 1
                let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
                client.connection.send(content: packet, contentContext: context, isComplete: true, completion: .contentProcessed { [queue = self.queue] _ in
                    queue.async { client.inFlight -= 1 }
                })
            }
            if needKey { self.onKeyframeNeeded?() }
        }
    }

    // MARK: - WebSocket

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        let id = ObjectIdentifier(client)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("viewer connected: \(connection.endpoint)")
                self.clients[id] = client
                self.onViewersChanged?(self.clients.count)
                if let config = self.configJSON { self.sendText(config, to: client) }
                self.onKeyframeNeeded?()
            case .failed, .cancelled:
                if self.clients.removeValue(forKey: id) != nil {
                    print("viewer disconnected")
                    self.onViewersChanged?(self.clients.count)
                }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: client)
    }

    private func receive(on client: Client) {
        client.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["t"] as? String == "key" { self.onKeyframeNeeded?() } else { self.onInput?(json) }
            }
            if error == nil { self.receive(on: client) } else { client.connection.cancel() }
        }
    }

    private func sendText(_ text: String, to client: Client) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        client.connection.send(content: text.data(using: .utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    // MARK: - HTTP (just enough to hand out the viewer page)

    private func serveHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [html] _, _, _, _ in
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            response.append(html)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
