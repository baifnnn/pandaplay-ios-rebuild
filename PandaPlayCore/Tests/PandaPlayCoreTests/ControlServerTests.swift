import XCTest
@testable import PandaPlayCore

final class ControlServerTests: XCTestCase {
    /// The server must outlive the exchange: `attach` installs a `[weak self]` receive
    /// closure, so a discarded server silently drops every reply.
    private func connect(
        info: (() -> PlistValue)? = nil,
        setup: ((PlistValue) -> PlistValue?)? = nil,
        pairing: PairingSession? = nil,
        screenConfigured: Bool = false
    ) -> (ControlServer, LoopbackChannel) {
        let server = ControlServer()
        server.infoProvider = info
        server.setupHandler = setup
        server.pairing = pairing
        server.screenConfigured = screenConfigured
        let (client, host) = LoopbackChannel.pair()
        server.attach(host)
        return (server, client)
    }

    private func request(_ method: String, _ target: String, cseq: Int, body: Data? = nil) -> Data {
        var text = "\(method) \(target) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        if let body {
            text += "Content-Type: application/x-apple-binary-plist\r\n"
            text += "Content-Length: \(body.count)\r\n\r\n"
            var out = Data(text.utf8)
            out.append(body)
            return out
        }
        return Data((text + "\r\n").utf8)
    }

    /// Splits one response into its head text and its declared body.
    private func split(_ data: Data) -> (head: String, body: Data) {
        guard let boundary = RtspRequest.findHeaderEnd(data) else {
            return (String(data: data, encoding: .utf8) ?? "", Data())
        }
        let head = String(data: data.subdata(in: 0..<boundary.headerEnd), encoding: .utf8) ?? ""
        var length = 0
        for line in head.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data.count >= boundary.bodyStart + length
            ? data.subdata(in: boundary.bodyStart..<(boundary.bodyStart + length))
            : Data()
        return (head, body)
    }

    // MARK: - Targets

    func testOptionsIsAnswered() {
        let (server, client) = connect()
        client.send(request("OPTIONS", "*", cseq: 1))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 200 OK"))
        XCTAssertTrue(reply.head.contains("CSeq: 1"))
        XCTAssertEqual(server.optionsAnswered, 1)
    }

    func testUnknownTargetIsNotImplemented() {
        let (server, client) = connect()
        client.send(request("GET", "/nope", cseq: 2))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 501 Not Implemented"), "got [\(reply.head)]")
        XCTAssertEqual(server.requestsParsed, 1)
    }

    func testInfoUsesOctetStreamButShipsAPlist() {
        let (server, client) = connect()
        client.send(request("GET", "/info", cseq: 3))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 200 OK"))
        XCTAssertTrue(reply.head.contains("Content-Type: application/octet-stream"))
        XCTAssertEqual(reply.body.prefix(8), Data("bplist00".utf8))
        XCTAssertEqual(server.infoAnswered, 1)
    }

    func testFeedbackNeedsAConfiguredScreen() {
        let (server, client) = connect(screenConfigured: false)
        let body = PlistCodec.encode(PlistValue.dict().add("type", .from("x")))
        client.send(request("POST", "/feedback", cseq: 4, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 400 Bad Request"), "got [\(reply.head)]")
        XCTAssertEqual(server.feedbackAnswered, 0)
    }

    func testFeedbackIsAnsweredOnceConfigured() {
        let (server, client) = connect(screenConfigured: true)
        let body = PlistCodec.encode(PlistValue.dict().add("type", .from("x")))
        client.send(request("POST", "/feedback", cseq: 5, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 200 OK"))
        XCTAssertEqual(server.feedbackAnswered, 1)
    }

    func testAuthSetupAcknowledgesWithoutClaimingSuccess() {
        let (server, client) = connect()
        let body = PlistCodec.encode(PlistValue.dict().add("name", .from("x")))
        client.send(request("POST", "/auth-setup", cseq: 6, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 200 OK"))
        XCTAssertEqual(server.authSetupAnswered, 1)
    }

    // MARK: - Stream methods

    func testSetupWithoutAHandlerIsUnsupportedTransport() {
        let (server, client) = connect(setup: nil)
        let body = PlistCodec.encode(PlistValue.dict().add("streams", .array([])))
        client.send(request("SETUP", "/stream", cseq: 7, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 461 Unsupported Transport"), "got [\(reply.head)]")
        XCTAssertEqual(server.setupsAnswered, 0)
    }

    func testSetupWithAHandlerEchoesPorts() {
        let handler: (PlistValue) -> PlistValue? = { _ in
            PlistValue.dict().add("streams", .array([
                PlistValue.dict()
                    .add("type", .from(Int64(110)))
                    .add("dataPort", .from(7100))
                    .add("controlPort", .from(7101))
            ]))
        }
        let (server, client) = connect(setup: handler)
        let body = PlistCodec.encode(PlistValue.dict().add("streams", .array([
            PlistValue.dict().add("type", .from(Int64(110)))
        ])))
        client.send(request("SETUP", "/stream", cseq: 8, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 200 OK"), "got [\(reply.head)]")
        let decoded = PlistCodec.decode(reply.body).value
        let streams = decoded?.tryGet("streams")?.items
        XCTAssertEqual(streams?.count, 1)
        XCTAssertEqual(streams?.first?.getInteger("dataPort", -1), 7100)
        XCTAssertEqual(server.setupsAnswered, 1)
    }

    func testRecordTeardownSetParameterAreAccepted() {
        let (server, client) = connect()
        client.send(request("RECORD", "/stream", cseq: 9))
        let record = split(client.takeReceived()).head
        client.send(request("TEARDOWN", "/stream", cseq: 10))
        let teardown = split(client.takeReceived()).head
        client.send(request("SET_PARAMETER", "/stream", cseq: 11))
        let setParameter = split(client.takeReceived()).head
        XCTAssertTrue(record.hasPrefix("RTSP/1.0 200 OK"), "record [\(record)]")
        XCTAssertTrue(teardown.hasPrefix("RTSP/1.0 200 OK"), "teardown [\(teardown)]")
        XCTAssertTrue(setParameter.hasPrefix("RTSP/1.0 200 OK"), "set_parameter [\(setParameter)]")
        XCTAssertEqual(server.recordsAnswered, 1)
        XCTAssertEqual(server.teardownsAnswered, 1)
        XCTAssertEqual(server.setParametersAnswered, 1)
    }

    // MARK: - Commands

    func testCommandWithoutBodyIsBadRequest() {
        let (server, client) = connect()
        client.send(request("POST", "/command", cseq: 12))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 400 Bad Request"), "got [\(reply.head)]")
        XCTAssertEqual(server.commandsHandled, 0)
    }

    func testTakeScreenAnswersWithTheSurface() {
        let (server, client) = connect()
        server.screenWidth = 1280
        server.screenHeight = 720
        let body = PlistCodec.encode(PlistValue.dict()
            .add("type", .from("takeScreen"))
            .add("params", .dict()))
        client.send(request("POST", "/command", cseq: 13, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 200 OK"), "got [\(reply.head)]")
        let decoded = PlistCodec.decode(reply.body).value
        XCTAssertEqual(decoded?.getInteger("width", -1), 1280)
        XCTAssertEqual(decoded?.getInteger("height", -1), 720)
    }

    func testDisableBluetoothIsPureSignalling() {
        let (server, client) = connect()
        let body = PlistCodec.encode(PlistValue.dict().add("type", .from("disableBluetooth")))
        client.send(request("POST", "/command", cseq: 14, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 200 OK"), "got [\(reply.head)]")
        XCTAssertTrue(reply.body.isEmpty)
        XCTAssertEqual(server.commandsHandled, 1)
    }

    func testUnknownCommandIsNotImplemented() {
        let (server, client) = connect()
        let body = PlistCodec.encode(PlistValue.dict().add("type", .from("noSuchCommand")))
        client.send(request("POST", "/command", cseq: 15, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 501 Not Implemented"), "got [\(reply.head)]")
        XCTAssertEqual(server.commandsHandled, 1)
    }

    func testTouchIsDecodedFromParams() {
        let (server, client) = connect()
        var seen: TouchMessage?
        server.onTouch = { seen = $0 }
        let body = PlistCodec.encode(PlistValue.dict()
            .add("type", .from("hidSetInputMode"))
            .add("params", .dict()
                .add("action", .from(Int64(1)))
                .add("x", .from(640))
                .add("y", .from(360))))
        client.send(request("POST", "/command", cseq: 16, body: body))
        XCTAssertEqual(seen?.action, .down)
        XCTAssertEqual(seen?.x, 640)
        XCTAssertEqual(seen?.y, 360)
    }

    // MARK: - Pairing

    func testPairSetupWithoutASessionIsUnavailable() {
        let (server, client) = connect()
        let body = PlistCodec.encode(PlistValue.dict().add("state", .from(1)))
        client.send(request("POST", "/pair-setup", cseq: 17, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 503 Service Unavailable"), "got [\(reply.head)]")
        XCTAssertEqual(server.pairSetupAnswered, 0)
    }

    func testPairSetupFirstStep() throws {
        let identity = try PairingIdentity.create()
        let session = PairingSession(identity: identity)
        let (server, client) = connect(pairing: session)
        let body = PlistCodec.encode(PlistValue.dict().add("state", .from(1)))
        client.send(request("POST", "/pair-setup", cseq: 18, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 200 OK"), "got [\(reply.head)]")
        let decoded = PlistCodec.decode(reply.body).value
        XCTAssertEqual(decoded?.getInteger("state", -1), 2)
        XCTAssertEqual(decoded?.tryGet("salt")?.bytes?.count, 32)
        XCTAssertEqual(decoded?.tryGet("publicKey")?.bytes?.count, 384)
        XCTAssertEqual(server.pairSetupAnswered, 1)
    }

    func testPairSetupUnknownStateIsBadRequest() throws {
        let identity = try PairingIdentity.create()
        let session = PairingSession(identity: identity)
        let (server, client) = connect(pairing: session)
        let body = PlistCodec.encode(PlistValue.dict().add("state", .from(9)))
        client.send(request("POST", "/pair-setup", cseq: 19, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 400 Bad Request"), "got [\(reply.head)]")
        XCTAssertEqual(server.pairSetupAnswered, 0)
    }

    func testPairVerifyWithoutASessionIsUnavailable() {
        let (server, client) = connect()
        let body = PlistCodec.encode(PlistValue.dict().add("state", .from(1)))
        client.send(request("POST", "/pair-verify", cseq: 20, body: body))
        let reply = split(client.takeReceived())
        XCTAssertTrue(reply.head.hasPrefix("RTSP/1.0 503 Service Unavailable"), "got [\(reply.head)]")
        XCTAssertEqual(server.pairVerifyAnswered, 0)
    }
}

final class InfoPayloadTests: XCTestCase {
    func testFeaturesTrackThePhysicalSize() {
        let withoutPhysical = InfoPayload.build(
            deviceID: Data([0xab]), width: 1920, height: 1080, uuid: "u"
        )
        XCTAssertEqual(withoutPhysical.getInteger("features", -1), 0)

        let withPhysical = InfoPayload.build(
            deviceID: Data([0xab]), width: 1920, height: 1080, uuid: "u", physicalWidth: 1920
        )
        XCTAssertEqual(withPhysical.getInteger("features", -1), 8)
    }

    func testDisplayShape() {
        let body = InfoPayload.build(deviceID: Data([0x01, 0x02]), width: 1920, height: 1080, uuid: "abc")
        let displays = body.tryGet("displays")?.items
        XCTAssertEqual(displays?.count, 1)
        let display = displays?.first
        XCTAssertEqual(display?.getInteger("widthPixels", -1), 1920)
        XCTAssertEqual(display?.getInteger("heightPixels", -1), 1080)
        XCTAssertEqual(display?.getInteger("maxFPS", -1), 60)
        XCTAssertEqual(display?.tryGet("safeArea")?.getInteger("type", -1), 110)
    }

    func testModesAndIdentity() {
        let body = InfoPayload.build(deviceID: Data([0xde, 0xad]), width: 800, height: 600, uuid: "u")
        XCTAssertEqual(body.getString("sourceVersion"), "1.0.2")
        XCTAssertEqual(body.getString("deviceID"), "dead")
        XCTAssertEqual(body.getString("model"), "PandaPlay+")
        let modes = body.tryGet("modes")
        XCTAssertEqual(modes?.getInteger("screen", -1), 0)
        XCTAssertEqual(modes?.getInteger("audio", -1), 0)
        XCTAssertEqual(modes?.getInteger("video", -1), 0)
    }

    func testEncodesAsBinaryPlist() {
        let data = InfoPayload.encode(deviceID: Data([1]), width: 100, height: 100, uuid: "u")
        XCTAssertEqual(data.prefix(8), Data("bplist00".utf8))
        XCTAssertNotNil(PlistCodec.decode(data).value)
    }
}
