import DeadAirCore
import Foundation

/// User preferences, persisted in UserDefaults.
struct Settings {
    private let defaults = UserDefaults.standard

    static let alertAfterChoices: [TimeInterval] = [3, 5, 10, 20, 30]
    static let neverAlert: TimeInterval = -1
    static let thresholdChoices: [Double] = [Level.exactSilenceDB, -100, -90, -80, -70]

    /// Selected microphones, keyed by Core Audio UID, valued by the last known name
    /// (so we can still show "not connected" devices).
    var selectedDevices: [String: String] {
        get { defaults.dictionary(forKey: "selectedDevices") as? [String: String] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: "selectedDevices") }
    }

    /// Seconds of dead air before the pop-up appears; `neverAlert` to only use the menu bar.
    var alertAfter: TimeInterval {
        get { defaults.object(forKey: "alertAfter") as? Double ?? 5 }
        nonmutating set { defaults.set(newValue, forKey: "alertAfter") }
    }

    /// Peak level (dBFS) at or below which audio counts as dead air.
    var thresholdDB: Double {
        get { defaults.object(forKey: "thresholdDB") as? Double ?? -100 }
        nonmutating set { defaults.set(newValue, forKey: "thresholdDB") }
    }

    var silenceFloor: Float { Level.linear(fromDB: thresholdDB) }

    var playSound: Bool {
        get { defaults.bool(forKey: "playSound") }
        nonmutating set { defaults.set(newValue, forKey: "playSound") }
    }

    static func thresholdLabel(_ db: Double) -> String {
        db <= Level.exactSilenceDB ? "Digital silence only" : "Below \(Int(db)) dB"
    }
}
