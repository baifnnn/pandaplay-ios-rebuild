import Foundation

/// DNS wire-format encode/decode for the Bonjour responder.
///
/// Every multi-byte field in DNS is big-endian, which is the opposite of the media
/// channel, so this file spells the byte order out at every call site rather than
/// sharing helpers with the rest of the package.
public enum DnsType: UInt16, Sendable {
    case a = 1
    case ptr = 12
    case txt = 16
    case aaaa = 28
    case srv = 33
    case any = 255
}

public enum DnsClass: UInt16, Sendable {
    case `in` = 1
    case any = 255
}

public struct DnsQuestion: Equatable, Sendable {
    public let name: String
    public let type: DnsType
    public let classValue: DnsClass

    public init(name: String, type: DnsType, classValue: DnsClass = .in) {
        self.name = name
        self.type = type
        self.classValue = classValue
    }
}

public final class DnsRecord: @unchecked Sendable {
    public let name: String
    public let type: DnsType
    public let classValue: DnsClass
    /// mDNS uses the top bit of the class field to ask receivers not to cache.
    public let cacheFlush: Bool
    public let ttl: UInt32
    public let data: Data

    public init(
        name: String,
        type: DnsType,
        classValue: DnsClass = .in,
        cacheFlush: Bool = true,
        ttl: UInt32 = 4500,
        data: Data
    ) {
        self.name = name
        self.type = type
        self.classValue = classValue
        self.cacheFlush = cacheFlush
        self.ttl = ttl
        self.data = data
    }

    /// A copy with a different TTL. Records are immutable so a goodbye packet cannot
    /// mutate the advertisement that will be sent again later.
    public func retimed(ttl: UInt32) -> DnsRecord {
        DnsRecord(
            name: name,
            type: type,
            classValue: classValue,
            cacheFlush: cacheFlush,
            ttl: ttl,
            data: data
        )
    }
}

public enum DnsWire {
    public static let headerSize = 12
    public static let flagResponse: UInt16 = 0x8000
    public static let flagAuthoritative: UInt16 = 0x0400
    /// Longest single label the wire format allows.
    public static let maxLabelLength = 63
    /// Pointer chains longer than this are treated as a loop.
    private static let maxPointerHops = 32

    /// Encoded length of a name, including its terminating zero byte.
    public static func nameLength(_ name: String) -> Int {
        var total = 1
        for label in name.split(separator: ".") where !label.isEmpty {
            total += 1 + label.utf8.count
        }
        return total
    }

    @discardableResult
    public static func writeName(_ buffer: inout [UInt8], _ offset: inout Int, _ name: String) -> Bool {
        for label in name.split(separator: ".") where !label.isEmpty {
            let bytes = Array(label.utf8)
            guard bytes.count <= maxLabelLength, offset + 1 + bytes.count < buffer.count else {
                return false
            }
            buffer[offset] = UInt8(bytes.count)
            offset += 1
            for byte in bytes {
                buffer[offset] = byte
                offset += 1
            }
        }
        guard offset < buffer.count else { return false }
        buffer[offset] = 0
        offset += 1
        return true
    }

    /// Reads a possibly compressed name. `0xC0` introduces a pointer to an earlier offset.
    public static func readName(_ bytes: [UInt8], _ offset: inout Int) -> String? {
        var labels: [String] = []
        var cursor = offset
        var hops = 0
        var resumeAt = -1

        while cursor < bytes.count {
            let length = Int(bytes[cursor])
            if length == 0 {
                cursor += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < bytes.count else { return nil }
                let target = (length & 0x3F) << 8 | Int(bytes[cursor + 1])
                if resumeAt < 0 { resumeAt = cursor + 2 }
                hops += 1
                guard hops <= maxPointerHops, target < bytes.count else { return nil }
                cursor = target
                continue
            }
            guard cursor + 1 + length <= bytes.count else { return nil }
            let slice = Array(bytes[(cursor + 1)..<(cursor + 1 + length)])
            labels.append(String(decoding: slice, as: UTF8.self))
            cursor += 1 + length
        }

        offset = resumeAt >= 0 ? resumeAt : cursor
        return labels.isEmpty ? "." : labels.joined(separator: ".")
    }

    public static func encodeQuery(name: String, type: DnsType, id: UInt16 = 0) -> Data {
        var buffer = [UInt8](repeating: 0, count: headerSize + nameLength(name) + 4)
        writeU16BE(&buffer, 0, id)
        writeU16BE(&buffer, 2, 0)
        writeU16BE(&buffer, 4, 1)
        var offset = headerSize
        writeName(&buffer, &offset, name)
        writeU16BE(&buffer, offset, type.rawValue)
        writeU16BE(&buffer, offset + 2, DnsClass.in.rawValue)
        return Data(buffer.prefix(offset + 4))
    }

    /// Parses a query. A response bit set means this is not a question and is ignored.
    public static func parseQuery(_ data: Data) -> (id: UInt16, questions: [DnsQuestion])? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { return nil }
        let flags = readU16BE(bytes, 2)
        guard flags & flagResponse == 0 else { return nil }
        let id = readU16BE(bytes, 0)
        let count = Int(readU16BE(bytes, 4))
        var offset = headerSize
        var questions: [DnsQuestion] = []
        questions.reserveCapacity(count)
        for _ in 0..<count {
            guard let name = readName(bytes, &offset), offset + 4 <= bytes.count else { return nil }
            let type = DnsType(rawValue: readU16BE(bytes, offset)) ?? .any
            let classValue = DnsClass(rawValue: readU16BE(bytes, offset + 2) & 0x7FFF) ?? .in
            offset += 4
            questions.append(DnsQuestion(name: name, type: type, classValue: classValue))
        }
        return (id, questions)
    }

    public static func encodeResponse(
        id: UInt16,
        questions: [DnsQuestion],
        answers: [DnsRecord]
    ) -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        writeU16BE(&buffer, 0, id)
        writeU16BE(&buffer, 2, flagResponse | flagAuthoritative)
        writeU16BE(&buffer, 4, UInt16(questions.count))
        writeU16BE(&buffer, 6, UInt16(answers.count))
        writeU16BE(&buffer, 8, 0)
        writeU16BE(&buffer, 10, 0)

        var offset = headerSize
        for question in questions {
            writeName(&buffer, &offset, question.name)
            writeU16BE(&buffer, offset, question.type.rawValue)
            writeU16BE(&buffer, offset + 2, question.classValue.rawValue)
            offset += 4
        }

        for answer in answers {
            writeName(&buffer, &offset, answer.name)
            writeU16BE(&buffer, offset, answer.type.rawValue)
            let classBits = answer.classValue.rawValue | (answer.cacheFlush ? 0x8000 : 0)
            writeU16BE(&buffer, offset + 2, classBits)
            writeU32BE(&buffer, offset + 4, answer.ttl)
            writeU16BE(&buffer, offset + 8, UInt16(answer.data.count))
            offset += 10
            guard offset + answer.data.count <= buffer.count else { return Data() }
            for byte in answer.data {
                buffer[offset] = byte
                offset += 1
            }
        }
        return Data(buffer.prefix(offset))
    }

    // MARK: - Record data

    public static func ptrData(target: String) -> Data {
        var buffer = [UInt8](repeating: 0, count: nameLength(target))
        var offset = 0
        writeName(&buffer, &offset, target)
        return Data(buffer.prefix(offset))
    }

    public static func srvData(priority: UInt16, weight: UInt16, port: UInt16, target: String) -> Data {
        var buffer = [UInt8](repeating: 0, count: 6 + nameLength(target))
        writeU16BE(&buffer, 0, priority)
        writeU16BE(&buffer, 2, weight)
        writeU16BE(&buffer, 4, port)
        var offset = 6
        writeName(&buffer, &offset, target)
        return Data(buffer.prefix(offset))
    }

    /// TXT rdata: one length-prefixed string per entry. An empty list is a single zero
    /// byte, which is what an empty TXT record must look like.
    public static func txtData(_ entries: [String]) -> Data {
        guard !entries.isEmpty else { return Data([0]) }
        var out: [UInt8] = []
        for entry in entries {
            let bytes = Array(entry.utf8)
            out.append(UInt8(min(bytes.count, 255)))
            out.append(contentsOf: bytes.prefix(255))
        }
        return Data(out)
    }

    public static func aData(_ address: UInt32) -> Data {
        var out = [UInt8](repeating: 0, count: 4)
        writeU32BE(&out, 0, address)
        return Data(out)
    }

    /// Splits TXT rdata into a dictionary. Keys are `key=value`; a key without `=` maps to
    /// an empty string, which is how mDNS encodes a bare flag.
    public static func parseTxt(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var out: [String: String] = [:]
        var offset = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            offset += 1
            guard length > 0, offset + length <= bytes.count else { break }
            let text = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
            offset += length
            if let equals = text.firstIndex(of: "=") {
                out[String(text[text.startIndex..<equals])] = String(text[text.index(after: equals)...])
            } else {
                out[text] = ""
            }
        }
        return out
    }

    // MARK: - Byte helpers

    static func readU16BE(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func writeU16BE(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt16) {
        guard offset + 1 < buffer.count else { return }
        buffer[offset] = UInt8(value >> 8)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    static func writeU32BE(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        guard offset + 3 < buffer.count else { return }
        for i in 0..<4 {
            buffer[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32(i)))
        }
    }
}
