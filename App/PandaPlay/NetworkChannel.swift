import Foundation
import Network
import PandaPlayCore

/// Bridges a `NWConnection` onto the core's synchronous `ByteChannel` seam.
///
/// The core is written against a plain send/receive interface so it stays testable off
/// Apple platforms; this is the one place that knows about Network.framework. Every byte
/// arrives on an arbitrary queue, so the callbacks are marshalled to the main queue the
/// session runs on.
final class NetworkChannel: ByteChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closedFlag = false

    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?

    /// Bytes queued by the core that have not reached the socket yet. Kept so a caller can
    /// assert the core only answers what it meant to.
    private(set) var outgoingBytes = 0

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onReceive?(data)
            }
            if error != nil || isComplete {
                self.finish()
                return
            }
            self.pump()
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if closedFlag {
            lock.unlock()
            return
        }
        outgoingBytes += data.count
        lock.unlock()
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        finish()
    }

    private func finish() {
        lock.lock()
        let alreadyClosed = closedFlag
        closedFlag = true
        lock.unlock()
        guard !alreadyClosed else { return }
        connection.cancel()
        onClose?()
    }
}

/// Accepts controller connections on the control port and hands each one to the session.
///
/// The accessory only ever listens; it never dials out, which is why there is no
/// `NWConnection(to:)` anywhere in this file.
final class ListenerSet: @unchecked Sendable {
    private let queue: DispatchQueue
    private var listeners: [UInt16: NWListener] = [:]
    private(set) var lastError: String?

    /// Called with the new channel and the slot it belongs to.
    var onConnection: ((NetworkChannel, Int) -> Void)?

    /// Announces the service on the local link once the control port is up.
    var onControlReady: ((UInt16) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Opens one listener per port. The first port is the control lane; the rest are media.
    func open(ports: [UInt16], serviceType: String, serviceName: String) {
        for (slot, port) in ports.enumerated() {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                lastError = "bad_port_\(port)"
                continue
            }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: nwPort)
                if slot == 0 {
                    listener.service = NWListener.Service(
                        name: serviceName,
                        type: "_\(serviceType)._tcp",
                        domain: nil,
                        txtRecord: Data()
                    )
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case let .failed(error) = state {
                        self.lastError = "listener_\(port):\(error)"
                    }
                    if case .ready = state, slot == 0 {
                        self.onControlReady?(port)
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    let channel = NetworkChannel(connection: connection, queue: self.queue)
                    self.onConnection?(channel, slot)
                    channel.start()
                }
                listener.start(queue: queue)
                listeners[port] = listener
            } catch {
                lastError = "listener_\(port):\(error.localizedDescription)"
            }
        }
    }

    var isOpen: Bool { !listeners.isEmpty }
    var portList: [UInt16] { listeners.keys.sorted() }

    func close() {
        for listener in listeners.values {
            listener.cancel()
        }
        listeners.removeAll()
    }
}
