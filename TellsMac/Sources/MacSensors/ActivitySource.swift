import AppKit
import CoreGraphics
import Foundation
import Synchronization

/// What the activity source reports. Only times and one number (hard rules 2 and 3).
enum ActivityEvent: Sendable, Equatable {
    case probe(secondsSinceInput: Double)
    case sleep
    case wake
}

protocol ActivitySource: Sendable {
    func start(handler: @escaping @Sendable (ActivityEvent) -> Void)
    func stop()
}

/// Public APIs only: `CGEventSource.secondsSinceLastEventType`, polled each 1 s (D-034),
/// and the `NSWorkspace` sleep and wake notifications. It needs no permission.
/// The timer is parked while the Mac sleeps and set again on wake (check 8).
final class SystemActivitySource: ActivitySource {
    static let probeInterval = 1.0
    static let timerLeeway = DispatchTimeInterval.milliseconds(100)

    private struct Running: @unchecked Sendable {
        let timer: DispatchSourceTimer
        let observers: [any NSObjectProtocol]
    }

    private let running = Mutex<Running?>(nil)
    private let queue = DispatchQueue(label: "tells.activity.probe")

    func start(handler: @escaping @Sendable (ActivityEvent) -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let arm: @Sendable () -> Void = {
            timer.schedule(deadline: .now() + Self.probeInterval, repeating: Self.probeInterval, leeway: Self.timerLeeway)
        }
        arm()
        timer.setEventHandler {
            handler(.probe(secondsSinceInput: Self.secondsSinceAnyInput()))
        }
        timer.resume()
        let center = NSWorkspace.shared.notificationCenter
        let observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [queue] _ in
                queue.async { timer.schedule(deadline: .distantFuture, repeating: .never) }   // no timer fires while asleep
                handler(.sleep)
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [queue] _ in
                handler(.wake)
                queue.async { arm() }
            },
        ]
        running.withLock { $0 = Running(timer: timer, observers: observers) }
    }

    func stop() {
        let old = running.withLock { current -> Running? in
            defer { current = nil }
            return current
        }
        guard let old else { return }
        old.timer.cancel()
        for observer in old.observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Any input event type: `kCGAnyInputEventType` is `~0`.
    private static func secondsSinceAnyInput() -> Double {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
