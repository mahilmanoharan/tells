import Foundation
import Synchronization
import TellsCore

/// Times of key down and key up. It does not know which key (hard rule 2).
/// Hardware: the keyboard, through a public listen-only `CGEvent` tap. Permission: Input Monitoring.
public final class KeyboardTimingSensor: Sensor {
    public let id: SensorID = .keyboard
    public let permission: PermissionKind? = .inputMonitoring
    public let usesPrivateAPI = false

    private let permissions: any PermissionChecking
    private let hasKeyboard: @Sendable () -> Bool
    private let source: any KeyEventSource
    private let now: @Sendable () -> Date
    private let continuation = Mutex<AsyncStream<SensorSample>.Continuation?>(nil)
    private let suppressed = Mutex(false)

    public convenience init(permissions: any PermissionChecking = SystemPermissions()) {
        self.init(permissions: permissions, hasKeyboard: { true }, source: SystemKeyEventSource(), now: { Date() })
    }

    // DEFAULT: D-060
    init(permissions: any PermissionChecking, hasKeyboard: @escaping @Sendable () -> Bool,
         source: any KeyEventSource, now: @escaping @Sendable () -> Date) {
        self.permissions = permissions
        self.hasKeyboard = hasKeyboard
        self.source = source
        self.now = now
    }

    /// While true, the sensor drops all key events (D-026). The app sets it when the insights window is key.
    public func setSuppressed(_ value: Bool) {
        suppressed.withLock { $0 = value }
    }

    public func availability() async -> SensorAvailability { currentAvailability() }

    public func start() throws -> AsyncStream<SensorSample> {
        let state = currentAvailability()
        guard state == .available else { throw SensorError.notAvailable(state) }
        finishStream()
        let (stream, newContinuation) = AsyncStream<SensorSample>.makeStream(bufferingPolicy: .unbounded)
        continuation.withLock { $0 = newContinuation }
        let started = source.start { [weak self] event in self?.handle(event) }
        guard started else {
            finishStream()
            throw SensorError.notAvailable(.permissionDenied(.inputMonitoring))
        }
        return stream
    }

    public func stop() async {
        source.stop()
        finishStream()
    }

    /// Runs on the tap thread. It stamps the time and yields one sample (check 5).
    func handle(_ event: KeyEvent) {
        guard !suppressed.withLock({ $0 }), !event.isAutorepeat else { return }
        let sample = SensorSample(sensor: .keyboard, time: now(), kind: event.isDown ? .keyDown : .keyUp)
        _ = continuation.withLock { $0?.yield(sample) }
    }

    private func currentAvailability() -> SensorAvailability {
        guard hasKeyboard() else { return .notOnThisMac }
        switch permissions.status(of: .inputMonitoring) {
        case .granted: return .available
        case .denied: return .permissionDenied(.inputMonitoring)
        case .notAsked: return .permissionNotAsked(.inputMonitoring)
        }
    }

    private func finishStream() {
        let old = continuation.withLock { current -> AsyncStream<SensorSample>.Continuation? in
            defer { current = nil }
            return current
        }
        old?.finish()
    }
}
