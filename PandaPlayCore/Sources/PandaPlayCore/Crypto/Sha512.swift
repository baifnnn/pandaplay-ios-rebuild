import Foundation

/// SHA-512 (FIPS 180-4). Implemented here instead of using CryptoKit so the whole
/// protocol stack builds and can be exercised on non-Apple hosts too.
public struct Sha512 {
    public static let blockSize = 128
    public static let digestSize = 64

    private static let k: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
        0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
        0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
        0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
        0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
        0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
        0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
        0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
        0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
        0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
        0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
        0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]

    private var state: [UInt64]
    private var pending: [UInt8] = []
    private var byteCount: UInt64 = 0

    public init() {
        state = [
            0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
            0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
        ]
    }

    public mutating func update(_ data: Data) {
        byteCount &+= UInt64(data.count)
        pending.append(contentsOf: data)
        var offset = 0
        while pending.count - offset >= Sha512.blockSize {
            let block = Array(pending[offset..<(offset + Sha512.blockSize)])
            process(block)
            offset += Sha512.blockSize
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    public mutating func update(_ bytes: [UInt8]) {
        update(Data(bytes))
    }

    public mutating func finalize() -> Data {
        let totalBits = byteCount &* 8
        var tail: [UInt8] = [0x80]
        let remainder = (pending.count + 1) % Sha512.blockSize
        let zeros = remainder <= 112 ? 112 - remainder : 112 + Sha512.blockSize - remainder
        tail.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        tail.append(contentsOf: [UInt8](repeating: 0, count: 8))
        for i in 0..<8 {
            tail.append(UInt8(truncatingIfNeeded: totalBits >> (56 - 8 * UInt64(i))))
        }
        pending.append(contentsOf: tail)

        var offset = 0
        while pending.count - offset >= Sha512.blockSize {
            let block = Array(pending[offset..<(offset + Sha512.blockSize)])
            process(block)
            offset += Sha512.blockSize
        }
        pending.removeAll(keepingCapacity: false)

        var out = Data(capacity: Sha512.digestSize)
        for word in state {
            out.append(UInt8(truncatingIfNeeded: word >> 56))
            out.append(UInt8(truncatingIfNeeded: word >> 48))
            out.append(UInt8(truncatingIfNeeded: word >> 40))
            out.append(UInt8(truncatingIfNeeded: word >> 32))
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }

    public static func hash(_ data: Data) -> Data {
        var hasher = Sha512()
        hasher.update(data)
        return hasher.finalize()
    }

    public static func hash(_ bytes: [UInt8]) -> Data {
        hash(Data(bytes))
    }

    public static func hash(_ text: String) -> Data {
        hash(Data(text.utf8))
    }

    private mutating func process(_ block: [UInt8]) {
        var w = [UInt64](repeating: 0, count: 80)
        for i in 0..<16 {
            var value: UInt64 = 0
            for k in 0..<8 { value = (value << 8) | UInt64(block[i * 8 + k]) }
            w[i] = value
        }
        for i in 16..<80 {
            let s0 = rotr(w[i - 15], 1) ^ rotr(w[i - 15], 8) ^ (w[i - 15] >> 7)
            let s1 = rotr(w[i - 2], 19) ^ rotr(w[i - 2], 61) ^ (w[i - 2] >> 6)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for i in 0..<80 {
            let s1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Sha512.k[i] &+ w[i]
            let s0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e
            e = d &+ t1
            d = c; c = b; b = a
            a = t1 &+ t2
        }

        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private func rotr(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value >> count) | (value << (64 - count))
    }
}
