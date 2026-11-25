import XCTest
@testable import PandaPlayCore

/// Sanity checks for the multi-precision core. Every other module rides on this, so a
/// silent carry or quotient bug here shows up much later as a wrong key.
final class BigUIntTests: XCTestCase {
    private func hex(_ value: BigUInt) -> String {
        value.toBigEndianData().map { String(format: "%02x", $0) }.joined()
    }

    /// p = 2^255 - 19
    private var curvePrime: BigUInt {
        var bytes = [UInt8](repeating: 0xff, count: 32)
        bytes[0] = 0x7f
        bytes[31] = 0xed
        return BigUInt(bigEndian: Data(bytes))
    }

    func testMultiplyCarries() {
        let a = BigUInt(bigEndian: Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]))
        XCTAssertEqual(hex(a * a), "fffffffffffffffe0000000000000001")

        let c = BigUInt(UInt64.max)
        XCTAssertEqual(hex(c * c), "fffffffffffffffe0000000000000001")
    }

    func testDivisionIdentity() {
        let a = BigUInt(bigEndian: Data([
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98,
            0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
        ]))
        let b = BigUInt(bigEndian: Data([0x00, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]))
        let (q, r) = a.divided(by: b)
        XCTAssertEqual(q * b + r, a)
        XCTAssertLessThan(r, b)
    }

    func testSmallRemainders() {
        let p = curvePrime
        XCTAssertEqual(BigUInt(2).modPow(BigUInt(255), p), BigUInt(19))
        XCTAssertEqual(BigUInt(2).modPow(BigUInt(256), p), BigUInt(38))
        XCTAssertEqual(BigUInt(2).modPow(BigUInt(5), BigUInt(7)), BigUInt(4))
    }

    func testModByCurvePrime() {
        let p = curvePrime
        // 2^255 mod p == 19
        let twoTo255 = BigUInt(1).shiftedLeft(255)
        XCTAssertEqual(twoTo255.mod(p), BigUInt(19))
        // p itself reduces to zero.
        XCTAssertTrue(p.mod(p).isZero)
        // p + 1 reduces to one.
        XCTAssertEqual((p + BigUInt(1)).mod(p), BigUInt(1))
    }

    func testQuotientIsExact() {
        let p = curvePrime
        let big = BigUInt(3) * p + BigUInt(77)
        let (q, r) = big.divided(by: p)
        XCTAssertEqual(q, BigUInt(3))
        XCTAssertEqual(r, BigUInt(77))
    }

    func testShiftRoundTrip() {
        let value = BigUInt(bigEndian: Data([0x12, 0x34, 0x56, 0x78, 0x9a]))
        XCTAssertEqual(value.shiftedLeft(13).shiftedRight(13), value)
    }

    func testFermatLittleTheorem() {
        // 2^(p-1) mod p == 1 for the Curve25519 prime, which also exercises modPow over
        // a full 255-bit modulus and exponent.
        let p = curvePrime
        XCTAssertEqual(BigUInt(2).modPow(p - BigUInt(1), p), BigUInt(1))
    }

    func testModPowKnownValue() {
        XCTAssertEqual(BigUInt(3).modPow(BigUInt(5), BigUInt(1000)), BigUInt(243))
        XCTAssertEqual(BigUInt(2).modPow(BigUInt(10), BigUInt(1000)), BigUInt(24))
    }
}
