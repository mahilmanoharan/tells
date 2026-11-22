import Foundation

/// Keyboard features of SPEC.md 3.2 and 3.3. It reads only times (hard rule 2).
public struct KeyboardExtractor: FeatureExtractor {
    public let sensor: SensorID = .keyboard
    public let schemaVersion = 1

    // DEFAULT: D-035
    static let pauseLimitMs = 2000.0
    static let minimumValues = 10
    // DEFAULT: D-027
    static let typingWindowKeys = 20.0
    static let minimumTypingWindows = 12

    static let keyCount = Self.feature("key_count")
    static let ikiMean = Self.feature("iki_mean_ms")
    static let ikiMedian = Self.feature("iki_median_ms")
    static let ikiSD = Self.feature("iki_sd_ms")
    static let ikiIQR = Self.feature("iki_iqr_ms")
    static let holdMedian = Self.feature("hold_median_ms")
    static let holdSD = Self.feature("hold_sd_ms")
    static let pauseCount = Self.feature("pause_count")
    static let typingSeconds = Self.feature("typing_s")
    static let dayKeyCount = Self.feature("day_key_count")
    static let dayTypingWindows = Self.feature("day_typing_windows")
    static let dayIkiMedian = Self.feature("day_iki_median_ms")
    static let dayIkiSD = Self.feature("day_iki_sd_ms")
    static let dayHoldMedian = Self.feature("day_hold_median_ms")

    public init() {}

    public var windowFeatures: [FeatureName] {
        [Self.keyCount, Self.ikiMean, Self.ikiMedian, Self.ikiSD, Self.ikiIQR, Self.holdMedian,
         Self.holdSD, Self.pauseCount, Self.typingSeconds]
    }

    public var dayFeatures: [FeatureName] {
        [Self.dayKeyCount, Self.dayTypingWindows, Self.dayIkiMedian, Self.dayIkiSD, Self.dayHoldMedian]
    }

    public func extractWindow(_ samples: [SensorSample], window: DateInterval) -> FeatureVector {
        let downs = samples.filter { $0.sensor == .keyboard && $0.kind == .keyDown }.map(\.time)
        let ups = samples.filter { $0.sensor == .keyboard && $0.kind == .keyUp }.map(\.time)
        var vector: FeatureVector = [Self.keyCount: Double(downs.count)]

        let intervals = zip(downs, downs.dropFirst()).map { $1.timeIntervalSince($0) * 1000 }
        let typingIntervals = intervals.filter { $0 <= Self.pauseLimitMs }
        vector[Self.pauseCount] = Double(intervals.count - typingIntervals.count)
        vector[Self.typingSeconds] = typingIntervals.reduce(0, +) / 1000
        if typingIntervals.count >= Self.minimumValues {
            vector[Self.ikiMean] = Stats.mean(typingIntervals)
            vector[Self.ikiMedian] = Stats.median(typingIntervals)
            vector[Self.ikiSD] = Stats.sampleSD(typingIntervals)
            vector[Self.ikiIQR] = Stats.iqr(typingIntervals)
        }

        let holds = Self.holds(downs: downs, ups: ups)
        if holds.count >= Self.minimumValues {
            vector[Self.holdMedian] = Stats.median(holds)
            vector[Self.holdSD] = Stats.sampleSD(holds)
        }
        return vector
    }

    public func extractDay(_ rows: [FeatureRow], day: TellsDay) -> FeatureVector {
        let dayRows = rows.filter { $0.sensor == .keyboard && $0.day == day }
        guard !dayRows.isEmpty else { return [:] }
        let counts = dayRows.compactMap { $0.values[Self.keyCount] }
        let typing = dayRows.filter { ($0.values[Self.keyCount] ?? 0) >= Self.typingWindowKeys }
        var vector: FeatureVector = [
            Self.dayKeyCount: counts.reduce(0, +),
            Self.dayTypingWindows: Double(typing.count),
        ]
        if typing.count >= Self.minimumTypingWindows {
            // DEFAULT: D-062
            for (dayFeature, windowFeature) in [(Self.dayIkiMedian, Self.ikiMedian), (Self.dayIkiSD, Self.ikiSD),
                                                (Self.dayHoldMedian, Self.holdMedian)] {
                let values = typing.compactMap { $0.values[windowFeature] }
                if !values.isEmpty { vector[dayFeature] = Stats.median(values) }
            }
        }
        return vector
    }

    /// Key ups pair with key downs in first-in, first-out order (DEC-12). A hold over the limit is dropped.
    static func holds(downs: [Date], ups: [Date]) -> [Double] {
        var holds: [Double] = []
        var nextDown = 0
        for up in ups {
            guard nextDown < downs.count, downs[nextDown] <= up else { continue }
            let hold = up.timeIntervalSince(downs[nextDown]) * 1000
            nextDown += 1
            if hold <= pauseLimitMs { holds.append(hold) }
        }
        return holds
    }

    private static func feature(_ suffix: String) -> FeatureName {
        guard let name = FeatureName("keyboard." + suffix) else { preconditionFailure("bad feature name") }
        return name
    }
}

/// Plain statistics. `quantile` uses linear interpolation between ranks (D-061).
enum Stats {
    static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

    static func median(_ values: [Double]) -> Double { quantile(values, 0.5) }

    static func sampleSD(_ values: [Double]) -> Double {
        let average = mean(values)
        let squares = values.map { ($0 - average) * ($0 - average) }.reduce(0, +)
        return (squares / Double(values.count - 1)).squareRoot()
    }

    static func iqr(_ values: [Double]) -> Double { quantile(values, 0.75) - quantile(values, 0.25) }

    // DEFAULT: D-061
    static func quantile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
}
