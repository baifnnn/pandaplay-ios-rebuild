import XCTest
@testable import PandaPlayCore

final class TelemetryTests: XCTestCase {
    func testRecordsCarryUptimeAndValue() {
        var now: Int64 = 1_000
        let log = TelemetryLog(clock: { now })
        now = 1_250
        log.emit("receiver_control_tcp_connected", true)
        now = 1_500
        log.emit("receiver_decoded_frames", 7)

        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log.records[0].uptimeMilliseconds, 250)
        XCTAssertEqual(log.records[0].key, "receiver_control_tcp_connected")
        XCTAssertEqual(log.records[0].value, "true")
        XCTAssertEqual(log.records[1].value, "7")
    }

    func testBoolRendersAsTrueAndFalse() {
        let log = TelemetryLog()
        log.emit("a", true)
        log.emit("b", false)
        XCTAssertEqual(log.last("a"), "true")
        XCTAssertEqual(log.last("b"), "false")
    }

    func testFloatKeepsThreeDecimals() {
        let log = TelemetryLog()
        log.emit("touch_move_rate_hz", 12.3456)
        XCTAssertEqual(log.last("touch_move_rate_hz"), "12.346")
        log.emit("ratio", 2.0)
        XCTAssertEqual(log.last("ratio"), "2.000")
    }

    func testRenderUsesTabAndEquals() {
        var now: Int64 = 0
        let log = TelemetryLog(clock: { now })
        now = 12
        log.emit("k", 1)
        XCTAssertEqual(log.render(), "12\tk=1")
    }

    func testCountByPrefix() {
        let log = TelemetryLog()
        log.emit("media_touch_down", true)
        log.emit("media_touch_up", true)
        log.emit("receiver_decoded_frames", 1)
        XCTAssertEqual(log.count(prefix: "media_touch_"), 2)
        XCTAssertEqual(log.count(prefix: "nothing_"), 0)
    }

    func testRecordsAreCapped() {
        let log = TelemetryLog()
        log.maxRecords = 4
        for i in 0..<10 { log.emit("k", i) }
        XCTAssertEqual(log.count, 4)
        XCTAssertEqual(log.records.first?.value, "6")
        XCTAssertEqual(log.last("k"), "9")
    }

    func testDisabledLogRecordsNothing() {
        let log = TelemetryLog()
        log.enabled = false
        log.emit("k", 1)
        XCTAssertEqual(log.count, 0)
    }
}

final class FrameLengthHistogramTests: XCTestCase {
    func testPassthroughBoundary() {
        XCTAssertEqual(FrameLengthHistogram.band(for: 0), 1)
        XCTAssertEqual(FrameLengthHistogram.band(for: 8192), 1)
        XCTAssertEqual(FrameLengthHistogram.band(for: 8193), 2)
    }

    func testThresholdTable() {
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x4000), 2)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x4001), 3)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x8000), 3)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x8001), 4)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x10000), 4)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x10001), 5)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x40000), 5)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x40001), 6)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x100000), 6)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x100001), 7)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x400000), 7)
        XCTAssertEqual(FrameLengthHistogram.band(for: 0x400001), 8)
    }

    func testCountsLandInTheRightBucket() {
        var histogram = FrameLengthHistogram()
        histogram.add(100)
        histogram.add(0x4001)
        histogram.add(0x4001)
        histogram.add(0x200000)
        XCTAssertEqual(histogram.total, 4)
        XCTAssertEqual(histogram[1], 1)
        XCTAssertEqual(histogram[3], 2)
        XCTAssertEqual(histogram[7], 1)
        XCTAssertEqual(histogram.bands.reduce(0, +), 4)
    }
}

final class DnsWireTests: XCTestCase {
    func testNameLengthMatchesTheWire() {
        XCTAssertEqual(DnsWire.nameLength("panda.wireless-car.local"), 26)
        var buffer = [UInt8](repeating: 0, count: 64)
        var offset = 0
        XCTAssertTrue(DnsWire.writeName(&buffer, &offset, "panda.wireless-car.local"))
        XCTAssertEqual(offset, 26)
    }

    func testQueryRoundTrip() throws {
        let data = DnsWire.encodeQuery(name: "panda.wireless-car.local", type: .ptr, id: 0x1234)
        let parsed = try XCTUnwrap(DnsWire.parseQuery(data))
        XCTAssertEqual(parsed.id, 0x1234)
        XCTAssertEqual(parsed.questions.count, 1)
        XCTAssertEqual(parsed.questions[0].name, "panda.wireless-car.local")
        XCTAssertEqual(parsed.questions[0].type, .ptr)
        XCTAssertEqual(parsed.questions[0].classValue, .in)
    }

    func testResponseIsIgnoredAsAQuery() {
        let query = DnsWire.encodeQuery(name: "x.local", type: .any)
        var bytes = [UInt8](query)
        bytes[2] |= 0x80
        XCTAssertNil(DnsWire.parseQuery(Data(bytes)))
    }

    func testCompressedNameIsFollowed() throws {
        // "a.local" at offset 0, then a question that points back at it.
        var buffer = [UInt8](repeating: 0, count: 64)
        var write = 0
        DnsWire.writeName(&buffer, &write, "a.local")
        let nameEnd = write
        buffer[write] = 0xC0
        buffer[write + 1] = 0x00
        var read = write
        let name = try XCTUnwrap(DnsWire.readName(buffer, &read))
        XCTAssertEqual(name, "a.local")
        XCTAssertEqual(read, nameEnd + 2)
    }

    func testPointerLoopIsRejected() {
        var buffer = [UInt8](repeating: 0, count: 8)
        buffer[0] = 0xC0
        buffer[1] = 0x00
        var offset = 0
        XCTAssertNil(DnsWire.readName(buffer, &offset))
    }

    func testTxtDataShape() {
        let data = DnsWire.txtData(["ty=PandaPlay+", "ver=1.3"])
        XCTAssertEqual(data.count, 22)
        let parsed = DnsWire.parseTxt(data)
        XCTAssertEqual(parsed["ty"], "PandaPlay+")
        XCTAssertEqual(parsed["ver"], "1.3")
    }

    func testEmptyTxtIsASingleZero() {
        XCTAssertEqual(DnsWire.txtData([]), Data([0]))
        XCTAssertTrue(DnsWire.parseTxt(DnsWire.txtData([])).isEmpty)
    }

    func testBareKeyParsesWithEmptyValue() {
        let parsed = DnsWire.parseTxt(DnsWire.txtData(["flag"]))
        XCTAssertEqual(parsed["flag"], "")
    }

    func testResponseRoundTrip() throws {
        let question = DnsQuestion(name: "panda.wireless-car.local", type: .ptr)
        let answers = [
            DnsRecord(name: "panda.wireless-car.local", type: .ptr,
                      data: DnsWire.ptrData(target: "Box.panda.wireless-car.local")),
            DnsRecord(name: "Box.panda.wireless-car.local", type: .srv,
                      data: DnsWire.srvData(priority: 0, weight: 0, port: 7000,
                                            target: "box.local")),
            DnsRecord(name: "Box.panda.wireless-car.local", type: .txt,
                      data: DnsWire.txtData(["ty=PandaPlay+"])),
            DnsRecord(name: "box.local", type: .a, data: DnsWire.aData(0x7F00_0001)),
        ]
        let encoded = DnsWire.encodeResponse(id: 0x4321, questions: [question], answers: answers)
        XCTAssertEqual(encoded.count > 0, true)

        let bytes = [UInt8](encoded)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 0), 0x4321)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 2) & DnsWire.flagResponse, DnsWire.flagResponse)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 4), 1)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 6), 4)

        // Walk forward past the question and confirm the first answer is a PTR.
        var offset = DnsWire.headerSize
        let questionName = try XCTUnwrap(DnsWire.readName(bytes, &offset))
        XCTAssertEqual(questionName, "panda.wireless-car.local")
        offset += 4
        let answerName = try XCTUnwrap(DnsWire.readName(bytes, &offset))
        XCTAssertEqual(answerName, "panda.wireless-car.local")
        XCTAssertEqual(DnsWire.readU16BE(bytes, offset), DnsType.ptr.rawValue)
        XCTAssertEqual(DnsWire.readU16BE(bytes, offset + 2) & 0x7FFF, DnsClass.in.rawValue)
        XCTAssertEqual(DnsWire.readU16BE(bytes, offset + 2) & 0x8000, 0x8000)
        XCTAssertEqual(DnsWire.readU16BE(bytes, offset + 8) > 0, true)
    }

    func testSrvDataLayout() {
        let data = DnsWire.srvData(priority: 1, weight: 2, port: 7100, target: "h.local")
        let bytes = [UInt8](data)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 0), 1)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 2), 2)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 4), 7100)
        var offset = 6
        XCTAssertEqual(DnsWire.readName(bytes, &offset), "h.local")
    }

    func testRetimedLeavesTheOriginalAlone() {
        let record = DnsRecord(name: "a.local", type: .ptr, data: Data([1]))
        let goodbye = record.retimed(ttl: 0)
        XCTAssertEqual(record.ttl, 4500)
        XCTAssertEqual(goodbye.ttl, 0)
        XCTAssertEqual(goodbye.data, record.data)
    }
}
