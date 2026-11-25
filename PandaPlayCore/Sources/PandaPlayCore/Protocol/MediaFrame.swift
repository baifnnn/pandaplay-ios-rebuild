import Foundation

/// The 21 command words the media channel actually uses. Values and the odd/even
/// convention (odd = "this is a reply") come from the accessory's dispatch table, not
/// from a spec document.
public enum MediaCommand: UInt32, Sendable {
    case none = 0x0000_0000
    case c2pHello = 0x0001_0000
    case c2pHelloReply = 0x0001_0001
    case controlRequest = 0x0001_0010
    case controlReply = 0x0001_0011
    case controlAck = 0x0001_0020
    case controlStatus = 0x0001_0040
    case controlMode = 0x0001_0200
    case controlAuxiliary = 0x0001_02b0
    case controlTiming = 0x0001_03e0
    case controlKeepalive = 0x0001_0400
    case clockRequest = 0x0001_0450
    case clockReply = 0x0001_0451
    case controlSession = 0x0001_0470
    case controlEvent = 0x0001_0610
    case timingReset = 0x0001_0690
    case timingResetReply = 0x0001_0691
    case p2cHello = 0x0002_0000
    case p2cHelloReply = 0x0002_0001
    case videoPull = 0x0002_0590
    case streamSetup = 0x0003_0000
    case streamSetupReply = 0x0003_0001
    case streamTiming = 0x0003_0020
    case streamTimingAlt = 0x0003_0120
    case streamTimingAux = 0x0003_1020
    case streamMode = 0x0004_0010
    case probe = 0x7000_0000
    case probeReply = 0x7000_0001
    case halt = 0x8000_0010
    case haltAlt = 0x8000_0020
}

/// Coarse classification used by the `known_command` telemetry counter.
public enum MediaCategory: Int, Sendable {
    case unknown = 0
    case c2pHello = 1
    case p2cHello = 2
    case controlRequest = 3
    case timingReset = 4
    case probe = 5
    case controlStatus = 6
    case controlMode = 7
    case controlTiming = 8
    case controlKeepalive = 9
    case controlSession = 10
    case controlEvent = 11
    case clockRequest = 12
    case controlAck = 13
    case streamSetup = 14
    case halt = 15
    case haltAlt = 16
    case reply = 17
    case generic = 18
    case none = 19
    case videoPull = 20
}

public enum MediaFrameStatus: Int, Sendable {
    case ok = 0
    case needMore = 1
    /// The declared total is smaller than a bare header.
    case shortHeader = 2
    case badChecksum = 3
    case frameTooLarge = 4
    case unknownCommand = 5
    case frameLimit = 6
}

/// A signalling frame: 16-byte header plus payload.
///
/// Layout, all big-endian except the trailing auxiliary word:
/// ```
/// +0   uint32 command
/// +4   uint32 totalLength          (payload + 16)
/// +8   uint32 command ^ totalLength
/// +12  uint32 auxiliary            (host order)
/// +16  payload
/// ```
public struct MediaFrame: Equatable, Sendable {
    public static let headerSize = 16
    /// The accessory refuses anything whose total exceeds 0x400, so the largest payload
    /// a sender can produce is 1008 bytes.
    public static let maxSendPayload = 0x3f0
    /// Inbound frames are capped at 0x2000 total unless the lenient flag is set.
    public static let maxReceiveTotal = 0x2000
    public static let lenientReceiveTotal = 0x1000_0000
    /// At most 128 frames may be outstanding in either direction.
    public static let frameLimit = 0x80

    public let command: MediaCommand
    /// The word exactly as it appeared on the wire. `command` falls back to `.none` for a
    /// word the enumeration does not name, so the raw value is the only way to tell
    /// "this sender said zero" from "this sender said something we do not know" — and the
    /// odd/even reply test has to run on the raw word, not the fallback.
    public let rawCommand: UInt32
    public let totalLength: UInt32
    public let auxiliary: UInt32
    public let payload: Data

    public init(command: MediaCommand, auxiliary: UInt32 = 0, payload: Data = Data()) {
        precondition(payload.count <= MediaFrame.maxSendPayload, "payload exceeds the 1008-byte send cap")
        self.command = command
        self.rawCommand = command.rawValue
        self.auxiliary = auxiliary
        self.payload = payload
        self.totalLength = UInt32(payload.count + MediaFrame.headerSize)
    }

    /// Rebuilds a frame from a wire word, keeping the raw value even when the word is not
    /// one the enumeration names.
    init(wireCommand: UInt32, auxiliary: UInt32, payload: Data) {
        self.command = MediaCommand(rawValue: wireCommand) ?? MediaCommand.none
        self.rawCommand = wireCommand
        self.auxiliary = auxiliary
        self.payload = payload
        self.totalLength = UInt32(payload.count + MediaFrame.headerSize)
    }

    /// `true` when the sender used a word this endpoint does not name at all.
    public var isUnknownWord: Bool {
        MediaCommand(rawValue: rawCommand) == nil
    }

    /// `true` when the word is a reply rather than a request. Tested on the raw word so an
    /// unnamed odd value is still recognised as a reply.
    public var isPeerReply: Bool {
        rawCommand & 1 == 1
    }

    public var payloadLength: Int { payload.count }

    public static func checksum(command: UInt32, totalLength: UInt32) -> UInt32 {
        command ^ totalLength
    }

    public func toBytes() -> Data {
        var out = [UInt8](repeating: 0, count: MediaFrame.headerSize + payload.count)
        ByteOrder.writeU32BE(&out, 0, command.rawValue)
        ByteOrder.writeU32BE(&out, 4, totalLength)
        ByteOrder.writeU32BE(&out, 8, MediaFrame.checksum(command: command.rawValue, totalLength: totalLength))
        ByteOrder.writeU32LE(&out, 12, auxiliary)
        if !payload.isEmpty {
            out.replaceSubrange(MediaFrame.headerSize..<out.count, with: payload)
        }
        return Data(out)
    }

    /// Pulls one frame out of `buffer`. `consumed` is 0 unless the status is `.ok`.
    public static func read(
        _ buffer: Data,
        lenient: Bool = false
    ) -> (status: MediaFrameStatus, frame: MediaFrame?, consumed: Int) {
        guard buffer.count >= MediaFrame.headerSize else {
            return (.needMore, nil, 0)
        }
        return buffer.withUnsafeBytes { raw -> (MediaFrameStatus, MediaFrame?, Int) in
            let commandWord = ByteOrder.readU32BE(raw, 0)
            let total = ByteOrder.readU32BE(raw, 4)
            let checksum = ByteOrder.readU32BE(raw, 8)
            let auxiliary = ByteOrder.readU32LE(raw, 12)

            guard checksum == MediaFrame.checksum(command: commandWord, totalLength: total) else {
                return (.badChecksum, nil, 0)
            }
            guard total >= UInt32(MediaFrame.headerSize) else {
                return (.shortHeader, nil, 0)
            }
            let ceiling = lenient ? MediaFrame.lenientReceiveTotal : MediaFrame.maxReceiveTotal
            guard total <= UInt32(ceiling) else {
                return (.frameTooLarge, nil, 0)
            }
            guard buffer.count >= Int(total) else {
                return (.needMore, nil, 0)
            }
            let payloadCount = Int(total) - MediaFrame.headerSize
            let payload = payloadCount > 0
                ? buffer.subdata(in: MediaFrame.headerSize..<Int(total))
                : Data()
            let frame = MediaFrame(wireCommand: commandWord, auxiliary: auxiliary, payload: payload)
            return (.ok, frame, Int(total))
        }
    }

    /// `true` when the word is a command this endpoint recognises. The payload length
    /// matters for the hello words only, which is why it is a parameter.
    public static func isKnown(_ command: MediaCommand, payloadLength: Int = headerSize) -> Bool {
        MediaFrame.categoryOf(command, payloadLength: payloadLength) != .unknown
    }

    public static func categoryOf(_ command: MediaCommand, payloadLength: Int) -> MediaCategory {
        switch command {
        case .halt: return .halt
        case .haltAlt: return .haltAlt
        case .none: return .none
        case .c2pHello: return payloadLength == MediaFrame.headerSize ? .c2pHello : .unknown
        case .p2cHello: return payloadLength == MediaFrame.headerSize ? .p2cHello : .unknown
        case .controlRequest: return .controlRequest
        case .controlAck: return .controlAck
        case .controlStatus: return .controlStatus
        case .controlMode: return .controlMode
        case .controlTiming: return .controlTiming
        case .controlKeepalive: return .controlKeepalive
        case .controlSession: return .controlSession
        case .controlEvent: return .controlEvent
        case .controlAuxiliary: return .generic
        case .clockRequest: return .clockRequest
        case .timingReset: return .timingReset
        case .streamSetup: return .streamSetup
        case .streamMode: return .generic
        case .streamTiming, .streamTimingAlt, .streamTimingAux: return .generic
        case .videoPull: return .videoPull
        case .probe: return .probe
        case .c2pHelloReply, .controlReply, .clockReply, .timingResetReply,
             .p2cHelloReply, .streamSetupReply, .probeReply:
            return .reply
        }
    }

    /// Odd command words are replies. An endpoint never answers a reply, which is what
    /// keeps two peers from ping-ponging acknowledgements forever.
    public static func isReply(_ command: MediaCommand) -> Bool {
        command.rawValue & 1 == 1
    }
}
