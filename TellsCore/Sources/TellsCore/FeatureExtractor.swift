import Foundation

public protocol FeatureExtractor: Sendable {
    var sensor: SensorID { get }
    var schemaVersion: Int { get }
    var windowFeatures: [FeatureName] { get }
    var dayFeatures: [FeatureName] { get }
    /// Pure function. Samples are in time order and inside `window`.
    func extractWindow(_ samples: [SensorSample], window: DateInterval) -> FeatureVector
    /// Pure function. Rows of this sensor from 18:00 on day-1 to 04:00 on day+1 (DEC-3).
    func extractDay(_ rows: [FeatureRow], day: TellsDay) -> FeatureVector
}
