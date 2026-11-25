import XCTest
@testable import PandaPlayCore

final class BonjourTests: XCTestCase {
    private let advertisement = BonjourAdvertisement(
        instanceName: "Box",
        port: 7000,
        hostName: "box",
        address: 0xC0A8_0001
    )

    func testNames() {
        XCTAssertEqual(advertisement.serviceTypeFqdn, "panda.wireless-car.local")
        XCTAssertEqual(advertisement.instanceFqdn, "Box.panda.wireless-car.local")
        XCTAssertEqual(advertisement.hostFqdn, "box.local")
    }

    func testRecordSet() {
        let records = advertisement.records()
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records[0].type, .ptr)
        XCTAssertEqual(records[1].type, .srv)
        XCTAssertEqual(records[2].type, .txt)
        XCTAssertEqual(records[3].type, .a)

        var offset = 0
        let srv = [UInt8](records[1].data)
        XCTAssertEqual(DnsWire.readU16BE(srv, 4), 7000)
        offset = 6
        XCTAssertEqual(DnsWire.readName(srv, &offset), "box.local")
    }

    func testPtrAnswersAServiceBrowse() throws {
        let query = DnsWire.encodeQuery(name: "panda.wireless-car.local", type: .ptr, id: 9)
        let reply = try XCTUnwrap(BonjourResponder.respond(to: query, advertisement: advertisement))
        let bytes = [UInt8](reply)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 0), 9)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 6), 1)

        // Question block: name, qtype, qclass.
        var offset = DnsWire.headerSize
        XCTAssertEqual(try XCTUnwrap(DnsWire.readName(bytes, &offset)), "panda.wireless-car.local")
        offset += 4

        // Answer block: the owner name is written out in full, not compressed.
        XCTAssertEqual(try XCTUnwrap(DnsWire.readName(bytes, &offset)), "panda.wireless-car.local")
        XCTAssertEqual(DnsWire.readU16BE(bytes, offset), DnsType.ptr.rawValue)

        var rdataOffset = offset + 10
        XCTAssertEqual(try XCTUnwrap(DnsWire.readName(bytes, &rdataOffset)),
                       "Box.panda.wireless-car.local")
    }

    func testSrvAndTxtAnswers() throws {
        let srvQuery = DnsWire.encodeQuery(name: "Box.panda.wireless-car.local", type: .srv)
        let srvReply = try XCTUnwrap(BonjourResponder.respond(to: srvQuery, advertisement: advertisement))
        XCTAssertEqual(DnsWire.readU16BE([UInt8](srvReply), 6), 1)

        let txtQuery = DnsWire.encodeQuery(name: "Box.panda.wireless-car.local", type: .txt)
        let txtReply = try XCTUnwrap(BonjourResponder.respond(to: txtQuery, advertisement: advertisement))
        XCTAssertEqual(DnsWire.readU16BE([UInt8](txtReply), 6), 1)
    }

    func testUnrelatedQuestionIsIgnored() {
        let query = DnsWire.encodeQuery(name: "example.com", type: .a)
        XCTAssertNil(BonjourResponder.respond(to: query, advertisement: advertisement))
    }

    func testWrongTypeIsIgnored() {
        let query = DnsWire.encodeQuery(name: "panda.wireless-car.local", type: .a)
        XCTAssertNil(BonjourResponder.respond(to: query, advertisement: advertisement))
    }

    func testGoodbyeCarriesZeroTtl() {
        let packet = BonjourResponder.goodbye(advertisement: advertisement)
        let bytes = [UInt8](packet)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 6), 4)

        // No questions, so the first answer starts right after the header.
        var offset = DnsWire.headerSize
        _ = DnsWire.readName(bytes, &offset)
        let ttl = UInt32(DnsWire.readU16BE(bytes, offset + 4)) << 16
            | UInt32(DnsWire.readU16BE(bytes, offset + 6))
        XCTAssertEqual(ttl, 0)
    }

    func testAnnouncementHasNoQuestions() {
        let packet = BonjourResponder.announcement(advertisement: advertisement)
        let bytes = [UInt8](packet)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 4), 0)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 6), 4)
        XCTAssertEqual(DnsWire.readU16BE(bytes, 2) & DnsWire.flagResponse, DnsWire.flagResponse)
    }

    func testTxtCarriesTheTypeTag() throws {
        let records = advertisement.records()
        let txt = DnsWire.parseTxt(records[2].data)
        XCTAssertEqual(txt["ty"], "PandaPlay+")
        XCTAssertEqual(txt["ver"], "1.3")
        XCTAssertEqual(txt["proto"], "1")
        XCTAssertEqual(txt["srcvers"], "1.0.2")
    }
}
