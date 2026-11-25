import Foundation

/// The PXC hello the accessory sends to a phone before any projection starts.
///
/// The key order is fixed by the accessory's append sequence, not by a dictionary: a
/// marshalling round-trip would reorder it and the phone would reject the handshake.
/// `versionCode` is always 1 — the bundle build number is *not* the wire version, which
/// is a trap the original source comments on explicitly.
public struct PxcHello: Equatable, Sendable {
    public static let pxcVersion = "1.0.2"
    public static let wireVersionCode: Int64 = 1
    /// H.264 I-frame handling is not implemented, and the field is forced false: there is
    /// no caller override in the accessory.
    public static let supportH264IFrame = false
    public static let appVersionFingerPrint = ""

    public var phoneUuid: String
    public var phoneBrand: String
    public var phoneModel: String
    public var phoneOs: String
    public var phoneOsVersion: String
    public var package: String
    public var token: String
    public var publicKey: String
    public var encryptedHUID: String
    public var timeZone: String
    public var time: Int64
    public var currentTime: Int64

    public init(
        phoneUuid: String = "",
        phoneBrand: String = "Apple",
        phoneModel: String = "",
        phoneOs: String = "iOS",
        phoneOsVersion: String = "",
        package: String = "top.shareway.pandaplayplus.ios",
        token: String = "",
        publicKey: String = "",
        encryptedHUID: String = "",
        timeZone: String = "UTC",
        time: Int64 = 0,
        currentTime: Int64 = 0
    ) {
        self.phoneUuid = phoneUuid
        self.phoneBrand = phoneBrand
        self.phoneModel = phoneModel
        self.phoneOs = phoneOs
        self.phoneOsVersion = phoneOsVersion
        self.package = package
        self.token = token
        self.publicKey = publicKey
        self.encryptedHUID = encryptedHUID
        self.timeZone = timeZone
        self.time = time
        self.currentTime = currentTime
    }

    /// Key order: pxcVersion, phoneUUID, phoneBrand, phoneModel, phoneOs, package,
    /// phoneOsVersion, versionCode, supportH264IFrame, supportFunction,
    /// appVersionFingerPrint, token, pubkey, encryptedHUID, currentTimeZone.
    public func toJSON() -> String {
        var out = "{\"pxcVersion\":\"\(PxcHello.pxcVersion)\""
        out += ",\"phoneUUID\":\(PxcHello.quote(phoneUuid))"
        out += ",\"phoneBrand\":\(PxcHello.quote(phoneBrand))"
        out += ",\"phoneModel\":\(PxcHello.quote(phoneModel))"
        out += ",\"phoneOs\":\(PxcHello.quote(phoneOs))"
        out += ",\"package\":\(PxcHello.quote(package))"
        out += ",\"phoneOsVersion\":\(PxcHello.quote(phoneOsVersion))"
        out += ",\"versionCode\":\(PxcHello.wireVersionCode)"
        out += ",\"supportH264IFrame\":\(PxcHello.supportH264IFrame)"
        out += ",\"supportFunction\":0"
        out += ",\"appVersionFingerPrint\":\"\""
        out += ",\"token\":\(PxcHello.quote(token))"
        out += ",\"pubkey\":\(PxcHello.quote(publicKey))"
        out += ",\"encryptedHUID\":\(PxcHello.quote(encryptedHUID))"
        out += ",\"currentTimeZone\":\(PxcHello.quote(timeZone))"
        out += "}"
        return out
    }

    /// The clock envelope the accessory sends around a hello or a clock request. `time`
    /// and `currentTime` carry the same value.
    public static func clockEnvelope(time: Int64, currentTime: Int64, timeZone: String) -> String {
        "{\"time\":\(time),\"currentTime\":\(currentTime),\"currentTimeZone\":\(quote(timeZone))}"
    }

    public static let supportFunctionEnvelope = "{\"supportFunction\":0}"
    public static let controlBeacon = "{\"control\":1}"

    private static func quote(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("\"")
        for character in value {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if let ascii = character.asciiValue, ascii < 0x20 {
                    escaped += String(format: "\\u%04x", ascii)
                } else {
                    escaped.append(character)
                }
            }
        }
        escaped.append("\"")
        return escaped
    }
}
