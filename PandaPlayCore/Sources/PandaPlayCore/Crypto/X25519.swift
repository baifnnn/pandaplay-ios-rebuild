import Foundation

/// X25519 (RFC 7748) on top of `BigUInt`. Scalar multiplication is a Montgomery ladder over
/// the prime field 2^255-19, which is all the pairing handshake needs.
public enum X25519 {
    public static let keySize = 32

    private static let p = BigUInt(bigEndian: Data([
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xed,
    ]))

    private static let a24 = BigUInt(121_665)

    public static func basePoint() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 9
        return Data(bytes)
    }

    /// Clamps a 32-byte scalar per RFC 7748: clear the low 3 bits, clear bit 255 and set
    /// bit 254.
    public static func clamp(_ scalar: Data) -> Data {
        var bytes = [UInt8](scalar)
        bytes[0] &= 248
        bytes[31] &= 127
        bytes[31] |= 64
        return Data(bytes)
    }

    public static func publicKey(privateKey: Data) -> Data {
        scalarMult(k: clamp(privateKey), u: basePoint())
    }

    public static func sharedSecret(privateKey: Data, peerPublic: Data) -> Data {
        scalarMult(k: clamp(privateKey), u: peerPublic)
    }

    /// RFC 7748 §5: the wire form is little-endian and the top bit is masked off.
    private static func decodeU(_ u: Data) -> BigUInt {
        var bytes = [UInt8](u)
        bytes[31] &= 127
        return BigUInt(littleEndian: Data(bytes)).mod(p)
    }

    private static func encodeU(_ value: BigUInt) -> Data {
        Data(value.toBigEndianData(paddedTo: 32).reversed())
    }

    public static func scalarMult(k: Data, u: Data) -> Data {
        let x1 = decodeU(u)
        var x2 = BigUInt(1)
        var z2 = BigUInt()
        var x3 = x1
        var z3 = BigUInt(1)
        var swap = 0

        let scalar = [UInt8](k)
        for t in stride(from: 254, through: 0, by: -1) {
            let bit = Int((scalar[t / 8] >> UInt8(t % 8)) & 1)
            if swap ^ bit != 0 {
                let tx = x2; x2 = x3; x3 = tx
                let tz = z2; z2 = z3; z3 = tz
            }
            swap = bit

            // Differences are formed as (x + p - y): BigInteger here is unsigned and
            // asserts on underflow, so a bare subtraction would trap halfway through
            // the ladder whenever z happened to exceed x.
            let a = (x2 + z2).mod(p)
            let aa = (a * a).mod(p)
            let b = ((x2 + p) - z2).mod(p)
            let bb = (b * b).mod(p)
            let e = ((aa + p) - bb).mod(p)
            let c = (x3 + z3).mod(p)
            let d = ((x3 + p) - z3).mod(p)
            let da = (d * a).mod(p)
            let cb = (c * b).mod(p)
            let sum = (da + cb).mod(p)
            let diff = ((da + p) - cb).mod(p)
            x3 = (sum * sum).mod(p)
            z3 = (x1 * (diff * diff).mod(p)).mod(p)
            x2 = (aa * bb).mod(p)
            z2 = (e * ((aa + (a24 * e).mod(p)).mod(p))).mod(p)
        }

        if swap != 0 {
            let tx = x2; x2 = x3; x3 = tx
            let tz = z2; z2 = z3; z3 = tz
        }

        // x2 * z2^(p-2) mod p
        let zInv = z2.modPow(p - BigUInt(2), p)
        let result = (x2 * zInv).mod(p)
        return encodeU(result)
    }
}
