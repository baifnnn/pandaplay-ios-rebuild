import XCTest
@testable import PandaPlayCore

final class CryptoTests: XCTestCase {
    func testChaCha20Block() {
        let key = Data((0..<32).map { UInt8($0) })
        let nonce = Data([0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0])
        let block = ChaCha20.block(key: key, counter: 1, nonce: nonce)
        let hex = block.map { String(format: "%02x", $0) }.joined()
        print("chacha block=\(hex)")
        XCTAssertEqual(block.count, 64)
    }

    func testPoly1305Tag() {
        let key = Data([
            0x85, 0xd6, 0xbe, 0x78, 0x57, 0x55, 0x6d, 0x33, 0x7f, 0x44, 0x52, 0xfe, 0x42, 0xd5, 0x06, 0xa8,
            0x01, 0x03, 0x80, 0x8a, 0xfb, 0x0d, 0xb2, 0xfd, 0x4a, 0xbf, 0xf6, 0xaf, 0x41, 0x49, 0xf5, 0x1b,
        ])
        let message = Data("Cryptographic Forum Research Group".utf8)
        let tag = Poly1305.tag(key: key, message: message)
        let hex = tag.map { String(format: "%02x", $0) }.joined()
        print("poly1305 tag=\(hex)")
        XCTAssertEqual(hex, "a8061dc1305136c6c22b8baf0c0127a9")
    }

    func testAeadRoundTrip() {
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x07, count: 12)
        let plaintext = Data("hello receiver".utf8)
        let sealed = Aead.encrypt(key: key, nonce: nonce, plaintext: plaintext)
        XCTAssertEqual(sealed.count, plaintext.count + Aead.tagSize)
        let opened = Aead.open(key: key, nonce: nonce, sealed: sealed)
        XCTAssertEqual(opened, plaintext)

        var tampered = sealed
        tampered[0] ^= 0xff
        XCTAssertNil(Aead.open(key: key, nonce: nonce, sealed: tampered))
    }

    func testSha512KnownVector() {
        let hex = Sha512.hash(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            hex,
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        )
    }

    func testHkdfDeterministic() {
        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data((0..<13).map { UInt8($0) })
        let a = Hkdf.deriveKey(salt: salt, ikm: ikm, infoText: "Pair-Setup-Encrypt-Salt", length: 32)
        let b = Hkdf.deriveKey(salt: salt, ikm: ikm, infoText: "Pair-Setup-Encrypt-Salt", length: 32)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
        let c = Hkdf.deriveKey(salt: salt, ikm: ikm, infoText: "Pair-Verify-Encrypt-Salt", length: 32)
        XCTAssertNotEqual(a, c)
    }

    func testX25519Rfc7748() {
        let aliceSecret = Data([
            0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d, 0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
            0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a, 0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a,
        ])
        let bobSecret = Data([
            0x5d, 0xab, 0x08, 0x7e, 0x62, 0x4a, 0x8a, 0x4b, 0x79, 0xe1, 0x7f, 0x8b, 0x83, 0x80, 0x0e, 0xe6,
            0x6f, 0x3b, 0xb1, 0x29, 0x26, 0x18, 0xb6, 0xfd, 0x1c, 0x2f, 0x8b, 0x27, 0xff, 0x88, 0xe0, 0xeb,
        ])
        let alicePublic = X25519.publicKey(privateKey: aliceSecret)
        let bobPublic = X25519.publicKey(privateKey: bobSecret)
        let aliceHex = alicePublic.map { String(format: "%02x", $0) }.joined()
        let bobHex = bobPublic.map { String(format: "%02x", $0) }.joined()
        print("x25519 alice=\(aliceHex)")
        print("x25519 bob=\(bobHex)")
        XCTAssertEqual(aliceHex, "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        XCTAssertEqual(bobHex, "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")

        let sharedA = X25519.sharedSecret(privateKey: aliceSecret, peerPublic: bobPublic)
        let sharedB = X25519.sharedSecret(privateKey: bobSecret, peerPublic: alicePublic)
        let sharedHex = sharedA.map { String(format: "%02x", $0) }.joined()
        print("x25519 shared=\(sharedHex)")
        XCTAssertEqual(sharedA, sharedB)
        XCTAssertEqual(sharedHex, "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    }

    func testEd25519Rfc8032() throws {
        let seed = Data([
            0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60, 0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
            0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19, 0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60,
        ])
        let expectedPublic = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
        let publicKey = try Ed25519.publicKey(seed: seed)
        let publicHex = publicKey.map { String(format: "%02x", $0) }.joined()
        print("ed25519 public=\(publicHex)")
        XCTAssertEqual(publicHex, expectedPublic)

        let message = Data()
        let signature = try Ed25519.sign(seed: seed, message: message)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()
        print("ed25519 sig=\(signatureHex)")
        XCTAssertEqual(
            signatureHex,
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
                + "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
        )

        let verified = try Ed25519.verify(publicKey: publicKey, message: message, signature: signature)
        XCTAssertTrue(verified)

        var tampered = signature
        tampered[0] ^= 0xff
        let rejected = try Ed25519.verify(publicKey: publicKey, message: message, signature: tampered)
        XCTAssertFalse(rejected)
    }

    func testSrpShapes() {
        let salt = Data(repeating: 0x11, count: 32)
        let verifier = SrpServer.computeVerifier(salt: salt, identity: "PandaPlay+", password: "3939")
        XCTAssertEqual(verifier.count, SrpServer.hashSize)
        let server = SrpServer(salt: salt, verifier: verifier)
        XCTAssertEqual(server.publicBBytes.count, SrpServer.padSize)
        XCTAssertFalse(server.publicB.isZero)
        XCTAssertLessThan(server.publicB, SrpServer.N)
    }
}
