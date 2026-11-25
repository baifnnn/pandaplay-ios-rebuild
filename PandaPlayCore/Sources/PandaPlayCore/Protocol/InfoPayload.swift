import Foundation

/// The body of a `/info` response.
///
/// The key set comes from the accessory's display-info builder. Two details are easy to
/// get wrong and both are load bearing:
///  * the body is a **binary plist** even though the response declares
///    `application/octet-stream`;
///  * `features` is 8 only when the controller supplied a physical width, so a probe
///    without one sees `features: 0` and must not conclude the receiver lacks features.
public enum InfoPayload {
    public static let sourceVersion = "1.0.2"
    /// Display class 110, the accessory's own value.
    public static let displayType: Int64 = 110
    public static let featuresPresent: Int64 = 8
    public static let featuresAbsent: Int64 = 0
    public static let statusFlagsIdle: Int64 = 0

    /// Screen sizes below 17 or above 4096 are rejected by the accessory, as is a frame
    /// rate outside 1...60.
    public static let minimumDimension = 17
    public static let maximumDimension = 4096
    public static let minimumFPS = 1
    public static let maximumFPS = 60

    public static let modeNames = ["screen", "audio", "video"]

    /// One entry of `displays`. The `safeArea` sub-dictionary repeats the size because the
    /// controller uses it for its own chrome layout.
    public static func display(
        width: Int,
        height: Int,
        uuid: String,
        maxFPS: Int = 60,
        physicalWidth: Int = 0,
        physicalHeight: Int = 0,
        orientation: Int = 1
    ) -> PlistValue {
        let safeArea = PlistValue.dict()
            .add("uuid", .from(uuid))
            .add("type", .from(displayType))
            .add("widthPixels", .from(width))
            .add("heightPixels", .from(height))
            .add("drawUIOutsideSafeArea", .from(false))
        return PlistValue.dict()
            .add("widthPixels", .from(width))
            .add("heightPixels", .from(height))
            .add("originXPixels", .from(0))
            .add("originYPixels", .from(0))
            .add("maxFPS", .from(maxFPS))
            .add("widthPhysical", .from(physicalWidth))
            .add("heightPhysical", .from(physicalHeight))
            .add("orientation", .from(orientation))
            .add("uiAppearanceMode", .from(0))
            .add("uiAppearanceSetting", .from(0))
            .add("mapAppearanceMode", .from(0))
            .add("mapAppearanceSetting", .from(0))
            .add("safeArea", safeArea)
            .add("viewArea", .from(0))
            .add("initialViewArea", .from(0))
    }

    /// The whole response body.
    public static func build(
        deviceID: Data,
        width: Int,
        height: Int,
        uuid: String,
        maxFPS: Int = 60,
        physicalWidth: Int = 0,
        physicalHeight: Int = 0
    ) -> PlistValue {
        let modes = PlistValue.dict()
        for name in modeNames {
            _ = modes.add(name, .from(0))
        }
        let displays = PlistValue.array([
            display(
                width: width, height: height, uuid: uuid, maxFPS: maxFPS,
                physicalWidth: physicalWidth, physicalHeight: physicalHeight
            )
        ])
        // `features` tracks whether the controller told us the real panel size; it is not
        // a statement about what this receiver can decode.
        let features = physicalWidth != 0 ? featuresPresent : featuresAbsent
        return PlistValue.dict()
            .add("sourceVersion", .from(sourceVersion))
            .add("deviceID", .from(deviceID.map { String(format: "%02x", $0) }.joined()))
            .add("model", .from("PandaPlay+"))
            .add("name", .from("PandaPlay+"))
            .add("features", .from(features))
            .add("statusFlags", .from(statusFlagsIdle))
            .add("modes", modes)
            .add("displays", displays)
    }

    public static func encode(
        deviceID: Data,
        width: Int,
        height: Int,
        uuid: String,
        maxFPS: Int = 60,
        physicalWidth: Int = 0,
        physicalHeight: Int = 0
    ) -> Data {
        PlistCodec.encode(build(
            deviceID: deviceID, width: width, height: height, uuid: uuid,
            maxFPS: maxFPS, physicalWidth: physicalWidth, physicalHeight: physicalHeight
        ))
    }

    /// Keys a `SETUP` body is expected to use.
    public static let setupStreamKeys = [
        "streams", "type", "dataPort", "controlPort", "timingPort", "streamConnectionID"
    ]

    /// The five per-stream encryption key names a `SETUP` reply may carry.
    public static let streamKeyNames = [
        "DataStream-Output-Encryption-Key",
        "Events-Read-Encryption-Key",
        "Events-Write-Encryption-Key",
        "Control-Write-Encryption-Key",
        "Control-Read-Encryption-Key",
    ]

    /// Reasons a `SETUP` can be refused, in the accessory's own wording.
    public static let streamRejections = [
        "unsupported_transport",
        "unsupported_plist",
        "unsupported_codec",
        "invalid_connection_id",
        "invalid_codec_type",
        "unsupported_stream_type",
        "unsupported_stream_count",
        "invalid_stream_type",
        "invalid_stream_dictionary",
        "empty_streams",
        "already_configured",
    ]
}
