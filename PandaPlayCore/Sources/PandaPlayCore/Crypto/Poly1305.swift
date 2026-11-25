import Foundation

/// Poly1305 one-time authenticator (RFC 8439 §2.5), 5 x 26-bit limbs on UInt64 lanes.
public struct Poly1305 {
    public static let tagSize = 16
    public static let keySize = 32

    private var r0: UInt32 = 0, r1: UInt32 = 0, r2: UInt32 = 0, r3: UInt32 = 0, r4: UInt32 = 0
    private var s0: UInt32 = 0, s1: UInt32 = 0, s2: UInt32 = 0, s3: UInt32 = 0
    private var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0
    private var buffer: [UInt8] = []

    public init(key: Data) {
        precondition(key.count == Poly1305.keySize, "Poly1305 key must be 32 bytes")
        let k = [UInt8](key)
        // Clamp before splitting. The mask is 0x0ffffffc0ffffffc0ffffffc0fffffff
        // applied to the little-endian 128-bit block, so word 0 keeps bits 0..27 and
        // words 1..3 clear bits 0,1 plus the top nibble.
        let t0 = Poly1305.le32(k, 0) & 0x0fff_ffff
        let t1 = Poly1305.le32(k, 4) & 0x0fff_fffc
        let t2 = Poly1305.le32(k, 8) & 0x0fff_fffc
        let t3 = Poly1305.le32(k, 12) & 0x0fff_fffc
        s0 = Poly1305.le32(k, 16)
        s1 = Poly1305.le32(k, 20)
        s2 = Poly1305.le32(k, 24)
        s3 = Poly1305.le32(k, 28)

        r0 = t0 & 0x03ff_ffff
        r1 = ((t0 >> 26) | (t1 << 6)) & 0x03ff_ffff
        r2 = ((t1 >> 20) | (t2 << 12)) & 0x03ff_ffff
        r3 = ((t2 >> 14) | (t3 << 18)) & 0x03ff_ffff
        r4 = t3 >> 8
    }

    public static func tag(key: Data, message: Data) -> Data {
        var poly = Poly1305(key: key)
        poly.update(message)
        return poly.finalize()
    }

    public mutating func update(_ data: Data) {
        buffer.append(contentsOf: data)
        var offset = 0
        while buffer.count - offset >= 16 {
            absorb(Array(buffer[offset..<(offset + 16)]))
            offset += 16
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    public mutating func finalize() -> Data {
        if !buffer.isEmpty {
            let tail = buffer
            buffer.removeAll(keepingCapacity: false)
            absorb(tail)
        }

        var a0 = UInt64(h0), a1 = UInt64(h1), a2 = UInt64(h2), a3 = UInt64(h3), a4 = UInt64(h4)
        var carry = a1 >> 26; a1 &= 0x3ff_ffff; a2 &+= carry
        carry = a2 >> 26; a2 &= 0x3ff_ffff; a3 &+= carry
        carry = a3 >> 26; a3 &= 0x3ff_ffff; a4 &+= carry
        carry = a4 >> 26; a4 &= 0x3ff_ffff; a0 &+= carry
        carry = a0 >> 26; a0 &= 0x3ff_ffff; a1 &+= carry

        // h has two candidate residues: h itself, or h - (2^130 - 5).
        // Compute g = h + 5 - 2^130 in wrapping arithmetic; the borrow out of g4 tells us
        // which residue to keep, and a mask selects it without a branch.
        var g0 = a0 &+ 5
        carry = g0 >> 26; g0 &= 0x3ff_ffff
        var g1 = a1 &+ carry; carry = g1 >> 26; g1 &= 0x3ff_ffff
        var g2 = a2 &+ carry; carry = g2 >> 26; g2 &= 0x3ff_ffff
        var g3 = a3 &+ carry; carry = g3 >> 26; g3 &= 0x3ff_ffff
        let g4 = a4 &+ carry &- (UInt64(1) << 26)

        // g4 wrapped to a huge value when h < p, so its top bit is the borrow.
        let keepG = (g4 >> 63) &- 1
        a0 = (a0 & ~keepG) | (g0 & keepG)
        a1 = (a1 & ~keepG) | (g1 & keepG)
        a2 = (a2 & ~keepG) | (g2 & keepG)
        a3 = (a3 & ~keepG) | (g3 & keepG)
        a4 = (a4 & ~keepG) | ((g4 & 0x3ff_ffff) & keepG)

        let f0 = UInt32(truncatingIfNeeded: a0 | (a1 << 26))
        let f1 = UInt32(truncatingIfNeeded: (a1 >> 6) | (a2 << 20))
        let f2 = UInt32(truncatingIfNeeded: (a2 >> 12) | (a3 << 14))
        let f3 = UInt32(truncatingIfNeeded: (a3 >> 18) | (a4 << 8))

        var w0 = UInt64(f0) &+ UInt64(s0)
        var w1 = UInt64(f1) &+ UInt64(s1) &+ (w0 >> 32); w0 &= 0xffff_ffff
        var w2 = UInt64(f2) &+ UInt64(s2) &+ (w1 >> 32); w1 &= 0xffff_ffff
        let w3 = UInt64(f3) &+ UInt64(s3) &+ (w2 >> 32); w2 &= 0xffff_ffff

        var tag = [UInt8](repeating: 0, count: 16)
        Poly1305.writeLE32(&tag, 0, UInt32(truncatingIfNeeded: w0))
        Poly1305.writeLE32(&tag, 4, UInt32(truncatingIfNeeded: w1))
        Poly1305.writeLE32(&tag, 8, UInt32(truncatingIfNeeded: w2))
        Poly1305.writeLE32(&tag, 12, UInt32(truncatingIfNeeded: w3))
        return Data(tag)
    }

    /// Absorbs up to 16 bytes. A short block carries its 0x01 marker right after the
    /// data; a full block carries it in byte 16.
    private mutating func absorb(_ block: [UInt8]) {
        var padded = [UInt8](repeating: 0, count: 17)
        let take = min(block.count, 16)
        for i in 0..<take { padded[i] = block[i] }
        padded[take] = 0x01

        let t0 = Poly1305.le32(padded, 0)
        let t1 = Poly1305.le32(padded, 4)
        let t2 = Poly1305.le32(padded, 8)
        let t3 = Poly1305.le32(padded, 12)

        let aa0 = UInt64(h0) &+ UInt64(t0 & 0x03ff_ffff)
        let aa1 = UInt64(h1) &+ UInt64(((t0 >> 26) | (t1 << 6)) & 0x03ff_ffff)
        let aa2 = UInt64(h2) &+ UInt64(((t1 >> 20) | (t2 << 12)) & 0x03ff_ffff)
        let aa3 = UInt64(h3) &+ UInt64(((t2 >> 14) | (t3 << 18)) & 0x03ff_ffff)
        let aa4 = UInt64(h4) &+ UInt64((t3 >> 8) | (UInt32(padded[16]) << 24))

        let rr0 = UInt64(r0), rr1 = UInt64(r1), rr2 = UInt64(r2), rr3 = UInt64(r3), rr4 = UInt64(r4)
        let ss1 = rr1 &* 5, ss2 = rr2 &* 5, ss3 = rr3 &* 5, ss4 = rr4 &* 5

        var d0 = aa0 &* rr0 &+ aa1 &* ss4 &+ aa2 &* ss3 &+ aa3 &* ss2 &+ aa4 &* ss1
        var d1 = aa0 &* rr1 &+ aa1 &* rr0 &+ aa2 &* ss4 &+ aa3 &* ss3 &+ aa4 &* ss2
        var d2 = aa0 &* rr2 &+ aa1 &* rr1 &+ aa2 &* rr0 &+ aa3 &* ss4 &+ aa4 &* ss3
        var d3 = aa0 &* rr3 &+ aa1 &* rr2 &+ aa2 &* rr1 &+ aa3 &* rr0 &+ aa4 &* ss4
        var d4 = aa0 &* rr4 &+ aa1 &* rr3 &+ aa2 &* rr2 &+ aa3 &* rr1 &+ aa4 &* rr0

        var carry = d0 >> 26; d0 &= 0x3ff_ffff; d1 &+= carry
        carry = d1 >> 26; d1 &= 0x3ff_ffff; d2 &+= carry
        carry = d2 >> 26; d2 &= 0x3ff_ffff; d3 &+= carry
        carry = d3 >> 26; d3 &= 0x3ff_ffff; d4 &+= carry
        // The overflow out of h4 comes back into h0 multiplied by five, because
        // 2^130 = 5 (mod 2^130 - 5). Folding it in as a plain carry loses that factor.
        carry = d4 >> 26; d4 &= 0x3ff_ffff; d0 &+= carry &* 5
        carry = d0 >> 26; d0 &= 0x3ff_ffff; d1 &+= carry

        h0 = UInt32(d0 & 0x3ff_ffff)
        h1 = UInt32(d1 & 0x3ff_ffff)
        h2 = UInt32(d2 & 0x3ff_ffff)
        h3 = UInt32(d3 & 0x3ff_ffff)
        h4 = UInt32(d4 & 0x3ff_ffff)
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func writeLE32(_ out: inout [UInt8], _ o: Int, _ v: UInt32) {
        out[o] = UInt8(truncatingIfNeeded: v)
        out[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
        out[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
        out[o + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    /// Constant-time comparison for tag verification.
    public static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
