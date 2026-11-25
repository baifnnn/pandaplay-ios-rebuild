import Foundation
import Combine
import CoreGraphics
import CoreMedia
import PandaPlayCore

/// Owns everything that runs for one accessory session: the socket listeners, the core
/// receive session, and the decoder feed.
///
/// The core has no idea Network.framework exists; it hands back bytes and expects them to be
/// written. This class is the whole adapter, and it is deliberately the only place in the app
/// that touches both sides.
@MainActor
final class AppSession: ObservableObject {

    enum Status: Equatable {
        case idle
        case listening
        case streaming
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "未启动"
            case .listening: return "等待连接"
            case .streaming: return "已连接"
            case let .failed(reason): return "错误：\(reason)"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lanes: [LaneSummary] = []
    @Published private(set) var framesDecoded = 0
    @Published private(set) var framesRejected = 0
    @Published private(set) var touchAdmitted = 0
    @Published private(set) var keyframeRequests = 0
    @Published private(set) var surfaceSize = CGSize.zero
    @Published private(set) var lastEvent = ""
    @Published private(set) var logLines: [String] = []

    struct LaneSummary: Identifiable, Equatable {
        let id: Int
        let port: UInt16
        let kind: String
        let open: Bool
        let frames: Int
        let bytes: Int
    }

    /// The lane the display is bound to. The controller drives video on the first media lane.
    let primaryVideoSlot = 1

    private let queue = DispatchQueue(label: "pandaplay.session", qos: .userInteractive)
    private var listeners: ListenerSet?
    private var core: ReceiveSession?
    private var host: DisplayHost?
    private var channels: [Int: NetworkChannel] = [:]
    private var presentationClock: CMTime = .zero
    private var frameDuration: CMTime = CMTime(value: 1, timescale: 60)
    private var started = false

    /// Ports the accessory publishes. The original exposes five candidates in its UI even
    /// though the transport layer arms seven listeners; the extra two stay dormant.
    static let candidatePorts: [UInt16] = [7000, 7100, 7101, 7102, 7103]

    weak var display: DisplayView?

    /// Called from the representable's `makeUIView`/`updateUIView`; the session holds the
    /// display weakly, so SwiftUI stays the owner.
    func attach(display view: DisplayView) {
        if display !== view { display = view }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        do {
            let identity = try PairingIdentity.create(identifier: "PandaPlay+", setupCode: "3939")
            let options = ReceiverOptions()
            let log = TelemetryLog(clock: { Int64(ProcessInfo.processInfo.systemUptime * 1000) })
            let host = DisplayHost(owner: self)
            let session = ReceiveSession(options: options, identity: identity, telemetry: log, host: host)
            session.prepare(ports: [7000, 7100, 7101, 7102, 7103])
            // Chain onto the telemetry sink the session installed rather than replacing it,
            // or the core stops logging the moment the UI wants to show anything.
            let coreSink = session.control.onLog
            session.control.onLog = { [weak self] key, value in
                coreSink?(key, value)
                Task { @MainActor in self?.appendLog("\(key)=\(value)") }
            }
            self.host = host
            self.core = session

            let set = ListenerSet(queue: queue)
            set.onConnection = { [weak self] channel, slot in
                Task { @MainActor in self?.adopt(channel, slot: slot) }
            }
            set.onControlReady = { [weak self] port in
                Task { @MainActor in
                    self?.appendLog("bonjour announced on \(port)")
                }
            }
            set.open(
                ports: session.lanes.map(\.port),
                serviceType: options.serviceType,
                serviceName: options.instanceName
            )
            self.listeners = set
            if let failure = set.lastError {
                status = .failed(failure)
            } else {
                status = .listening
            }
            refreshLanes()
        } catch {
            status = .failed("identity: \(error)")
        }
    }

    func stop() {
        for channel in channels.values { channel.close() }
        channels.removeAll()
        listeners?.close()
        listeners = nil
        core = nil
        started = false
        status = .idle
        refreshLanes()
    }

    // MARK: - Wiring

    private func adopt(_ channel: NetworkChannel, slot: Int) {
        guard let core else { return }
        channels[slot] = channel
        channel.onReceive = { [weak self] data in
            Task { @MainActor in self?.ingest(data, slot: slot) }
        }
        channel.onClose = { [weak self] in
            Task { @MainActor in
                self?.channels.removeValue(forKey: slot)
                self?.appendLog("lane \(slot) closed")
                self?.refreshLanes()
            }
        }
        core.markLaneOpen(slot: slot)
        appendLog("lane \(slot) accepted")
        refreshLanes()
    }

    private func ingest(_ data: Data, slot: Int) {
        guard let core, let channel = channels[slot] else { return }
        let reply = core.receive(data, onSlot: slot)
        if !reply.isEmpty {
            channel.send(reply)
        }
        // The pull frame is a separate write the core holds back until the peer's hello
        // established it as the accessory. Draining it here keeps the negotiation in one place.
        if slot == 0, let pull = core.takeControlPull() {
            channel.send(pull)
        }
        if core.state == .streaming {
            status = .streaming
        }
        framesDecoded = core.framesDecoded
        framesRejected = core.framesRejected
        touchAdmitted = core.touchAdmitted
        keyframeRequests = core.keyframeRequests
        refreshLanes()
    }

    // MARK: - Display feed

    fileprivate func deliver(_ accessUnit: Data, on lane: MediaLane) {
        guard let display else { return }
        do {
            let disposition = try AccessUnitClassifier.classify(accessUnit)
            if let record = disposition.record {
                // New parameter sets mean the decoder needs a new format description before
                // it will accept the picture that follows in the same unit.
                if display.configure(sps: record.sps, pps: record.pps) {
                    appendLog("decoder reconfigured \(Int(display.surfaceSize.width))x\(Int(display.surfaceSize.height))")
                    surfaceSize = display.surfaceSize
                } else {
                    appendLog("decoder rejected parameter sets")
                    core?.requestKeyframe(reason: "reconfigure_failed")
                    return
                }
            }
            guard disposition.kind != .parameterSetsOnly else { return }
            presentationClock = CMTimeAdd(presentationClock, frameDuration)
            display.enqueue(accessUnit, presentationTime: presentationClock)
        } catch {
            appendLog("access unit rejected: \(error)")
            core?.rejectFrame("frame_nal_type")
        }
    }

    fileprivate func askForKeyframe(_ reason: String) {
        appendLog("keyframe requested: \(reason)")
    }

    private func refreshLanes() {
        guard let core else {
            lanes = []
            return
        }
        lanes = core.lanes.map {
            LaneSummary(
                id: $0.slot,
                port: $0.port,
                kind: $0.kind == .control ? "控制" : "视频",
                open: $0.isOpen,
                frames: $0.framesReceived,
                bytes: $0.bytesReceived
            )
        }
    }

    private func appendLog(_ line: String) {
        lastEvent = line
        logLines.append(line)
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }

    /// Diagnostics shown in the UI, matching the keys the original logs.
    var snapshot: [(String, String)] {
        guard let core else { return [] }
        return [
            ("transport", "seven_fixed_ipv4_loopback_listeners"),
            ("mode", "continuous"),
            ("poll_hz", "60"),
            ("frames_decoded", "\(core.framesDecoded)"),
            ("frames_rejected", "\(core.framesRejected)"),
            ("authenticated", "\(core.framesAuthenticated)"),
            ("touch", "\(core.touchAdmitted)/\(core.touchWritten)"),
            ("keyframes", "\(core.keyframeRequests)"),
            ("capability", AccessUnitClassifier.capabilityProfile),
            ("audio", "none"),
        ]
    }
}

/// The core's window into the decoder. Held by the session, never by the core alone, so the
/// display feed cannot outlive the object that owns the layer.
final class DisplayHost: ReceiverHost, @unchecked Sendable {
    private weak var owner: AppSession?

    init(owner: AppSession) {
        self.owner = owner
    }

    func deliverAccessUnit(_ accessUnit: Data, on lane: MediaLane) {
        Task { @MainActor [weak owner] in
            owner?.deliver(accessUnit, on: lane)
        }
    }

    func requestKeyframe(reason: String) {
        Task { @MainActor [weak owner] in
            owner?.askForKeyframe(reason)
        }
    }
}
