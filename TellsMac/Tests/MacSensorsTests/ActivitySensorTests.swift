import Foundation
import Synchronization
import Testing
import TellsCore
@testable import MacSensors

private final class FakeActivitySource: ActivitySource {
    let stops = Mutex(0)
    func start(handler: @escaping @Sendable (ActivityEvent) -> Void) {}
    func stop() { stops.withLock { $0 += 1 } }
}

private func makeActivitySensor(source: FakeActivitySource = FakeActivitySource()) -> ActivitySensor {
    ActivitySensor(source: source, now: { Date(timeIntervalSince1970: 100) })
}

struct ActivitySensorTests {
    @Test func declaresItself() async {
        let sensor = makeActivitySensor()
        #expect(sensor.id == .activity)
        #expect(sensor.permission == nil)
        #expect(!sensor.usesPrivateAPI)
        #expect(await sensor.availability() == .available)
    }

    @Test func yieldsProbeSleepAndWakeAndPausesProbesWhileAsleep() async throws {
        let sensor = makeActivitySensor()
        let stream = try sensor.start()
        sensor.handle(.probe(secondsSinceInput: 2.5))
        sensor.handle(.sleep)
        sensor.handle(.probe(secondsSinceInput: 9))   // dropped: the Mac sleeps
        sensor.handle(.wake)
        sensor.handle(.probe(secondsSinceInput: 700))
        await sensor.stop()
        var samples: [SensorSample] = []
        for await sample in stream { samples.append(sample) }
        #expect(samples.map(\.kind) == [.inputProbe, .systemSleep, .systemWake, .inputProbe])
        #expect(samples.map(\.value) == [2.5, 0, 0, 700])
        #expect(samples.allSatisfy { $0.sensor == .activity })
    }

    @Test func stopFinishesTheStreamAndIsSafeTwice() async throws {
        let source = FakeActivitySource()
        let sensor = makeActivitySensor(source: source)
        let stream = try sensor.start()
        await sensor.stop()
        await sensor.stop()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
        sensor.handle(.probe(secondsSinceInput: 1))   // after stop: no crash, no sample
    }
}
