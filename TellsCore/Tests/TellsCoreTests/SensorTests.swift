import Foundation
import Testing
@testable import TellsCore

@Suite("Sensor")
struct SensorTests {
    @Test func permissionDeniedBlocksStart() async throws {
        let sensor = FakeSensor(id: .keyboard, permission: .inputMonitoring, permissionStatus: .denied)
        #expect(await sensor.availability() == .permissionDenied(.inputMonitoring))
        #expect(throws: SensorError.notAvailable(.permissionDenied(.inputMonitoring))) {
            try sensor.start()
        }
    }

    @Test func permissionNotAskedBlocksStart() async throws {
        let sensor = FakeSensor(id: .keyboard, permission: .inputMonitoring, permissionStatus: .notAsked)
        #expect(await sensor.availability() == .permissionNotAsked(.inputMonitoring))
        #expect(throws: SensorError.notAvailable(.permissionNotAsked(.inputMonitoring))) {
            try sensor.start()
        }
    }

    @Test func sensorNotOnThisMacBlocksStart() async throws {
        let sensor = FakeSensor(id: .light, permission: nil, hardwarePresent: false)
        #expect(await sensor.availability() == .notOnThisMac)
        #expect(throws: SensorError.notAvailable(.notOnThisMac)) { try sensor.start() }
    }

    @Test func flagKeyHasTheDocumentedForm() {
        #expect(SensorFlag.key(for: .crowd) == "flag.crowd")
        #expect(SensorFlag.key(for: .trackpad) == "flag.trackpad")
    }

    @Test func privateSensorIsDisabledUntilItsFlagIsOn() async throws {
        let suite = "tells.tests.flag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sensor = FakeSensor(id: .trackpad, permission: nil, usesPrivateAPI: true, defaultsSuite: suite)

        #expect(SensorFlag.isOn(.trackpad, in: defaults) == false)
        #expect(await sensor.availability() == .disabledByFlag)
        #expect(throws: SensorError.notAvailable(.disabledByFlag)) { try sensor.start() }

        defaults.set(true, forKey: "flag.trackpad")
        #expect(SensorFlag.isOn(.trackpad, in: defaults))
        #expect(await sensor.availability() == .available)
    }

    @Test func stopFinishesTheStreamAndIsSafeTwice() async throws {
        let sensor = FakeSensor(id: .activity, permission: nil)
        let stream = try sensor.start()
        #expect(sensor.isRunning)
        let first = SensorSample(sensor: .activity, time: Date(timeIntervalSince1970: 10), kind: .inputProbe, value: 2)
        let second = SensorSample(sensor: .activity, time: Date(timeIntervalSince1970: 11), kind: .inputProbe, value: 3)
        sensor.emit(first)
        sensor.emit(second)

        await sensor.stop()
        await sensor.stop()

        var received: [SensorSample] = []
        for await sample in stream { received.append(sample) }
        #expect(received == [first, second])
        #expect(sensor.isRunning == false)
    }
}

@Suite("SensorSample")
struct SensorSampleTests {
    @Test func hasNoStringPropertyAndNoKeyCode() {
        let sample = SensorSample(sensor: .keyboard, time: Date(timeIntervalSince1970: 0), kind: .keyDown)
        let children = Mirror(reflecting: sample).children
        #expect(children.map(\.label) == ["sensor", "time", "kind", "value"])
        for child in children {
            #expect(!(child.value is String), "Property \(child.label ?? "?") is a String")
            #expect(!(child.value is Substring))
            #expect(!(child.value is Character))
        }
        #expect(sample.value == 0)
    }
}
