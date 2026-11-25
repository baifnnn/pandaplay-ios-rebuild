import Foundation

/// The 8-byte framing layer used on media window slots.
///
/// This is a different protocol from the 16-byte signalling frame: little-endian fields,
/// a reserved word instead of a checksum, and no command/total correlation. The receiver
/// picks one framer per connection at accept time and never mixes them.
///
/// Layout, all little-endian:
/// ```
/// +0  uint16 command
/// +2  uint16 payloadLength
/// +4  uint32 reserved
/// +8  payload
/// ```
public final class MediaWindowFramer {
    public static let headerSize = 8
    public static let maxPayload = 0x1000
    public static let frameLimit = 0x800

    /// Command words on this layer. These are 16-bit and unrelated to `MediaCommand`.
    public static let controlRequest: UInt16 = 0x10
    public static let ready: UInt16 = 0x70
    public static let pull: UInt16 = 0x72

    /// A control request carries at least the capture configuration; anything shorter is
    /// truncated rather than merely small.
    public static let minimumControlRequestPayload = 0x1b
    public static let minimumTouchPayload = 10

    public let kind: FrameChannelKind
    public let slot: Int
    public var surfaceWidth = 0
    public var surfaceHeight = 0
    public var clampsToSurface = true
    public var lenientMode = false

    public private(set) var framesRead = 0
    public private(set) var oversizedFrames = 0
    public private(set) var overflowFrames = 0
    public private(set) var touchAccepted = 0
    public private(set) var touchRejected = 0
    public private(set) var touchClamped = 0
    public private(set) var claimed = false

    /// Records the command that claimed the lane: 0x70 on a control slot, 0x72 on a
    /// video slot.
    public private(set) var claimedCommand: UInt16 = 0

    public var onPayload: ((UInt16, Data) -> Void)?
    public var onTouch: ((TouchPhase, Int, Int) -> Void)?
    public var onLog: ((String) -> Void)?

    private var headerBytes = [UInt8](repeating: 0, count: MediaWindowFramer.headerSize)
    private var headerFilled = 0
    private var inPayload = false
    private var command: UInt16 = 0
    private var payloadLength = 0
    private var reservedWord: UInt32 = 0
    private var payloadBytes: [UInt8] = []
    private var pressed = false
    private var reservedLogged = false

    public init(kind: FrameChannelKind, slot: Int) {
        self.kind = kind
        self.slot = slot
    }

    public var isConfigured: Bool { surfaceWidth > 0 && surfaceHeight > 0 }

    /// Feeds arbitrary bytes. Returns the outcome of the last frame the chunk completed,
    /// or `.accepted` when it completed none — a short chunk is not an error.
    @discardableResult
    public func feed(_ chunk: Data) -> TouchOutcome {
        var outcome = TouchOutcome.accepted
        for byte in chunk {
            if inPayload {
                payloadBytes.append(byte)
                if payloadBytes.count >= payloadLength {
                    outcome = completeFrame()
                }
                continue
            }

            headerBytes[headerFilled] = byte
            headerFilled += 1
            guard headerFilled == MediaWindowFramer.headerSize else { continue }

            let header = Data(headerBytes)
            command = header.withUnsafeBytes { ByteOrder.readU16LE($0, 0) }
            payloadLength = Int(header.withUnsafeBytes { ByteOrder.readU16LE($0, 2) })
            reservedWord = header.withUnsafeBytes { ByteOrder.readU32LE($0, 4) }

            if payloadLength > MediaWindowFramer.maxPayload {
                oversizedFrames += 1
                onLog?("media_window_oversized")
                resetHeader()
                outcome = .invalidAction
                continue
            }
            if framesRead >= MediaWindowFramer.frameLimit && !lenientMode {
                overflowFrames += 1
                onLog?("media_window_overflow")
                resetHeader()
                outcome = .unknownSlot
                continue
            }
            if reservedWord != 0 && !reservedLogged {
                reservedLogged = true
                onLog?(kind == .control ? "media_control_reserved_word" : "media_video_reserved_word")
            }

            headerFilled = 0
            inPayload = true
            payloadBytes = []
            payloadBytes.reserveCapacity(payloadLength)
            if payloadLength == 0 {
                outcome = completeFrame()
            }
        }
        return outcome
    }

    @discardableResult
    private func completeFrame() -> TouchOutcome {
        // Capture the command before the reset clears it: the dispatch below depends on
        // it and `resetPayload` zeroes the field.
        let finished = command
        let body = Data(payloadBytes)
        resetPayload()
        framesRead += 1
        return dispatch(command: finished, payload: body)
    }

    private func dispatch(command finished: UInt16, payload: Data) -> TouchOutcome {
        if !claimed {
            let claims = (kind == .control && finished == MediaWindowFramer.ready)
                || (kind == .video && finished == MediaWindowFramer.pull)
            if claims {
                claimed = true
                claimedCommand = finished
                onLog?(kind == .control ? "media_ready" : "media_pull")
            }
        }

        onPayload?(finished, payload)

        switch finished {
        case MediaWindowFramer.controlRequest:
            return handleControlRequest(payload)
        case MediaWindowFramer.pull:
            return handleTouch(payload)
        case MediaWindowFramer.ready:
            return .accepted
        default:
            return .accepted
        }
    }

    private func handleControlRequest(_ payload: Data) -> TouchOutcome {
        guard payload.count >= MediaWindowFramer.minimumControlRequestPayload else {
            touchRejected += 1
            return .payloadTooShort
        }
        return .accepted
    }

    /// Touch decoding. Four checks in a fixed order: payload length, action validity,
    /// then the gesture rules, then the geometry. Reordering these changes which error a
    /// bad sequence reports, so the order is part of the protocol.
    private func handleTouch(_ payload: Data) -> TouchOutcome {
        guard payload.count >= MediaWindowFramer.minimumTouchPayload else {
            touchRejected += 1
            return .payloadTooShort
        }
        guard let action = payload.withUnsafeBytes({ raw -> TouchAction? in
            TouchAction(rawValue: ByteOrder.readI16BE(raw, 0))
        }) else {
            touchRejected += 1
            return .invalidAction
        }
        let x = Int(payload.withUnsafeBytes { ByteOrder.readI16BE($0, 2) })
        let y = Int(payload.withUnsafeBytes { ByteOrder.readI16BE($0, 4) })

        if action == .cancel {
            pressed = false
            touchAccepted += 1
            onTouch?(.cancel, x, y)
            return .accepted
        }

        if action == .down && pressed {
            touchRejected += 1
            return .duplicateDown
        }
        if action == .move && !pressed {
            touchRejected += 1
            return .moveWithoutDown
        }

        var px = x
        var py = y
        if !isConfigured || px < 0 || py < 0 || px >= surfaceWidth || py >= surfaceHeight {
            let mayClamp = action != .move && lenientMode && clampsToSurface && pressed
            guard mayClamp, isConfigured else {
                touchRejected += 1
                return isConfigured ? .outOfBounds : .notConfigured
            }
            px = min(max(px, 0), surfaceWidth - 1)
            py = min(max(py, 0), surfaceHeight - 1)
            touchClamped += 1
            onLog?("media_touch_clamped")
        }

        pressed = action != .up
        touchAccepted += 1
        onTouch?(TouchPhase(action: action), px, py)
        return .accepted
    }

    private func resetHeader() {
        headerFilled = 0
        inPayload = false
        payloadBytes = []
    }

    private func resetPayload() {
        inPayload = false
        headerFilled = 0
        command = 0
        payloadLength = 0
        reservedWord = 0
        payloadBytes = []
    }

    /// The `media_control_request` telemetry value: which command a lane opened with.
    public func requestCode() -> Int {
        if kind == .control {
            switch claimedCommand {
            case MediaWindowFramer.controlRequest: return 1
            case MediaWindowFramer.ready: return 2
            default: return 4
            }
        }
        switch claimedCommand {
        case MediaWindowFramer.pull: return 3
        default: return 5
        }
    }

    public static func build(command: UInt16, payload: Data, reserved: UInt32 = 0) -> Data {
        precondition(payload.count <= maxPayload, "payload exceeds the 4096-byte window cap")
        var out = [UInt8](repeating: 0, count: headerSize + payload.count)
        ByteOrder.writeU16LE(&out, 0, command)
        ByteOrder.writeU16LE(&out, 2, UInt16(payload.count))
        ByteOrder.writeU32LE(&out, 4, reserved)
        if !payload.isEmpty {
            out.replaceSubrange(headerSize..<out.count, with: payload)
        }
        return Data(out)
    }
}
