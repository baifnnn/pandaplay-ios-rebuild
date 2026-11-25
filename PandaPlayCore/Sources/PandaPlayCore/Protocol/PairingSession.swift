import Foundation

/// Phases of the two-stage pairing handshake. The numbers match the `phase` field the
/// accessory stores, which is why the RTSP body can simply echo them as `state`.
public enum PairPhase: Int, Sendable {
    case idle = 0
    case setupRequested = 1
    case setupResponded = 2
    case proofReceived = 3
    case setupComplete = 4
    case verifyRequested = 5
    case verifyComplete = 6
    case failed = 7
}

public enum PairError: String, Error, Sendable {
    case unexpectedPhase
    case badLength
    case badProof
    case badSignature
    case decryptFailed
    case expired
    case replayRejected
}

/// The eight HKDF labels and the two nonces the handshake uses.
///
/// The nonces are seven ASCII bytes placed at offset 4 of a 12-byte ChaCha20-Poly1305
/// nonce; the first four bytes stay zero. That is the accessory's construction, not a
/// generic one, and swapping it breaks interop.
public enum PairingLabels {
    public static let setupEncryptSalt = "Pair-Setup-Encrypt-Salt"
    public static let setupEncryptInfo = "Pair-Setup-Encrypt-Info"
    public static let setupControllerSignSalt = "Pair-Setup-Controller-Sign-Salt"
    public static let setupControllerSignInfo = "Pair-Setup-Controller-Sign-Info"
    public static let setupAccessorySignSalt = "Pair-Setup-Accessory-Sign-Salt"
    public static let setupAccessorySignInfo = "Pair-Setup-Accessory-Sign-Info"
    public static let verifyEncryptSalt = "Pair-Verify-Encrypt-Salt"
    public static let verifyEncryptInfo = "Pair-Verify-Encrypt-Info"

    public static let setupNonce = Data("PS-Mg05".utf8)
    public static let verifyNonce = Data("PS-Mg06".utf8)

    /// Builds the 12-byte nonce: four zero bytes then the seven-byte tag.
    public static func nonce12(_ tag: Data) -> Data {
        precondition(tag.count == 7, "pairing nonces are seven bytes")
        var out = Data(repeating: 0, count: 4)
        out.append(tag)
        return out
    }
}

/// Long-term identity of this accessory: an Ed25519 seed, the SRP salt and the SRP
/// verifier digest. Everything the handshake needs to stay constant across sessions.
public struct PairingIdentity: Sendable {
    public let ed25519Seed: Data
    public let ed25519Public: Data
    public let identifier: String
    public let srpSalt: Data
    public let srpVerifier: Data

    public init(ed25519Seed: Data, identifier: String, setupCode: String) throws {
        guard ed25519Seed.count == Ed25519.privateKeySize else { throw PairError.badLength }
        self.ed25519Seed = ed25519Seed
        self.ed25519Public = try Ed25519.publicKey(seed: ed25519Seed)
        self.identifier = identifier
        var salt = [UInt8](repeating: 0, count: SrpServer.saltSize)
        for i in 0..<salt.count { salt[i] = UInt8.random(in: 0...255) }
        self.srpSalt = Data(salt)
        self.srpVerifier = SrpServer.computeVerifier(
            salt: srpSalt, identity: identifier, password: setupCode
        )
    }

    /// A fresh identity with the shipped defaults. The default setup code is the one the
    /// original app uses when the user has not chosen a device password.
    public static func create(
        identifier: String = "PandaPlay+",
        setupCode: String = "3939"
    ) throws -> PairingIdentity {
        var seed = [UInt8](repeating: 0, count: Ed25519.privateKeySize)
        for i in 0..<seed.count { seed[i] = UInt8.random(in: 0...255) }
        return try PairingIdentity(ed25519Seed: Data(seed), identifier: identifier, setupCode: setupCode)
    }
}

/// One pairing attempt. Handles both stages; `beginSetup`/`completeSetup`/`finishSetup`
/// cover `/pair-setup` and `beginVerify`/`buildVerifyResponse`/`finishVerify` cover
/// `/pair-verify`.
public final class PairingSession {
    public static let timeoutSeconds = 10

    public private(set) var phase: PairPhase = .idle
    public private(set) var lastError: PairError?
    public private(set) var controllerPublicKey: Data?
    public private(set) var sessionKey: Data?
    public var onLog: ((String, Any) -> Void)?

    private let identity: PairingIdentity
    private let clock: () -> Int64
    private var srp: SrpServer
    private var startedAt: Int64 = 0
    private var accessoryCurvePrivate: Data?

    public init(identity: PairingIdentity, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.identity = identity
        self.clock = clock
        self.srp = SrpServer(salt: identity.srpSalt, verifier: identity.srpVerifier)
    }

    public var isExpired: Bool {
        guard startedAt != 0 else { return false }
        return clock() - startedAt > Int64(PairingSession.timeoutSeconds)
    }

    // MARK: - Stage one

    /// Returns the SRP salt and public B for the `state: 2` response.
    public func beginSetup() throws -> (salt: Data, publicB: Data) {
        guard phase == .idle || phase == .setupRequested else { throw PairError.unexpectedPhase }
        startedAt = clock()
        phase = .setupResponded
        onLog?("pair_setup", "responded")
        return (identity.srpSalt, srp.publicBBytes)
    }

    /// Verifies the controller proof M1 and returns the server proof M2.
    public func completeSetup(controllerA: Data, controllerM1: Data) throws -> Data {
        guard phase == .setupResponded else { throw PairError.unexpectedPhase }
        guard controllerA.count == SrpServer.padSize else {
            phase = .failed
            lastError = .badLength
            throw PairError.badLength
        }
        guard controllerM1.count == SrpServer.hashSize else {
            phase = .failed
            lastError = .badLength
            throw PairError.badLength
        }
        guard var verified = Optional(srp),
              let m2 = verified.tryVerify(clientA: controllerA, clientM1: controllerM1, identity: identity.identifier) else {
            phase = .failed
            lastError = .badProof
            throw PairError.badProof
        }
        srp = verified
        phase = .proofReceived
        onLog?("pair_setup_proof", true)
        return m2
    }

    /// Decrypts the controller's signed subset, checks the signature, and stores the
    /// controller's long-term public key.
    @discardableResult
    public func finishSetup(encryptedSubset: Data) throws -> Data {
        guard phase == .proofReceived else { throw PairError.unexpectedPhase }

        let keyMaterial = Hkdf.deriveKey(
            salt: Data(PairingLabels.setupEncryptSalt.utf8),
            ikm: srp.sessionKey ?? Data(repeating: 0, count: 64),
            infoText: PairingLabels.setupEncryptInfo,
            length: 32
        )
        guard let plain = Aead.open(
            key: keyMaterial,
            nonce: PairingLabels.nonce12(PairingLabels.setupNonce),
            sealed: encryptedSubset,
            aad: Data()
        ) else {
            phase = .failed
            lastError = .decryptFailed
            throw PairError.decryptFailed
        }
        // Layout: controller long-term public key (32) | identifier (n) | signature (64).
        guard plain.count >= 96 else {
            phase = .failed
            lastError = .badLength
            throw PairError.badLength
        }
        let controllerLTPK = plain.prefix(32)
        let signature = plain.suffix(64)
        let identifierBytes = plain.subdata(in: 32..<(plain.count - 64))

        // The controller signs its own public key followed by the identifier, so the
        // accessory can tell a substituted key from the real one.
        var signed = Data()
        signed.append(controllerLTPK)
        signed.append(identifierBytes)
        guard (try? Ed25519.verify(publicKey: controllerLTPK, message: signed, signature: signature)) == true else {
            phase = .failed
            lastError = .badSignature
            throw PairError.badSignature
        }

        controllerPublicKey = controllerLTPK
        sessionKey = keyMaterial
        phase = .setupComplete
        onLog?("pair_setup", "complete")
        return controllerLTPK
    }

    // MARK: - Stage two

    /// Returns the accessory's ephemeral Curve25519 public key for the `state: 2` response.
    public func beginVerify(controllerCurvePublic: Data) throws -> Data {
        guard phase == .setupComplete || phase == .verifyRequested else { throw PairError.unexpectedPhase }
        guard controllerCurvePublic.count == X25519.keySize else {
            phase = .failed
            lastError = .badLength
            throw PairError.badLength
        }
        var secret = [UInt8](repeating: 0, count: X25519.keySize)
        for i in 0..<secret.count { secret[i] = UInt8.random(in: 0...255) }
        let scalar = X25519.clamp(Data(secret))
        accessoryCurvePrivate = scalar
        phase = .verifyRequested
        onLog?("pair_verify", "responded")
        return X25519.publicKey(privateKey: scalar)
    }

    /// Encrypts the accessory's signature over its own curve key for the `state: 4`
    /// response.
    public func buildVerifyResponse() throws -> Data {
        guard phase == .verifyRequested, let secret = accessoryCurvePrivate else {
            throw PairError.unexpectedPhase
        }
        let accessoryCurvePublic = X25519.publicKey(privateKey: secret)

        // Shared secret comes from the controller's key, which `beginVerify` already
        // accepted; the derivation runs over the accessory side of the exchange.
        guard let peer = pendingControllerCurve else {
            phase = .failed
            lastError = .unexpectedPhase
            throw PairError.unexpectedPhase
        }
        let shared = X25519.sharedSecret(privateKey: secret, peerPublic: peer)
        let key = Hkdf.deriveKey(
            salt: Data(PairingLabels.verifyEncryptSalt.utf8),
            ikm: shared,
            infoText: PairingLabels.verifyEncryptInfo,
            length: 32
        )

        var signed = Data()
        signed.append(accessoryCurvePublic)
        signed.append(Data(identity.identifier.utf8))
        guard let signature = try? Ed25519.sign(seed: identity.ed25519Seed, message: signed) else {
            phase = .failed
            lastError = .badSignature
            throw PairError.badSignature
        }
        var plain = Data()
        plain.append(accessoryCurvePublic)
        plain.append(Data(identity.identifier.utf8))
        plain.append(signature)

        let sealed = Aead.encrypt(
            key: key,
            nonce: PairingLabels.nonce12(PairingLabels.verifyNonce),
            plaintext: plain,
            aad: Data()
        )
        sessionKey = key
        return sealed
    }

    /// Stores the controller's curve key; `beginVerify` needs it for the shared secret.
    public func rememberControllerCurve(_ key: Data) {
        pendingControllerCurve = key
    }

    @discardableResult
    public func finishVerify(encrypted: Data) throws -> Data {
        guard phase == .verifyRequested, let key = sessionKey, let secret = accessoryCurvePrivate else {
            throw PairError.unexpectedPhase
        }
        guard let plain = Aead.open(
            key: key,
            nonce: PairingLabels.nonce12(PairingLabels.verifyNonce),
            sealed: encrypted,
            aad: Data()
        ) else {
            phase = .failed
            lastError = .decryptFailed
            throw PairError.decryptFailed
        }
        guard plain.count >= 96, let controllerKey = controllerPublicKey else {
            phase = .failed
            lastError = .badLength
            throw PairError.badLength
        }
        let curveKey = plain.prefix(32)
        let signature = plain.suffix(64)
        let identifierBytes = plain.subdata(in: 32..<(plain.count - 64))

        var signed = Data()
        signed.append(curveKey)
        signed.append(identifierBytes)
        guard (try? Ed25519.verify(publicKey: controllerKey, message: signed, signature: signature)) == true else {
            phase = .failed
            lastError = .badSignature
            throw PairError.badSignature
        }
        _ = secret
        phase = .verifyComplete
        onLog?("pair_verify", "complete")
        return curveKey
    }

    private var pendingControllerCurve: Data?
}
