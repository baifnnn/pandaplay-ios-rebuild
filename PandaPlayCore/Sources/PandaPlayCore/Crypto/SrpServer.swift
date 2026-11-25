import Foundation

/// SRP-6a server side, matching the accessory role in the pairing handshake.
///
/// The group is RFC 3526 group 15 (3072-bit MODP) with generator 5 — that is what the
/// original binary embeds, and the verifier width tells you it is a real SRP exchange
/// rather than a shared secret: the accessory only ever stores `v`, never the password.
public struct SrpServer {
    public static let padSize = 384
    public static let hashSize = 64
    public static let saltSize = 32

    /// RFC 3526 group 15, 3072-bit MODP.
    public static let groupHex = """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74\
        020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437\
        4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05\
        98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB\
        9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
        E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718\
        3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33\
        A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864\
        D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2\
        08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """

    public static let N: BigUInt = {
        let hex = groupHex.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return BigUInt(bigEndian: Data(bytes))
    }()

    public static let G = BigUInt(5)

    public let salt: Data
    public let verifier: BigUInt
    public let secretB: BigUInt
    public let publicB: BigUInt
    public private(set) var verified = false
    /// The session key `K = H(S)` produced by the accepted proof. Callers derive the
    /// pairing encryption key from this, so it has to survive `tryVerify`.
    public private(set) var sessionKey: Data?

    /// `verifier` is the 64-byte digest `H(salt | H(I | ":" | P))`; the exponentiation
    /// `g^x mod N` happens here so the caller never handles the raw x.
    public init(salt: Data, verifier: Data, secretB: BigUInt? = nil) {
        precondition(salt.count == SrpServer.saltSize, "SRP salt must be 32 bytes")
        self.salt = salt
        self.verifier = SrpServer.G.modPow(BigUInt(bigEndian: verifier), SrpServer.N)
        var b = secretB ?? BigUInt()
        if b.isZero {
            var random = [UInt8](repeating: 0, count: 32)
            for i in 0..<random.count { random[i] = UInt8.random(in: 0...255) }
            b = BigUInt(bigEndian: Data(random))
        }
        self.secretB = b
        // B = k*v + g^b, with k = H(N | PAD(g)) per SRP-6a.
        let k = SrpServer.multiplier()
        let gb = SrpServer.G.modPow(b, SrpServer.N)
        self.publicB = (k * self.verifier + gb).mod(SrpServer.N)
    }

    public var publicBBytes: Data {
        publicB.toBigEndianData(paddedTo: SrpServer.padSize)
    }

    private static func multiplier() -> BigUInt {
        var mac = Sha512()
        mac.update(N.toBigEndianData(paddedTo: padSize))
        mac.update(G.toBigEndianData(paddedTo: padSize))
        return BigUInt(bigEndian: mac.finalize())
    }

    /// Computes `x = H(salt | H(I | ":" | P))`. The result is a 64-byte digest, matching
    /// the `BN_bin2bn(..., 0x40, ...)` the original binary performs.
    public static func computeVerifier(salt: Data, identity: String, password: String) -> Data {
        var inner = Sha512()
        inner.update(Data(identity.utf8))
        inner.update(Data([0x3a])) // ":"
        inner.update(Data(password.utf8))
        let xDigest = inner.finalize()

        var outer = Sha512()
        outer.update(salt)
        outer.update(xDigest)
        return outer.finalize()
    }

    /// Verifies the client proof M1 and returns the server proof M2.
    ///
    /// A session accepts exactly one proof; a second call returns nil so a replayed
    /// handshake cannot silently succeed.
    public mutating func tryVerify(clientA: Data, clientM1: Data, identity: String) -> Data? {
        guard !verified else { return nil }
        guard clientA.count == SrpServer.padSize, clientM1.count == SrpServer.hashSize else {
            return nil
        }
        let a = BigUInt(bigEndian: clientA)
        guard !a.isZero, a < SrpServer.N else { return nil }

        let u = SrpServer.scrambling(a, publicB)
        // S = (A * v^u)^b mod N
        let vu = verifier.modPow(u, SrpServer.N)
        let base = (a * vu).mod(SrpServer.N)
        let s = base.modPow(secretB, SrpServer.N)
        let key = SrpServer.sessionKeyDigest(s)

        let expectedM1 = SrpServer.clientProof(
            identity: identity, salt: salt, a: a, b: publicB, key: key
        )
        guard Poly1305.equal(expectedM1, clientM1) else { return nil }

        verified = true
        self.sessionKey = key
        return SrpServer.serverProof(a: a, m1: clientM1, key: key)
    }

    static func scrambling(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var mac = Sha512()
        mac.update(a.toBigEndianData(paddedTo: padSize))
        mac.update(b.toBigEndianData(paddedTo: padSize))
        return BigUInt(bigEndian: mac.finalize())
    }

    /// SRP-6a folds the premaster secret into a fixed-width digest before use.
    static func sessionKeyDigest(_ s: BigUInt) -> Data {
        Sha512.hash(s.toBigEndianData(paddedTo: padSize))
    }

    static func clientProof(identity: String, salt: Data, a: BigUInt, b: BigUInt, key: Data) -> Data {
        var mac = Sha512()
        mac.update(Sha512.hash(N.toBigEndianData(paddedTo: padSize)))
        mac.update(Sha512.hash(G.toBigEndianData(paddedTo: padSize)))
        mac.update(Data(identity.utf8))
        mac.update(salt)
        mac.update(a.toBigEndianData(paddedTo: padSize))
        mac.update(b.toBigEndianData(paddedTo: padSize))
        mac.update(key)
        return mac.finalize()
    }

    static func serverProof(a: BigUInt, m1: Data, key: Data) -> Data {
        var mac = Sha512()
        mac.update(a.toBigEndianData(paddedTo: padSize))
        mac.update(m1)
        mac.update(key)
        return mac.finalize()
    }
}
