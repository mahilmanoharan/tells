import Foundation

/// App switch features of SPEC.md 3.2 and 3.3. A sample has only a category (hard rule 3).
/// Each `appActivated` sample is one real change of app: the sensor drops repeat activations.
/// An `appFrontmost` sample marks the app already in front. It is not a switch.
public struct AppSwitchExtractor: FeatureExtractor {
    public let sensor: SensorID = .appswitch
    public let schemaVersion = 1

    // DEFAULT: D-066
    static let rateMinInputMinutes = 30.0

    static let switchCount = Self.feature("switch_count")
    static let categoryCount = Self.feature("category_count")
    static let daySwitchCount = Self.feature("day_switch_count")
    static let daySwitchRate = Self.feature("day_switch_rate_h")
    static let activityInputS = FeatureName("activity.input_s")

    /// Window seconds name and day minutes name of each category.
    static let categoryFeatures: [(category: AppCategory, seconds: FeatureName, dayMinutes: FeatureName)] =
        AppCategory.allCases.map { category in
            let label = Self.label(category)
            return (category, Self.feature(label + "_s"), Self.feature("day_" + label + "_min"))
        }

    public init() {}

    public var windowFeatures: [FeatureName] {
        [Self.switchCount, Self.categoryCount] + Self.categoryFeatures.map(\.seconds)
    }

    public var dayFeatures: [FeatureName] {
        [Self.daySwitchCount, Self.daySwitchRate] + Self.categoryFeatures.map(\.dayMinutes)
    }

    public func extractWindow(_ samples: [SensorSample], window: DateInterval) -> FeatureVector {
        // An `appFrontmost` sample starts category time like an activation. It is not a switch.
        let activations = samples.filter { $0.sensor == .appswitch && ($0.kind == .appActivated || $0.kind == .appFrontmost) }
        let switches = activations.filter { $0.kind == .appActivated }.count
        // DEFAULT: D-066
        // The app in front at window start is known only from an `appFrontmost` sample at window start.
        // Without one, time before the first sample counts for no category.
        var seconds: [AppCategory: Double] = [:]
        for (index, sample) in activations.enumerated() {
            let end = index + 1 < activations.count ? activations[index + 1].time : window.end
            let category = AppCategory(rawValue: Int(sample.value)) ?? .other
            seconds[category, default: 0] += max(0, end.timeIntervalSince(sample.time))
        }
        var vector: FeatureVector = [
            Self.switchCount: Double(switches),
            Self.categoryCount: Double(Set(activations.map { Int($0.value) }).count),
        ]
        for feature in Self.categoryFeatures { vector[feature.seconds] = seconds[feature.category] ?? 0 }
        return vector
    }

    public func extractDay(_ rows: [FeatureRow], day: TellsDay) -> FeatureVector {
        let dayRows = rows.filter { $0.sensor == .appswitch && $0.day == day }
        guard !dayRows.isEmpty else { return [:] }
        let switches = dayRows.compactMap { $0.values[Self.switchCount] }.reduce(0, +)
        var vector: FeatureVector = [Self.daySwitchCount: switches]
        for feature in Self.categoryFeatures {
            vector[feature.dayMinutes] = dayRows.compactMap { $0.values[feature.seconds] }.reduce(0, +) / 60
        }
        // DEFAULT: D-066
        // The input minutes come from the `activity` rows in `rows`, summed as in `ActivityExtractor`.
        if let inputS = Self.activityInputS {
            let inputMin = rows.filter { $0.sensor == .activity && $0.day == day }
                .compactMap { $0.values[inputS] }.reduce(0, +) / 60
            if inputMin >= Self.rateMinInputMinutes { vector[Self.daySwitchRate] = switches / (inputMin / 60) }
        }
        return vector
    }

    private static func label(_ category: AppCategory) -> String {
        switch category {
        case .other: "other"
        case .productivity: "productivity"
        case .developer: "developer"
        case .social: "social"
        case .entertainment: "entertainment"
        }
    }

    private static func feature(_ suffix: String) -> FeatureName {
        guard let name = FeatureName("appswitch." + suffix) else { preconditionFailure("bad feature name") }
        return name
    }
}
