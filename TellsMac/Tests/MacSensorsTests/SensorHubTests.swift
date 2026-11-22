import AppKit
import Foundation
import Synchronization
import Testing
import TellsCore
@testable import MacSensors

private final class FakeSensor: Sensor {
    let id: SensorID
    let permission: PermissionKind? = nil
    let usesPrivateAPI = false
    private let continuation = Mutex<AsyncStream<SensorSample>.Continuation?>(nil)
    private let starts = Mutex(0)
    private let canStart: Bool

    init(_ id: SensorID, canStart: Bool = true) {
        self.id = id
        self.canStart = canStart
    }

    var startCount: Int { starts.withLock { $0 } }
    var isRunning: Bool { continuation.withLock { $0 != nil } }

    func availability() async -> SensorAvailability { .available }

    func start() throws -> AsyncStream<SensorSample> {
        guard canStart else { throw SensorError.notAvailable(.notOnThisMac) }
        starts.withLock { $0 += 1 }
        let (stream, new) = AsyncStream<SensorSample>.makeStream()
        continuation.withLock { $0 = new }
        return stream
    }

    func stop() async {
        let old = continuation.withLock { current -> AsyncStream<SensorSample>.Continuation? in
            defer { current = nil }
            return current
        }
        old?.finish()
    }

    func emit(_ sample: SensorSample) { _ = continuation.withLock { $0?.yield(sample) } }
}

private final class FakeClamshell: ClamshellSource {
    let handler = Mutex<(@Sendable (Bool) -> Void)?>(nil)
    func start(handler: @escaping @Sendable (Bool) -> Void) { self.handler.withLock { $0 = handler } }
    func stop() {}
    func send(closed: Bool) { handler.withLock { $0 }?(closed) }
}

private final class FakePermissions: PermissionChecking {
    func status(of kind: PermissionKind) -> PermissionStatus { .granted }
    func request(_ kind: PermissionKind) {}
}

private final class FakeKeySource: KeyEventSource {
    func start(handler: @escaping @Sendable (KeyEvent) -> Void) -> Bool { true }
    func stop() {}
}

private struct Rig {
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    let clamshell = FakeClamshell()
    let buffer = RawEventBuffer()
    let store = InMemoryFeatureStore()
    let clock: WindowClock
    let hub: SensorHub
    let sensors: [FakeSensor]

    init(sensors: [FakeSensor], extra: [any Sensor] = []) {
        self.sensors = sensors
        clock = WindowClock(buffer: buffer, extractors: [KeyboardExtractor(), ActivityExtractor(), AppSwitchExtractor()],
                            store: store, sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) })
        hub = SensorHub(sensors: sensors + extra, buffer: buffer, clock: clock, workspaceCenter: workspace,
                        appCenter: app, clamshell: clamshell, now: { Date() })
    }

    /// Waits until the hub has handled `count` events.
    func waitForEvents(_ count: Int) async {
        for _ in 0..<2000 {
            if await hub.handledEventCount >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

struct SensorHubTests {
    @Test func startsAllSensorsAndSkipsOneThatCannotStart() async {
        let good = FakeSensor(.keyboard), bad = FakeSensor(.activity, canStart: false)
        let rig = Rig(sensors: [good, bad])
        await rig.hub.run()
        #expect(good.isRunning)
        #expect(!bad.isRunning)
        await rig.hub.shutdown()
        #expect(!good.isRunning)
    }

    @Test func storesSamplesFromTheStreams() async {
        let sensor = FakeSensor(.keyboard)
        let rig = Rig(sensors: [sensor])
        await rig.hub.run()
        sensor.emit(SensorSample(sensor: .keyboard, time: Date(), kind: .keyDown))
        for _ in 0..<400 where await rig.buffer.count(for: .keyboard) == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await rig.buffer.count(for: .keyboard) == 1)
        await rig.hub.shutdown()
    }

    @Test func eachStopEventStopsSensorsAndTheEndEventStartsThem() async {
        let events: [(center: KeyPath<Rig, NotificationCenter>, stop: Notification.Name, start: Notification.Name)] = [
            (\.workspace, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (\.workspace, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (\.workspace, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for event in events {
            let sensor = FakeSensor(.keyboard)
            let rig = Rig(sensors: [sensor])
            await rig.hub.run()
            rig[keyPath: event.center].post(name: event.stop, object: nil)
            await rig.waitForEvents(1)
            #expect(!sensor.isRunning, "\(event.stop.rawValue)")
            #expect(await !rig.clock.isRunning)
            rig[keyPath: event.center].post(name: event.start, object: nil)
            await rig.waitForEvents(2)
            #expect(sensor.isRunning, "\(event.start.rawValue)")
            #expect(sensor.startCount == 2)
            await rig.hub.shutdown()
        }
    }

    @Test func lidAndPauseStopAndStartAgain() async {
        let sensor = FakeSensor(.keyboard)
        let rig = Rig(sensors: [sensor])
        await rig.hub.run()
        rig.clamshell.send(closed: true)
        await rig.waitForEvents(1)
        #expect(!sensor.isRunning)
        rig.clamshell.send(closed: false)
        await rig.waitForEvents(2)
        #expect(sensor.isRunning)
        await rig.hub.setPaused(true)
        await rig.waitForEvents(3)
        #expect(!sensor.isRunning)
        await rig.hub.setPaused(false)
        await rig.waitForEvents(4)
        #expect(sensor.isRunning)
        await rig.hub.shutdown()
    }

    @Test func sensorsStayStoppedUntilEveryReasonEnds() async {
        let sensor = FakeSensor(.keyboard)
        let rig = Rig(sensors: [sensor])
        await rig.hub.run()
        rig.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        rig.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        rig.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await rig.waitForEvents(3)
        #expect(!sensor.isRunning)
        rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await rig.waitForEvents(4)
        #expect(sensor.isRunning)
        await rig.hub.shutdown()
    }

    @Test func quitStopsAndDoesNotStartAgain() async {
        let sensor = FakeSensor(.keyboard)
        let rig = Rig(sensors: [sensor])
        await rig.hub.run()
        rig.app.post(name: NSApplication.willTerminateNotification, object: nil)
        await rig.waitForEvents(1)
        #expect(!sensor.isRunning)
        #expect(sensor.startCount == 1)
        await rig.hub.shutdown()
    }

    @Test func stopClosesThePartialWindowFromSamplesAlreadySent() async throws {
        let sensor = FakeSensor(.keyboard)
        let rig = Rig(sensors: [sensor])
        await rig.hub.run()
        sensor.emit(SensorSample(sensor: .keyboard, time: Date(), kind: .keyDown))
        rig.clamshell.send(closed: true)
        await rig.waitForEvents(1)
        #expect(await rig.buffer.count(for: .keyboard) == 0)   // raw samples are gone at stop
        await rig.hub.shutdown()
    }

    @Test func suppressInputGoesToTheKeyboardSensor() async throws {
        let keyboard = KeyboardTimingSensor(permissions: FakePermissions(), hasKeyboard: { true },
                                            source: FakeKeySource(), now: { Date(timeIntervalSince1970: 100) })
        let rig = Rig(sensors: [], extra: [keyboard])
        let stream = try keyboard.start()
        await rig.hub.setKeyboardSuppressed(true)
        keyboard.handle(KeyEvent(isDown: true, isAutorepeat: false))
        await rig.hub.setKeyboardSuppressed(false)
        keyboard.handle(KeyEvent(isDown: false, isAutorepeat: false))
        await keyboard.stop()
        var kinds: [SampleKind] = []
        for await sample in stream { kinds.append(sample.kind) }
        #expect(kinds == [.keyUp])
    }
}
