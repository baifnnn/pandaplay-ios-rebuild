import Foundation

/// ChaCha20 stream cipher (RFC 8439). The receiver needs it for the frame-encryption
/// path, and keeping it in-house keeps the module free of platform crypto.
public struct ChaCha20 {
    public static let keySize = 32
    public static let nonceSize = 12
    public static let blockSize = 64

    private static let sigma: (UInt32, UInt32, UInt32, UInt32) =
        (0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574)

    @inline(__always)
    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    @inline(__always)
    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 7)
    }

    /// One 64-byte keystream block for `counter`.
    public static func block(key: Data, counter: UInt32, nonce: Data) -> [UInt8] {
        precondition(key.count == keySize, "ChaCha20 key must be 32 bytes")
        precondition(nonce.count == nonceSize, "ChaCha20 nonce must be 12 bytes")

        var initial = [UInt32](repeating: 0, count: 16)
        initial[0] = ChaCha20.sigma.0
        initial[1] = ChaCha20.sigma.1
        initial[2] = ChaCha20.sigma.2
        initial[3] = ChaCha20.sigma.3

        let keyBytes = [UInt8](key)
        for i in 0..<8 {
            let o = i * 4
            initial[4 + i] = UInt32(keyBytes[o])
                | (UInt32(keyBytes[o + 1]) << 8)
                | (UInt32(keyBytes[o + 2]) << 16)
                | (UInt32(keyBytes[o + 3]) << 24)
        }
        let nonceBytes = [UInt8](nonce)
        initial[12] = counter
        for i in 0..<3 {
            let o = i * 4
            initial[13 + i] = UInt32(nonceBytes[o])
                | (UInt32(nonceBytes[o + 1]) << 8)
                | (UInt32(nonceBytes[o + 2]) << 16)
                | (UInt32(nonceBytes[o + 3]) << 24)
        }

        var working = initial
        for _ in 0..<10 {
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }

        var out = [UInt8](repeating: 0, count: blockSize)
        for i in 0..<16 {
            let value = working[i] &+ initial[i]
            out[i * 4] = UInt8(truncatingIfNeeded: value)
            out[i * 4 + 1] = UInt8(truncatingIfNeeded: value >> 8)
            out[i * 4 + 2] = UInt8(truncatingIfNeeded: value >> 16)
            out[i * 4 + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }
        return out
    }

    /// XORs `data` in place with the keystream starting at `counter`.
    public static func xor(key: Data, counter: UInt32, nonce: Data, data: inout Data) {
        let count = data.count
        guard count > 0 else { return }
        var bytes = [UInt8](data)
        var offset = 0
        var blockIndex: UInt32 = 0
        while offset < count {
            let stream = block(key: key, counter: counter &+ blockIndex, nonce: nonce)
            let take = min(ChaCha20.blockSize, count - offset)
            for i in 0..<take { bytes[offset + i] ^= stream[i] }
            offset += take
            blockIndex &+= 1
        }
        data = Data(bytes)
    }

    /// The receiver leaves the first `plainPrefix` bytes of a frame in the clear and
    /// encrypts the rest, so the keystream has to skip those bytes in its first block.
    public static func decryptFrame(
        key: Data,
        nonce: Data,
        frame: inout Data,
        plainPrefix: Int = 32
    ) {
        let count = frame.count
        guard count > plainPrefix else { return }
        var bytes = [UInt8](frame)
        var offset = plainPrefix
        var blockIndex: UInt32 = 0
        while offset < count {
            let stream = block(key: key, counter: blockIndex, nonce: nonce)
            let startInBlock = blockIndex == 0 ? plainPrefix : 0
            let take = min(ChaCha20.blockSize - startInBlock, count - offset)
            for i in 0..<take { bytes[offset + i] ^= stream[startInBlock + i] }
            offset += take
            blockIndex &+= 1
        }
        frame = Data(bytes)
    }
}
