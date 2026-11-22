import Foundation
import Synchronization
import Testing
import TellsCore
@testable import MacSensors

private struct FakePermissions: PermissionChecking {
    let state: PermissionStatus
    func status(of kind: PermissionKind) -> PermissionStatus { state }
    func request(_ kind: PermissionKind) {}
}

private final class FakeSource: KeyEventSource {
    let accept: Bool
    let stops = Mutex(0)
    init(accept: Bool = true) { self.accept = accept }
    func start(handler: @escaping @Sendable (KeyEvent) -> Void) -> Bool { accept }
    func stop() { stops.withLock { $0 += 1 } }
}

private func makeSensor(_ state: PermissionStatus = .granted, keyboard: Bool = true,
                        source: FakeSource = FakeSource()) -> KeyboardTimingSensor {
    KeyboardTimingSensor(permissions: FakePermissions(state: state), hasKeyboard: { keyboard },
                         source: source, now: { Date(timeIntervalSince1970: 100) })
}

struct KeyboardTimingSensorTests {
    @Test func declaresItself() {
        let sensor = makeSensor()
        #expect(sensor.id == .keyboard)
        #expect(sensor.permission == .inputMonitoring)
        #expect(!sensor.usesPrivateAPI)
    }

    @Test func availabilityFollowsPermissionAndHardware() async {
        #expect(await makeSensor(.granted).availability() == .available)
        #expect(await makeSensor(.denied).availability() == .permissionDenied(.inputMonitoring))
        #expect(await makeSensor(.notAsked).availability() == .permissionNotAsked(.inputMonitoring))
        #expect(await makeSensor(.granted, keyboard: false).availability() == .notOnThisMac)
    }

    @Test func startThrowsWhenDeniedOrAbsent() {
        #expect(throws: SensorError.notAvailable(.permissionDenied(.inputMonitoring))) {
            try makeSensor(.denied).start()
        }
        #expect(throws: SensorError.notAvailable(.notOnThisMac)) {
            try makeSensor(.granted, keyboard: false).start()
        }
        #expect(throws: SensorError.notAvailable(.permissionDenied(.inputMonitoring))) {
            try makeSensor(.granted, source: FakeSource(accept: false)).start()
        }
    }

    @Test func yieldsOnlyKeyDownAndKeyUpAndDropsAutorepeat() async throws {
        let sensor = makeSensor()
        let stream = try sensor.start()
        sensor.handle(KeyEvent(isDown: true, isAutorepeat: false))
        sensor.handle(KeyEvent(isDown: true, isAutorepeat: true))
        sensor.handle(KeyEvent(isDown: false, isAutorepeat: false))
        await sensor.stop()
        var kinds: [SampleKind] = []
        for await sample in stream {
            #expect(sample.sensor == .keyboard)
            #expect(sample.value == 0)
            kinds.append(sample.kind)
        }
        #expect(kinds == [.keyDown, .keyUp])
    }

    @Test func suppressFlagDropsAllKeyEvents() async throws {
        let sensor = makeSensor()
        let stream = try sensor.start()
        sensor.setSuppressed(true)
        sensor.handle(KeyEvent(isDown: true, isAutorepeat: false))
        sensor.handle(KeyEvent(isDown: false, isAutorepeat: false))
        sensor.setSuppressed(false)
        sensor.handle(KeyEvent(isDown: true, isAutorepeat: false))
        await sensor.stop()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 1)
    }

    @Test func stopFinishesTheStreamAndIsSafeTwice() async throws {
        let source = FakeSource()
        let sensor = makeSensor(source: source)
        let stream = try sensor.start()
        await sensor.stop()
        await sensor.stop()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
        sensor.handle(KeyEvent(isDown: true, isAutorepeat: false)) // after stop: no crash, no sample
    }
}
