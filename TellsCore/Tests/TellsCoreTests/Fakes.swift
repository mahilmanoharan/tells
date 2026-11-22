import Foundation
import Synchronization
import Testing
@testable import TellsCore

/// A fake sensor. It reads no hardware. Tests set its permission, hardware and flag state.
final class FakeSensor: Sensor {
    let id: SensorID
    let permission: PermissionKind?
    let usesPrivateAPI: Bool
    private let permissionStatus: PermissionStatus
    private let hardwarePresent: Bool
    private let defaultsSuite: String
    private let continuation = Mutex<AsyncStream<SensorSample>.Continuation?>(nil)

    init(id: SensorID, permission: PermissionKind?, permissionStatus: PermissionStatus = .granted,
         hardwarePresent: Bool = true, usesPrivateAPI: Bool = false, defaultsSuite: String = "tells.tests") {
        self.id = id
        self.permission = permission
        self.permissionStatus = permissionStatus
        self.hardwarePresent = hardwarePresent
        self.usesPrivateAPI = usesPrivateAPI
        self.defaultsSuite = defaultsSuite
    }

    var isRunning: Bool { continuation.withLock { $0 != nil } }

    func availability() async -> SensorAvailability { currentAvailability() }

    func start() throws -> AsyncStream<SensorSample> {
        let state = currentAvailability()
        guard state == .available else { throw SensorError.notAvailable(state) }
        let (stream, newContinuation) = AsyncStream<SensorSample>.makeStream()
        continuation.withLock { $0 = newContinuation }
        return stream
    }

    func stop() async {
        let old = continuation.withLock { current -> AsyncStream<SensorSample>.Continuation? in
            defer { current = nil }
            return current
        }
        old?.finish()
    }

    func emit(_ sample: SensorSample) {
        _ = continuation.withLock { $0?.yield(sample) }
    }

    private func currentAvailability() -> SensorAvailability {
        guard hardwarePresent else { return .notOnThisMac }
        if usesPrivateAPI {
            guard let defaults = UserDefaults(suiteName: defaultsSuite), SensorFlag.isOn(id, in: defaults) else {
                return .disabledByFlag
            }
        }
        if let permission {
            switch permissionStatus {
            case .granted: break
            case .denied: return .permissionDenied(permission)
            case .notAsked: return .permissionNotAsked(permission)
            }
        }
        return .available
    }
}

/// A fake extractor. Its day feature is the sum of `activity.input_s` over the rows it gets.
struct SumExtractor: FeatureExtractor {
    static let inputSeconds = FeatureName("activity.input_s")
    static let inputMinutes = FeatureName("activity.input_min")

    let sensor: SensorID = .activity
    let schemaVersion = 1
    var windowFeatures: [FeatureName] { [Self.inputSeconds].compactMap { $0 } }
    var dayFeatures: [FeatureName] { [Self.inputMinutes].compactMap { $0 } }

    func extractWindow(_ samples: [SensorSample], window: DateInterval) -> FeatureVector { [:] }

    func extractDay(_ rows: [FeatureRow], day: TellsDay) -> FeatureVector {
        guard let input = Self.inputSeconds, let output = Self.inputMinutes else { return [:] }
        let seconds = rows.compactMap { $0.values[input] }.reduce(0, +)
        return [output: seconds / 60]
    }
}

func name(_ text: String) throws -> FeatureName {
    try #require(FeatureName(text))
}

func row(_ sensor: SensorID, minute: Int, day: TellsDay = TellsDay(yyyymmdd: 20261121),
         values: FeatureVector = [:]) -> FeatureRow {
    FeatureRow(sensor: sensor, schemaVersion: 1,
               windowStart: Date(timeIntervalSince1970: 1_795_000_000 + Double(minute * 60)),
               utcOffsetMinutes: 0, day: day, coverageSeconds: 300, values: values)
}
