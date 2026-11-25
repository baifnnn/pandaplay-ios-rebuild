import Foundation

/// Arbitrary-precision unsigned integer: little-endian 32-bit limbs, no trailing zero
/// limb. Only the operations SRP-6a and the curve code need are here.
///
/// Division is Knuth algorithm D over 32-bit limbs. A 3072-bit modexp costs roughly
/// 4,600 multiplies plus divisions on ~96-limb values, which stays well under a second
/// even unoptimized, so there is no Montgomery layer.
public struct BigUInt: Equatable, Comparable, CustomStringConvertible {
    public private(set) var limbs: [UInt32]

    public init() { limbs = [] }

    public init(_ value: UInt64) {
        if value == 0 {
            limbs = []
        } else if value <= UInt64(UInt32.max) {
            limbs = [UInt32(value)]
        } else {
            limbs = [UInt32(value & 0xffff_ffff), UInt32(value >> 32)]
        }
    }

    public init(limbs raw: [UInt32]) {
        limbs = raw
        normalize()
    }

    /// Big-endian magnitude, the order every wire format here uses.
    public init(bigEndian data: Data) {
        var value = BigUInt()
        for byte in data {
            value = value.shiftedLeft(8)
            value.addSmall(UInt32(byte))
        }
        self = value
    }

    /// Little-endian magnitude. RFC 7748 and RFC 8032 both put the least significant
    /// byte first, so the curve code reads and writes through these two helpers.
    public init(littleEndian data: Data) {
        self.init(bigEndian: Data(data.reversed()))
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    public var isZero: Bool { limbs.isEmpty }

    public var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return limbs.count * 32 - last.leadingZeroBitCount
    }

    public var description: String {
        toBigEndianData().map { String(format: "%02x", $0) }.joined()
    }

    public func toBigEndianData() -> Data {
        guard !isZero else { return Data() }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            bytes.append(UInt8((limb >> 24) & 0xff))
            bytes.append(UInt8((limb >> 16) & 0xff))
            bytes.append(UInt8((limb >> 8) & 0xff))
            bytes.append(UInt8(limb & 0xff))
        }
        var start = 0
        while start < bytes.count - 1 && bytes[start] == 0 { start += 1 }
        return Data(bytes[start...])
    }

    /// Fixed-width big-endian, left padded. SRP and the field code need constant length.
    public func toBigEndianData(paddedTo width: Int) -> Data {
        let raw = toBigEndianData()
        if raw.count >= width { return raw.suffix(width) }
        var out = Data(repeating: 0, count: width - raw.count)
        out.append(raw)
        return out
    }

    public static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            if lhs.limbs[i] != rhs.limbs[i] { return lhs.limbs[i] < rhs.limbs[i] }
        }
        return false
    }

    public static func == (lhs: BigUInt, rhs: BigUInt) -> Bool { lhs.limbs == rhs.limbs }

    private mutating func addSmall(_ value: UInt32) {
        guard value != 0 else { return }
        if limbs.isEmpty { limbs = [value]; return }
        var carry = value
        var i = 0
        while carry != 0 && i < limbs.count {
            let (sum, overflow) = limbs[i].addingReportingOverflow(carry)
            limbs[i] = sum
            carry = overflow ? 1 : 0
            i += 1
        }
        if carry != 0 { limbs.append(carry) }
    }

    public func shiftedLeft(_ bits: Int) -> BigUInt {
        guard !isZero, bits > 0 else { return self }
        let limbShift = bits / 32
        let bitShift = UInt32(bits % 32)
        var out = [UInt32](repeating: 0, count: limbs.count + limbShift + 1)
        for i in 0..<limbs.count {
            let v = limbs[i]
            if bitShift == 0 {
                out[i + limbShift] |= v
            } else {
                out[i + limbShift] |= v << bitShift
                out[i + limbShift + 1] |= v >> (32 - bitShift)
            }
        }
        return BigUInt(limbs: out)
    }

    public func shiftedRight(_ bits: Int) -> BigUInt {
        guard !isZero, bits > 0 else { return self }
        let limbShift = bits / 32
        let bitShift = UInt32(bits % 32)
        guard limbShift < limbs.count else { return BigUInt() }
        var out = [UInt32](repeating: 0, count: limbs.count - limbShift)
        for i in 0..<out.count {
            let src = i + limbShift
            var v = limbs[src]
            if bitShift != 0 {
                v >>= bitShift
                if src + 1 < limbs.count { v |= limbs[src + 1] << (32 - bitShift) }
            }
            out[i] = v
        }
        return BigUInt(limbs: out)
    }

    public static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let n = max(lhs.limbs.count, rhs.limbs.count)
        var out = [UInt32](repeating: 0, count: n + 1)
        var carry: UInt32 = 0
        for i in 0..<n {
            let a = i < lhs.limbs.count ? lhs.limbs[i] : 0
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (s1, o1) = a.addingReportingOverflow(b)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        out[n] = carry
        return BigUInt(limbs: out)
    }

    /// Requires `lhs >= rhs`.
    public static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction underflow")
        var out = [UInt32](repeating: 0, count: lhs.limbs.count)
        var borrow: UInt32 = 0
        for i in 0..<lhs.limbs.count {
            let a = lhs.limbs[i]
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (d1, o1) = a.subtractingReportingOverflow(b)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        return BigUInt(limbs: out)
    }

    public static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return BigUInt() }
        var out = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count + 1)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            let a = UInt64(lhs.limbs[i])
            for j in 0..<rhs.limbs.count {
                let product = a * UInt64(rhs.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            // The carry has to be added, not stored: an earlier row may already have
            // left a value in this slot, and dropping it loses a limb of the product.
            var k = i + rhs.limbs.count
            while carry != 0 {
                let sum = UInt64(out[k]) + carry
                out[k] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                k += 1
            }
        }
        return BigUInt(limbs: out)
    }

    /// Knuth algorithm D. Returns (quotient, remainder).
    ///
    /// The quotient digit is estimated from the top two limbs of the running remainder
    /// and then corrected downwards by actually subtracting. Estimating and trusting the
    /// estimate is what makes hand-rolled versions of this return remainders that are
    /// larger than the divisor, which then poisons every later modPow.
    public func divided(by divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "division by zero")
        if self < divisor { return (BigUInt(), self) }
        if divisor.limbs.count == 1 { return dividedBySingleLimb(divisor.limbs[0]) }

        let n = divisor.limbs.count
        let m = limbs.count - n
        let shift = divisor.limbs[n - 1].leadingZeroBitCount
        let v = divisor.shiftedLeft(shift).limbs
        precondition(v.count == n, "normalised divisor changed width")

        var u = self.shiftedLeft(shift).limbs
        while u.count < limbs.count + 1 { u.append(0) }
        if u.count > limbs.count + 1 { u = Array(u.prefix(limbs.count + 1)) }

        var q = [UInt32](repeating: 0, count: m + 1)
        let base = UInt64(1) << 32

        for j in stride(from: m, through: 0, by: -1) {
            let numerator = (UInt64(u[j + n]) << 32) | UInt64(u[j + n - 1])
            var qhat = numerator / UInt64(v[n - 1])
            var rhat = numerator % UInt64(v[n - 1])

            // Refine the estimate against the next divisor limb. Without this the digit
            // can be several too large and the add-back path only tolerates one.
            while true {
                if qhat >= base {
                    qhat -= 1
                    rhat += UInt64(v[n - 1])
                    if rhat >= base { break }
                    continue
                }
                let lhs = qhat * UInt64(v[n - 2])
                let rhs = (rhat << 32) | UInt64(u[j + n - 2])
                if lhs > rhs {
                    qhat -= 1
                    rhat += UInt64(v[n - 1])
                    if rhat >= base { break }
                    continue
                }
                break
            }

            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let product = qhat * UInt64(v[i]) + carry
                carry = product >> 32
                let low = Int64(product & 0xffff_ffff)
                var diff = Int64(u[j + i]) - low + borrow
                if diff < 0 {
                    diff += Int64(base)
                    borrow = -1
                } else {
                    borrow = 0
                }
                u[j + i] = UInt32(truncatingIfNeeded: diff)
            }
            var top = Int64(u[j + n]) - Int64(carry) + borrow
            if top < 0 {
                top += Int64(base)
                borrow = -1
            } else {
                borrow = 0
            }
            u[j + n] = UInt32(truncatingIfNeeded: top)

            if borrow != 0 {
                // The digit was still one too large: add the divisor back.
                var addCarry: UInt64 = 0
                for i in 0..<n {
                    let sum = UInt64(u[j + i]) + UInt64(v[i]) + addCarry
                    u[j + i] = UInt32(truncatingIfNeeded: sum)
                    addCarry = sum >> 32
                }
                u[j + n] = UInt32(truncatingIfNeeded: UInt64(u[j + n]) + addCarry)
                qhat -= 1
            }
            q[j] = UInt32(truncatingIfNeeded: qhat)
        }

        var remainder = BigUInt(limbs: Array(u[0..<n]))
        if shift > 0 { remainder = remainder.shiftedRight(shift) }
        return (BigUInt(limbs: q), remainder)
    }

    private func dividedBySingleLimb(_ d: UInt32) -> (quotient: BigUInt, remainder: BigUInt) {
        var q = [UInt32](repeating: 0, count: limbs.count)
        var remainder: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let cur = (remainder << 32) | UInt64(limbs[i])
            q[i] = UInt32(cur / UInt64(d))
            remainder = cur % UInt64(d)
        }
        return (BigUInt(limbs: q), BigUInt(UInt64(remainder)))
    }

    public func mod(_ m: BigUInt) -> BigUInt { divided(by: m).remainder }

    /// Square-and-multiply. Slower than Montgomery but far simpler to keep correct.
    public func modPow(_ exponent: BigUInt, _ modulus: BigUInt) -> BigUInt {
        guard !modulus.isZero else { return BigUInt() }
        if modulus == BigUInt(1) { return BigUInt() }
        var result = BigUInt(1)
        var base = self.mod(modulus)
        let width = exponent.bitWidth
        guard width > 0 else { return result }
        for i in 0..<width {
            let bit = (exponent.limbs[i / 32] >> UInt32(i % 32)) & 1
            if bit == 1 { result = (result * base).mod(modulus) }
            if i + 1 < width { base = (base * base).mod(modulus) }
        }
        return result
    }
}
