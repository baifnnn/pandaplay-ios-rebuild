import Foundation

/// Touch actions as they appear on the wire. The values are the accessory's, and note
/// that they are *not* the same numbers the callback uses — see `TouchPhase`.
public enum TouchAction: Int16, Sendable {
    case down = 1
    case move = 2
    case up = 3
    case cancel = 4

    /// Label used in `media_touch_<label>` telemetry.
    public var label: String {
        switch self {
        case .down: return "down"
        case .move: return "move"
        case .up: return "up"
        case .cancel: return "cancel"
        }
    }
}

/// The phase codes handed to the touch consumer. Cancel stays at 4 while the three
/// ordinary phases are renumbered from zero, which is what makes `move == 0` a valid
/// check in the original.
public enum TouchPhase: Int, Sendable {
    case move = 0
    case down = 1
    case up = 2
    case cancel = 4

    public init(action: TouchAction) {
        switch action {
        case .down: self = .down
        case .move: self = .move
        case .up: self = .up
        case .cancel: self = .cancel
        }
    }

    public var action: TouchAction {
        switch self {
        case .down: return .down
        case .move: return .move
        case .up: return .up
        case .cancel: return .cancel
        }
    }

    /// Label used in `media_touch_<label>` telemetry.
    public var label: String {
        switch self {
        case .down: return "down"
        case .move: return "move"
        case .up: return "up"
        case .cancel: return "cancel"
        }
    }
}

/// A decoded touch sample. Coordinates are signed because the wire form is a signed
/// 16-bit big-endian pair and a bad sender can put a negative in there.
public struct TouchMessage: Equatable, Sendable {
    public static let payloadSize = 16
    public static let minimumSize = 10

    public let action: TouchAction
    public let x: Int
    public let y: Int
    public let field2: Int
    public let slot: Int

    public init(action: TouchAction, x: Int, y: Int, field2: Int = 0, slot: Int = 0) {
        self.action = action
        self.x = x
        self.y = y
        self.field2 = field2
        self.slot = slot
    }

    /// Layout inside a 0x10 control-request payload: action, x, y, then a second pair.
    /// All four fields are big-endian 16-bit, which is why `ByteOrder.readI16BE` exists.
    public static func parse(_ payload: Data) -> TouchMessage? {
        guard payload.count >= minimumSize else { return nil }
        return payload.withUnsafeBytes { raw -> TouchMessage? in
            let actionRaw = ByteOrder.readI16BE(raw, 0)
            guard let action = TouchAction(rawValue: actionRaw) else { return nil }
            return TouchMessage(
                action: action,
                x: Int(ByteOrder.readI16BE(raw, 2)),
                y: Int(ByteOrder.readI16BE(raw, 4)),
                field2: Int(ByteOrder.readI16BE(raw, 6))
            )
        }
    }

    public func toPayload() -> Data {
        var out = [UInt8](repeating: 0, count: TouchMessage.minimumSize)
        ByteOrder.writeI16BE(&out, 0, action.rawValue)
        ByteOrder.writeI16BE(&out, 2, Int16(clamping: x))
        ByteOrder.writeI16BE(&out, 4, Int16(clamping: y))
        ByteOrder.writeI16BE(&out, 6, Int16(clamping: field2))
        return Data(out)
    }

    /// Wraps the sample in a signalling control request, the form used on slots 0 and 1.
    public func toFrame() -> MediaFrame {
        MediaFrame(command: .controlRequest, payload: toPayload())
    }
}

/// Result code for a touch attempt. A struct rather than an enum because the accessory
/// returns `0` for both "accepted" and "payload too short"; Swift rejects duplicate
/// enum raw values, and dropping either name would lose a real distinction.
public struct TouchOutcome: RawRepresentable, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let accepted = TouchOutcome(rawValue: 0)
    public static let payloadTooShort = TouchOutcome(rawValue: 0)
    public static let notConfigured = TouchOutcome(rawValue: 1)
    public static let invalidAction = TouchOutcome(rawValue: 2)
    public static let outOfBounds = TouchOutcome(rawValue: 4)
    public static let moveWithoutDown = TouchOutcome(rawValue: 5)
    public static let duplicateDown = TouchOutcome(rawValue: 6)
    public static let unknownSlot = TouchOutcome(rawValue: 7)

    public var isSuccess: Bool { rawValue == 0 }

    public var label: String {
        switch rawValue {
        case 0: return "accepted"
        case 1: return "not_configured"
        case 2: return "invalid_action"
        case 4: return "out_of_bounds"
        case 5: return "move_without_down"
        case 6: return "duplicate_down"
        case 7: return "unknown_slot"
        default: return "code_\(rawValue)"
        }
    }
}

/// Stateful touch validation for one surface.
///
/// The order of the checks is load bearing and matches the accessory: length, then
/// action validity, then the gesture rules, and only then the geometry. A second down
/// out of bounds is a duplicate down, not an out-of-bounds sample.
public final class TouchProcessor {
    public let width: Int
    public let height: Int
    public var clampsToSurface: Bool
    public private(set) var clampedCount = 0
    public private(set) var sentCount = 0
    public private(set) var rejectedCount = 0
    public private(set) var coalescedMoves = 0

    private var pressed = false
    private var lastX = Int.min
    private var lastY = Int.min

    public init(width: Int, height: Int, clampsToSurface: Bool = true) {
        self.width = width
        self.height = height
        self.clampsToSurface = clampsToSurface
    }

    public var isConfigured: Bool { width > 0 && height > 0 }

    public func apply(_ message: TouchMessage) -> (outcome: TouchOutcome, effective: TouchMessage) {
        guard isConfigured else {
            rejectedCount += 1
            return (.notConfigured, message)
        }

        if message.action == .cancel {
            pressed = false
            sentCount += 1
            return (.accepted, message)
        }

        if message.action == .down, pressed {
            rejectedCount += 1
            return (.duplicateDown, message)
        }
        if message.action == .move, !pressed {
            rejectedCount += 1
            return (.moveWithoutDown, message)
        }

        var x = message.x
        var y = message.y
        var moved = false
        if x < 0 || y < 0 || x >= width || y >= height {
            let mayClamp = message.action != .move && clampsToSurface && pressed
            guard mayClamp else {
                rejectedCount += 1
                return (.outOfBounds, message)
            }
            x = min(max(x, 0), width - 1)
            y = min(max(y, 0), height - 1)
            clampedCount += 1
            moved = true
        }

        if message.action == .move, !moved, x == lastX, y == lastY {
            coalescedMoves += 1
            return (.accepted, TouchMessage(action: .move, x: x, y: y))
        }

        lastX = x
        lastY = y
        if message.action == .up { pressed = false } else if message.action == .down { pressed = true }
        sentCount += 1
        return (.accepted, TouchMessage(action: message.action, x: x, y: y))
    }
}
