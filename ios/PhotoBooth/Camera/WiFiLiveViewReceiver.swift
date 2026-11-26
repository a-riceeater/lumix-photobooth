import CoreGraphics
import Foundation
import Network

/// Receives the S5II's UDP live view (port of S5II-Bridge StreamSink). Bind it
/// BEFORE `startstream` so the first datagrams aren't answered with ICMP
/// port-unreachable, and keep it open for as long as the camera may stream:
/// a stream aimed at a closed port, followed by a second startstream, is what
/// produced err_busy during research.
final class WiFiLiveViewReceiver: @unchecked Sendable {
    let port: UInt16
    private let queue = DispatchQueue(label: "photobooth.wifi.liveview", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var decoding = false
    private var lastDatagramAt: Date?
    private(set) var datagrams = 0
    /// Called with each decoded frame (on a background queue).
    var onFrame: (@Sendable (CGImage) -> Void)?

    init(port: UInt16 = 49199) { self.port = port }

    var isListening: Bool { lock.withLock { listener != nil } }
    var secondsSinceLastDatagram: TimeInterval? { lock.withLock { lastDatagramAt.map { Date().timeIntervalSince($0) } } }

    func start() throws {
        guard !isListening else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port) else { throw LumixWiFiError.transport("bad port \(port)") }
        let l = try NWListener(using: params, on: p)
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.lock.withLock { self.connections.append(c) }
            self.receive(on: c)
        }
        l.start(queue: queue)
        lock.withLock { listener = l }
    }

    func stop() {
        let (l, cs) = lock.withLock { () -> (NWListener?, [NWConnection]) in
            defer { listener = nil; connections = [] }
            return (listener, connections)
        }
        l?.cancel()
        cs.forEach { $0.cancel() }
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle(data) }
            if error == nil { self.receive(on: c) }
        }
    }

    /// Decode at most one frame at a time; drop datagrams that arrive meanwhile.
    private func handle(_ data: Data) {
        let busy = lock.withLock { () -> Bool in
            datagrams += 1
            lastDatagramAt = Date()
            if decoding { return true }
            decoding = true
            return false
        }
        guard !busy else { return }
        defer { lock.withLock { decoding = false } }
        guard let jpeg = WiFiLiveViewParser.jpeg(fromDatagram: data), let image = PreviewFeed.decode(jpeg) else { return }
        onFrame?(image)
    }
}
