import Foundation

/// Little/big endian accessors that never depend on the host byte order.
public enum ByteOrder {
    public static func readU16LE(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    public static func readU32LE(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
        UInt32(b[o])
            | (UInt32(b[o + 1]) << 8)
            | (UInt32(b[o + 2]) << 16)
            | (UInt32(b[o + 3]) << 24)
    }

    public static func readU64LE(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
        UInt64(readU32LE(b, o)) | (UInt64(readU32LE(b, o + 4)) << 32)
    }

    public static func readU32BE(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24)
            | (UInt32(b[o + 1]) << 16)
            | (UInt32(b[o + 2]) << 8)
            | UInt32(b[o + 3])
    }

    /// Touch coordinates travel as big-endian int16, so signed widening is explicit.
    public static func readI16BE(_ b: UnsafeRawBufferPointer, _ o: Int) -> Int16 {
        Int16(bitPattern: (UInt16(b[o]) << 8) | UInt16(b[o + 1]))
    }

    public static func readI16BE(_ b: [UInt8], _ o: Int) -> Int16 {
        Int16(bitPattern: (UInt16(b[o]) << 8) | UInt16(b[o + 1]))
    }

    public static func writeU16LE(_ out: inout [UInt8], _ o: Int, _ v: UInt16) {
        out[o] = UInt8(truncatingIfNeeded: v)
        out[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }

    public static func writeU32LE(_ out: inout [UInt8], _ o: Int, _ v: UInt32) {
        out[o] = UInt8(truncatingIfNeeded: v)
        out[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
        out[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
        out[o + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    public static func writeU64LE(_ out: inout [UInt8], _ o: Int, _ v: UInt64) {
        writeU32LE(&out, o, UInt32(truncatingIfNeeded: v))
        writeU32LE(&out, o + 4, UInt32(truncatingIfNeeded: v >> 32))
    }

    public static func writeU32BE(_ out: inout [UInt8], _ o: Int, _ v: UInt32) {
        out[o] = UInt8(truncatingIfNeeded: v >> 24)
        out[o + 1] = UInt8(truncatingIfNeeded: v >> 16)
        out[o + 2] = UInt8(truncatingIfNeeded: v >> 8)
        out[o + 3] = UInt8(truncatingIfNeeded: v)
    }

    public static func writeI16BE(_ out: inout [UInt8], _ o: Int, _ v: Int16) {
        let u = UInt16(bitPattern: v)
        out[o] = UInt8(truncatingIfNeeded: u >> 8)
        out[o + 1] = UInt8(truncatingIfNeeded: u)
    }

    public static func concat(_ parts: [Data]) -> Data {
        var total = 0
        for part in parts { total += part.count }
        var out = Data(capacity: total)
        for part in parts { out.append(part) }
        return out
    }
}
