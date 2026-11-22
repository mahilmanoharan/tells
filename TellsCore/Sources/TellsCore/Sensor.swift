import Foundation

public protocol Sensor: AnyObject, Sendable {
    var id: SensorID { get }
    var permission: PermissionKind? { get }      // nil if no permission is necessary
    var usesPrivateAPI: Bool { get }             // true: needs a feature flag (hard rule 5)
    func availability() async -> SensorAvailability
    func start() throws -> AsyncStream<SensorSample>  // throws if not available
    func stop() async                                  // finishes the stream; safe to call 2 times
}

// DEFAULT: D-053
public enum SensorError: Error, Equatable {
    case notAvailable(SensorAvailability)
}

/// Feature flags for sensors that use private APIs (D-042). All flags are off by default.
public enum SensorFlag {
    public static func key(for sensor: SensorID) -> String { "flag.\(sensor.rawValue)" }

    public static func isOn(_ sensor: SensorID, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(for: sensor))
    }
}
