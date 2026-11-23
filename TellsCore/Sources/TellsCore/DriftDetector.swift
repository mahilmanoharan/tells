import Foundation

public enum DriftState: String, Sendable, Equatable { case normal, drifting }

/// The z-score to start a drift, and the windows in a row that it needs (design/experiences.md Section 9).
public enum DriftSensitivity: String, Sendable, CaseIterable {
    case low, medium, high

    public var startZ: Double {
        switch self {
        case .low: 2.5
        case .medium: 2.0
        case .high: 1.5
        }
    }

    public var startWindows: Int { self == .low ? 4 : 3 }
}

/// Level 1 drift (PLAN.md Section 6, SPEC.md 2.6). It needs no labels and no check-in.
/// The baseline is the log of `keyboard.iki_median_ms` in the same local hour plus or minus 1,
/// from the 14 most recent usable typing days before the window, however far back (D-039).
/// The store keeps rows for 30 days (DEC-13), so older days are not there.
public actor DriftDetector {
    // DEFAULT: D-027
    static let typingWindowKeys = 20.0
    static let usableDayWindows = 12
    // DEFAULT: D-029
    static let minimumBaselineDays = 3
    static let endZ = 1.0
    static let endWindows = 2
    static let baselineDays = 14
    // DEFAULT: D-090
    static let minimumBaselineWindows = 5
    static let warmUp: TimeInterval = 1800

    private static let keyCount = FeatureName("keyboard.key_count")
    private static let ikiMedian = FeatureName("keyboard.iki_median_ms")

    private let store: any FeatureReader
    private let calendar: Calendar
    public private(set) var sensitivity: DriftSensitivity
    public private(set) var state = DriftState.normal
    private var startStreak = 0
    private var endStreak = 0
    private var cursor: Date?

    public init(store: any FeatureReader, sensitivity: DriftSensitivity = .medium, calendar: Calendar = .current) {
        self.store = store
        self.sensitivity = sensitivity
        self.calendar = calendar
    }

    public func setSensitivity(_ value: DriftSensitivity) { sensitivity = value }

    /// A typing window has 20 or more key presses and an IKI median (D-027).
    static func isTypingWindow(_ row: FeatureRow) -> Bool {
        guard row.sensor == .keyboard, let count = keyCount.flatMap({ row.values[$0] }),
              let median = ikiMedian.flatMap({ row.values[$0] }) else { return false }
        return count >= typingWindowKeys && median > 0
    }

    /// The z-score of a typing window, or nil for a window that is not a typing window or when the
    /// baseline has fewer than 3 usable typing days.
    public func zScore(for row: FeatureRow) async -> Double? {
        guard Self.isTypingWindow(row), let name = Self.ikiMedian, let value = row.values[name], value > 0 else { return nil }
        let from = row.windowStart.addingTimeInterval(-Double(Retention.days + 1) * 86_400)
        guard let history = try? await store.featureRows(.keyboard, in: DateInterval(start: from, end: row.windowStart)) else {
            return nil
        }
        let past = history.filter { $0.day < row.day && Self.isTypingWindow($0) }
        let usableDays = Dictionary(grouping: past, by: \.day).filter { $0.value.count >= Self.usableDayWindows }
        let usable = usableDays.keys.sorted(by: >).prefix(Self.baselineDays).reduce(into: [TellsDay: [FeatureRow]]()) { $0[$1] = usableDays[$1] }
        guard usable.count >= Self.minimumBaselineDays else { return nil }
        let hour = localHour(of: row)
        let logs = usable.values.flatMap { $0 }
            .filter { Self.hourDistance(localHour(of: $0), hour) <= 1 }
            .compactMap { $0.values[name] }
            .map { log($0) }
        guard logs.count >= Self.minimumBaselineWindows else { return nil }
        let spread = Stats.sampleSD(logs)
        guard spread > 0 else { return nil }
        return (log(value) - Stats.mean(logs)) / spread
    }

    /// Reads the keyboard rows that closed since the last call, in order, and gives the drift state.
    public func update(now: Date) async -> DriftState {
        let from = cursor ?? now.addingTimeInterval(-Self.warmUp)
        let rows = (try? await store.featureRows(.keyboard, in: DateInterval(start: from, end: max(from, now)))) ?? []
        for row in rows where cursor.map({ row.windowStart > $0 }) ?? true {
            if let z = await zScore(for: row) { advance(with: z) }
            cursor = row.windowStart
        }
        if cursor == nil { cursor = from }
        return state
    }

    /// Feeds one z-score to the nudge rule. A window with no z-score changes nothing (D-090).
    func advance(with z: Double) {
        let size = abs(z)
        switch state {
        case .normal:
            startStreak = size >= sensitivity.startZ ? startStreak + 1 : 0
            if startStreak >= sensitivity.startWindows {
                state = .drifting
                startStreak = 0
                endStreak = 0
            }
        case .drifting:
            endStreak = size < Self.endZ ? endStreak + 1 : 0
            if endStreak >= Self.endWindows {
                state = .normal
                startStreak = 0
                endStreak = 0
            }
        }
    }

    private func localHour(of row: FeatureRow) -> Int {
        let local = row.windowStart.addingTimeInterval(Double(row.utcOffsetMinutes) * 60)
        var utc = calendar
        utc.timeZone = .gmt
        return utc.component(.hour, from: local)
    }

    /// Distance on a 24 hour circle.
    private static func hourDistance(_ a: Int, _ b: Int) -> Int {
        let gap = abs(a - b)
        return min(gap, 24 - gap)
    }
}
