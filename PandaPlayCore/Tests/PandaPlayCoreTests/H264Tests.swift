import XCTest
@testable import PandaPlayCore

/// Vectors here are shaped like the controller's output: one access unit, every NAL
/// length-prefixed with four big-endian bytes. SPS/PPS bodies are not decodable streams,
/// only structurally valid NAL units, which is all the accessory parses.
final class H264Tests: XCTestCase {

    // MARK: - Helpers

    private func nal(_ type: UInt8, _ body: [UInt8], refIdc: UInt8 = 3) -> [UInt8] {
        var out: [UInt8] = [0, 0, 0, 0]
        let length = body.count + 1
        out[0] = UInt8((length >> 24) & 0xff)
        out[1] = UInt8((length >> 16) & 0xff)
        out[2] = UInt8((length >> 8) & 0xff)
        out[3] = UInt8(length & 0xff)
        out.append((refIdc << 5) | (type & 0x1f))
        out.append(contentsOf: body)
        return out
    }

    /// SPS header with profile 0x64 (High), compatibility 0x00, level 0x1f (3.1).
    private var spsBody: [UInt8] { [0x64, 0x00, 0x1f, 0xaa, 0xbb, 0xcc] }
    private var ppsBody: [UInt8] { [0xee, 0x38, 0x80] }
    private var idrBody: [UInt8] { [0x88, 0x84, 0x21] }

    private func accessUnit(_ parts: [[UInt8]]) -> Data {
        Data(parts.flatMap { $0 })
    }

    // MARK: - Splitting

    func testSplitReadsEveryLengthPrefixedUnit() throws {
        let unit = accessUnit([nal(7, spsBody), nal(8, ppsBody), nal(5, idrBody)])
        let units = try H264.split(accessUnit: unit)
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[0].nalType, .sps)
        XCTAssertEqual(units[1].nalType, .pps)
        XCTAssertEqual(units[2].nalType, .idrSlice)
        XCTAssertEqual(units[0].bytes.count, spsBody.count + 1)
        XCTAssertEqual(units[0].nalRefIdc, 3)
    }

    func testSplitHonoursATwoByteLengthSize() throws {
        var out: [UInt8] = []
        for part in [nal(7, spsBody), nal(5, idrBody)] {
            // Strip the four-byte prefix the helper added and re-emit with two bytes.
            let body = Array(part.dropFirst(4))
            let length = body.count
            out.append(UInt8((length >> 8) & 0xff))
            out.append(UInt8(length & 0xff))
            out.append(contentsOf: body)
        }
        let units = try H264.split(accessUnit: Data(out), lengthSize: .two)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].nalType, .sps)
        XCTAssertEqual(units[1].nalType, .idrSlice)
    }

    func testSplitRejectsAnEmptyUnit() {
        XCTAssertThrowsError(try H264.split(accessUnit: Data())) { error in
            XCTAssertEqual(error as? H264.ParseError, .empty)
        }
    }

    func testSplitRejectsATruncatedLengthPrefix() {
        // Three bytes where four are needed.
        XCTAssertThrowsError(try H264.split(accessUnit: Data([0, 0, 0]))) { error in
            XCTAssertEqual(error as? H264.ParseError, .truncatedLengthPrefix)
        }
    }

    func testSplitRejectsABodyShorterThanDeclared() {
        // Length says 9, only 3 follow.
        let bad = Data([0, 0, 0, 9, 0x65, 0x88, 0x84])
        XCTAssertThrowsError(try H264.split(accessUnit: bad)) { error in
            XCTAssertEqual(error as? H264.ParseError, .truncatedBody)
        }
    }

    func testSplitRejectsAZeroLengthUnit() {
        let bad = Data([0, 0, 0, 0, 0x65])
        XCTAssertThrowsError(try H264.split(accessUnit: bad)) { error in
            XCTAssertEqual(error as? H264.ParseError, .zeroLengthNAL)
        }
    }

    // MARK: - NAL classification

    func testPictureAndParameterFlagsAreDistinct() throws {
        let units = try H264.split(accessUnit: accessUnit([nal(7, spsBody), nal(8, ppsBody), nal(5, idrBody)]))
        XCTAssertTrue(units[0].isParameterSet)
        XCTAssertFalse(units[0].isIDR)
        XCTAssertTrue(units[1].isParameterSet)
        XCTAssertTrue(units[2].isIDR)
        XCTAssertTrue(units[2].isKeyframe)
        XCTAssertFalse(units[2].isParameterSet)
    }

    func testNonIDRSliceIsNotAKeyframe() throws {
        let units = try H264.split(accessUnit: accessUnit([nal(1, [0x9a, 0x11], refIdc: 2)]))
        XCTAssertEqual(units[0].nalType, .slice)
        XCTAssertFalse(units[0].isIDR)
        XCTAssertFalse(units[0].isKeyframe)
        XCTAssertEqual(units[0].nalRefIdc, 2)
    }

    func testAnnexBIsRecognisedButIsNotTheReceiveFormat() {
        let annexB = Data([0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1f])
        XCTAssertTrue(H264.looksAnnexB(annexB))
        // The receive path only speaks AVCC, so an Annex-B buffer is not a valid unit.
        XCTAssertThrowsError(try H264.split(accessUnit: annexB))
    }

    // MARK: - avcC

    func testConfigurationRecordComesFromTheParameterSets() throws {
        let units = try H264.split(accessUnit: accessUnit([nal(7, spsBody), nal(8, ppsBody), nal(5, idrBody)]))
        let record = try XCTUnwrap(H264.ConfigurationRecord(units: units))
        XCTAssertEqual(record.profileIndication, 0x64)
        XCTAssertEqual(record.profileCompatibility, 0x00)
        XCTAssertEqual(record.levelIndication, 0x1f)
        XCTAssertEqual(record.lengthSize, .four)
        XCTAssertEqual(record.sps.count, 1)
        XCTAssertEqual(record.pps.count, 1)
        XCTAssertEqual(Array(record.sps[0]), [0x67] + spsBody, "the NAL header byte is part of the parameter set")
        XCTAssertEqual(Array(record.pps[0]), [0x68] + ppsBody)
    }

    func testConfigurationRecordNeedsBothParameterSets() throws {
        let onlySPS = try H264.split(accessUnit: accessUnit([nal(7, spsBody), nal(5, idrBody)]))
        XCTAssertNil(H264.ConfigurationRecord(units: onlySPS))
        let onlyPPS = try H264.split(accessUnit: accessUnit([nal(8, ppsBody)]))
        XCTAssertNil(H264.ConfigurationRecord(units: onlyPPS))
    }

    func testAvcCBoxLayoutMatchesTheAppleExpectation() throws {
        let units = try H264.split(accessUnit: accessUnit([nal(7, spsBody), nal(8, ppsBody)]))
        let record = try XCTUnwrap(H264.ConfigurationRecord(units: units))
        let box = H264.avcCBox(record)
        let bytes = [UInt8](box)
        XCTAssertEqual(bytes[0], 1, "configurationVersion")
        XCTAssertEqual(bytes[1], 0x64, "profile")
        XCTAssertEqual(bytes[2], 0x00, "compatibility")
        XCTAssertEqual(bytes[3], 0x1f, "level")
        XCTAssertEqual(bytes[4], 0xff, "reserved bits plus lengthSizeMinusOne=3")
        XCTAssertEqual(bytes[5], 0xe1, "reserved bits plus one SPS")
        XCTAssertEqual(bytes[6], 0x00)
        XCTAssertEqual(bytes[7], UInt8(spsBody.count + 1))
        XCTAssertEqual(Array(bytes[8..<(8 + spsBody.count + 1)]), [0x67] + spsBody)
        let ppsCountAt = 8 + spsBody.count + 1
        XCTAssertEqual(bytes[ppsCountAt], 1, "one PPS")
        XCTAssertEqual(bytes[ppsCountAt + 1], 0x00)
        XCTAssertEqual(bytes[ppsCountAt + 2], UInt8(ppsBody.count + 1))
        XCTAssertEqual(Array(bytes[(ppsCountAt + 3)..<(ppsCountAt + 3 + ppsBody.count + 1)]), [0x68] + ppsBody)
        XCTAssertEqual(bytes.suffix(2), [0, 0], "two trailing bytes for the decoder's read-past")
    }

    func testAvcCRoundTripsThroughItsParser() throws {
        let units = try H264.split(accessUnit: accessUnit([nal(7, spsBody), nal(8, ppsBody)]))
        let record = try XCTUnwrap(H264.ConfigurationRecord(units: units))
        let parsed = try H264.parseConfigurationRecord(H264.avcCBox(record))
        XCTAssertEqual(parsed.profileIndication, record.profileIndication)
        XCTAssertEqual(parsed.levelIndication, record.levelIndication)
        XCTAssertEqual(parsed.lengthSize, record.lengthSize)
        XCTAssertEqual(parsed.sps, record.sps)
        XCTAssertEqual(parsed.pps, record.pps)
    }

    func testParserRejectsAReservedLengthSize() {
        // lengthSizeMinusOne == 2 is reserved by the spec.
        var box = [UInt8](repeating: 0, count: 12)
        box[0] = 1
        box[4] = 0xfe
        XCTAssertThrowsError(try H264.parseConfigurationRecord(Data(box))) { error in
            XCTAssertEqual(error as? H264.ParseError, .badLengthSize)
        }
    }

    func testMultipleParameterSetsAreAllCarried() throws {
        let secondSPS: [UInt8] = [0x4d, 0x00, 0x1e, 0x11]
        let units = try H264.split(accessUnit: accessUnit([nal(7, spsBody), nal(7, secondSPS), nal(8, ppsBody)]))
        let record = try XCTUnwrap(H264.ConfigurationRecord(units: units))
        XCTAssertEqual(record.sps.count, 2)
        XCTAssertEqual(Array(record.sps[1]), [0x67] + secondSPS)
        let parsed = try H264.parseConfigurationRecord(H264.avcCBox(record))
        XCTAssertEqual(parsed.sps.count, 2)
    }

    // MARK: - Classification

    func testAPlainSliceIsDelivered() throws {
        let disposition = try AccessUnitClassifier.classify(accessUnit([nal(1, [0x9a])]))
        XCTAssertEqual(disposition.kind, .deliver)
        XCTAssertTrue(disposition.hasSlice)
        XCTAssertFalse(disposition.isKeyframe)
        XCTAssertNil(disposition.record)
    }

    func testParameterSetsWithASliceReconfigureFirst() throws {
        let unit = accessUnit([nal(7, spsBody), nal(8, ppsBody), nal(5, idrBody)])
        let disposition = try AccessUnitClassifier.classify(unit)
        XCTAssertEqual(disposition.kind, .reconfigure)
        XCTAssertTrue(disposition.isKeyframe)
        XCTAssertNotNil(disposition.record)
        XCTAssertEqual(disposition.units.count, 3)
    }

    func testParameterSetsAloneAreNotAPicture() throws {
        let disposition = try AccessUnitClassifier.classify(accessUnit([nal(7, spsBody), nal(8, ppsBody)]))
        XCTAssertEqual(disposition.kind, .parameterSetsOnly)
        XCTAssertFalse(disposition.hasSlice)
        XCTAssertFalse(disposition.isKeyframe)
        XCTAssertNotNil(disposition.record)
    }

    func testSEIOnlyIsNotAPictureEither() throws {
        let disposition = try AccessUnitClassifier.classify(accessUnit([nal(6, [0x05, 0x01])]))
        XCTAssertEqual(disposition.kind, .parameterSetsOnly)
        XCTAssertFalse(disposition.hasSlice)
    }

    func testCapabilityProfileNamesNoAudio() {
        XCTAssertEqual(AccessUnitClassifier.capabilityProfile, "car_h264_full_initial_arbitration_no_audio_v3")
        XCTAssertTrue(AccessUnitClassifier.capabilityProfile.contains("no_audio"))
    }
}
