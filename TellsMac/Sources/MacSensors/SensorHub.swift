import AppKit
import Foundation
import TellsCore

/// Why the sensors are stopped. The sensors run only while no reason is active (SPEC.md 1.4).
// DEFAULT: D-069
enum StopReason: Hashable, Sendable {
    case sleep, lid, display, session, pause, quit
}

/// Starts and stops all sensors and the `WindowClock`. It puts each sample in the `RawEventBuffer`.
public actor SensorHub {
    private enum Event: Sendable {
        case stop(StopReason)
        case resume(StopReason)
    }

    private let sensors: [any Sensor]
    private let buffer: RawEventBuffer
    private let clock: WindowClock
    private let workspaceCenter: NotificationCenter
    private let appCenter: NotificationCenter
    private let clamshell: (any ClamshellSource)?
    private let now: @Sendable () -> Date

    private var reasons: Set<StopReason> = []
    private var isRunning = false
    private var startedIDs: Set<SensorID> = []
    private var readers: [Task<Void, Never>] = []
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var eventTask: Task<Void, Never>?
    private var eventsHandled = 0
    private var eventContinuation: AsyncStream<Event>.Continuation?

    public init(sensors: [any Sensor], buffer: RawEventBuffer, clock: WindowClock) {
        self.init(sensors: sensors, buffer: buffer, clock: clock,
                  workspaceCenter: NSWorkspace.shared.notificationCenter, appCenter: .default,
                  clamshell: SystemClamshellSource(), now: { Date() })
    }

    init(sensors: [any Sensor], buffer: RawEventBuffer, clock: WindowClock,
         workspaceCenter: NotificationCenter, appCenter: NotificationCenter,
         clamshell: (any ClamshellSource)?, now: @escaping @Sendable () -> Date) {
        self.sensors = sensors
        self.buffer = buffer
        self.clock = clock
        self.workspaceCenter = workspaceCenter
        self.appCenter = appCenter
        self.clamshell = clamshell
        self.now = now
    }

    /// Listens for the stop events and starts the sensors.
    public func run() async {
        guard eventTask == nil else { return }
        let (events, continuation) = AsyncStream<Event>.makeStream()
        eventContinuation = continuation
        observe(into: continuation)
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        await startSensors()
    }

    /// The user pause (D-041).
    public func setPaused(_ paused: Bool) {
        eventContinuation?.yield(paused ? .stop(.pause) : .resume(.pause))
    }

    /// D-026: the keyboard sensor drops all key events while this is true.
    public func setKeyboardSuppressed(_ value: Bool) {
        for case let keyboard as KeyboardTimingSensor in sensors { keyboard.setSuppressed(value) }
    }

    /// Stops everything and removes the listeners.
    public func shutdown() async {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        clamshell?.stop()
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        await stopSensors()
    }

    var running: Bool { isRunning }
    var handledEventCount: Int { eventsHandled }

    private func handle(_ event: Event) async {
        switch event {
        case .stop(let reason): reasons.insert(reason)
        case .resume(let reason): reasons.remove(reason)
        }
        if reasons.isEmpty { await startSensors() } else { await stopSensors() }
        eventsHandled += 1
    }

    private func startSensors() async {
        guard !isRunning, reasons.isEmpty else { return }
        isRunning = true
        let startTime = now()
        for sensor in sensors { _ = startOne(sensor) }
        await clock.start(sensors: startedIDs, at: startTime)
    }

    /// Starts the sensor and reads its stream into the buffer. A sensor that cannot start is skipped.
    private func startOne(_ sensor: any Sensor) -> Bool {
        guard let stream = try? sensor.start() else { return false }
        startedIDs.insert(sensor.id)
        let buffer = buffer
        readers.append(Task {
            for await sample in stream { await buffer.append(sample) }
        })
        return true
    }

    /// Starts the sensors that could not start before, for example after the user grants a permission.
    /// The app calls it when a permission may have changed. It does nothing while the hub is stopped.
    // DEFAULT: D-080
    public func retryUnstarted() async {
        guard isRunning else { return }
        var added: Set<SensorID> = []
        for sensor in sensors where !startedIDs.contains(sensor.id) {
            guard await sensor.availability() == .available, isRunning, !startedIDs.contains(sensor.id) else { continue }
            if startOne(sensor) { added.insert(sensor.id) }
        }
        if !added.isEmpty { await clock.add(sensors: added, at: now()) }
    }

    private func stopSensors() async {
        guard isRunning else { return }
        isRunning = false
        startedIDs = []
        for sensor in sensors { await sensor.stop() }
        for reader in readers { await reader.value }   // each stream is finished, so this drains it
        readers = []
        await clock.stop(at: now())
    }

    private func observe(into continuation: AsyncStream<Event>.Continuation) {
        let pairs: [(NotificationCenter, Notification.Name, Event)] = [
            (workspaceCenter, NSWorkspace.willSleepNotification, .stop(.sleep)),
            (workspaceCenter, NSWorkspace.didWakeNotification, .resume(.sleep)),
            (workspaceCenter, NSWorkspace.screensDidSleepNotification, .stop(.display)),
            (workspaceCenter, NSWorkspace.screensDidWakeNotification, .resume(.display)),
            (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, .stop(.session)),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, .resume(.session)),
            (appCenter, NSApplication.willTerminateNotification, .stop(.quit)),
        ]
        for (center, name, event) in pairs {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield(event) }
            observers.append((center, token))
        }
        clamshell?.start { closed in continuation.yield(closed ? .stop(.lid) : .resume(.lid)) }
    }
}
