import Foundation

/// The reply the accessory decides on after one complete inbound frame.
///
/// Mirrors the pairing table in the original dispatcher: a hello opens a lane, odd words
/// are the peer's replies and are never answered, and four commands get exactly one
/// payload-bearing answer each.
public enum MediaReplyKind: Int, Sendable {
    case silent = 0
    case acknowledge
    case handshakeReply
    case controlPayload
    case clockReply
}

public struct MediaReplyDecision: Equatable, Sendable {
    public let kind: MediaReplyKind
    public let reply: MediaCommand
    public let payload: Data
    public let role: Int
    public let diagnostic: String

    public init(kind: MediaReplyKind, reply: MediaCommand = .none, payload: Data = Data(),
                role: Int = 0, diagnostic: String = "") {
        self.kind = kind
        self.reply = reply
        self.payload = payload
        self.role = role
        self.diagnostic = diagnostic
    }

    public var isSilent: Bool { kind == .silent }
}

/// Stateful responder for one media endpoint.
///
/// Every lane carries the same six fields the accessory keeps per connection: handshake
/// state, pending role, armed flag, probe-sent flag, last probe command and the last
/// response timestamp.
public final class MediaResponder {
    public static let helloPayloadLength = MediaFrame.headerSize
    public static let controlBeaconJSON = "{\"control\":1}"

    private struct LaneState {
        var handshakeState = 0
        var pendingRole = 0
        var armed = false
        var probeSent = false
        var lastProbeCommand: UInt32 = 0
        var lastResponseMs: Int64 = 0
    }

    private let laneCount: Int
    private var lanes: [LaneState]
    private var controlReplyStaged = Data()
    private var controlReplyUsed = false
    private var timingResetUsed = false
    public var onLog: ((String, Any) -> Void)?

    public init(laneCount: Int = 7) {
        precondition(laneCount >= 1 && laneCount <= 8, "lane count must be 1...8")
        self.laneCount = laneCount
        self.lanes = Array(repeating: LaneState(), count: laneCount)
    }

    public func roleOf(_ lane: Int) -> Int {
        guard lane >= 0 && lane < laneCount else { return 0 }
        return lanes[lane].pendingRole
    }

    public func isHandshaken(_ lane: Int) -> Bool {
        guard lane >= 0 && lane < laneCount else { return false }
        return lanes[lane].handshakeState != 0
    }

    public func isArmed(_ lane: Int) -> Bool {
        guard lane >= 0 && lane < laneCount else { return false }
        return lanes[lane].armed
    }

    public func markArmed(_ lane: Int) {
        guard lane >= 0 && lane < laneCount else { return }
        lanes[lane].armed = true
    }

    public var isControlReplyUsed: Bool { controlReplyUsed }

    /// Installs the capture configuration a later control reply will carry. The
    /// `takeScreen` command fills this; the reply drains it exactly once.
    public func stageControlReply(_ payload: Data) {
        controlReplyStaged = payload
    }

    public var stagedControlReply: Data { controlReplyStaged }

    /// The one request the accessory originates: a control pull carrying `{"control":1}`.
    public static func buildControlPull() -> MediaFrame {
        MediaFrame(command: .videoPull, payload: Data(controlBeaconJSON.utf8))
    }

    public func respond(
        lane: Int,
        command: MediaCommand,
        payloadLength: Int,
        clock: Int64,
        timeZone: String
    ) -> MediaReplyDecision {
        guard lane >= 0 && lane < laneCount else {
            return MediaReplyDecision(kind: .silent, diagnostic: "lane_out_of_range")
        }

        // Hello must carry exactly one header's worth of payload; anything else is a
        // malformed probe rather than a hello with extra data.
        if command == .c2pHello || command == .p2cHello {
            guard payloadLength == MediaResponder.helloPayloadLength else {
                return MediaReplyDecision(kind: .silent, diagnostic: "hello_payload_length")
            }
            guard lanes[lane].handshakeState == 0 else {
                return MediaReplyDecision(kind: .silent, diagnostic: "duplicate_hello")
            }
            let role = command == .c2pHello ? 1 : 2
            lanes[lane].handshakeState = 1
            lanes[lane].pendingRole = role
            lanes[lane].lastResponseMs = clock
            let reply = MediaCommand(rawValue: command.rawValue | 1) ?? .none
            let diagnostic = role == 1 ? "connection_role_c2p" : "connection_role_p2c"
            return MediaReplyDecision(
                kind: .handshakeReply, reply: reply, role: role, diagnostic: diagnostic
            )
        }

        // Odd words are the peer's replies. Answering one starts an acknowledgement loop.
        if MediaFrame.isReply(command) {
            return MediaReplyDecision(kind: .silent, diagnostic: classifyPeerReply(command))
        }

        guard lanes[lane].armed else {
            return MediaReplyDecision(kind: .silent, diagnostic: "lane_not_armed")
        }

        switch command {
        case .controlRequest:
            guard !controlReplyUsed, !controlReplyStaged.isEmpty else {
                return MediaReplyDecision(kind: .silent, diagnostic: "control_reply_unavailable")
            }
            controlReplyUsed = true
            let payload = controlReplyStaged
            controlReplyStaged = Data()
            return MediaReplyDecision(
                kind: .controlPayload, reply: .controlReply, payload: payload,
                diagnostic: "control_reply_sent"
            )
        case .clockRequest:
            return MediaReplyDecision(
                kind: .clockReply, reply: .clockReply,
                payload: Data(PxcHello.clockEnvelope(time: clock, currentTime: clock, timeZone: timeZone).utf8),
                diagnostic: "clock_reply_sent"
            )
        case .timingReset:
            guard !timingResetUsed else {
                return MediaReplyDecision(kind: .silent, diagnostic: "timing_reset_repeated")
            }
            timingResetUsed = true
            return MediaReplyDecision(
                kind: .acknowledge, reply: .timingResetReply, diagnostic: "timing_reset_sent"
            )
        case .streamSetup:
            return MediaReplyDecision(
                kind: .acknowledge, reply: .streamSetupReply, diagnostic: "stream_setup_acknowledged"
            )
        case .probe:
            return MediaReplyDecision(
                kind: .acknowledge, reply: .probeReply, diagnostic: "probe_acknowledged"
            )
        default:
            guard MediaFrame.isKnown(command) else {
                return MediaReplyDecision(kind: .silent, diagnostic: "unknown_command")
            }
            let reply = MediaCommand(rawValue: command.rawValue | 1) ?? .none
            return MediaReplyDecision(
                kind: .acknowledge, reply: reply, diagnostic: "generic_acknowledge"
            )
        }
    }

    /// Every odd word gets the same telemetry label: the accessory does not distinguish
    /// which reply arrived, only that its probe was answered.
    private func classifyPeerReply(_ command: MediaCommand) -> String {
        "p2c_response"
    }
}
