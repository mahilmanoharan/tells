import Foundation

public struct Prediction: Sendable, Equatable {
    public let day: TellsDay
    public let target: CheckInItem
    public let value: Double              // clamped to 1...5

    public init(day: TellsDay, target: CheckInItem, value: Double) {
        self.day = day
        self.target = target
        self.value = min(max(value, 1), 5)
    }
}

public protocol ModelProvider: Sendable {
    var target: CheckInItem { get }
    var featureNames: [FeatureName] { get }   // the features the model uses
    var isMock: Bool { get }                  // true until G3 closes
    var modelVersion: String { get }
    /// nil if `windowCount` is less than 12 (D-027), or if a name in `featureNames` is absent (DEC-8).
    func predict(_ features: FeatureVector, day: TellsDay, windowCount: Int) async -> Prediction?
}

/// Not-enough-data thresholds (D-027).
public enum DataThreshold {
    public static let minimumWindowsToday = 12
}

/// The day features of one day, built from the saved `FeatureRow` values of that day (DEC-16).
public struct TodayFeatures: Sendable, Equatable {
    public let day: TellsDay
    public let values: FeatureVector
    public let windowCount: Int

    public init(day: TellsDay, values: FeatureVector, windowCount: Int) {
        self.day = day
        self.values = values
        self.windowCount = windowCount
    }

    /// Pure function. For each extractor, it gives the rows of its sensor to `extractDay`, then merges the vectors.
    public static func build(day: TellsDay, rows: [FeatureRow], extractors: [any FeatureExtractor]) -> TodayFeatures {
        var values: FeatureVector = [:]
        for extractor in extractors {
            let sensorRows = rows.filter { $0.sensor == extractor.sensor }
            values.merge(extractor.extractDay(sensorRows, day: day)) { _, new in new }
        }
        // DEFAULT: D-050
        let windowCount = Set(rows.filter { $0.day == day }.map(\.windowStart)).count
        return TodayFeatures(day: day, values: values, windowCount: windowCount)
    }
}

/// The practice model until gate G3 closes. A fixed linear function, so tests know the answer.
public struct MockModelProvider: ModelProvider {
    public static let sleepStart = FeatureName("activity.sleep_start_min")
    public static let lateInput = FeatureName("activity.late_input_min")

    public let target: CheckInItem = .energy
    public let featureNames: [FeatureName] = [sleepStart, lateInput].compactMap { $0 }
    public let isMock = true
    public let modelVersion = "mock-1" // DEFAULT: D-051

    public init() {}

    public func predict(_ features: FeatureVector, day: TellsDay, windowCount: Int) async -> Prediction? {
        guard windowCount >= DataThreshold.minimumWindowsToday,
              let sleepStartName = Self.sleepStart, let lateInputName = Self.lateInput,
              let sleepStart = features[sleepStartName], let lateInput = features[lateInputName]
        else { return nil }
        // DEFAULT: D-051
        let energy = 4.0 - 0.002 * sleepStart - 0.01 * lateInput
        return Prediction(day: day, target: target, value: energy)
    }
}
