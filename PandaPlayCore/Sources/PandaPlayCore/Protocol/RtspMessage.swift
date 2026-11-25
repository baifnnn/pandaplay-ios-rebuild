import Foundation

/// The six status lines the accessory actually emits. Anything else is a bug in the
/// caller, not a missing case: the original binary compares against these six small
/// strings and nothing more.
public enum RtspStatus: Int, Sendable {
    case ok = 200
    case badRequest = 400
    case forbidden = 403
    /// 461 is the AirPlay-family "unsupported transport" code, used when a SETUP asks
    /// for a transport this receiver will not carry.
    case unsupportedTransport = 461
    case notImplemented = 501
    case serviceUnavailable = 503

    public var reasonPhrase: String {
        switch self {
        case .ok: return "OK"
        case .badRequest: return "Bad Request"
        case .forbidden: return "Forbidden"
        case .unsupportedTransport: return "Unsupported Transport"
        case .notImplemented: return "Not Implemented"
        case .serviceUnavailable: return "Service Unavailable"
        }
    }
}

/// The six targets the receiver routes on. Raw values mirror the dispatch index in the
/// original binary so a trace comparison stays readable.
public enum RtspTarget: Int, Sendable {
    case pairSetup = 0
    case pairVerify = 1
    case authSetup = 2
    case info = 3
    case feedback = 4
    case command = 5
    case unknown = 12
}

/// The four stream methods plus SET_PARAMETER. `none` means the method string was not
/// one the receiver knows.
public enum RtspMethod: Int, Sendable {
    case none = -1
    case setParameter = 6
    case setup = 9
    case record = 10
    case teardown = 11
}

/// Wire names for the `type` field inside a `/command` plist body.
///
/// The wire form is camelCase while the receiver's internal name is snake_case; the two
/// spellings exist side by side in the original binary's tables, so both are kept here.
public enum RtspCommandType {
    public static let requestUI = "requestUI"
    public static let takeScreen = "takeScreen"
    public static let releaseScreen = "releaseScreen"
    public static let modesChanged = "modesChanged"
    public static let hidSetInputMode = "hidSetInputMode"
    public static let disableBluetooth = "disableBluetooth"
    public static let forceKeyFrame = "forceKeyFrame"
    public static let updateFeedback = "updateFeedback"
    public static let duckAudio = "duckAudio"
    public static let unduckAudio = "unduckAudio"
    public static let hidCopyInputMode = "hidCopyInputMode"

    /// Maps a wire spelling onto the internal label used in telemetry and dispatch.
    public static func internalName(for wire: String) -> String {
        switch wire {
        case requestUI: return "request_ui"
        case takeScreen: return "take_screen"
        case releaseScreen: return "release_screen"
        case modesChanged: return "modes_changed"
        case hidSetInputMode: return "hid_set_input_mode"
        case disableBluetooth: return "disable_bluetooth"
        case forceKeyFrame: return "force_key_frame"
        case updateFeedback: return "update_feedback"
        case duckAudio: return "duck_audio"
        case unduckAudio: return "unduck_audio"
        case hidCopyInputMode: return "hid_copy_input_mode"
        default: return "invalid"
        }
    }

    public static func target(of path: String) -> RtspTarget {
        switch path {
        case "/pair-setup": return .pairSetup
        case "/pair-verify": return .pairVerify
        case "/auth-setup": return .authSetup
        case "/info": return .info
        case "/feedback": return .feedback
        case "/command": return .command
        default: return .unknown
        }
    }

    public static func method(of verb: String) -> RtspMethod {
        switch verb {
        case "SET_PARAMETER": return .setParameter
        case "SETUP": return .setup
        case "RECORD": return .record
        case "TEARDOWN": return .teardown
        default: return .none
        }
    }
}

public enum RtspParseFailure: String, Sendable {
    case bufferLimit
    case messageLimit
    case headerEncoding
    case startLine
    case version
    case headerSyntax
}

/// One parsed RTSP request.
///
/// The header section is capped at 64 KiB and the body length comes from
/// `Content-Length`; both numbers are the accessory's, not a guess.
public struct RtspRequest: Sendable {
    public static let maxHeaderSection = 0x10000
    public static let supportedVersion = "RTSP/1.0"

    public let method: String
    public let target: String
    public let version: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, target: String, version: String = supportedVersion,
                headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
    }

    public var isOptions: Bool { method == "OPTIONS" }
    public var isPost: Bool { method == "POST" }
    public var isGet: Bool { method == "GET" }

    public var contentLength: Int? {
        guard let raw = headers["content-length"] else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    public var contentType: String? { headers["content-type"] }

    public var cseq: Int {
        guard let raw = headers["cseq"] else { return 0 }
        return Int(raw.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    public var hasCSeq: Bool { headers["cseq"] != nil }

    /// Finds the blank line that ends the header section. Only a full CRLFCRLF counts;
    /// a bare LF is the `rtsp_bare_lf` diagnostic rather than an accepted terminator.
    public static func findHeaderEnd(_ buffer: Data) -> (headerEnd: Int, bodyStart: Int)? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 4 else { return nil }
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0x0d, bytes[index + 1] == 0x0a,
               bytes[index + 2] == 0x0d, bytes[index + 3] == 0x0a {
                return (index, index + 4)
            }
            index += 1
        }
        return nil
    }

    /// Parses a complete request from `buffer`. Returns nil and fills `failure` when the
    /// bytes are not a request yet or are malformed.
    public static func parse(_ buffer: Data, failure: inout RtspParseFailure?) -> RtspRequest? {
        if buffer.count > maxHeaderSection {
            failure = .bufferLimit
            return nil
        }
        guard let boundary = findHeaderEnd(buffer) else {
            failure = .messageLimit
            return nil
        }
        let headerData = buffer.subdata(in: 0..<boundary.headerEnd)
        // Anything below 0x20 other than tab, CR and LF means the bytes are not UTF-8
        // text at all, which is what the original reports as a header encoding failure.
        for byte in headerData where byte < 0x20 && byte != 0x09 && byte != 0x0d && byte != 0x0a {
            failure = .headerEncoding
            return nil
        }
        guard let text = String(data: headerData, encoding: .utf8) else {
            failure = .headerEncoding
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let startLine = lines.first, !startLine.isEmpty else {
            failure = .startLine
            return nil
        }
        let parts = startLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            failure = .startLine
            return nil
        }
        guard parts[2] == supportedVersion else {
            failure = .version
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                failure = .headerSyntax
                return nil
            }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                failure = .headerSyntax
                return nil
            }
            let key = name.lowercased()
            // A repeated header is ambiguous for Content-Length and a sign of smuggling
            // for anything else, so both are rejected rather than merged.
            guard headers[key] == nil else {
                failure = .headerSyntax
                return nil
            }
            guard key != "transfer-encoding" else {
                failure = .headerSyntax
                return nil
            }
            if key == "content-length" {
                guard let length = Int(value), length >= 0 else {
                    failure = .headerSyntax
                    return nil
                }
            }
            headers[key] = value
        }
        var bodyLength = 0
        if let raw = headers["content-length"] {
            bodyLength = Int(raw) ?? 0
        }
        guard buffer.count >= boundary.bodyStart + bodyLength else {
            failure = .messageLimit
            return nil
        }
        let body = bodyLength > 0
            ? buffer.subdata(in: boundary.bodyStart..<(boundary.bodyStart + bodyLength))
            : Data()
        failure = nil
        return RtspRequest(
            method: parts[0],
            target: parts[1],
            version: parts[2],
            headers: headers,
            body: body
        )
    }

    /// Total byte length this request occupies, used by the socket reader to advance.
    public var encodedLength: Int {
        guard let boundary = RtspRequest.findHeaderEnd(headerBytes) else { return headerBytes.count }
        return boundary.bodyStart + body.count
    }

    private var headerBytes: Data {
        var out = Data()
        out.append(Data("\(method) \(target) \(version)\r\n".utf8))
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            out.append(Data("\(name): \(value)\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }
}

public enum RtspResponse {
    public static let binaryPlistContentType = "application/x-apple-binary-plist"
    public static let octetStreamContentType = "application/octet-stream"

    public static func statusLine(_ status: RtspStatus) -> String {
        "\(status.rawValue) \(status.reasonPhrase)"
    }

    public static func build(
        cseq: Int,
        status: RtspStatus,
        body: Data = Data(),
        contentType: String? = nil
    ) -> Data {
        var text = "RTSP/1.0 \(statusLine(status))\r\n"
        text += "CSeq: \(cseq)\r\n"
        if body.isEmpty {
            text += "Content-Length: 0\r\n\r\n"
        } else {
            let type = contentType ?? binaryPlistContentType
            text += "Content-Type: \(type)\r\n"
            text += "Content-Length: \(body.count)\r\n\r\n"
        }
        var out = Data(text.utf8)
        if !body.isEmpty { out.append(body) }
        return out
    }

    public static func ok(cseq: Int, body: Data = Data(), contentType: String? = nil) -> Data {
        build(cseq: cseq, status: .ok, body: body, contentType: contentType)
    }

    public static func badRequest(cseq: Int) -> Data { build(cseq: cseq, status: .badRequest) }
    public static func forbidden(cseq: Int) -> Data { build(cseq: cseq, status: .forbidden) }
    public static func unsupportedTransport(cseq: Int) -> Data {
        build(cseq: cseq, status: .unsupportedTransport)
    }
    public static func notImplemented(cseq: Int) -> Data { build(cseq: cseq, status: .notImplemented) }
    public static func serviceUnavailable(cseq: Int) -> Data {
        build(cseq: cseq, status: .serviceUnavailable)
    }
}
