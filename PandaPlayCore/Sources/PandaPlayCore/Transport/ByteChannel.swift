import Foundation

/// A duplex byte pipe.
///
/// The RTSP server and the media readers talk to this instead of a socket so the same
/// state machines can be exercised without a network stack. Apple builds supply a
/// `Network.framework` implementation; Windows and unit tests supply their own.
public protocol ByteChannel: AnyObject, Sendable {
    func send(_ data: Data)
    func close()
    /// Set by the owner. Called on whatever queue the channel reads from.
    var onReceive: (@Sendable (Data) -> Void)? { get set }
    var onClose: (@Sendable () -> Void)? { get set }
}

/// One end of an in-memory channel pair, used by tests and by the loopback harness.
///
/// Writes are delivered synchronously to the peer, which makes timing deterministic:
/// a test that writes a request sees the reply before the call returns.
public final class LoopbackChannel: ByteChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var peer: LoopbackChannel?
    private var closed = false
    /// Everything this end wrote, in order. This is what the *writer's* side of the wire
    /// sent, not what the peer sent back.
    public private(set) var written = Data()
    /// Everything the peer wrote to this end, in order — the inbound byte stream.
    public private(set) var received = Data()

    public var onReceive: (@Sendable (Data) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    public init() {}

    /// Makes two ends talk to each other.
    public static func pair() -> (LoopbackChannel, LoopbackChannel) {
        let a = LoopbackChannel()
        let b = LoopbackChannel()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    public func send(_ data: Data) {
        lock.lock()
        written.append(data)
        let target = peer
        let isClosed = closed
        lock.unlock()
        guard !isClosed, let target else { return }
        target.deliver(data)
    }

    /// Injects bytes as if the peer had written them, recording them as inbound traffic.
    public func deliver(_ data: Data) {
        lock.lock()
        received.append(data)
        lock.unlock()
        onReceive?(data)
    }

    /// Returns and clears the inbound byte stream. Tests assert against this so one
    /// step's reply cannot be confused with the previous step's.
    public func takeReceived() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let out = received
        received = Data()
        return out
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let target = peer
        lock.unlock()
        onClose?()
        target?.peerClosed()
    }

    private func peerClosed() {
        onClose?()
    }
}
