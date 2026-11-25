import XCTest
@testable import PandaPlayCore

/// End-to-end coverage for the session layer: a controller speaks signalling frames on
/// the control lane and a window channel's touch payloads on a media lane, and the session
/// answers with the same bytes a real accessory would.
final class ReceiveSessionTests: XCTestCase {

    private func makeSession(
        screenWidth: Int = 1280,
        screenHeight: Int = 720
    ) -> (ReceiveSession, RecordingHost) {
        var options = ReceiverOptions()
        options.controlPort = 7000
        options.mediaPortBase = 7100
        options.mediaCandidateCount = 4
        options.screenWidth = screenWidth
        options.screenHeight = screenHeight
        options.advertise = false
        let telemetry = TelemetryLog(clock: { 0 })
        let host = RecordingHost()
        let session = ReceiveSession(
            options: options,
            identity: try? PairingIdentity.create(),
            telemetry: telemetry,
            host: host
        )
        session.prepare(ports: [7000, 7100, 7101, 7102])
        return (session, host)
    }

    private func helloPayload(_ fill: UInt8 = 0x11) -> Data {
        Data(repeating: fill, count: MediaFrame.headerSize)
    }

    // MARK: - Lane layout

    func testLanesMatchTheSevenPortBand() {
        let (session, _) = makeSession()
        XCTAssertEqual(session.lanes.count, 4)
        XCTAssertEqual(session.lanes[0].kind, .control)
        XCTAssertEqual(session.lanes[1].kind, .video)
        XCTAssertEqual(session.lanes[2].kind, .video)
        XCTAssertEqual(session.state, .negotiating)
    }

    func testFirstTwoSlotsAreSignallingAndTheRestAreWindows() {
        XCTAssertFalse(ChannelSlot.usesWindowFraming(slot: 0))
        XCTAssertFalse(ChannelSlot.usesWindowFraming(slot: 1))
        XCTAssertTrue(ChannelSlot.usesWindowFraming(slot: 2))
        XCTAssertTrue(ChannelSlot.usesWindowFraming(slot: 6))
    }

    func testPortsAreTakenFromTheBand() {
        let (session, _) = makeSession()
        XCTAssertEqual(session.lanes.map(\.port), [7000, 7100, 7101, 7102])
    }

    // MARK: - Hello

    func testHelloPinsTheRoleAndAnswersOnTheWire() {
        let (session, _) = makeSession()
        let reply = session.receive(
            MediaFrame(command: .c2pHello, payload: helloPayload()).toBytes(),
            onSlot: 0
        )
        let parsed = MediaFrame.read(reply)
        XCTAssertEqual(parsed.status, .ok)
        XCTAssertEqual(parsed.frame?.command, .c2pHelloReply)
        XCTAssertEqual(session.responder.roleOf(0), 1)
        XCTAssertTrue(session.responder.isArmed(0))
        XCTAssertEqual(session.framesAuthenticated, 1)
    }

    func testHelloReplyCarriesNoPayload() {
        let (session, _) = makeSession()
        let reply = session.receive(
            MediaFrame(command: .c2pHello, payload: helloPayload()).toBytes(),
            onSlot: 0
        )
        let parsed = MediaFrame.read(reply)
        XCTAssertEqual(parsed.frame?.payload.count, 0)
        XCTAssertEqual(parsed.frame?.totalLength, UInt32(MediaFrame.headerSize))
    }

    func testShortHelloIsIgnored() {
        let (session, _) = makeSession()
        let reply = session.receive(
            MediaFrame(command: .p2cHello, payload: Data(repeating: 0, count: 4)).toBytes(),
            onSlot: 0
        )
        XCTAssertTrue(reply.isEmpty)
        XCTAssertEqual(session.responder.roleOf(0), 0)
        XCTAssertEqual(session.framesAuthenticated, 0)
    }

    func testDuplicateHelloIsRefused() {
        let (session, _) = makeSession()
        let hello = MediaFrame(command: .c2pHello, payload: helloPayload()).toBytes()
        _ = session.receive(hello, onSlot: 0)
        let second = session.receive(hello, onSlot: 0)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(session.framesAuthenticated, 1)
    }

    // MARK: - Control lane

    func testControlRequestIsAnsweredOnceWithTheStagedBody() {
        let (session, _) = makeSession()
        _ = session.receive(
            MediaFrame(command: .c2pHello, payload: helloPayload()).toBytes(),
            onSlot: 0
        )
        let surface = PlistValue.dict()
            .add("width", .from(Int64(1280)))
            .add("height", .from(Int64(720)))
        session.responder.stageControlReply(PlistCodec.encode(surface))

        let reply = session.receive(
            MediaFrame(command: .controlRequest, payload: Data()).toBytes(),
            onSlot: 0
        )
        let parsed = MediaFrame.read(reply)
        XCTAssertEqual(parsed.frame?.command, .controlReply)
        guard let body = parsed.frame?.payload else {
            return XCTFail("control reply carried no body")
        }
        let decoded = PlistCodec.decode(body).value
        XCTAssertEqual(decoded?.getInteger("width", -1), 1280)
        XCTAssertEqual(decoded?.getInteger("height", -1), 720)
        XCTAssertTrue(session.responder.stagedControlReply.isEmpty)
    }

    func testControlReplyIsOneShot() {
        let (session, _) = makeSession()
        _ = session.receive(
            MediaFrame(command: .c2pHello, payload: helloPayload()).toBytes(),
            onSlot: 0
        )
        session.responder.stageControlReply(PlistCodec.encode(PlistValue.dict().add("a", .from(1))))
        _ = session.receive(MediaFrame(command: .controlRequest).toBytes(), onSlot: 0)
        let second = session.receive(MediaFrame(command: .controlRequest).toBytes(), onSlot: 0)
        XCTAssertTrue(second.isEmpty, "the staged buffer is consumed by the first reply")
    }

    func testClockRequestIsAnsweredWithTheEnvelope() {
        let (session, _) = makeSession()
        _ = session.receive(
            MediaFrame(command: .c2pHello, payload: helloPayload()).toBytes(),
            onSlot: 0
        )
        let reply = session.receive(
            MediaFrame(command: .clockRequest).toBytes(),
            onSlot: 0
        )
        let parsed = MediaFrame.read(reply)
        XCTAssertEqual(parsed.frame?.command, .clockReply)
        let text = String(decoding: parsed.frame?.payload ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"time\":"), "unexpected envelope: \(text)")
        XCTAssertTrue(text.contains("\"currentTime\":"))
        XCTAssertTrue(text.contains("\"currentTimeZone\":\""))
    }

    func testPeerReplyIsNeverAnswered() {
        let (session, _) = makeSession()
        _ = session.receive(
            MediaFrame(command: .c2pHello, payload: helloPayload()).toBytes(),
            onSlot: 0
        )
        // 0x10045 is odd, i.e. a controller's own reply to something. It is not a named
        // case, so the frame is built by hand rather than through MediaCommand.
        let reply = session.receive(rawFrame(command: 0x0001_0045, payload: Data()), onSlot: 0)
        XCTAssertTrue(reply.isEmpty)
    }

    /// Builds a signalling frame around an arbitrary command word, checksum included.
    private func rawFrame(command: UInt32, payload: Data) -> Data {
        var out = [UInt8](repeating: 0, count: MediaFrame.headerSize + payload.count)
        let total = UInt32(payload.count + MediaFrame.headerSize)
        ByteOrder.writeU32BE(&out, 0, command)
        ByteOrder.writeU32BE(&out, 4, total)
        ByteOrder.writeU32BE(&out, 8, command ^ total)
        if !payload.isEmpty {
            out.replaceSubrange(
                MediaFrame.headerSize..<(MediaFrame.headerSize + payload.count),
                with: payload
            )
        }
        return Data(out)
    }

    // MARK: - Touch on the control lane

    func testTouchOnTheControlLaneIsAdmitted() {
        let (session, _) = makeSession()
        _ = session.receive(
            MediaFrame(command: .c2pHello, payload: helloPayload()).toBytes(),
            onSlot: 0
        )
        let touch = TouchMessage(action: .down, x: 400, y: 250)
        _ = session.receive(
            MediaFrame(command: .controlRequest, payload: touch.toPayload()).toBytes(),
            onSlot: 0
        )
        XCTAssertEqual(session.touchAdmitted, 1)
        XCTAssertEqual(session.touchWritten, 1)
        XCTAssertEqual(session.telemetry.count(prefix: "media_touch_"), 1)
    }

    func testTouchBeyondTheSurfaceIsRejected() {
        let (session, _) = makeSession()
        _ = session.receive(
            MediaFrame(command: .c2pHello, payload: helloPayload()).toBytes(),
            onSlot: 0
        )
        // The clamp path needs an already-pressed surface, so a lone out-of-range move
        // is the case that has to be refused outright.
        _ = session.receive(
            MediaFrame(command: .controlRequest, payload: TouchMessage(action: .move, x: 4000, y: 4000).toPayload()).toBytes(),
            onSlot: 0
        )
        XCTAssertEqual(session.touchRejected, 1)
        XCTAssertEqual(session.touchWritten, 0)
    }

    // MARK: - Media lanes

    func testVideoPullDeliversAnAccessUnit() {
        let (session, host) = makeSession()
        let accessUnit = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88])
        let reply = session.receive(
            MediaFrame(command: .videoPull, payload: accessUnit).toBytes(),
            onSlot: 1
        )
        XCTAssertTrue(reply.isEmpty, "the video lane never answers")
        XCTAssertEqual(session.framesDecoded, 1)
        XCTAssertEqual(host.accessUnits.count, 1)
        XCTAssertEqual(host.accessUnits.first?.lane.slot, 1)
        XCTAssertEqual(host.accessUnits.first?.data, accessUnit)
    }

    func testEmptyVideoPullIsRejectedAndAsksForKeyframe() {
        let (session, host) = makeSession()
        _ = session.receive(MediaFrame(command: .videoPull, payload: Data()).toBytes(), onSlot: 1)
        XCTAssertEqual(session.framesDecoded, 0)
        XCTAssertEqual(session.framesRejected, 1)
        XCTAssertEqual(session.keyframeRequests, 1)
        XCTAssertEqual(host.keyframeReasons, ["frame_missing_slice"])
    }

    func testSignallingFrameOnTheVideoLaneIsDroppedSilently() {
        let (session, _) = makeSession()
        let reply = session.receive(
            MediaFrame(command: .controlStatus, payload: Data(repeating: 0, count: 8)).toBytes(),
            onSlot: 1
        )
        XCTAssertTrue(reply.isEmpty)
        XCTAssertEqual(session.framesDecoded, 0)
        XCTAssertEqual(session.framesRejected, 0, "a known word is not a framing failure")
    }

    func testUnknownWordOnTheVideoLaneIsRejected() {
        let (session, _) = makeSession()
        _ = session.receive(rawFrame(command: 0x0000_0088, payload: Data([0x01])), onSlot: 1)
        XCTAssertEqual(session.framesRejected, 1)
    }

    // MARK: - Window lane

    func testWindowTouchReachesTheSurface() {
        let (session, _) = makeSession()
        let payload = TouchMessage(action: .down, x: 640, y: 360).toPayload()
        let wire = MediaWindowFramer.build(
            command: MediaWindowFramer.pull,
            payload: payload
        )
        let reply = session.receive(wire, onSlot: 2)
        XCTAssertTrue(reply.isEmpty, "a window lane is one-directional")
        XCTAssertEqual(session.touchAdmitted, 2, "the window path records the phase and the sample")
        XCTAssertEqual(session.lanes[2].touchAccepted, 1)
    }

    func testWindowTouchSequenceIsCounted() {
        let (session, _) = makeSession()
        func send(_ message: TouchMessage) {
            _ = session.receive(
                MediaWindowFramer.build(command: MediaWindowFramer.pull, payload: message.toPayload()),
                onSlot: 2
            )
        }
        send(TouchMessage(action: .down, x: 100, y: 100))
        send(TouchMessage(action: .move, x: 120, y: 120))
        send(TouchMessage(action: .up, x: 120, y: 120))
        XCTAssertEqual(session.lanes[2].touchAccepted, 3)
        XCTAssertEqual(session.lanes[2].touchRejected, 0)
    }

    func testWindowMoveWithoutDownIsRejected() {
        let (session, _) = makeSession()
        _ = session.receive(
            MediaWindowFramer.build(
                command: MediaWindowFramer.pull,
                payload: TouchMessage(action: .move, x: 10, y: 10).toPayload()
            ),
            onSlot: 2
        )
        XCTAssertEqual(session.lanes[2].touchRejected, 1)
        XCTAssertEqual(session.lanes[2].touchAccepted, 0)
    }

    // MARK: - Setup and commands

    func testSetupAnswersEachStreamOnItsOwnPort() {
        let (session, _) = makeSession()
        let body = PlistValue.dict().add(
            "streams",
            .array([
                PlistValue.dict().add("type", .from(Int64(110))),
                PlistValue.dict().add("type", .from(Int64(110))),
            ])
        )
        let reply = session.control.debugHandleSetup(body)
        let streams = reply?.tryGet("streams")?.items ?? []
        XCTAssertEqual(streams.count, 2)
        XCTAssertEqual(streams[0].getInteger("dataPort", -1), 7000)
        XCTAssertEqual(streams[1].getInteger("dataPort", -1), 7100)
        XCTAssertEqual(session.state, .streaming)
    }

    func testSetupRejectsAnEmptyStreamList() {
        let (session, _) = makeSession()
        let body = PlistValue.dict().add("streams", .array([]))
        XCTAssertNil(session.control.debugHandleSetup(body))
        XCTAssertNotEqual(session.state, .streaming)
    }

    func testTakeScreenReportsTheConfiguredSurface() {
        let (session, _) = makeSession()
        let result = session.control.debugHandleCommand(
            ControlCommand(
                wireType: "takeScreen",
                internalType: "take_screen",
                params: PlistValue.dict(),
                cseq: 3
            )
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.extras?.getInteger("width", -1), 1280)
        XCTAssertEqual(result.extras?.getInteger("height", -1), 720)
        XCTAssertTrue(session.control.screenConfigured)
    }

    func testReleaseScreenPausesTheSession() {
        let (session, _) = makeSession()
        _ = session.control.debugHandleCommand(
            ControlCommand(wireType: "takeScreen", internalType: "take_screen", params: .dict(), cseq: 1)
        )
        _ = session.control.debugHandleCommand(
            ControlCommand(wireType: "releaseScreen", internalType: "release_screen", params: .dict(), cseq: 2)
        )
        XCTAssertFalse(session.control.screenConfigured)
        XCTAssertEqual(session.state, .paused)
    }

    func testForceKeyFrameRaisesARequest() {
        let (session, host) = makeSession()
        _ = session.control.debugHandleCommand(
            ControlCommand(wireType: "forceKeyFrame", internalType: "force_key_frame", params: .dict(), cseq: 4)
        )
        XCTAssertEqual(session.keyframeRequests, 1)
        XCTAssertEqual(host.keyframeReasons, ["force_key_frame"])
    }

    func testUnknownCommandIsUnsupported() {
        let (session, _) = makeSession()
        let result = session.control.debugHandleCommand(
            ControlCommand(wireType: "nope", internalType: "nope", params: .dict(), cseq: 5)
        )
        if case .unsupported = result.outcome {
            // expected
        } else {
            XCTFail("expected an unsupported outcome, got \(result.outcome)")
        }
    }

    // MARK: - Control pull and diagnostics

    func testControlPullIsSentOnceAfterTheAccessoryTakesRoleTwo() {
        let (session, _) = makeSession()
        _ = session.receive(
            MediaFrame(command: .p2cHello, payload: helloPayload()).toBytes(),
            onSlot: 0
        )
        XCTAssertEqual(session.responder.roleOf(0), 2)
        let pull = session.takeControlPull()
        let parsed = MediaFrame.read(pull ?? Data())
        XCTAssertEqual(parsed.frame?.command, .videoPull)
        XCTAssertEqual(String(decoding: parsed.frame?.payload ?? Data(), as: UTF8.self), "{\"control\":1}")
        XCTAssertNil(session.takeControlPull(), "the pull is one-shot")
    }

    func testSnapshotEmitsTheSessionCounters() {
        let (session, _) = makeSession()
        session.emitSnapshot()
        let rendered = session.telemetry.render()
        for key in [
            "usb_projection_last_preparation_failure",
            "receiver_capability_profile",
            "receiver_modes_scope",
            "receiver_audio_ownership_policy",
            "receiver_decoder_recovery_policy",
            "protocol_ledger_count",
        ] {
            XCTAssertTrue(rendered.contains(key), "missing \(key)")
        }
    }

    func testPrepareEmitsTheTransportMarkers() {
        let (session, _) = makeSession()
        let rendered = session.telemetry.render()
        XCTAssertTrue(rendered.contains("media_listener_ready"))
        XCTAssertTrue(rendered.contains("seven_fixed_ipv4_loopback_listeners"))
        XCTAssertTrue(rendered.contains("frame_delivery_poll_hz"))
    }

    func testAdvertisementUsesTheCustomServiceType() {
        let (session, _) = makeSession()
        let advert = session.advertisement(host: "pandaplay", address: 0x7F00_0001)
        XCTAssertEqual(advert.serviceType, "panda.wireless-car")
        XCTAssertNotEqual(advert.serviceType, "_airplay._tcp")
        XCTAssertEqual(advert.port, 7000)
    }
}

/// Captures what the session hands to the host so tests can assert on delivery.
final class RecordingHost: ReceiverHost {
    struct Delivered {
        let data: Data
        let lane: MediaLane
    }

    private(set) var accessUnits: [Delivered] = []
    private(set) var keyframeReasons: [String] = []

    func deliverAccessUnit(_ accessUnit: Data, on lane: MediaLane) {
        accessUnits.append(Delivered(data: accessUnit, lane: lane))
    }

    func requestKeyframe(reason: String) {
        keyframeReasons.append(reason)
    }
}
