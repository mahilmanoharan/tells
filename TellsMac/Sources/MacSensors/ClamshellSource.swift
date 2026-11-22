import Foundation
import IOKit
import Synchronization

/// Reports lid closed or open (D-045). It reads the public `AppleClamshellState` property of `IOPMrootDomain`.
protocol ClamshellSource: Sendable {
    /// `handler(true)` when the lid closes, `handler(false)` when it opens.
    func start(handler: @escaping @Sendable (Bool) -> Void)
    func stop()
}

// DEFAULT: D-070
final class SystemClamshellSource: ClamshellSource {
    private final class Context: @unchecked Sendable {
        let handler: @Sendable (Bool) -> Void
        let lastClosed = Mutex<Bool?>(nil)
        init(handler: @escaping @Sendable (Bool) -> Void) { self.handler = handler }
    }

    private struct Running: @unchecked Sendable {
        let port: IONotificationPortRef
        let notifier: io_object_t
        let service: io_service_t
        let context: Unmanaged<Context>
    }

    private let running = Mutex<Running?>(nil)

    func start(handler: @escaping @Sendable (Bool) -> Void) {
        stop()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue(label: "tells.clamshell"))
        let context = Unmanaged.passRetained(Context(handler: handler))
        var notifier: io_object_t = 0
        let callback: IOServiceInterestCallback = { refcon, service, _, _ in
            guard let refcon else { return }
            let context = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()
            let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
            guard let closed = value?.takeRetainedValue() as? Bool else { return }
            let changed = context.lastClosed.withLock { last -> Bool in
                defer { last = closed }
                return last != closed
            }
            if changed { context.handler(closed) }
        }
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, callback,
                                                      context.toOpaque(), &notifier)
        guard result == KERN_SUCCESS else {
            context.release()
            IONotificationPortDestroy(port)
            IOObjectRelease(service)
            return
        }
        running.withLock { $0 = Running(port: port, notifier: notifier, service: service, context: context) }
    }

    func stop() {
        let old = running.withLock { current -> Running? in
            defer { current = nil }
            return current
        }
        guard let old else { return }
        IOObjectRelease(old.notifier)
        IOObjectRelease(old.service)
        IONotificationPortDestroy(old.port)
        old.context.release()
    }
}
