import Foundation
import Synchronization
import TellsCore

/// Seconds since the last input, each 1 s, and system sleep and wake.
/// Hardware: keyboard, mouse and trackpad as one input clock. API: public (`CGEventSource`, `NSWorkspace`).
/// It reads no key code and no text (hard rules 2 and 3). It needs no permission.
public final class ActivitySensor: Sensor {
    public let id: SensorID = .activity
    public let permission: PermissionKind? = nil
    public let usesPrivateAPI = false

    private let source: any ActivitySource
    private let now: @Sendable () -> Date
    private let continuation = Mutex<AsyncStream<SensorSample>.Continuation?>(nil)
    private let asleep = Mutex(false)

    public convenience init() {
        self.init(source: SystemActivitySource(), now: { Date() })
    }

    // DEFAULT: D-064
    init(source: any ActivitySource, now: @escaping @Sendable () -> Date) {
        self.source = source
        self.now = now
    }

    public func availability() async -> SensorAvailability { .available }

    public func start() throws -> AsyncStream<SensorSample> {
        finishStream()
        asleep.withLock { $0 = false }
        let (stream, newContinuation) = AsyncStream<SensorSample>.makeStream(bufferingPolicy: .unbounded)
        continuation.withLock { $0 = newContinuation }
        source.start { [weak self] event in self?.handle(event) }
        return stream
    }

    public func stop() async {
        source.stop()
        finishStream()
    }

    /// Runs on the probe queue or the notification thread. It stamps the time and yields one sample.
    /// No probe is sent while the Mac sleeps (PLAN.md Section 4.2, step 4).
    func handle(_ event: ActivityEvent) {
        let sample: SensorSample
        switch event {
        case .probe(let seconds):
            guard !asleep.withLock({ $0 }) else { return }
            sample = SensorSample(sensor: .activity, time: now(), kind: .inputProbe, value: seconds)
        case .sleep:
            asleep.withLock { $0 = true }
            sample = SensorSample(sensor: .activity, time: now(), kind: .systemSleep)
        case .wake:
            asleep.withLock { $0 = false }
            sample = SensorSample(sensor: .activity, time: now(), kind: .systemWake)
        }
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
