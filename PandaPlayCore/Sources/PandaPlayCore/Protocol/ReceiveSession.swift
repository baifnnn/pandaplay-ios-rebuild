import Foundation

/// Everything the receiver reads from its environment.
public struct ReceiverOptions: Sendable {
    /// Port the RTSP control endpoint listens on.
    public var controlPort: UInt16 = 7000
    /// First port of the media window band.
    public var mediaPortBase: UInt16 = 7100
    /// How many media ports to open. The accessory opens seven; the UI exposes five.
    public var mediaCandidateCount: Int = 7
    /// Capture surface the controller is told about.
    public var screenWidth: Int = 1920
    public var screenHeight: Int = 1080
    /// Bonjour service type. Not an AirPlay name — see `BonjourAdvertisement`.
    public var serviceType: String = "panda.wireless-car"
    public var instanceName: String = "PandaPlay+"
    /// Whether to answer mDNS queries at all.
    public var advertise: Bool = true
    /// Window a media slot stays open without traffic.
    public var mediaWindowSeconds: Int = 30

    public init() {}

    public static let maximumMediaPorts = 7
    public static let minimumPort: UInt16 = 1025
}

/// Counters and state for one media lane.
public final class MediaLane: @unchecked Sendable {
    public let slot: Int
    public let kind: FrameChannelKind
    public private(set) var port: UInt16 = 0
    public internal(set) var isOpen = false
    public internal(set) var framesReceived = 0
    public internal(set) var bytesReceived = 0
    public internal(set) var framesRejected = 0
    public internal(set) var readyFrames = 0
    public internal(set) var pullFrames = 0
    public internal(set) var touchAccepted = 0
    public internal(set) var touchRejected = 0
    public internal(set) var lastFailure: String?

    init(slot: Int, kind: FrameChannelKind, port: UInt16) {
        self.slot = slot
        self.kind = kind
        self.port = port
    }
}

public enum StreamState: Int, Sendable {
    case idle = 0
    case negotiating = 1
    case streaming = 2
    case paused = 3
    case retired = 4
}

/// Withholds the parts that need Apple frameworks so the protocol layer still builds and
/// tests on a non-Apple host.
///
/// On iOS the real implementation wraps `Network.framework` and `AVSampleBufferDisplayLayer`;
/// everywhere else these are inert. Keeping the seam here is what lets `PandaPlayCore` be
/// verified by `swift test` on this machine instead of only on a Mac.
public protocol ReceiverHost: AnyObject {
    /// Called with each decoded H.264 access unit, in Annex-B or AVCC form as received.
    func deliverAccessUnit(_ accessUnit: Data, on lane: MediaLane)
    /// Called when the receiver decides it needs a keyframe before it can continue.
    func requestKeyframe(reason: String)
}

/// An inert host, used by tests and by the command-line probe.
public final class NullReceiverHost: ReceiverHost {
    public init() {}
    public func deliverAccessUnit(_ accessUnit: Data, on lane: MediaLane) {}
    public func requestKeyframe(reason: String) {}
}

/// The receiver's orchestration layer.
///
/// It owns no sockets. A host feeds it inbound bytes per lane and it does the framing,
/// the response decisions, the touch decode, and the command dispatch; the same code path
/// therefore runs under `swift test`, under the loopback probe, and on the device.
public final class ReceiveSession: @unchecked Sendable {
    public let options: ReceiverOptions
    public let telemetry: TelemetryLog
    public let identity: PairingIdentity?
    public let pairing: PairingSession?
    public let control: ControlServer
    public let responder: MediaResponder
    public let touch: TouchProcessor
    public private(set) var lanes: [MediaLane] = []
    public var host: ReceiverHost

    private let lock = NSLock()
    private var windowFramers: [Int: MediaWindowFramer] = [:]
    private var controlPullSent = false
    private var controlPullPending = false

    public private(set) var state: StreamState = .idle
    public private(set) var framesDecoded = 0
    public private(set) var framesRejected = 0
    public private(set) var framesAuthenticated = 0
    public private(set) var keyframeRequests = 0
    public private(set) var touchAdmitted = 0
    public private(set) var touchWritten = 0
    public private(set) var touchRejected = 0

    /// Last error the session hit, or nil.
    public private(set) var lastError: String?

    public init(
        options: ReceiverOptions = ReceiverOptions(),
        identity: PairingIdentity? = nil,
        telemetry: TelemetryLog = TelemetryLog(),
        host: ReceiverHost = NullReceiverHost()
    ) {
        self.options = options
        self.telemetry = telemetry
        self.identity = identity
        self.pairing = identity.map { PairingSession(identity: $0) }
        self.control = ControlServer()
        self.responder = MediaResponder(laneCount: max(1, min(8, options.mediaCandidateCount)))
        self.touch = TouchProcessor(width: options.screenWidth, height: options.screenHeight)
        self.host = host
        wire()
    }

    private func wire() {
        control.screenWidth = options.screenWidth
        control.screenHeight = options.screenHeight
        control.pairing = pairing
        control.infoProvider = { [weak self] in
            guard let self else { return PlistValue.dict() }
            return InfoPayload.build(
                deviceID: identity?.ed25519Public ?? Data(),
                width: options.screenWidth,
                height: options.screenHeight,
                uuid: identity?.identifier ?? "receiver"
            )
        }
        control.setupHandler = { [weak self] body in self?.handleSetup(body) }
        control.feedbackHandler = { [weak self] body in
            self?.telemetry.emit("feedback", body.entries.count)
            return nil
        }
        control.commandHandler = { [weak self] command in
            self?.handleCommand(command) ?? .unsupported()
        }
        control.onTouch = { [weak self] message in
            self?.admitTouch(message)
        }
        control.onLog = { [weak self] key, value in
            self?.telemetry.emit(key, value)
        }
    }

    // MARK: - Lifecycle

    /// Prepares the lanes. No I/O happens here; the host supplies ports and bytes.
    public func prepare(ports: [UInt16]) {
        let clipped = Array(ports.prefix(ReceiverOptions.maximumMediaPorts))
        var built: [MediaLane] = []
        for (index, port) in clipped.enumerated() {
            let kind: FrameChannelKind = index == 0 ? .control : .video
            built.append(MediaLane(slot: index, kind: kind, port: port))
            if ChannelSlot.usesWindowFraming(slot: index) {
                let framer = MediaWindowFramer(kind: kind, slot: index)
                framer.surfaceWidth = options.screenWidth
                framer.surfaceHeight = options.screenHeight
                framer.onTouch = { [weak self] phase, x, y in
                    self?.windowTouch(phase: phase, x: x, y: y)
                }
                framer.onLog = { [weak self] key in
                    self?.telemetry.emit(key)
                }
                windowFramers[index] = framer
            }
        }
        lanes = built
        state = .negotiating
        telemetry.emit("media_listener_ready", built.count)
        telemetry.emit("usb_projection_transport", "seven_fixed_ipv4_loopback_listeners")
        telemetry.emit("usb_projection_mode", "continuous")
        telemetry.emit("usb_projection_requested", true)
        telemetry.emit("usb_projection_worker_active", true)
        telemetry.emit("frame_delivery_poll_hz", 60)
    }

    public func markLaneOpen(slot: Int) {
        guard let lane = lane(slot) else { return }
        lane.isOpen = true
        telemetry.emit("receiver_control_tcp_connected", true)
        telemetry.emit("receiver_control_tcp_connections", lanes.filter(\.isOpen).count)
    }

    public func lane(_ slot: Int) -> MediaLane? {
        lanes.first { $0.slot == slot }
    }

    public func retire(_ reason: String) {
        state = .retired
        telemetry.emit("media_window_closed", reason)
    }

    // MARK: - Inbound traffic

    /// Feeds one chunk of inbound bytes for a lane and returns the bytes to write back.
    ///
    /// Signalling lanes return zero or more complete replies; window lanes never reply,
    /// because that channel is one-directional by construction.
    public func receive(_ data: Data, onSlot slot: Int) -> Data {
        guard let lane = lane(slot) else {
            lastError = "unknown_lane"
            return Data()
        }
        lane.bytesReceived += data.count
        telemetry.emit("connection\(slot + 1)_received_total", lane.bytesReceived)

        if let framer = windowFramers[slot] {
            let outcome = framer.feed(data)
            // The framer owns the touch counters; copy them every time, because a rejected
            // gesture still has to show up on the lane.
            lane.framesReceived = framer.framesRead
            lane.touchAccepted = framer.touchAccepted
            lane.touchRejected = framer.touchRejected
            if !outcome.isSuccess {
                lane.framesRejected += 1
                telemetry.emit("media_window_rejected", outcome.label)
            }
            return Data()
        }

        var outbound = Data()
        var buffer = data
        while !buffer.isEmpty {
            let result = MediaFrame.read(buffer)
            switch result.status {
            case .ok:
                // A `.ok` status with no frame would otherwise re-enter this loop forever:
                // `break` inside a `switch` leaves the switch, not the enclosing `while`.
                guard let frame = result.frame, result.consumed > 0 else { return outbound }
                lane.framesReceived += 1
                telemetry.emit("connection\(slot + 1)_frame_length", frame.payloadLength)
                telemetry.emit("connection\(slot + 1)_frame_complete", true)
                let reply = handle(frame: frame, on: lane)
                if !reply.isEmpty { outbound.append(reply) }
                buffer = buffer.subdata(in: result.consumed..<buffer.count)
            case .needMore:
                return outbound
            default:
                lane.framesRejected += 1
                lane.lastFailure = "framing:\(result.status)"
                telemetry.emit("receiver_rejected_frames", framesRejected + 1)
                lastError = lane.lastFailure
                return outbound
            }
        }
        return outbound
    }

    private func handle(frame: MediaFrame, on lane: MediaLane) -> Data {
        let payloadLength = frame.payload.count

        // Video lane: a pull frame carries an H.264 access unit.
        if lane.kind == .video {
            guard frame.command == .videoPull else {
                if frame.isUnknownWord || !MediaFrame.isKnown(frame.command, payloadLength: payloadLength) {
                    rejectFrame("frame_nal_type")
                }
                return Data()
            }
            lane.pullFrames += 1
            return deliver(accessUnit: frame.payload, on: lane)
        }

        // A control request is the touch carrier when its payload is at least a touch
        // sample; an empty one is the controller asking for the staged control body.
        if frame.command == .controlRequest, let message = TouchMessage.parse(frame.payload) {
            admitTouch(message)
            return Data()
        }
        if frame.command == .videoPull {
            lane.pullFrames += 1
            return deliver(accessUnit: frame.payload, on: lane)
        }

        // The reply test and the unknown-word test have to run on the raw word: an odd
        // value the enumeration does not name still falls back to `.none` above, and
        // answering it would start an acknowledgement loop.
        if frame.isPeerReply {
            telemetry.emit("connection\(lane.slot + 1)_write_category", "p2c_response")
            telemetry.emit("p2c_response", lane.slot)
            return Data()
        }
        if frame.isUnknownWord {
            telemetry.emit("connection\(lane.slot + 1)_write_category", "unknown_command")
            rejectFrame("frame_nal_type")
            return Data()
        }

        let decision = responder.respond(
            lane: lane.slot,
            command: frame.command,
            payloadLength: payloadLength,
            clock: Int64(Date().timeIntervalSince1970 * 1000),
            timeZone: TimeZone.current.identifier
        )
        guard !decision.isSilent else {
            telemetry.emit("connection\(lane.slot + 1)_write_category", decision.diagnostic)
            if decision.diagnostic == "p2c_response" {
                telemetry.emit("p2c_response", lane.slot)
            }
            return Data()
        }

        let reply = MediaFrame(command: decision.reply, payload: decision.payload).toBytes()
        telemetry.emit("connection\(lane.slot + 1)_write_category", decision.diagnostic)
        telemetry.emit("connection\(lane.slot + 1)_write_sent", reply.count)
        telemetry.emit("media_tx_total", reply.count)

        if decision.kind == .handshakeReply {
            responder.markArmed(lane.slot)
            lane.readyFrames += 1
            framesAuthenticated += 1
            telemetry.emit("receiver_authenticated_frames", framesAuthenticated)
            telemetry.emit("receiver_session_setup", responder.roleOf(lane.slot))
            // Taking role two means the receiver now drives. The pull is queued rather than
            // appended here so the transport can flush it on its own schedule.
            if responder.roleOf(lane.slot) == 2 {
                controlPullPending = true
            }
        }
        return reply
    }

    /// The one request the receiver starts on its own: ask the controller for a control
    /// frame. Returns nil when nothing is queued or the pull already went out.
    public func takeControlPull() -> Data? {
        guard controlPullPending, !controlPullSent else { return nil }
        controlPullPending = false
        controlPullSent = true
        telemetry.emit("media_negotiation", 1)
        return MediaResponder.buildControlPull().toBytes()
    }

    private func deliver(accessUnit: Data, on lane: MediaLane) -> Data {
        guard !accessUnit.isEmpty else {
            rejectFrame("frame_missing_slice")
            return Data()
        }
        framesDecoded += 1
        telemetry.emit("receiver_decoded_frames", framesDecoded)
        telemetry.emit("receiver_packet_processing", accessUnit.count)
        host.deliverAccessUnit(accessUnit, on: lane)
        return Data()
    }

    private func rejectFrame(_ reason: String) {
        framesRejected += 1
        telemetry.emit("receiver_rejected_frames", framesRejected)
        telemetry.emit("receiver_video_failure_reason", reason)
        lastError = reason
        if reason == "frame_missing_slice" {
            requestKeyframe(reason: reason)
        }
    }

    public func requestKeyframe(reason: String) {
        keyframeRequests += 1
        telemetry.emit("receiver_keyframe_command_requested", keyframeRequests)
        telemetry.emit("receiver_keyframe_command_reason", reason)
        host.requestKeyframe(reason: reason)
    }

    // MARK: - Touch

    private func admitTouch(_ message: TouchMessage) {
        let result = touch.apply(message)
        switch result.outcome {
        case .accepted, .payloadTooShort:
            touchAdmitted += 1
            touchWritten += 1
            telemetry.emit("receiver_touch_admitted_count", touchAdmitted)
            telemetry.emit("receiver_touch_written_count", touchWritten)
            telemetry.emit("media_touch_\(result.effective.action.label)", true)
            if touch.clampedCount > 0 {
                telemetry.emit("media_touch_clamped", touch.clampedCount)
            }
        default:
            touchRejected += 1
            telemetry.emit("receiver_touch_rejected_count", touchRejected)
            telemetry.emit("media_touch_rejected", result.outcome.label)
        }
    }

    private func windowTouch(phase: TouchPhase, x: Int, y: Int) {
        touchAdmitted += 1
        touchWritten += 1
        telemetry.emit("receiver_touch_admitted_count", touchAdmitted)
        telemetry.emit("receiver_touch_written_count", touchWritten)
        telemetry.emit("media_touch_\(phase.action.label)", true)
        admitTouch(TouchMessage(action: phase.action, x: x, y: y))
    }

    // MARK: - RTSP handlers

    private func handleSetup(_ body: PlistValue) -> PlistValue? {
        guard let streams = body.tryGet("streams"), streams.kind == .array, !streams.items.isEmpty else {
            telemetry.emit("stream_setup_rejection", "empty_streams")
            return nil
        }
        guard streams.items.count <= lanes.count else {
            telemetry.emit("stream_setup_rejection", "unsupported_stream_count")
            return nil
        }
        var reply: [PlistValue] = []
        for (index, stream) in streams.items.enumerated() {
            guard stream.kind == .dictionary else {
                telemetry.emit("stream_setup_rejection", "invalid_stream_dictionary")
                return nil
            }
            let type = stream.getInteger("type", 110)
            let lane = lanes[min(index, max(0, lanes.count - 1))]
            reply.append(
                PlistValue.dict()
                    .add("type", .from(type))
                    .add("dataPort", .from(Int64(lane.port)))
                    .add("controlPort", .from(Int64(lane.port)))
                    .add("streamConnectionID", .from(Int64(index)))
            )
        }
        state = .streaming
        telemetry.emit("receiver_session_setup", reply.count)
        return PlistValue.dict().add("streams", .array(reply))
    }

    private func handleCommand(_ command: ControlCommand) -> CommandResult {
        switch command.internalType {
        case "take_screen":
            control.screenConfigured = true
            telemetry.emit("capture_configuration", "\(options.screenWidth)x\(options.screenHeight)")
            return .accepted(
                status: 0,
                extras: PlistValue.dict()
                    .add("width", .from(Int64(options.screenWidth)))
                    .add("height", .from(Int64(options.screenHeight)))
                    .add("orientation", .from(1))
            )
        case "release_screen":
            control.screenConfigured = false
            state = .paused
            telemetry.emit("media_window_closed", "release_screen")
            return .accepted()
        case "request_ui", "modes_changed", "hid_set_input_mode", "disable_bluetooth":
            return .accepted()
        case "force_key_frame":
            requestKeyframe(reason: "force_key_frame")
            return .accepted()
        case "duck_audio":
            telemetry.emit("receiver_audio_ownership_policy", "duck")
            return .accepted()
        case "unduck_audio":
            telemetry.emit("receiver_audio_ownership_policy", "unduck")
            return .accepted()
        case "update_feedback":
            telemetry.emit("feedback", "update")
            return .accepted()
        case "hid_copy_input_mode":
            telemetry.emit("hidCopyInputMode", true)
            return .accepted()
        default:
            return .unsupported()
        }
    }

    // MARK: - Diagnostics

    /// Emits the one-shot counters the accessory reports at the end of a session.
    public func emitSnapshot() {
        telemetry.emit("receiver_bonjour_registering", false)
        telemetry.emit("receiver_frame_mailbox_taken", 0)
        telemetry.emit("receiver_frame_mailbox_overwritten", 0)
        telemetry.emit("protocol_ledger_count", framesDecoded + framesRejected)
        telemetry.emit("receiver_decoder_recovery_policy", "await_keyframe_then_resume")
        telemetry.emit("receiver_capability_profile", "car_h264_full_initial_arbitration_no_audio_v3")
        telemetry.emit("receiver_modes_scope", "per_channel_observed_not_global_owner")
        telemetry.emit("receiver_audio_ownership_policy",
                       "initial_arbitration_screen_audio_inactive_apps_no_audio_streams")
        telemetry.emit("usb_projection_last_preparation_failure", "none")
    }

    /// Cached Bonjour advertisement for this session.
    public func advertisement(host: String, address: UInt32) -> BonjourAdvertisement {
        BonjourAdvertisement(
            serviceType: options.serviceType,
            instanceName: options.instanceName,
            port: options.controlPort,
            hostName: host,
            address: address
        )
    }
}
