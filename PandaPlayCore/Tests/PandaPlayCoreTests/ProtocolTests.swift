import XCTest
@testable import PandaPlayCore

final class FramingTests: XCTestCase {
    func testSignallingHeaderLayout() {
        let frame = MediaFrame(command: .controlRequest, auxiliary: 0, payload: Data([0xaa, 0xbb, 0xcc]))
        let wire = frame.toBytes()
        XCTAssertEqual(wire.count, 19)
        XCTAssertEqual(ByteOrder.readU32BE(wire.withUnsafeBytes { $0 }, 0), 0x0001_0010)
        XCTAssertEqual(ByteOrder.readU32BE(wire.withUnsafeBytes { $0 }, 4), 19)
        XCTAssertEqual(
            ByteOrder.readU32BE(wire.withUnsafeBytes { $0 }, 8),
            0x0001_0010 ^ 19
        )
        XCTAssertEqual(wire[16], 0xaa)
    }

    func testRoundTrip() {
        let frame = MediaFrame(command: .videoPull, auxiliary: 7, payload: Data(repeating: 0x5a, count: 40))
        let result = MediaFrame.read(frame.toBytes())
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.consumed, 56)
        XCTAssertEqual(result.frame?.command, .videoPull)
        XCTAssertEqual(result.frame?.auxiliary, 7)
        XCTAssertEqual(result.frame?.payload.count, 40)
    }

    func testBadChecksumRejected() {
        var wire = [UInt8](MediaFrame(command: .controlAck).toBytes())
        wire[8] ^= 0xff
        XCTAssertEqual(MediaFrame.read(Data(wire)).status, .badChecksum)
    }

    func testShortTotalRejected() {
        var wire = [UInt8](repeating: 0, count: 16)
        ByteOrder.writeU32BE(&wire, 0, 0x0001_0010)
        ByteOrder.writeU32BE(&wire, 4, 12)
        ByteOrder.writeU32BE(&wire, 8, 0x0001_0010 ^ 12)
        XCTAssertEqual(MediaFrame.read(Data(wire)).status, .shortHeader)
    }

    func testStrictAndLenientCeilings() {
        let oversized = 0x4000
        var wire = [UInt8](repeating: 0, count: 16)
        ByteOrder.writeU32BE(&wire, 0, 0x0001_0010)
        ByteOrder.writeU32BE(&wire, 4, UInt32(oversized))
        ByteOrder.writeU32BE(&wire, 8, 0x0001_0010 ^ UInt32(oversized))
        XCTAssertEqual(MediaFrame.read(Data(wire)).status, .frameTooLarge)
        XCTAssertEqual(MediaFrame.read(Data(wire), lenient: true).status, .needMore)
    }

    func testHelloCategoryDependsOnPayload() {
        XCTAssertEqual(MediaFrame.categoryOf(.c2pHello, payloadLength: 16), .c2pHello)
        XCTAssertEqual(MediaFrame.categoryOf(.c2pHello, payloadLength: 4), .unknown)
        XCTAssertEqual(MediaFrame.categoryOf(.p2cHello, payloadLength: 16), .p2cHello)
    }

    func testOddWordsAreReplies() {
        XCTAssertTrue(MediaFrame.isReply(.c2pHelloReply))
        XCTAssertTrue(MediaFrame.isReply(.controlReply))
        XCTAssertFalse(MediaFrame.isReply(.c2pHello))
        XCTAssertFalse(MediaFrame.isReply(.videoPull))
    }

    func testConstants() {
        XCTAssertEqual(MediaFrame.headerSize, 16)
        XCTAssertEqual(MediaFrame.maxSendPayload, 1008)
        XCTAssertEqual(MediaFrame.maxReceiveTotal, 8192)
        XCTAssertEqual(MediaFrame.frameLimit, 128)
        XCTAssertEqual(MediaWindowFramer.headerSize, 8)
        XCTAssertEqual(MediaWindowFramer.maxPayload, 4096)
        XCTAssertEqual(MediaWindowFramer.frameLimit, 2048)
    }
}

final class MediaWindowTests: XCTestCase {
    private func touch(_ action: Int16, _ x: Int16, _ y: Int16) -> Data {
        var out = [UInt8](repeating: 0, count: 10)
        ByteOrder.writeI16BE(&out, 0, action)
        ByteOrder.writeI16BE(&out, 2, x)
        ByteOrder.writeI16BE(&out, 4, y)
        return Data(out)
    }

    func testWindowHeaderLayout() {
        let wire = MediaWindowFramer.build(command: 0x10, payload: Data([1, 2, 3]))
        XCTAssertEqual(wire.count, 11)
        XCTAssertEqual(ByteOrder.readU16LE(wire.withUnsafeBytes { $0 }, 0), 0x10)
        XCTAssertEqual(ByteOrder.readU16LE(wire.withUnsafeBytes { $0 }, 2), 3)
        XCTAssertEqual(ByteOrder.readU32LE(wire.withUnsafeBytes { $0 }, 4), 0)
        XCTAssertEqual(wire[8], 1)
    }

    func testFramesSplitOutOfOneChunk() {
        let framer = MediaWindowFramer(kind: .control, slot: 0)
        var received: [UInt16] = []
        framer.onPayload = { command, _ in received.append(command) }
        let body = Data(repeating: 0, count: 27)
        var chunk = Data()
        chunk.append(MediaWindowFramer.build(command: 0x10, payload: body))
        chunk.append(MediaWindowFramer.build(command: 0x10, payload: body))
        chunk.append(MediaWindowFramer.build(command: 0x10, payload: body))
        framer.feed(chunk)
        XCTAssertEqual(framer.framesRead, 3)
        XCTAssertEqual(received.count, 3)
    }

    func testAssemblyAcrossReads() {
        let framer = MediaWindowFramer(kind: .control, slot: 0)
        let wire = MediaWindowFramer.build(command: 0x70, payload: Data(repeating: 9, count: 5))
        for byte in wire { framer.feed(Data([byte])) }
        XCTAssertEqual(framer.framesRead, 1)
        XCTAssertTrue(framer.claimed)
        XCTAssertEqual(framer.claimedCommand, 0x70)
    }

    func testTouchSequence() {
        let framer = MediaWindowFramer(kind: .video, slot: 2)
        framer.surfaceWidth = 100
        framer.surfaceHeight = 50
        var phases: [TouchPhase] = []
        framer.onTouch = { phase, _, _ in phases.append(phase) }

        framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(1, 40, 20)))
        framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(2, 70, 40)))
        framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(3, 70, 40)))

        XCTAssertEqual(phases, [.down, .move, .up])
        XCTAssertEqual(framer.touchRejected, 0)
        XCTAssertEqual(framer.touchAccepted, 3)
    }

    func testTouchOutOfBoundsWithoutClamping() {
        let framer = MediaWindowFramer(kind: .video, slot: 2)
        framer.surfaceWidth = 100
        framer.surfaceHeight = 50
        var phases: [TouchPhase] = []
        framer.onTouch = { phase, _, _ in phases.append(phase) }

        // Every one of these is outside the surface and lenient mode is off, so all
        // three are refused and no phase reaches the consumer.
        _ = framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(1, 640, 360)))
        _ = framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(2, 700, 400)))
        _ = framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(3, 700, 400)))

        XCTAssertEqual(phases.count, 0)
        XCTAssertEqual(framer.touchRejected, 3)
    }

    func testTouchRejections() {
        let framer = MediaWindowFramer(kind: .video, slot: 2)
        framer.surfaceWidth = 100
        framer.surfaceHeight = 50

        XCTAssertEqual(framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(2, 10, 10))), .moveWithoutDown)
        XCTAssertEqual(framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(1, 10, 10))), .accepted)
        XCTAssertEqual(framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(1, 10, 10))), .duplicateDown)
        XCTAssertEqual(framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(9, 10, 10))), .invalidAction)
        XCTAssertEqual(framer.feed(MediaWindowFramer.build(command: 0x72, payload: Data([1, 2]))), .payloadTooShort)
    }

    func testClamping() {
        let framer = MediaWindowFramer(kind: .video, slot: 2)
        framer.surfaceWidth = 100
        framer.surfaceHeight = 50
        framer.lenientMode = true
        var last: (Int, Int)?
        framer.onTouch = { _, x, y in last = (x, y) }

        framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(1, 10, 10)))
        framer.feed(MediaWindowFramer.build(command: 0x72, payload: touch(3, 500, 500)))
        XCTAssertEqual(last?.0, 99)
        XCTAssertEqual(last?.1, 49)
        XCTAssertEqual(framer.touchClamped, 1)
    }

    func testOversizedPayloadRefused() {
        let framer = MediaWindowFramer(kind: .control, slot: 0)
        var wire = [UInt8](repeating: 0, count: 8)
        ByteOrder.writeU16LE(&wire, 0, 0x10)
        ByteOrder.writeU16LE(&wire, 2, UInt16(MediaWindowFramer.maxPayload + 1))
        framer.feed(Data(wire))
        XCTAssertEqual(framer.oversizedFrames, 1)
    }
}

final class TouchMessageTests: XCTestCase {
    func testPayloadRoundTrip() {
        let message = TouchMessage(action: .down, x: 640, y: 360)
        let payload = message.toPayload()
        XCTAssertEqual(payload.count, 10)
        let parsed = TouchMessage.parse(payload)
        XCTAssertEqual(parsed?.action, .down)
        XCTAssertEqual(parsed?.x, 640)
        XCTAssertEqual(parsed?.y, 360)
    }

    func testRejectsShortPayload() {
        XCTAssertNil(TouchMessage.parse(Data(repeating: 0, count: 4)))
    }

    func testProcessorRules() {
        let processor = TouchProcessor(width: 100, height: 50)
        XCTAssertEqual(processor.apply(TouchMessage(action: .move, x: 1, y: 1)).outcome, .moveWithoutDown)
        XCTAssertEqual(processor.apply(TouchMessage(action: .down, x: 10, y: 10)).outcome, .accepted)
        XCTAssertEqual(processor.apply(TouchMessage(action: .down, x: 10, y: 10)).outcome, .duplicateDown)
        XCTAssertEqual(processor.apply(TouchMessage(action: .up, x: 10, y: 10)).outcome, .accepted)
        XCTAssertEqual(processor.apply(TouchMessage(action: .move, x: 10, y: 10)).outcome, .moveWithoutDown)
        XCTAssertEqual(processor.sentCount, 2)
    }

    func testProcessorClampsOnlyWhilePressed() {
        let processor = TouchProcessor(width: 100, height: 50)
        XCTAssertEqual(processor.apply(TouchMessage(action: .up, x: 500, y: 500)).outcome, .outOfBounds)
        processor.apply(TouchMessage(action: .down, x: 10, y: 10))
        let result = processor.apply(TouchMessage(action: .up, x: 500, y: 500))
        XCTAssertEqual(result.outcome, .accepted)
        XCTAssertEqual(result.effective.x, 99)
        XCTAssertEqual(processor.clampedCount, 1)
    }

    func testProcessorUnconfigured() {
        let processor = TouchProcessor(width: 0, height: 0)
        XCTAssertEqual(processor.apply(TouchMessage(action: .down, x: 0, y: 0)).outcome, .notConfigured)
    }

    func testTouchOutcomeKeepsTheZeroCollision() {
        XCTAssertEqual(TouchOutcome.accepted.rawValue, 0)
        XCTAssertEqual(TouchOutcome.payloadTooShort.rawValue, 0)
        XCTAssertTrue(TouchOutcome.accepted.isSuccess)
    }
}

final class RtspTests: XCTestCase {
    func testTargetsAndMethods() {
        XCTAssertEqual(RtspCommandType.target(of: "/pair-setup"), .pairSetup)
        XCTAssertEqual(RtspCommandType.target(of: "/pair-verify"), .pairVerify)
        XCTAssertEqual(RtspCommandType.target(of: "/auth-setup"), .authSetup)
        XCTAssertEqual(RtspCommandType.target(of: "/info"), .info)
        XCTAssertEqual(RtspCommandType.target(of: "/feedback"), .feedback)
        XCTAssertEqual(RtspCommandType.target(of: "/command"), .command)
        XCTAssertEqual(RtspCommandType.target(of: "/nope"), .unknown)

        XCTAssertEqual(RtspCommandType.method(of: "SETUP"), .setup)
        XCTAssertEqual(RtspCommandType.method(of: "RECORD"), .record)
        XCTAssertEqual(RtspCommandType.method(of: "TEARDOWN"), .teardown)
        XCTAssertEqual(RtspCommandType.method(of: "SET_PARAMETER"), .setParameter)
        XCTAssertEqual(RtspCommandType.method(of: "POST"), .none)
    }

    func testInternalNames() {
        XCTAssertEqual(RtspCommandType.internalName(for: "takeScreen"), "take_screen")
        XCTAssertEqual(RtspCommandType.internalName(for: "forceKeyFrame"), "force_key_frame")
        XCTAssertEqual(RtspCommandType.internalName(for: "hidCopyInputMode"), "hid_copy_input_mode")
        XCTAssertEqual(RtspCommandType.internalName(for: "bogus"), "invalid")
    }

    func testStatusLines() {
        XCTAssertEqual(RtspResponse.statusLine(.ok), "200 OK")
        XCTAssertEqual(RtspResponse.statusLine(.badRequest), "400 Bad Request")
        XCTAssertEqual(RtspResponse.statusLine(.forbidden), "403 Forbidden")
        XCTAssertEqual(RtspResponse.statusLine(.unsupportedTransport), "461 Unsupported Transport")
        XCTAssertEqual(RtspResponse.statusLine(.notImplemented), "501 Not Implemented")
        XCTAssertEqual(RtspResponse.statusLine(.serviceUnavailable), "503 Service Unavailable")
    }

    func testRequestParse() {
        let raw = Data("POST /command RTSP/1.0\r\nCSeq: 7\r\nContent-Length: 3\r\n\r\nabc".utf8)
        var failure: RtspParseFailure?
        let request = RtspRequest.parse(raw, failure: &failure)
        XCTAssertNil(failure)
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.target, "/command")
        XCTAssertEqual(request?.cseq, 7)
        XCTAssertEqual(request?.body.count, 3)
    }

    func testRejectsBadVersion() {
        var failure: RtspParseFailure?
        let raw = Data("POST /command RTSP/9.9\r\nCSeq: 1\r\n\r\n".utf8)
        XCTAssertNil(RtspRequest.parse(raw, failure: &failure))
        XCTAssertEqual(failure, .version)
    }

    func testRejectsDuplicateHeader() {
        var failure: RtspParseFailure?
        let raw = Data("POST /command RTSP/1.0\r\nCSeq: 1\r\nCSeq: 2\r\n\r\n".utf8)
        XCTAssertNil(RtspRequest.parse(raw, failure: &failure))
        XCTAssertEqual(failure, .headerSyntax)
    }

    func testResponseShape() {
        let empty = RtspResponse.ok(cseq: 3)
        let text = String(data: empty, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("RTSP/1.0 200 OK\r\nCSeq: 3\r\n"))
        XCTAssertTrue(text.hasSuffix("Content-Length: 0\r\n\r\n"))

        let withBody = RtspResponse.ok(cseq: 4, body: Data([1, 2, 3]), contentType: RtspResponse.octetStreamContentType)
        let bodyText = String(data: withBody, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyText.contains("Content-Type: application/octet-stream"))
        XCTAssertTrue(bodyText.contains("Content-Length: 3"))
    }
}

final class PxcAndResponderTests: XCTestCase {
    func testHelloKeyOrder() {
        var hello = PxcHello()
        hello.phoneUuid = "abc"
        let json = hello.toJSON()
        let order = ["pxcVersion", "phoneUUID", "phoneBrand", "phoneModel", "phoneOs",
                     "package", "phoneOsVersion", "versionCode", "supportH264IFrame",
                     "supportFunction", "appVersionFingerPrint", "token", "pubkey",
                     "encryptedHUID", "currentTimeZone"]
        var cursor = json.startIndex
        for key in order {
            guard let found = json.range(of: "\"\(key)\"", range: cursor..<json.endIndex) else {
                XCTFail("missing key \(key)")
                return
            }
            cursor = found.upperBound
        }
    }

    func testHelloForcedFalse() {
        let json = PxcHello().toJSON()
        XCTAssertTrue(json.contains("\"supportH264IFrame\":false"))
        XCTAssertTrue(json.contains("\"versionCode\":1"))
        XCTAssertTrue(json.contains("\"appVersionFingerPrint\":\"\""))
    }

    func testClockEnvelopeSharesTheValue() {
        let text = PxcHello.clockEnvelope(time: 1234, currentTime: 1234, timeZone: "UTC")
        XCTAssertEqual(text, "{\"time\":1234,\"currentTime\":1234,\"currentTimeZone\":\"UTC\"}")
    }

    func testHelloOpensALane() {
        let responder = MediaResponder(laneCount: 4)
        let decision = responder.respond(lane: 0, command: .c2pHello, payloadLength: 16, clock: 5, timeZone: "UTC")
        XCTAssertEqual(decision.kind, .handshakeReply)
        XCTAssertEqual(decision.reply, .c2pHelloReply)
        XCTAssertEqual(responder.roleOf(0), 1)
        XCTAssertFalse(responder.isArmed(0))
    }

    func testDuplicateHelloRefused() {
        let responder = MediaResponder(laneCount: 4)
        _ = responder.respond(lane: 0, command: .c2pHello, payloadLength: 16, clock: 0, timeZone: "UTC")
        let second = responder.respond(lane: 0, command: .c2pHello, payloadLength: 16, clock: 0, timeZone: "UTC")
        XCTAssertEqual(second.diagnostic, "duplicate_hello")
    }

    func testShortHelloRefused() {
        let responder = MediaResponder(laneCount: 4)
        let decision = responder.respond(lane: 0, command: .p2cHello, payloadLength: 4, clock: 0, timeZone: "UTC")
        XCTAssertEqual(decision.diagnostic, "hello_payload_length")
    }

    func testUnarmedLaneStaysSilent() {
        let responder = MediaResponder(laneCount: 4)
        let decision = responder.respond(lane: 0, command: .controlAck, payloadLength: 0, clock: 0, timeZone: "UTC")
        XCTAssertTrue(decision.isSilent)
        XCTAssertEqual(decision.diagnostic, "lane_not_armed")
    }

    func testArmedLaneAnswersControlRequestOnce() {
        let responder = MediaResponder(laneCount: 4)
        _ = responder.respond(lane: 0, command: .c2pHello, payloadLength: 16, clock: 0, timeZone: "UTC")
        responder.markArmed(0)
        responder.stageControlReply(Data([9, 9, 9]))

        let first = responder.respond(lane: 0, command: .controlRequest, payloadLength: 0, clock: 0, timeZone: "UTC")
        XCTAssertEqual(first.kind, .controlPayload)
        XCTAssertEqual(first.reply, .controlReply)
        XCTAssertEqual(first.payload, Data([9, 9, 9]))

        let second = responder.respond(lane: 0, command: .controlRequest, payloadLength: 0, clock: 0, timeZone: "UTC")
        XCTAssertTrue(second.isSilent)
        XCTAssertEqual(second.diagnostic, "control_reply_unavailable")
    }

    func testRepliesAreNeverAnswered() {
        let responder = MediaResponder(laneCount: 4)
        _ = responder.respond(lane: 0, command: .c2pHello, payloadLength: 16, clock: 0, timeZone: "UTC")
        responder.markArmed(0)
        // 0x10011 is odd, so it is the peer answering us; answering it back would start
        // an acknowledgement loop.
        let decision = responder.respond(lane: 0, command: .controlReply, payloadLength: 0, clock: 0, timeZone: "UTC")
        XCTAssertTrue(decision.isSilent)
        XCTAssertEqual(decision.diagnostic, "p2c_response")
    }

    func testClockReply() {
        let responder = MediaResponder(laneCount: 4)
        _ = responder.respond(lane: 0, command: .c2pHello, payloadLength: 16, clock: 0, timeZone: "UTC")
        responder.markArmed(0)
        let decision = responder.respond(lane: 0, command: .clockRequest, payloadLength: 0, clock: 99, timeZone: "UTC")
        XCTAssertEqual(decision.kind, .clockReply)
        XCTAssertEqual(decision.reply, .clockReply)
        XCTAssertEqual(String(data: decision.payload, encoding: .utf8),
                       "{\"time\":99,\"currentTime\":99,\"currentTimeZone\":\"UTC\"}")
    }

    func testControlPullShape() {
        let frame = MediaResponder.buildControlPull()
        XCTAssertEqual(frame.command, .videoPull)
        XCTAssertEqual(frame.payload, Data("{\"control\":1}".utf8))
        XCTAssertEqual(frame.payload.count, 13)
    }
}
