import Foundation

/// The Scattered trigger (SPEC.md Section 5, D-037): the last window has 10 or more app switches
/// and more than the 90th percentile of the last 14 days.
public enum ScatteredTrigger {
    static let floor = 10.0
    // DEFAULT: D-091
    public static let historyDays = 14
    static let maximumAge: TimeInterval = 600

    private static let switchCount = FeatureName("appswitch.switch_count")

    /// `rows` are `appswitch` windows. `now` decides if the last window is recent.
    public static func isScattered(rows: [FeatureRow], now: Date, today: TellsDay) -> Bool {
        guard let name = switchCount else { return false }
        let ordered = rows.filter { $0.sensor == .appswitch && $0.values[name] != nil }.sorted { $0.windowStart < $1.windowStart }
        guard let last = ordered.last, let count = last.values[name],
              now.timeIntervalSince(last.windowStart) <= WindowClock.windowLength + maximumAge,
              count >= floor else { return false }
        let from = today.adding(days: -historyDays)
        let earlier = ordered.dropLast().filter { $0.day >= from }.compactMap { $0.values[name] }
        guard !earlier.isEmpty else { return true }   // only the floor applies
        return count > Stats.quantile(earlier, 0.9)
    }
}
