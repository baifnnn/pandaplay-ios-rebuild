import Foundation

/// The two framing layers in the media channel.
///
/// Slot 0 and 1 carry *signalling* frames with a 16-byte header. Slots 2 and 3 carry
/// *media window* frames with an 8-byte header. They never share a socket, so the two
/// framers live in separate types and a connection picks one at accept time.
public enum FrameChannelKind: Int, Sendable {
    case control = 0
    case video = 1
}

public enum ChannelSlot {
    /// Slots below this index use the 16-byte signalling header.
    public static let windowThreshold = 2

    public static func usesWindowFraming(slot: Int) -> Bool {
        slot >= windowThreshold
    }

    public static func kindOf(slot: Int) -> FrameChannelKind {
        slot == 0 ? .control : .video
    }
}
