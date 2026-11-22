import Foundation
import Synchronization
import TellsCore

/// One `appActivated` sample for each real change of the frontmost app. `value` is the `AppCategory`.
/// API: public (`NSWorkspace`). It needs no permission.
/// A sample has no bundle ID, no app name and no window title (hard rule 3).
public final class AppSwitchSensor: Sensor {
    public let id: SensorID = .appswitch
    public let permission: PermissionKind? = nil
    public let usesPrivateAPI = false

    private let source: any AppActivationSource
    private let now: @Sendable () -> Date
    private let continuation = Mutex<AsyncStream<SensorSample>.Continuation?>(nil)
    // DEFAULT: D-066
    // The process number of the last app, in memory only. It shows "different from the previous app" and never leaves this class.
    private let lastProcessID = Mutex<Int32?>(nil)

    public convenience init() {
        self.init(source: SystemAppActivationSource(), now: { Date() })
    }

    // DEFAULT: D-066
    init(source: any AppActivationSource, now: @escaping @Sendable () -> Date) {
        self.source = source
        self.now = now
    }

    public func availability() async -> SensorAvailability { .available }

    public func start() throws -> AsyncStream<SensorSample> {
        finishStream()
        lastProcessID.withLock { $0 = nil }
        let (stream, newContinuation) = AsyncStream<SensorSample>.makeStream(bufferingPolicy: .unbounded)
        continuation.withLock { $0 = newContinuation }
        source.start { [weak self] activation in self?.handle(activation) }
        if let current = source.frontmost(), !current.isTells {
            lastProcessID.withLock { $0 = current.processID }
            yield(current, kind: .appFrontmost)
        }
        return stream
    }

    public func stop() async {
        source.stop()
        finishStream()
    }

    /// An activation of Tells or of the same app as before gives no sample.
    /// An activation of Tells does not change the last app, so Safari, Tells, Safari is no switch.
    func handle(_ activation: AppActivation) {
        guard !activation.isTells else { return }
        let changed = lastProcessID.withLock { last -> Bool in
            defer { last = activation.processID }
            return last != activation.processID
        }
        guard changed else { return }
        yield(activation, kind: .appActivated)
    }

    private func yield(_ activation: AppActivation, kind: SampleKind) {
        let category = AppCategoryMap.category(for: activation.categoryType)
        let sample = SensorSample(sensor: .appswitch, time: now(), kind: kind, value: Double(category.rawValue))
        _ = continuation.withLock { $0?.yield(sample) }
    }

    private func finishStream() {
        let old = continuation.withLock { current -> AsyncStream<SensorSample>.Continuation? in
            defer { current = nil }
            return current
        }
        old?.finish()
    }
}
