import Foundation

/// Binary property list ("bplist00") encoder and decoder.
///
/// The receiver's RTSP bodies are binary plists: the accessory serialises them with
/// `NSPropertyListSerialization` at format 200, and its callers send the same shape.
/// Foundation's `PropertyListSerialization` would do this on Apple platforms, but the
/// protocol layer stays dependency-free so it can be tested anywhere.
public enum PlistKind: Sendable {
    case null
    case bool
    case integer
    case real
    case string
    case data
    case array
    case dictionary
    case uid
}

public final class PlistValue: @unchecked Sendable {
    public private(set) var kind: PlistKind
    fileprivate var boolValue: Bool = false
    fileprivate var integerValue: Int64 = 0
    fileprivate var realValue: Double = 0
    fileprivate var stringValue: String = ""
    fileprivate var storedData: Data = Data()
    fileprivate var arrayValue: [PlistValue] = []
    fileprivate var dictValue: [(String, PlistValue)] = []
    fileprivate var uidValue: UInt64 = 0

    private init(kind: PlistKind) {
        self.kind = kind
    }

    public static let null = PlistValue(kind: .null)
    public static let `true` = PlistValue(kind: .bool, bool: true)
    public static let `false` = PlistValue(kind: .bool, bool: false)

    private convenience init(kind: PlistKind, bool: Bool) {
        self.init(kind: kind)
        boolValue = bool
    }

    public static func from(_ value: Bool) -> PlistValue { value ? .true : .false }
    public static func from(_ value: Int64) -> PlistValue {
        let v = PlistValue(kind: .integer)
        v.integerValue = value
        return v
    }
    public static func from(_ value: Int) -> PlistValue { from(Int64(value)) }
    public static func from(_ value: UInt64) -> PlistValue { from(Int64(bitPattern: value)) }
    public static func from(_ value: Double) -> PlistValue {
        let v = PlistValue(kind: .real)
        v.realValue = value
        return v
    }
    public static func from(_ value: String) -> PlistValue {
        let v = PlistValue(kind: .string)
        v.stringValue = value
        return v
    }
    public static func fromData(_ value: Data) -> PlistValue {
        let v = PlistValue(kind: .data)
        v.storedData = value
        return v
    }
    public static func fromUid(_ value: UInt64) -> PlistValue {
        let v = PlistValue(kind: .uid)
        v.uidValue = value
        return v
    }
    public static func array(_ items: [PlistValue]) -> PlistValue {
        let v = PlistValue(kind: .array)
        v.arrayValue = items
        return v
    }
    public static func array(_ items: PlistValue...) -> PlistValue { array(items) }
    public static func dict() -> PlistValue { PlistValue(kind: .dictionary) }
    public static func dict(_ entries: [(String, PlistValue)]) -> PlistValue {
        let v = PlistValue(kind: .dictionary)
        v.dictValue = entries
        return v
    }

    @discardableResult
    public func add(_ key: String, _ value: PlistValue) -> PlistValue {
        precondition(kind == .dictionary, "add(_:_:) needs a dictionary")
        dictValue.append((key, value))
        return self
    }

    public var items: [PlistValue] { arrayValue }
    public var entries: [(String, PlistValue)] {
        precondition(kind == .dictionary, "entries needs a dictionary")
        return dictValue
    }
    public var text: String { stringValue }
    public var bytes: Data? { kind == .data ? storedData : nil }
    public var real: Double { realValue }
    public var integer: Int64 { integerValue }
    public var boolean: Bool { boolValue }
    public var uid: UInt64 { uidValue }

    public subscript(_ key: String) -> PlistValue? { tryGet(key) }
    public subscript(_ index: Int) -> PlistValue? {
        guard kind == .array, index >= 0, index < arrayValue.count else { return nil }
        return arrayValue[index]
    }

    public func tryGet(_ key: String) -> PlistValue? {
        guard kind == .dictionary else { return nil }
        for (name, value) in dictValue where name == key { return value }
        return nil
    }

    public func getString(_ key: String) -> String? { tryGet(key)?.text }
    public func getInteger(_ key: String, _ fallback: Int64) -> Int64 {
        guard let v = tryGet(key), v.kind == .integer else { return fallback }
        return v.integerValue
    }
    public func getBool(_ key: String, _ fallback: Bool) -> Bool {
        guard let v = tryGet(key), v.kind == .bool else { return fallback }
        return v.boolValue
    }
}

public enum PlistCodec {
    static let magic = "bplist00"
    static let trailerSize = 32

    /// A decoded offset table plus the bytes it points into. Passing this around keeps
    /// the recursive reader from re-slicing the whole document per object.
    struct Cursor {
        let bytes: [UInt8]
        let offsets: [Int]
        let objectRefSize: Int
        let count: Int
    }

    // MARK: - Encoding

    public static func encode(_ root: PlistValue) -> Data {
        var objects: [PlistValue] = []
        var children: [[Int]] = []
        var interned: [String: Int] = [:]

        /// Objects are laid out depth first with the root first. Scalars are interned so
        /// a document with seventy `false` values still stores one of them. Each
        /// container records the indices of its own children, which is what the
        /// reference table needs — grandchildren belong to their parent, not to us.
        func flatten(_ value: PlistValue) -> Int {
            let isContainer = value.kind == .array || value.kind == .dictionary
            if !isContainer, let existing = interned[internKey(value)] { return existing }

            let index = objects.count
            objects.append(value)
            children.append([])
            if !isContainer { interned[internKey(value)] = index }

            switch value.kind {
            case .array:
                children[index] = value.arrayValue.map { flatten($0) }
            case .dictionary:
                // A binary plist dictionary stores every key reference first, then every
                // value reference. Interleaving them parses as garbage, so the two runs
                // are built separately and concatenated.
                var keys: [Int] = []
                var values: [Int] = []
                keys.reserveCapacity(value.dictValue.count)
                values.reserveCapacity(value.dictValue.count)
                for (name, item) in value.dictValue {
                    keys.append(flatten(.from(name)))
                    values.append(flatten(item))
                }
                children[index] = keys + values
            default:
                break
            }
            return index
        }

        _ = flatten(root)

        let objectRefSize = byteWidth(for: UInt64(objects.count))

        var body = Data()
        body.append(contentsOf: Array(magic.utf8))

        var offsetTable: [Int] = []
        offsetTable.reserveCapacity(objects.count)
        for (index, value) in objects.enumerated() {
            offsetTable.append(body.count)
            append(value, children: children[index], objectRefSize: objectRefSize, into: &body)
        }

        let offsetIntSize = byteWidth(for: UInt64(max(body.count, 1)))
        let tableStart = body.count
        for offset in offsetTable {
            appendInteger(UInt64(offset), width: offsetIntSize, into: &body)
        }

        var trailer = [UInt8](repeating: 0, count: trailerSize)
        trailer[6] = UInt8(offsetIntSize)
        trailer[7] = UInt8(objectRefSize)
        writeBE(&trailer, 8, UInt64(objects.count))
        writeBE(&trailer, 16, 0)
        writeBE(&trailer, 24, UInt64(tableStart))
        body.append(contentsOf: trailer)
        return body
    }

    private static func internKey(_ value: PlistValue) -> String {
        switch value.kind {
        case .null: return "n"
        case .bool: return "b\(value.boolValue)"
        case .integer: return "i\(value.integerValue)"
        case .real: return "r\(value.realValue)"
        case .string: return "s\(value.stringValue)"
        case .data: return "d\(value.storedData.base64EncodedString())"
        case .uid: return "u\(value.uidValue)"
        default: return UUID().uuidString
        }
    }

    private static func append(
        _ value: PlistValue,
        children: [Int],
        objectRefSize: Int,
        into body: inout Data
    ) {
        switch value.kind {
        case .null:
            body.append(0x00)
        case .bool:
            body.append(value.boolValue ? 0x09 : 0x08)
        case .integer:
            appendSignedInteger(value.integerValue, into: &body)
        case .real:
            body.append(0x23)
            var bits = value.realValue.bitPattern
            withUnsafeBytes(of: &bits) { body.append(contentsOf: $0) }
        case .data:
            appendMarker(0x40, count: value.storedData.count, into: &body)
            body.append(value.storedData)
        case .string:
            appendString(value.stringValue, into: &body)
        case .uid:
            body.append(0x80 | 0x03)
            var v = value.uidValue
            let bytes = withUnsafeBytes(of: &v) { Array($0.prefix(4)) }
            body.append(contentsOf: bytes)
        case .array:
            appendMarker(0xA0, count: value.arrayValue.count, into: &body)
            for child in children { appendInteger(UInt64(child), width: objectRefSize, into: &body) }
        case .dictionary:
            appendMarker(0xD0, count: value.dictValue.count, into: &body)
            // Every key reference first, then every value reference.
            for child in children { appendInteger(UInt64(child), width: objectRefSize, into: &body) }
        }
    }

    private static func appendMarker(_ high: UInt8, count: Int, into body: inout Data) {
        if count < 15 {
            body.append(high | UInt8(count))
        } else {
            body.append(high | 0x0F)
            appendSignedInteger(Int64(count), into: &body)
        }
    }

    private static func appendString(_ text: String, into body: inout Data) {
        if text.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
            appendMarker(0x50, count: text.utf8.count, into: &body)
            body.append(contentsOf: Array(text.utf8))
        } else {
            let units = Array(text.utf16)
            appendMarker(0x60, count: units.count, into: &body)
            for unit in units {
                body.append(UInt8(truncatingIfNeeded: unit >> 8))
                body.append(UInt8(truncatingIfNeeded: unit))
            }
        }
    }

    private static func appendSignedInteger(_ value: Int64, into body: inout Data) {
        if value >= 0 && value <= 0xFF {
            body.append(0x10)
            body.append(UInt8(truncatingIfNeeded: value))
        } else if value >= 0 && value <= 0xFFFF {
            body.append(0x11)
            appendInteger(UInt64(value), width: 2, into: &body)
        } else if value >= 0 && value <= 0xFFFF_FFFF {
            body.append(0x12)
            appendInteger(UInt64(value), width: 4, into: &body)
        } else {
            body.append(0x13)
            appendInteger(UInt64(bitPattern: value), width: 8, into: &body)
        }
    }

    private static func appendInteger(_ value: UInt64, width: Int, into body: inout Data) {
        var bytes = [UInt8](repeating: 0, count: width)
        for i in 0..<width {
            bytes[width - 1 - i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))
        }
        body.append(contentsOf: bytes)
    }

    private static func writeBE(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for i in 0..<8 {
            buffer[offset + i] = UInt8(truncatingIfNeeded: value >> (56 - 8 * UInt64(i)))
        }
    }

    private static func byteWidth(for value: UInt64) -> Int {
        if value <= 0xFF { return 1 }
        if value <= 0xFFFF { return 2 }
        if value <= 0xFFFF_FFFF { return 4 }
        return 8
    }

    // MARK: - Decoding

    public static func decode(_ data: Data) -> (value: PlistValue?, error: String?) {
        guard data.count >= magic.count + trailerSize else {
            return (nil, "short_header")
        }
        guard let header = String(data: data.prefix(8), encoding: .ascii), header == magic else {
            return (nil, "invalid_version")
        }

        let trailerStart = data.count - trailerSize
        let bytes = [UInt8](data)
        let offsetIntSize = Int(bytes[trailerStart + 6])
        let objectRefSize = Int(bytes[trailerStart + 7])
        guard (1...8).contains(offsetIntSize), (1...8).contains(objectRefSize) else {
            return (nil, "parameter_length")
        }

        let numObjects = readBE(bytes, trailerStart + 8, 8)
        let topObject = readBE(bytes, trailerStart + 16, 8)
        let tableStart = readBE(bytes, trailerStart + 24, 8)
        guard numObjects > 0, numObjects <= 1_000_000 else { return (nil, "input_limit") }
        guard topObject < numObjects else { return (nil, "invalid_box_length") }
        guard tableStart + numObjects * UInt64(offsetIntSize) <= UInt64(trailerStart) else {
            return (nil, "trailing_data")
        }

        var offsets: [Int] = []
        offsets.reserveCapacity(Int(numObjects))
        for i in 0..<Int(numObjects) {
            offsets.append(Int(readBE(bytes, Int(tableStart) + i * offsetIntSize, offsetIntSize)))
        }

        let cursor = Cursor(bytes: bytes,
                            offsets: offsets,
                            objectRefSize: objectRefSize,
                            count: Int(numObjects))

        var path: Set<Int> = []
        guard let root = readObject(Int(topObject), cursor, &path, depth: 0) else {
            return (nil, "malformed_plist")
        }
        return (root, nil)
    }

    public static func decode(_ data: Data) -> PlistValue? {
        decode(data).value
    }

    /// Reads one object.
    ///
    /// `path` holds the object indices on the branch currently being read, not every
    /// index ever seen: a repeated scalar is normal in a binary plist (our encoder
    /// interns them), so a document-wide visited set would reject valid documents. Only
    /// a true cycle — an index already on this branch — is refused.
    private static func readObject(
        _ index: Int,
        _ cursor: Cursor,
        _ path: inout Set<Int>,
        depth: Int
    ) -> PlistValue? {
        guard depth < 64 else { return nil }
        guard index >= 0, index < cursor.count else { return nil }
        guard !path.contains(index) else { return nil }
        path.insert(index)
        defer { path.remove(index) }

        var offset = cursor.offsets[index]
        guard offset < cursor.bytes.count else { return nil }
        let marker = cursor.bytes[offset]
        offset += 1

        switch marker & 0xF0 {
        case 0x00:
            switch marker {
            case 0x00: return .null
            case 0x08: return .false
            case 0x09: return .true
            default: return .null
            }
        case 0x10:
            let width = 1 << Int(marker & 0x0F)
            guard offset + width <= cursor.bytes.count else { return nil }
            var raw: UInt64 = 0
            for i in 0..<width { raw = (raw << 8) | UInt64(cursor.bytes[offset + i]) }
            let signed: Int64
            switch width {
            case 1: signed = Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
            case 2: signed = Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
            case 4: signed = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
            default: signed = Int64(bitPattern: raw)
            }
            return .from(signed)
        case 0x20:
            let width = 1 << Int(marker & 0x0F)
            guard offset + width <= cursor.bytes.count else { return nil }
            if width == 4 {
                var raw: UInt32 = 0
                for i in 0..<4 { raw = (raw << 8) | UInt32(cursor.bytes[offset + i]) }
                return .from(Double(Float(bitPattern: raw)))
            }
            var raw: UInt64 = 0
            for i in 0..<8 { raw = (raw << 8) | UInt64(cursor.bytes[offset + i]) }
            return .from(Double(bitPattern: raw))
        case 0x40:
            guard let count = readCount(marker, cursor, &offset) else { return nil }
            guard offset + count <= cursor.bytes.count else { return nil }
            return .fromData(Data(cursor.bytes[offset..<(offset + count)]))
        case 0x50:
            guard let count = readCount(marker, cursor, &offset) else { return nil }
            guard offset + count <= cursor.bytes.count else { return nil }
            let slice = Array(cursor.bytes[offset..<(offset + count)])
            return .from(String(decoding: slice, as: UTF8.self))
        case 0x60:
            guard let count = readCount(marker, cursor, &offset) else { return nil }
            guard offset + count * 2 <= cursor.bytes.count else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(count)
            for i in 0..<count {
                units.append((UInt16(cursor.bytes[offset + i * 2]) << 8) | UInt16(cursor.bytes[offset + i * 2 + 1]))
            }
            return .from(String(decoding: units, as: UTF16.self))
        case 0x80:
            let width = Int(marker & 0x0F) + 1
            guard offset + width <= cursor.bytes.count else { return nil }
            var raw: UInt64 = 0
            for i in 0..<width { raw = (raw << 8) | UInt64(cursor.bytes[offset + i]) }
            return .fromUid(raw)
        case 0xA0:
            guard let count = readCount(marker, cursor, &offset) else { return nil }
            guard offset + count * cursor.objectRefSize <= cursor.bytes.count else { return nil }
            var items: [PlistValue] = []
            items.reserveCapacity(count)
            for i in 0..<count {
                let refOffset = offset + i * cursor.objectRefSize
                let child = Int(readBE(cursor.bytes, refOffset, cursor.objectRefSize))
                guard let value = readObject(child, cursor, &path, depth: depth + 1) else { return nil }
                items.append(value)
            }
            return .array(items)
        case 0xD0:
            guard let count = readCount(marker, cursor, &offset) else { return nil }
            guard offset + count * 2 * cursor.objectRefSize <= cursor.bytes.count else { return nil }
            let dict = PlistValue.dict()
            for i in 0..<count {
                let keyRef = Int(readBE(cursor.bytes, offset + i * cursor.objectRefSize, cursor.objectRefSize))
                let valueRef = Int(readBE(cursor.bytes, offset + (count + i) * cursor.objectRefSize, cursor.objectRefSize))
                guard let key = readObject(keyRef, cursor, &path, depth: depth + 1),
                      key.kind == .string else { return nil }
                guard let value = readObject(valueRef, cursor, &path, depth: depth + 1) else { return nil }
                dict.add(key.text, value)
            }
            return dict
        default:
            return nil
        }
    }

    private static func readCount(_ marker: UInt8, _ cursor: Cursor, _ offset: inout Int) -> Int? {
        let info = Int(marker & 0x0F)
        if info < 15 { return info }
        guard offset < cursor.bytes.count else { return nil }
        let intMarker = cursor.bytes[offset]
        guard intMarker & 0xF0 == 0x10 else { return nil }
        offset += 1
        let width = 1 << Int(intMarker & 0x0F)
        guard offset + width <= cursor.bytes.count else { return nil }
        var raw: UInt64 = 0
        for i in 0..<width { raw = (raw << 8) | UInt64(cursor.bytes[offset + i]) }
        offset += width
        guard raw <= UInt64(Int.max) else { return nil }
        return Int(raw)
    }

    private static func readBE(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> UInt64 {
        var raw: UInt64 = 0
        for i in 0..<width {
            guard offset + i < bytes.count else { return raw }
            raw = (raw << 8) | UInt64(bytes[offset + i])
        }
        return raw
    }
}
