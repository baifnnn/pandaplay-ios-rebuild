import Foundation

/// Outcome a command handler reports back for the `/command` target.
public enum CommandOutcome: Sendable {
    case accepted
    case rejected(Int64?)
    case unsupported
    case malformed
}

/// One `/command` request after the plist body has been decoded.
public struct ControlCommand: Sendable {
    public let wireType: String
    public let internalType: String
    public let params: PlistValue
    public let cseq: Int

    public init(wireType: String, internalType: String, params: PlistValue, cseq: Int) {
        self.wireType = wireType
        self.internalType = internalType
        self.params = params
        self.cseq = cseq
    }
}

public struct CommandResult: Sendable {
    public var outcome: CommandOutcome = .accepted
    public var status: Int64?
    public var extras: PlistValue?

    public static func accepted(status: Int64? = nil, extras: PlistValue? = nil) -> CommandResult {
        CommandResult(outcome: .accepted, status: status, extras: extras)
    }
    public static func rejected(_ status: Int64? = nil) -> CommandResult {
        CommandResult(outcome: .rejected(status))
    }
    public static func unsupported() -> CommandResult {
        CommandResult(outcome: .unsupported)
    }
}

/// The RTSP control endpoint.
///
/// Six named targets and four stream methods, not the single `/command` method a first
/// reading of the strings table suggests. Every routing decision here has a matching
/// branch in the accessory's dispatcher.
public final class ControlServer: @unchecked Sendable {
    /// The accessory buffers at most 64 KiB of request before it gives up.
    public static let maxBuffered = 0x10000

    private let lock = NSLock()
    private var buffered = Data()
    private var channel: ByteChannel?
    private var closed = false

    public private(set) var connectionsAccepted = 0
    public private(set) var requestsParsed = 0
    public private(set) var requestsRejected = 0
    public private(set) var optionsAnswered = 0
    public private(set) var commandsHandled = 0
    public private(set) var infoAnswered = 0
    public private(set) var feedbackAnswered = 0
    public private(set) var pairSetupAnswered = 0
    public private(set) var pairVerifyAnswered = 0
    public private(set) var authSetupAnswered = 0
    public private(set) var setupsAnswered = 0
    public private(set) var recordsAnswered = 0
    public private(set) var teardownsAnswered = 0
    public private(set) var setParametersAnswered = 0

    public var onLog: ((String, Any) -> Void)?
    public var commandHandler: ((ControlCommand) -> CommandResult)?
    public var onTouch: ((TouchMessage) -> Void)?
    public var pairing: PairingSession?
    public var infoProvider: (() -> PlistValue)?
    public var setupHandler: ((PlistValue) -> PlistValue?)?
    public var feedbackHandler: ((PlistValue) -> PlistValue?)?
    public var screenConfigured = false
    /// Screen size reported by `/info`. Kept here so the default probe answer is honest
    /// even before a controller has said anything.
    public var screenWidth = 1920
    public var screenHeight = 1080
    public var deviceID = Data()

    public init() {}

    public func attach(_ channel: ByteChannel) {
        lock.lock()
        self.channel = channel
        buffered = Data()
        closed = false
        connectionsAccepted += 1
        lock.unlock()
        onLog?("receiver_control_tcp_connected", true)
        onLog?("receiver_control_tcp_connections", connectionsAccepted)
        channel.onReceive = { [weak self] data in
            self?.ingest(data)
        }
        channel.onClose = { [weak self] in
            self?.markClosed()
        }
    }

    private func markClosed() {
        lock.lock()
        closed = true
        buffered = Data()
        lock.unlock()
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffered.append(data)
        if buffered.count > ControlServer.maxBuffered {
            lock.unlock()
            onLog?("rtsp_buffer_limit", buffered.count)
            respond(RtspResponse.badRequest(cseq: 0))
            return
        }
        let snapshot = buffered
        lock.unlock()

        var failure: RtspParseFailure?
        guard let request = RtspRequest.parse(snapshot, failure: &failure) else {
            // A truncated request is not an error yet; only a real parse failure is.
            if let failure {
                requestsRejected += 1
                onLog?("rtsp_parse_failure", failure.rawValue)
                if failure != .messageLimit {
                    respond(RtspResponse.badRequest(cseq: 0))
                }
            }
            return
        }

        let consumed = request.encodedLength
        lock.lock()
        if consumed <= buffered.count {
            buffered = buffered.subdata(in: consumed..<buffered.count)
        } else {
            buffered = Data()
        }
        lock.unlock()

        requestsParsed += 1
        let reply = dispatch(request)
        if let reply { respond(reply) }
        // A pipelined second request in the same chunk still has to be served.
        lock.lock()
        let leftover = buffered
        lock.unlock()
        if !leftover.isEmpty {
            ingest(Data())
        }
    }

    private func respond(_ data: Data) {
        lock.lock()
        let target = channel
        lock.unlock()
        target?.send(data)
    }

    // MARK: - Routing

    func dispatch(_ request: RtspRequest) -> Data? {
        if request.isOptions {
            optionsAnswered += 1
            return RtspResponse.ok(cseq: request.cseq)
        }
        let target = RtspCommandType.target(of: request.target)
        let method = RtspCommandType.method(of: request.method)
        switch target {
        case .pairSetup: return routePair(request, setup: true)
        case .pairVerify: return routePair(request, setup: false)
        case .authSetup: return routeAuthSetup(request)
        case .info: return routeInfo(request)
        case .feedback: return routeFeedback(request)
        case .command: return routeCommand(request)
        case .unknown: return routeMethod(target: target, method: method, request: request)
        }
    }

    private func routeMethod(target: RtspTarget, method: RtspMethod, request: RtspRequest) -> Data? {
        switch method {
        case .setup: return routeSetup(request)
        case .record:
            recordsAnswered += 1
            onLog?("receiver_rtsp_request_record_count", recordsAnswered)
            return RtspResponse.ok(cseq: request.cseq)
        case .teardown:
            teardownsAnswered += 1
            onLog?("teardown_received", true)
            return RtspResponse.ok(cseq: request.cseq)
        case .setParameter:
            setParametersAnswered += 1
            onLog?("set_parameter", true)
            return RtspResponse.ok(cseq: request.cseq)
        case .none:
            onLog?("rtsp_unsupported_target", request.target)
            return RtspResponse.notImplemented(cseq: request.cseq)
        }
    }

    private func routeSetup(_ request: RtspRequest) -> Data? {
        guard let handler = setupHandler else {
            onLog?("stream_setup_rejection", "no_handler")
            return RtspResponse.unsupportedTransport(cseq: request.cseq)
        }
        guard let body = decodeRequestPlist(request) else {
            onLog?("stream_setup_rejection", "unsupported_plist")
            return RtspResponse.badRequest(cseq: request.cseq)
        }
        guard let reply = handler(body) else {
            onLog?("stream_setup_rejection", "refused")
            return RtspResponse.unsupportedTransport(cseq: request.cseq)
        }
        setupsAnswered += 1
        onLog?("receiver_rtsp_request_stream_setup_count", setupsAnswered)
        return RtspResponse.ok(cseq: request.cseq, body: PlistCodec.encode(reply))
    }

    private func routeInfo(_ request: RtspRequest) -> Data? {
        guard request.isGet || request.isPost else {
            return RtspResponse.notImplemented(cseq: request.cseq)
        }
        let body: PlistValue
        if let provider = infoProvider {
            body = provider()
        } else {
            body = InfoPayload.build(
                deviceID: deviceID,
                width: screenWidth,
                height: screenHeight,
                uuid: UUID().uuidString
            )
        }
        infoAnswered += 1
        // The accessory serialises a binary plist but declares octet-stream. The mismatch
        // is real and a controller relies on it, so it is reproduced rather than fixed.
        return RtspResponse.ok(
            cseq: request.cseq,
            body: PlistCodec.encode(body),
            contentType: RtspResponse.octetStreamContentType
        )
    }

    private func routeFeedback(_ request: RtspRequest) -> Data? {
        guard request.isPost else {
            return RtspResponse.notImplemented(cseq: request.cseq)
        }
        guard screenConfigured else {
            onLog?("rtsp_feedback_before_configured", true)
            return RtspResponse.badRequest(cseq: request.cseq)
        }
        guard let body = decodeRequestPlist(request) else {
            return RtspResponse.badRequest(cseq: request.cseq)
        }
        let reply = feedbackHandler?(body)
        feedbackAnswered += 1
        if let reply {
            return RtspResponse.ok(cseq: request.cseq, body: PlistCodec.encode(reply))
        }
        return RtspResponse.ok(cseq: request.cseq)
    }

    private func routePair(_ request: RtspRequest, setup: Bool) -> Data? {
        guard let session = pairing else {
            return RtspResponse.serviceUnavailable(cseq: request.cseq)
        }
        guard let body = decodeRequestPlist(request) else {
            return RtspResponse.badRequest(cseq: request.cseq)
        }
        let step = body.getInteger("state", 0)
        let reply: PlistValue?
        if setup {
            reply = pairStep(session: session, state: step, body: body)
            if reply != nil { pairSetupAnswered += 1 }
        } else {
            reply = verifyStep(session: session, state: step, body: body)
            if reply != nil { pairVerifyAnswered += 1 }
        }
        guard let reply else {
            return RtspResponse.badRequest(cseq: request.cseq)
        }
        return RtspResponse.ok(cseq: request.cseq, body: PlistCodec.encode(reply))
    }

    private func pairStep(session: PairingSession, state: Int64, body: PlistValue) -> PlistValue? {
        switch state {
        case 1:
            guard let result = try? session.beginSetup() else { return nil }
            return PlistValue.dict()
                .add("state", .from(2))
                .add("salt", .fromData(result.salt))
                .add("publicKey", .fromData(result.publicB))
        case 3:
            let a = body.tryGet("publicKey")?.bytes ?? Data()
            let proof = body.tryGet("proof")?.bytes ?? Data()
            guard let m2 = try? session.completeSetup(controllerA: a, controllerM1: proof) else {
                return nil
            }
            return PlistValue.dict()
                .add("state", .from(4))
                .add("proof", .fromData(m2))
        case 5:
            let encrypted = body.tryGet("encryptedData")?.bytes ?? Data()
            guard (try? session.finishSetup(encryptedSubset: encrypted)) != nil else { return nil }
            return PlistValue.dict().add("state", .from(6))
        default:
            return nil
        }
    }

    private func verifyStep(session: PairingSession, state: Int64, body: PlistValue) -> PlistValue? {
        switch state {
        case 1:
            let curve = body.tryGet("publicKey")?.bytes ?? Data()
            session.rememberControllerCurve(curve)
            guard let accessory = try? session.beginVerify(controllerCurvePublic: curve) else {
                return nil
            }
            return PlistValue.dict()
                .add("state", .from(2))
                .add("publicKey", .fromData(accessory))
        case 3:
            guard let sealed = try? session.buildVerifyResponse() else { return nil }
            return PlistValue.dict()
                .add("state", .from(4))
                .add("encryptedData", .fromData(sealed))
        case 5:
            let encrypted = body.tryGet("encryptedData")?.bytes ?? Data()
            guard (try? session.finishVerify(encrypted: encrypted)) != nil else { return nil }
            return PlistValue.dict().add("state", .from(6))
        default:
            return nil
        }
    }

    private func routeAuthSetup(_ request: RtspRequest) -> Data? {
        guard let body = decodeRequestPlist(request) else {
            return RtspResponse.badRequest(cseq: request.cseq)
        }
        // No MFi coprocessor is present, so the only honest answer is an acknowledgement
        // of the request shape. Claiming a completed auth-setup would be a lie the
        // controller would act on.
        _ = body
        authSetupAnswered += 1
        onLog?("auth_setup", "acknowledged")
        return RtspResponse.ok(cseq: request.cseq)
    }

    private func routeCommand(_ request: RtspRequest) -> Data? {
        guard request.isPost, request.target == "/command" else {
            return RtspResponse.notImplemented(cseq: request.cseq)
        }
        guard !request.body.isEmpty else {
            onLog?("rtsp_empty_body", true)
            return RtspResponse.badRequest(cseq: request.cseq)
        }
        guard let body = decodeRequestPlist(request) else {
            onLog?("rtsp_plist_failure", true)
            return RtspResponse.badRequest(cseq: request.cseq)
        }
        guard let wire = body.getString("type"), !wire.isEmpty else {
            onLog?("rtsp_plist_no_status", true)
            return RtspResponse.badRequest(cseq: request.cseq)
        }
        let parameters = body.tryGet("params") ?? PlistValue.dict()
        commandsHandled += 1
        let command = ControlCommand(
            wireType: wire,
            internalType: RtspCommandType.internalName(for: wire),
            params: parameters,
            cseq: request.cseq
        )
        return finishCommand(commandResult: dispatchCommand(command), cseq: request.cseq)
    }

    /// The one place a decoded command turns into an outcome, shared by the wire path and
    /// the debug seam so tests exercise the same code a controller drives.
    public func dispatchCommand(_ command: ControlCommand) -> CommandResult {
        // Bluetooth release is pure signalling: the accessory answers 200 without
        // consulting a handler.
        if command.wireType == RtspCommandType.disableBluetooth {
            return .accepted()
        }

        if command.wireType == RtspCommandType.takeScreen {
            onLog?("capture_configuration", "\(screenWidth)x\(screenHeight)")
            let builtin = CommandResult.accepted(
                status: 0,
                extras: PlistValue.dict()
                    .add("width", .from(Int64(screenWidth)))
                    .add("height", .from(Int64(screenHeight)))
                    .add("orientation", .from(1))
            )
            guard let handler = commandHandler else { return builtin }
            let answer = handler(command)
            if case .unsupported = answer.outcome {
                return builtin
            }
            return answer
        }

        if command.wireType == RtspCommandType.hidSetInputMode {
            if let touch = decodeTouch(command.params) {
                onTouch?(touch)
            }
        }

        return commandHandler?(command) ?? .unsupported()
    }

    /// Test seam: routes a setup body through the same handler the wire path uses.
    public func debugHandleSetup(_ body: PlistValue) -> PlistValue? {
        setupHandler?(body)
    }

    /// Test seam: the same dispatch the wire path performs, without building RTSP bytes.
    public func debugHandleCommand(_ command: ControlCommand) -> CommandResult {
        dispatchCommand(command)
    }

    private func finishCommand(commandResult: CommandResult, cseq: Int) -> Data? {
        switch commandResult.outcome {
        case .unsupported:
            onLog?("rtsp_rejected", "unsupported")
            return RtspResponse.notImplemented(cseq: cseq)
        case .malformed:
            return RtspResponse.badRequest(cseq: cseq)
        case .rejected:
            onLog?("rtsp_rejected", commandResult.status ?? 0)
            return RtspResponse.badRequest(cseq: cseq)
        case .accepted:
            if commandResult.status == nil && commandResult.extras == nil {
                return RtspResponse.ok(cseq: cseq)
            }
            var payload = PlistValue.dict()
            if let status = commandResult.status {
                payload = payload.add("status", .from(status))
            }
            if let extras = commandResult.extras {
                for entry in extras.entries {
                    payload = payload.add(entry.0, entry.1)
                }
            }
            return RtspResponse.ok(cseq: cseq, body: PlistCodec.encode(payload))
        }
    }

    private func decodeRequestPlist(_ request: RtspRequest) -> PlistValue? {
        if request.body.isEmpty { return PlistValue.dict() }
        return PlistCodec.decode(request.body)
    }

    /// Reads a touch sample out of a `params` dictionary. Plist has no 16-bit type, so the
    /// fields are re-packed into the wire layout the touch parser expects.
    private func decodeTouch(_ parameters: PlistValue) -> TouchMessage? {
        let action = parameters.getInteger("action", -1)
        guard action >= 0, action <= Int64(Int16.max) else { return nil }
        var raw = [UInt8](repeating: 0, count: TouchMessage.minimumSize)
        ByteOrder.writeI16BE(&raw, 0, Int16(action))
        ByteOrder.writeI16BE(&raw, 2, Int16(clamping: parameters.getInteger("x", 0)))
        ByteOrder.writeI16BE(&raw, 4, Int16(clamping: parameters.getInteger("y", 0)))
        ByteOrder.writeI16BE(&raw, 6, Int16(clamping: parameters.getInteger("field2", 0)))
        return TouchMessage.parse(Data(raw))
    }
}
