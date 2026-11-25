import Foundation

/// AVC parameter sets and access units, in the form an accessory receives them.
///
/// The accessory never depacketises RTP and never implements I-frame handling: it receives
/// one access unit per pull frame and hands it to the platform decoder. What it does need is
/// enough structure to recognise a parameter-set change, because the decoder has to be told
/// about a new `avcC` before it can accept frames again.
public enum H264 {

    /// NAL unit types that matter to this accessory.
    public enum NALType: UInt8, Sendable {
        case slice = 1
        case partitionA = 2
        case partitionB = 3
        case partitionC = 4
        case idrSlice = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case accessUnitDelimiter = 9
        case endOfSequence = 10
        case endOfStream = 11
        case filler = 12
        case spsExtension = 13
        case prefixNAL = 14
        case subsetSPS = 15
        case reserved16 = 16
        case reserved17 = 17
        case reserved18 = 18
        case auxSlice = 19
    }

    /// One NAL unit sliced out of the access unit, without its length prefix.
    public struct NALUnit: Equatable, Sendable {
        public let type: UInt8
        public let bytes: Data

        public init(type: UInt8, bytes: Data) {
            self.type = type
            self.bytes = bytes
        }

        public var nalType: NALType? { NALType(rawValue: type & 0x1f) }
        public var isParameterSet: Bool { type & 0x1f == 7 || type & 0x1f == 8 }
        public var isIDR: Bool { type & 0x1f == 5 }
        /// A slice carrying an I picture. `slice_type` lives in the first byte's low five
        /// bits after the Exp-Golomb `first_mb_in_slice`, so a full parse needs the SPS.
        /// The accessory only distinguishes IDR from non-IDR, which is what this reports.
        public var isKeyframe: Bool { isIDR }
        public var nalRefIdc: UInt8 { (type >> 5) & 0x03 }
    }

    /// The length-prefix width declared by an `avcC` box.
    public enum LengthSize: Int, Sendable {
        case one = 1
        case two = 2
        case four = 4

        /// `lengthSizeMinusOne` from the avcC record, or nil for the reserved value 2...3.
        public init?(lengthSizeMinusOne: UInt8) {
            switch lengthSizeMinusOne {
            case 0: self = .one
            case 1: self = .two
            case 3: self = .four
            default: return nil
            }
        }
    }

    public enum ParseError: String, Error, Sendable {
        case empty
        case truncatedLengthPrefix
        case truncatedBody
        case zeroLengthNAL
        case badLengthSize
    }

    // MARK: - Access unit

    /// Splits a length-prefixed access unit into NAL units.
    ///
    /// The accessory's controller always sends AVCC framing (a four-byte big-endian length
    /// before every NAL), never Annex-B start codes, which is why the same code does not
    /// try both. A sender that gets this wrong produces `truncatedBody` rather than a
    /// silently mis-framed picture.
    public static func split(
        accessUnit: Data,
        lengthSize: LengthSize = .four
    ) throws -> [NALUnit] {
        guard !accessUnit.isEmpty else { throw ParseError.empty }
        let width = lengthSize.rawValue
        var units: [NALUnit] = []
        var offset = 0
        let total = accessUnit.count
        while offset < total {
            guard offset + width <= total else { throw ParseError.truncatedLengthPrefix }
            var declared = 0
            for index in 0..<width {
                declared = (declared << 8) | Int(accessUnit[accessUnit.startIndex + offset + index])
            }
            offset += width
            guard declared > 0 else { throw ParseError.zeroLengthNAL }
            guard offset + declared <= total else { throw ParseError.truncatedBody }
            let body = accessUnit.subdata(in: (accessUnit.startIndex + offset)..<(accessUnit.startIndex + offset + declared))
            units.append(NALUnit(type: body[body.startIndex], bytes: body))
            offset += declared
        }
        return units
    }

    /// `true` when the unit looks like Annex-B rather than AVCC, i.e. it starts with a start
    /// code. Only used for diagnostics; the receive path does not accept it.
    public static func looksAnnexB(_ accessUnit: Data) -> Bool {
        guard accessUnit.count >= 4 else { return false }
        let head = [UInt8](accessUnit.prefix(4))
        return (head[0] == 0 && head[1] == 0 && head[2] == 0 && head[3] == 1)
            || (head[0] == 0 && head[1] == 0 && head[2] == 1)
    }

    public static func hasParameterSets(_ units: [NALUnit]) -> Bool {
        units.contains { $0.nalType == .sps } && units.contains { $0.nalType == .pps }
    }

    public static func hasIDR(_ units: [NALUnit]) -> Bool {
        units.contains { $0.isIDR }
    }

    // MARK: - avcC

    /// The record a decoder needs before it can accept frames: SPS and PPS, plus the
    /// length-prefix width the sender uses.
    public struct ConfigurationRecord: Equatable, Sendable {
        public let configurationVersion: UInt8
        public let profileIndication: UInt8
        public let profileCompatibility: UInt8
        public let levelIndication: UInt8
        public let lengthSize: LengthSize
        public let sps: [Data]
        public let pps: [Data]

        public init(
            configurationVersion: UInt8 = 1,
            profileIndication: UInt8,
            profileCompatibility: UInt8,
            levelIndication: UInt8,
            lengthSize: LengthSize = .four,
            sps: [Data],
            pps: [Data]
        ) {
            self.configurationVersion = configurationVersion
            self.profileIndication = profileIndication
            self.profileCompatibility = profileCompatibility
            self.levelIndication = levelIndication
            self.lengthSize = lengthSize
            self.sps = sps
            self.pps = pps
        }

        /// Builds the record from the parameter-set units of a stream. A receiver that has
        /// just seen both parameter sets can hand this straight to the platform decoder.
        public init?(units: [NALUnit], lengthSize: LengthSize = .four) {
            let sps = units.filter { $0.nalType == .sps }.map(\.bytes)
            let pps = units.filter { $0.nalType == .pps }.map(\.bytes)
            guard let firstSPS = sps.first, firstSPS.count >= 4, !pps.isEmpty else { return nil }
            let bytes = [UInt8](firstSPS)
            self.init(
                profileIndication: bytes[1],
                profileCompatibility: bytes[2],
                levelIndication: bytes[3],
                lengthSize: lengthSize,
                sps: sps,
                pps: pps
            )
        }
    }

    /// Serialises the record in the layout `CMVideoFormatDescriptionCreateFromH264ParameterSets`
    /// consumes: one length-prefixed SPS, one length-prefixed PPS, trailing zero padding.
    ///
    /// The padding matters. The Apple decoder reads past the end of the parameter-set block,
    /// and a record that ends exactly on the last PPS byte crashes on some OS versions.
    public static func avcCBox(_ record: ConfigurationRecord) -> Data {
        var out = [UInt8]()
        out.append(record.configurationVersion)
        out.append(record.profileIndication)
        out.append(record.profileCompatibility)
        out.append(record.levelIndication)
        // reserved(6) | lengthSizeMinusOne(2)
        out.append(0xfc | UInt8(record.lengthSize.rawValue - 1))
        // reserved(3) | numOfSequenceParameterSets(5)
        out.append(0xe0 | UInt8(min(record.sps.count, 0x1f)))
        for set in record.sps.prefix(0x1f) {
            out.append(UInt8((set.count >> 8) & 0xff))
            out.append(UInt8(set.count & 0xff))
            out.append(contentsOf: set)
        }
        out.append(UInt8(min(record.pps.count, 0xff)))
        for set in record.pps.prefix(0xff) {
            out.append(UInt8((set.count >> 8) & 0xff))
            out.append(UInt8(set.count & 0xff))
            out.append(contentsOf: set)
        }
        // Two zero bytes of trailing room; the decoder indexes one past the block.
        out.append(0)
        out.append(0)
        return Data(out)
    }

    /// Reads back a record from an `avcC` box body, so a round trip can be asserted.
    public static func parseConfigurationRecord(_ body: Data) throws -> ConfigurationRecord {
        let bytes = [UInt8](body)
        guard bytes.count >= 7 else { throw ParseError.truncatedBody }
        guard let lengthSize = LengthSize(lengthSizeMinusOne: bytes[4] & 0x03) else {
            throw ParseError.badLengthSize
        }
        var offset = 5
        let spsCount = Int(bytes[offset] & 0x1f)
        offset += 1
        var sps: [Data] = []
        for _ in 0..<spsCount {
            guard offset + 2 <= bytes.count else { throw ParseError.truncatedBody }
            let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
            guard offset + length <= bytes.count else { throw ParseError.truncatedBody }
            sps.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        guard offset < bytes.count else { throw ParseError.truncatedBody }
        let ppsCount = Int(bytes[offset])
        offset += 1
        var pps: [Data] = []
        for _ in 0..<ppsCount {
            guard offset + 2 <= bytes.count else { throw ParseError.truncatedBody }
            let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
            guard offset + length <= bytes.count else { throw ParseError.truncatedBody }
            pps.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        return ConfigurationRecord(
            configurationVersion: bytes[0],
            profileIndication: bytes[1],
            profileCompatibility: bytes[2],
            levelIndication: bytes[3],
            lengthSize: lengthSize,
            sps: sps,
            pps: pps
        )
    }
}

/// What the receive path decides about one access unit before handing it to the decoder.
public struct AccessUnitDisposition: Equatable, Sendable {
    public enum Kind: Int, Sendable {
        case deliver = 0
        /// The unit carries new parameter sets, so the decoder configuration has to be
        /// rebuilt before the unit itself can be displayed.
        case reconfigure = 1
        /// No slice at all: the sender put SPS/PPS/SEI in a frame on its own.
        case parameterSetsOnly = 2
    }

    public let kind: Kind
    public let units: [H264.NALUnit]
    public let record: H264.ConfigurationRecord?

    public init(kind: Kind, units: [H264.NALUnit], record: H264.ConfigurationRecord? = nil) {
        self.kind = kind
        self.units = units
        self.record = record
    }

    public var isKeyframe: Bool { units.contains { $0.isIDR } }
    public var hasSlice: Bool { units.contains { $0.nalType?.rawValue ?? 0 <= 5 } }
}

/// Classifies an access unit the way the accessory does: parameter sets first, then
/// whether a slice is present.
public enum AccessUnitClassifier {
    public static let capabilityProfile = "car_h264_full_initial_arbitration_no_audio_v3"

    public static func classify(_ accessUnit: Data) throws -> AccessUnitDisposition {
        let units = try H264.split(accessUnit: accessUnit)
        let hasSlice = units.contains { ($0.type & 0x1f) <= 5 }
        if H264.hasParameterSets(units) {
            let record = H264.ConfigurationRecord(units: units)
            return AccessUnitDisposition(
                kind: hasSlice ? .reconfigure : .parameterSetsOnly,
                units: units,
                record: record
            )
        }
        return AccessUnitDisposition(kind: hasSlice ? .deliver : .parameterSetsOnly, units: units)
    }
}
