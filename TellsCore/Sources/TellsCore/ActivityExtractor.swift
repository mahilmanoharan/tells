import Foundation

/// Activity features of SPEC.md 3.2 and 3.3. It reads only times (hard rule 2).
/// A probe sample has `value` = seconds since the last input. It carries no event type.
public struct ActivityExtractor: FeatureExtractor {
    public let sensor: SensorID = .activity
    public let schemaVersion = 1

    // DEFAULT: D-063
    static let windowSeconds = 300.0
    static let inputProbeLimit = 1.0           // a probe under 1 s shows input in the last 1 s
    static let breakMinSeconds = 300.0
    static let breakMaxSeconds = 3600.0
    static let sleepMinSeconds = 180.0 * 60
    static let lowActivityMinutes = 60.0
    // Minutes after 00:00 of day D (DEC-3).
    static let dayStartMin = 240.0
    static let dayEndMin = 1680.0
    static let sleepStartFromMin = -360.0      // 18:00 on D-1
    static let sleepStartToMin = 360.0         // 06:00 on D
    static let lateFromMin = -120.0            // 22:00 on D-1

    static let inputS = Self.feature("input_s")
    static let leadingIdle = Self.feature("leading_idle_s")
    static let trailingIdle = Self.feature("trailing_idle_s")
    static let longestIdle = Self.feature("longest_idle_s")
    static let firstInputMin = Self.feature("first_input_min")
    static let lastInputMin = Self.feature("last_input_min")
    static let inputMin = Self.feature("input_min")
    static let lowActivity = Self.feature("low_activity")
    static let breakCount = Self.feature("break_count")
    static let longestStretch = Self.feature("longest_stretch_min")
    static let lateInputMin = Self.feature("late_input_min")
    static let sleepStart = Self.feature("sleep_start_min")
    static let sleepEnd = Self.feature("sleep_end_min")
    static let sleepGap = Self.feature("sleep_gap_min")
    static let coverageMin = Self.feature("coverage_min")

    public init() {}

    public var windowFeatures: [FeatureName] { [Self.inputS, Self.leadingIdle, Self.trailingIdle, Self.longestIdle] }

    public var dayFeatures: [FeatureName] {
        [Self.firstInputMin, Self.lastInputMin, Self.inputMin, Self.lowActivity, Self.breakCount,
         Self.longestStretch, Self.lateInputMin, Self.sleepStart, Self.sleepEnd, Self.sleepGap, Self.coverageMin]
    }

    public func extractWindow(_ samples: [SensorSample], window: DateInterval) -> FeatureVector {
        let probes = samples.filter { $0.sensor == .activity && $0.kind == .inputProbe }
        // Each probe gives the time of the last input. The same input shows in many probes.
        // Seconds after window start, sorted. The same input in many probes gives the same value, which changes no result.
        let inputs = probes.map { $0.time.timeIntervalSince(window.start) - $0.value }
            .filter { $0 >= 0 && $0 <= window.duration }
            .sorted()

        let length = window.duration
        var vector: FeatureVector = [Self.inputS: Double(probes.filter { $0.value < Self.inputProbeLimit }.count)]
        guard let first = inputs.first, let last = inputs.last else {
            vector[Self.leadingIdle] = length
            vector[Self.trailingIdle] = length
            vector[Self.longestIdle] = length
            return vector
        }
        vector[Self.leadingIdle] = first
        vector[Self.trailingIdle] = length - last
        let edges = [0] + inputs + [length]
        vector[Self.longestIdle] = zip(edges, edges.dropFirst()).map { $1 - $0 }.max() ?? length
        return vector
    }

    public func extractDay(_ rows: [FeatureRow], day: TellsDay) -> FeatureVector {
        let activity = rows.filter { $0.sensor == .activity }
        let dayRows = activity.filter { $0.day == day }
        // DEFAULT: D-063
        guard !dayRows.isEmpty else { return [:] }
        let midnight = Self.localMidnightSeconds(of: day)
        let windows = activity.map { Window(row: $0, midnight: midnight) }.sorted { $0.startMin < $1.startMin }

        let inputMin = dayRows.compactMap { $0.values[Self.inputS] }.reduce(0, +) / 60
        var vector: FeatureVector = [
            Self.inputMin: inputMin,
            Self.lowActivity: inputMin < Self.lowActivityMinutes ? 1 : 0,
            Self.coverageMin: dayRows.map(\.coverageSeconds).reduce(0, +) / 60,
            Self.lateInputMin: windows.filter { $0.startMin >= Self.lateFromMin && $0.startMin < Self.dayStartMin }
                .compactMap(\.inputSeconds).reduce(0, +) / 60,
        ]

        let points = windows.filter { $0.hasInput }
        addDayShape(&vector, points: points.filter { $0.startMin >= Self.dayStartMin && $0.startMin < Self.dayEndMin })
        addSleep(&vector, points: points)
        return vector
    }

    private func addDayShape(_ vector: inout FeatureVector, points: [Window]) {
        guard let first = points.first?.firstInputMin, let last = points.last?.lastInputMin else { return }
        vector[Self.firstInputMin] = first
        vector[Self.lastInputMin] = last
        let gaps = Self.gaps(points)
        vector[Self.breakCount] = Double(gaps.filter {
            $0.seconds >= Self.breakMinSeconds && $0.seconds <= Self.breakMaxSeconds
        }.count)
        var stretchStart = first
        var longest = 0.0
        for gap in gaps where gap.seconds >= Self.breakMinSeconds {
            longest = max(longest, gap.startMin - stretchStart)
            stretchStart = gap.endMin
        }
        vector[Self.longestStretch] = max(longest, last - stretchStart)
    }

    private func addSleep(_ vector: inout FeatureVector, points: [Window]) {
        let candidates = Self.gaps(points).filter {
            $0.startMin >= Self.sleepStartFromMin && $0.startMin <= Self.sleepStartToMin
                && $0.seconds >= Self.sleepMinSeconds
        }
        var best: Gap?
        for gap in candidates where gap.seconds > (best?.seconds ?? 0) { best = gap }   // first of equal gaps wins
        guard let best else { return }
        vector[Self.sleepStart] = best.startMin
        vector[Self.sleepEnd] = best.endMin
        vector[Self.sleepGap] = best.seconds / 60
    }

    /// A window row on the minute line of day D. A gap joins across windows (SPEC.md 3.3).
    private struct Window {
        let startMin: Double
        let firstInputMin: Double
        let lastInputMin: Double
        let hasInput: Bool
        let inputSeconds: Double?

        init(row: FeatureRow, midnight: Double) {
            let local = row.windowStart.timeIntervalSince1970 + Double(row.utcOffsetMinutes) * 60
            startMin = (local - midnight) / 60
            inputSeconds = row.values[ActivityExtractor.inputS]
            if let leading = row.values[ActivityExtractor.leadingIdle],
               let trailing = row.values[ActivityExtractor.trailingIdle],
               leading < ActivityExtractor.windowSeconds, trailing < ActivityExtractor.windowSeconds {
                hasInput = true
                firstInputMin = startMin + leading / 60
                lastInputMin = startMin + (ActivityExtractor.windowSeconds - trailing) / 60
            } else {
                hasInput = false
                firstInputMin = 0
                lastInputMin = 0
            }
        }
    }

    private struct Gap {
        let startMin: Double
        let endMin: Double
        var seconds: Double { (endMin - startMin) * 60 }
    }

    /// Gaps between the last input of one window and the first input of the next window with input.
    private static func gaps(_ points: [Window]) -> [Gap] {
        zip(points, points.dropFirst()).map { Gap(startMin: $0.lastInputMin, endMin: $1.firstInputMin) }
    }

    /// Seconds of 00:00 of `day`, in a clock where the local time is read as UTC.
    private static func localMidnightSeconds(of day: TellsDay) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = DateComponents(year: day.yyyymmdd / 10_000, month: day.yyyymmdd / 100 % 100, day: day.yyyymmdd % 100)
        return calendar.date(from: parts)?.timeIntervalSince1970 ?? 0
    }

    private static func feature(_ suffix: String) -> FeatureName {
        guard let name = FeatureName("activity." + suffix) else { preconditionFailure("bad feature name") }
        return name
    }
}
