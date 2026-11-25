import XCTest
@testable import PandaPlayCore

/// Isolates the arithmetic primitives so a failure points at one operation instead of at
/// whichever curve happened to call it first.
final class ArithmeticDiagnostics: XCTestCase {
    private func hex(_ value: BigUInt) -> String {
        value.toBigEndianData().map { String(format: "%02x", $0) }.joined()
    }

    private var p: BigUInt {
        var bytes = [UInt8](repeating: 0xff, count: 32)
        bytes[0] = 0x7f
        bytes[31] = 0xed
        return BigUInt(bigEndian: Data(bytes))
    }

    func testSquareModSmall() {
        // 2^256 mod p == 38 == 0x26
        let a = BigUInt(1).shiftedLeft(128)
        XCTAssertEqual(hex((a * a).mod(p)), "26")
    }

    func testSquareModMedium() {
        // 2^400 mod p == 0x26 followed by 36 zero digits (38 hex chars total)
        let a = BigUInt(1).shiftedLeft(200)
        XCTAssertEqual(hex((a * a).mod(p)), "26" + String(repeating: "0", count: 36))
    }

    func testSquareModTop() {
        // (2^254)^2 mod p, reference 0x6000...0004c
        let a = BigUInt(1).shiftedLeft(254)
        let expected = "6" + String(repeating: "0", count: 61) + "4c"
        XCTAssertEqual(hex((a * a).mod(p)), expected)
    }

    func testMultiplyThenMod() {
        let a = BigUInt(1).shiftedLeft(200) + BigUInt(12345)
        XCTAssertEqual(hex((a * a).mod(p)),
                       "607200000000000026000000000000000000000000000009156cb1")
    }

    func testPowTwoOverPowers() {
        XCTAssertEqual(BigUInt(2).modPow(BigUInt(64), p), BigUInt(1).shiftedLeft(64))
        XCTAssertEqual(BigUInt(2).modPow(BigUInt(128), p), BigUInt(1).shiftedLeft(128))
        XCTAssertEqual(BigUInt(2).modPow(BigUInt(200), p), BigUInt(1).shiftedLeft(200))
        XCTAssertEqual(BigUInt(2).modPow(BigUInt(254), p), BigUInt(1).shiftedLeft(254))
        XCTAssertEqual(BigUInt(2).modPow(BigUInt(255), p), BigUInt(19))
    }
}
