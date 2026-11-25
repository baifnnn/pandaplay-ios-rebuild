import Foundation

/// ChaCha20-Poly1305 AEAD (RFC 8439 §2.8) with the AirPlay wire convention of returning
/// ciphertext and tag glued together as `ct || tag`.
public enum Aead {
    public static let keySize = 32
    public static let nonceSize = 12
    public static let tagSize = 16

    /// The one-time Poly1305 key is the first 32 bytes of the keystream at counter 0;
    /// the message itself starts at counter 1.
    private static func oneTimeKey(key: Data, nonce: Data) -> Data {
        let stream = ChaCha20.block(key: key, counter: 0, nonce: nonce)
        return Data(stream[0..<32])
    }

    private static func pad16(_ count: Int) -> Data {
        let remainder = count % 16
        guard remainder != 0 else { return Data() }
        return Data(repeating: 0, count: 16 - remainder)
    }

    private static func macData(aad: Data, ciphertext: Data) -> Data {
        var out = Data(capacity: aad.count + ciphertext.count + 48)
        out.append(aad)
        out.append(pad16(aad.count))
        out.append(ciphertext)
        out.append(pad16(ciphertext.count))
        var lengths = [UInt8](repeating: 0, count: 16)
        ByteOrder.writeU64LE(&lengths, 0, UInt64(aad.count))
        ByteOrder.writeU64LE(&lengths, 8, UInt64(ciphertext.count))
        out.append(contentsOf: lengths)
        return out
    }

    public static func encrypt(key: Data, nonce: Data, plaintext: Data, aad: Data = Data()) -> Data {
        precondition(key.count == keySize, "AEAD key must be 32 bytes")
        precondition(nonce.count == nonceSize, "AEAD nonce must be 12 bytes")

        var ciphertext = plaintext
        ChaCha20.xor(key: key, counter: 1, nonce: nonce, data: &ciphertext)
        let tag = Poly1305.tag(key: oneTimeKey(key: key, nonce: nonce),
                               message: macData(aad: aad, ciphertext: ciphertext))
        var out = ciphertext
        out.append(tag)
        return out
    }

    /// `sealed` is `ct || tag`. Returns nil when the tag does not verify.
    public static func open(key: Data, nonce: Data, sealed: Data, aad: Data = Data()) -> Data? {
        precondition(key.count == keySize, "AEAD key must be 32 bytes")
        precondition(nonce.count == nonceSize, "AEAD nonce must be 12 bytes")
        guard sealed.count >= tagSize else { return nil }

        let split = sealed.count - tagSize
        let ciphertext = sealed.subdata(in: 0..<split)
        let tag = sealed.subdata(in: split..<sealed.count)
        let expected = Poly1305.tag(key: oneTimeKey(key: key, nonce: nonce),
                                    message: macData(aad: aad, ciphertext: ciphertext))
        guard Poly1305.equal(expected, tag) else { return nil }

        var plaintext = ciphertext
        ChaCha20.xor(key: key, counter: 1, nonce: nonce, data: &plaintext)
        return plaintext
    }
}
