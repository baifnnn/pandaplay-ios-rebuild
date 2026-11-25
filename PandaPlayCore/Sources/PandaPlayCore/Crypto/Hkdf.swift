import Foundation

/// HKDF with SHA-512 (RFC 5869). The pairing handshake derives every session key with a
/// named label, so the label-based overload here is the one most call sites use.
public enum Hkdf {
    public static let hashSize = Sha512.digestSize

    public static func extract(salt: Data, ikm: Data) -> Data {
        let effectiveSalt = salt.isEmpty ? Data(repeating: 0, count: hashSize) : salt
        var mac = Sha512()
        mac.update(effectiveSalt)
        mac.update(ikm)
        return mac.finalize()
    }

    public static func expand(prk: Data, info: Data, length: Int) -> Data {
        precondition(length > 0 && length <= 255 * hashSize, "HKDF length out of range")
        var output = Data(capacity: length)
        var previous = Data()
        var counter: UInt8 = 1
        while output.count < length {
            var mac = Sha512()
            mac.update(previous)
            mac.update(info)
            mac.update(Data([counter]))
            previous = mac.finalize()
            output.append(previous)
            counter &+= 1
        }
        return output.prefix(length)
    }

    public static func deriveKey(salt: Data, ikm: Data, info: Data, length: Int) -> Data {
        expand(prk: extract(salt: salt, ikm: ikm), info: info, length: length)
    }

    /// Label form: the pairing labels are ASCII, and mixing them in as text keeps the
    /// call sites readable.
    public static func deriveKey(salt: Data, ikm: Data, infoText: String, length: Int) -> Data {
        deriveKey(salt: salt, ikm: ikm, info: Data(infoText.utf8), length: length)
    }

    public static func deriveKey(saltText: String, ikm: Data, infoText: String, length: Int) -> Data {
        deriveKey(salt: Data(saltText.utf8), ikm: ikm, info: Data(infoText.utf8), length: length)
    }
}
