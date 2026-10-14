import Foundation

/// Why a channel is considered dead.
public enum DeadReason: Equatable, Sendable {
    /// Audio is arriving but it's (digital) silence — transmitter off, muted, battery dead.
    case silence
    /// The device stopped delivering audio buffers altogether.
    case noData
    /// The device vanished from the system (unplugged, Bluetooth dropped).
    case disconnected

    public var label: String {
        switch self {
        case .silence: return "silent"
        case .noData: return "no audio"
        case .disconnected: return "disconnected"
        }
    }
}

public enum ChannelHealth: Equatable, Sendable {
    case live
    case dead(reason: DeadReason, since: Date)

    public var isDead: Bool {
        if case .dead = self { return true }
        return false
    }

    public var deadSince: Date? {
        if case let .dead(_, since) = self { return since }
        return nil
    }
}

/// Decides whether one input channel is live or dead, given a stream of peak
/// readings. Pure value type so it can be tested without any audio hardware.
public struct SilenceTracker: Sendable {
    /// Linear peak amplitude (0...1) at or below which a reading counts as silence.
    /// 0 means "exact digital silence only".
    public var silenceFloor: Float
    /// How long silence must persist before the channel is declared dead.
    public var deadAfter: TimeInterval
    /// How long without any audio buffers before the channel is declared dead.
    public var stallAfter: TimeInterval

    private var startedAt: Date
    private var lastData: Date?
    private var silentSince: Date?
    private var disconnectedAt: Date?

    public init(
        startedAt: Date,
        silenceFloor: Float,
        deadAfter: TimeInterval = 1.5,
        stallAfter: TimeInterval = 2.0
    ) {
        self.startedAt = startedAt
        self.silenceFloor = silenceFloor
        self.deadAfter = deadAfter
        self.stallAfter = stallAfter
    }

    public var isDisconnected: Bool { disconnectedAt != nil }

    /// Record one polling interval. `peak` is nil when no audio buffers arrived
    /// during the interval.
    public mutating func record(peak: Float?, at now: Date) {
        guard let peak else { return }
        lastData = now
        if peak <= silenceFloor {
            if silentSince == nil { silentSince = now }
        } else {
            silentSince = nil
        }
    }

    public mutating func markDisconnected(at now: Date) {
        if disconnectedAt == nil { disconnectedAt = now }
    }

    /// Start afresh, e.g. after the device reappears or the Mac wakes.
    public mutating func reset(at now: Date) {
        startedAt = now
        lastData = nil
        silentSince = nil
        disconnectedAt = nil
    }

    public func health(at now: Date) -> ChannelHealth {
        if let disconnectedAt {
            return .dead(reason: .disconnected, since: disconnectedAt)
        }
        let dataRef = lastData ?? startedAt
        if now.timeIntervalSince(dataRef) >= stallAfter {
            return .dead(reason: .noData, since: min(dataRef, silentSince ?? dataRef))
        }
        if let silentSince, now.timeIntervalSince(silentSince) >= deadAfter {
            return .dead(reason: .silence, since: silentSince)
        }
        return .live
    }
}

/// A recorded period of dead air on one device.
public struct Dropout: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let deviceName: String
    public let reason: DeadReason
    public let start: Date
    public var end: Date?

    public init(deviceName: String, reason: DeadReason, start: Date, end: Date? = nil) {
        self.deviceName = deviceName
        self.reason = reason
        self.start = start
        self.end = end
    }

    public func duration(at now: Date) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }
}

public enum Level {
    /// Threshold values at or below this mean "exact digital silence".
    public static let exactSilenceDB: Double = -200

    public static func linear(fromDB db: Double) -> Float {
        db <= exactSilenceDB ? 0 : Float(pow(10, db / 20))
    }

    public static func decibels(fromLinear amplitude: Float) -> Double {
        amplitude <= 0 ? -.infinity : 20 * log10(Double(amplitude))
    }
}

public func formatDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded(.down)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
