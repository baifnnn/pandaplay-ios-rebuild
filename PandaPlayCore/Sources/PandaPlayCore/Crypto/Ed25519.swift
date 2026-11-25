import Foundation

public enum Ed25519Error: Error {
    case badKeyLength
    case badSignatureLength
}

/// Ed25519 (RFC 8032) over `BigUInt`, using extended twisted Edwards coordinates with
/// a = -1. Scalar multiplication is a plain double-and-add ladder: slow but short and
/// easy to audit, and the pairing handshake signs one small message per session.
public enum Ed25519 {
    public static let publicKeySize = 32
    public static let privateKeySize = 32
    public static let signatureSize = 64

    /// p = 2^255 - 19
    static let p = BigUInt(bigEndian: Data([
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xed,
    ]))

    /// L = 2^252 + 27742317777372353535851937790883648493
    static let orderL = BigUInt(bigEndian: Data([
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0xde, 0xf9, 0xde, 0xa2, 0xf7, 0x9c, 0xd6,
        0x58, 0x12, 0x63, 0x1a, 0x5c, 0xf5, 0xd3, 0xed,
    ]))

    /// d = -121665 / 121666 mod p
    static let d: BigUInt = {
        let numerator = (p - BigUInt(121_665)).mod(p)
        let denominatorInverse = BigUInt(121_666).modPow(p - BigUInt(2), p)
        return (numerator * denominatorInverse).mod(p)
    }()

    /// sqrt(-1) mod p, used when the square root needs the other root.
    static let sqrtMinusOne = BigUInt(2).modPow((p - BigUInt(1)).shiftedRight(2), p)

    // MARK: - Field arithmetic

    static func inverse(_ a: BigUInt) -> BigUInt {
        a.modPow(p - BigUInt(2), p)
    }

    // MARK: - Points

    public struct Point: Equatable {
        public var x: BigUInt
        public var y: BigUInt
        public var z: BigUInt
        public var t: BigUInt

        public static let identity = Point(x: BigUInt(0), y: BigUInt(1), z: BigUInt(1), t: BigUInt(0))

        /// Projective equality: compares x/z and y/z without inverting.
        public static func == (lhs: Point, rhs: Point) -> Bool {
            (lhs.x * rhs.z).mod(Ed25519.p) == (rhs.x * lhs.z).mod(Ed25519.p)
                && (lhs.y * rhs.z).mod(Ed25519.p) == (rhs.y * lhs.z).mod(Ed25519.p)
        }
    }

    /// Unified addition for a = -1 in extended coordinates.
    /// Every intermediate is reduced mod p: `e` and `f` are differences, so they are
    /// formed as `(x + p - y)` rather than `x - y` to keep BigUInt honest about signs.
    static func add(_ p1: Point, _ p2: Point) -> Point {
        let a = ((p1.y + p - p1.x).mod(p) * (p2.y + p - p2.x).mod(p)).mod(p)
        let b = ((p1.y + p1.x).mod(p) * (p2.y + p2.x).mod(p)).mod(p)
        let c = (p1.t * BigUInt(2) * d * p2.t).mod(p)
        let dd = (p1.z * BigUInt(2) * p2.z).mod(p)
        let e = (b + p - a).mod(p)
        let f = (dd + p - c).mod(p)
        let g = (dd + c).mod(p)
        let h = (b + a).mod(p)
        return Point(
            x: (e * f).mod(p),
            y: (g * h).mod(p),
            z: (f * g).mod(p),
            t: (e * h).mod(p)
        )
    }

    /// Doubling for a = -1: A = X^2, B = Y^2, C = 2Z^2, D = -A,
    /// E = (X+Y)^2 - A - B, G = D + B, F = G - C, H = D - B.
    static func twice(_ p1: Point) -> Point {
        let a = (p1.x * p1.x).mod(p)
        let b = (p1.y * p1.y).mod(p)
        let c = (p1.z * p1.z * BigUInt(2)).mod(p)
        let dd = (p + p - a).mod(p)
        let e = ((p1.x + p1.y) * (p1.x + p1.y) + p + p - a - b).mod(p)
        let g = (dd + b).mod(p)
        let f = (g + p - c).mod(p)
        let h = (dd + p - b).mod(p)
        return Point(
            x: (e * f).mod(p),
            y: (g * h).mod(p),
            z: (f * g).mod(p),
            t: (e * h).mod(p)
        )
    }

    static func multiply(_ point: Point, _ scalar: BigUInt) -> Point {
        var result = Point.identity
        var addend = point
        let width = scalar.bitWidth
        guard width > 0 else { return result }
        for i in 0..<width {
            let bit = (scalar.limbs[i / 32] >> UInt32(i % 32)) & 1
            if bit == 1 { result = add(result, addend) }
            if i + 1 < width { addend = twice(addend) }
        }
        return result
    }

    /// RFC 8032 §5.1.3 square-root recovery of x from y.
    static func recoverX(y: BigUInt, sign: Int) -> BigUInt {
        let y2 = (y * y).mod(p)
        let numerator = (y2 - BigUInt(1)).mod(p)
        let denominator = (d * y2 + BigUInt(1)).mod(p)
        let target = (numerator * inverse(denominator)).mod(p)

        var x = target.modPow((p + BigUInt(3)).shiftedRight(3), p)
        if (x * x).mod(p) != target {
            x = (x * sqrtMinusOne).mod(p)
        }
        let isOdd = (x.limbs.first.map { $0 & 1 } ?? 0) == 1
        if isOdd != (sign == 1) {
            x = (p - x).mod(p)
        }
        return x
    }

    static let basePoint: Point = {
        let y = (BigUInt(4) * inverse(BigUInt(5))).mod(p)
        let x = recoverX(y: y, sign: 0)
        return Point(x: x, y: y, z: BigUInt(1), t: (x * y).mod(p))
    }()

    // MARK: - Encoding

    static func encode(_ point: Point) -> Data {
        let zInv = inverse(point.z)
        let x = (point.x * zInv).mod(p)
        let y = (point.y * zInv).mod(p)
        // RFC 8032 §5.1.2: the wire form is y little-endian with the parity of x in the
        // top bit, not a big-endian y.
        var bytes = [UInt8](y.toBigEndianData(paddedTo: 32).reversed())
        let isOdd = (x.limbs.first.map { $0 & 1 } ?? 0) == 1
        if isOdd { bytes[31] |= 0x80 }
        return Data(bytes)
    }

    static func decode(_ data: Data) -> Point? {
        guard data.count == 32 else { return nil }
        var bytes = [UInt8](data)
        let sign = Int((bytes[31] >> 7) & 1)
        bytes[31] &= 0x7f
        let y = BigUInt(littleEndian: Data(bytes))
        guard y < p else { return nil }
        let x = recoverX(y: y, sign: sign)
        return Point(x: x, y: y, z: BigUInt(1), t: (x * y).mod(p))
    }

    // MARK: - Digest helpers

    /// RFC 8032 hashes are little-endian; every wire format in this project is
    /// big-endian, so the conversion is explicit at each hop.
    static func littleEndianValue(_ digest: Data) -> BigUInt {
        let bytes = [UInt8](digest)
        var sum = BigUInt()
        for i in stride(from: bytes.count - 1, through: 0, by: -1) {
            sum = sum.shiftedLeft(8) + BigUInt(UInt64(bytes[i]))
        }
        return sum
    }

    static func littleEndianBytes(_ value: BigUInt) -> Data {
        let big = value.toBigEndianData()
        var bytes = [UInt8](big.reversed())
        while bytes.count < 32 { bytes.append(0) }
        if bytes.count > 32 { bytes = Array(bytes.prefix(32)) }
        return Data(bytes)
    }

    static func clampedScalar(_ digest: Data) -> BigUInt {
        var scalar = [UInt8](digest.prefix(32))
        scalar[0] &= 248
        scalar[31] &= 127
        scalar[31] |= 64
        return littleEndianValue(Data(scalar))
    }

    // MARK: - Public API

    public static func publicKey(seed: Data) throws -> Data {
        guard seed.count == privateKeySize else { throw Ed25519Error.badKeyLength }
        let h = Sha512.hash(seed)
        let scalar = clampedScalar(h)
        return encode(multiply(basePoint, scalar))
    }

    public static func sign(seed: Data, message: Data) throws -> Data {
        guard seed.count == privateKeySize else { throw Ed25519Error.badKeyLength }
        let h = Sha512.hash(seed)
        let scalar = clampedScalar(h)
        let prefix = Data(h.suffix(32))
        let publicKeyBytes = encode(multiply(basePoint, scalar))

        var nonceInput = Data()
        nonceInput.append(prefix)
        nonceInput.append(message)
        let r = littleEndianValue(Sha512.hash(nonceInput)).mod(orderL)
        let rPoint = encode(multiply(basePoint, r))

        var kInput = Data()
        kInput.append(rPoint)
        kInput.append(publicKeyBytes)
        kInput.append(message)
        let k = littleEndianValue(Sha512.hash(kInput)).mod(orderL)

        let s = (r + k * scalar).mod(orderL)

        var signature = Data(capacity: 64)
        signature.append(rPoint)
        signature.append(littleEndianBytes(s))
        return signature
    }

    public static func verify(publicKey: Data, message: Data, signature: Data) throws -> Bool {
        guard publicKey.count == publicKeySize else { throw Ed25519Error.badKeyLength }
        guard signature.count == signatureSize else { throw Ed25519Error.badSignatureLength }
        guard let a = decode(publicKey) else { return false }

        let rBytes = Data(signature.prefix(32))
        guard let rPoint = decode(rBytes) else { return false }
        let s = littleEndianValue(Data(signature.suffix(32)))
        guard s < orderL else { return false }

        var kInput = Data()
        kInput.append(rBytes)
        kInput.append(publicKey)
        kInput.append(message)
        let k = littleEndianValue(Sha512.hash(kInput)).mod(orderL)

        // [s]B == R + [k]A
        let left = multiply(basePoint, s)
        let right = add(rPoint, multiply(a, k))
        return left == right
    }
}
