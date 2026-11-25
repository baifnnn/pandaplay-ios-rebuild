import Foundation

/// One `uptimeMs=key=value` record, matching the accessory's redacted diagnostics log.
public struct TelemetryRecord: Equatable, Sendable {
    public let uptimeMilliseconds: Int64
    public let key: String
    public let value: String

    public init(uptimeMilliseconds: Int64, key: String, value: String) {
        self.uptimeMilliseconds = uptimeMilliseconds
        self.key = key
        self.value = value
    }
}

/// An append-only event log keyed the way the accessory's counters are keyed.
///
/// The original writes `panda-native-redacted-diagnostics.log` with one `key=value` line
/// per counter update and an uptime prefix. Nothing here is a fidelity claim about the
/// on-disk format — this is the same data, rendered the same way, so the values can be
/// compared side by side.
public final class TelemetryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TelemetryRecord] = []
    private let startUptime: Int64
    private let clock: () -> Int64

    /// Upper bound on retained records. The accessory clamps its counters rather than
    /// growing without limit, and a runaway log is worse than a truncated one.
    public var maxRecords = 100_000
    public var enabled = true

    public init(clock: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) }) {
        self.clock = clock
        self.startUptime = clock()
    }

    public var records: [TelemetryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    public func emit(_ key: String, _ value: Any) {
        guard enabled else { return }
        let text: String
        switch value {
        case let flag as Bool: text = flag ? "true" : "false"
        case let number as Int: text = String(number)
        case let number as Int64: text = String(number)
        case let number as UInt32: text = String(number)
        case let number as Double:
            // The original formats floats with three decimals at most.
            text = String(format: "%.3f", number)
        case let string as String: text = string
        default: text = String(describing: value)
        }
        push(key, text)
    }

    public func emit(_ key: String) {
        guard enabled else { return }
        push(key, "true")
    }

    private func push(_ key: String, _ value: String) {
        let record = TelemetryRecord(
            uptimeMilliseconds: clock() - startUptime,
            key: key,
            value: value
        )
        lock.lock()
        defer { lock.unlock() }
        if storage.count >= maxRecords { storage.removeFirst() }
        storage.append(record)
    }

    /// Renders the log the way the accessory's exporter does: one `uptimeMs<TAB>key=value`
    /// line per record.
    public func render() -> String {
        records.map { "\($0.uptimeMilliseconds)\t\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    /// Number of records whose key starts with `prefix`.
    public func count(prefix: String) -> Int {
        records.reduce(into: 0) { total, record in
            if record.key.hasPrefix(prefix) { total += 1 }
        }
    }

    /// The most recent value recorded for `key`, or nil when it was never emitted.
    public func last(_ key: String) -> String? {
        records.last { $0.key == key }?.value
    }
}

/// Frame-length histogram with the accessory's eight-way banding.
///
/// Lengths below 8193 are passed through unbanded; above that the value is bucketed so a
/// counter dump stays readable. The thresholds are the exact immediates from the
/// accessory's telemetry callback.
public struct FrameLengthHistogram: Sendable {
    /// Lengths under this value are not banded at all.
    public static let passthroughLimit = 0x2001

    private var buckets = [Int](repeating: 0, count: 9)
    public private(set) var total = 0

    public init() {}

    /// Band index for one frame length, 1...8.
    public static func band(for length: Int) -> Int {
        if length < passthroughLimit { return 1 }
        if length > 0x400000 { return 8 }
        if length > 0x100000 { return 7 }
        if length > 0x40000 { return 6 }
        if length > 0x10000 { return 5 }
        if length > 0x8000 { return 4 }
        if length > 0x4000 { return 3 }
        return 2
    }

    public mutating func add(_ length: Int) {
        buckets[FrameLengthHistogram.band(for: length)] += 1
        total += 1
    }

    public subscript(band: Int) -> Int {
        guard band >= 0, band < buckets.count else { return 0 }
        return buckets[band]
    }

    public var bands: [Int] { buckets }
}
