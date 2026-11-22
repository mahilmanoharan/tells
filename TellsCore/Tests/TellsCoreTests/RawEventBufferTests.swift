import Foundation
import Testing
@testable import TellsCore

struct RawEventBufferTests {
    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    private func key(_ seconds: Double) -> SensorSample {
        SensorSample(sensor: .keyboard, time: t0.addingTimeInterval(seconds), kind: .keyDown)
    }

    @Test func keepsOnly20000SamplesForEachSensorAndWritesOverTheOldest() async {
        let buffer = RawEventBuffer()
        for index in 0..<20_005 { await buffer.append(key(Double(index))) }
        await buffer.append(SensorSample(sensor: .activity, time: t0, kind: .inputProbe))
        #expect(await buffer.count(for: .keyboard) == 20_000)
        #expect(await buffer.count(for: .activity) == 1)
        let all = await buffer.samples(for: .keyboard, in: DateInterval(start: t0, end: t0.addingTimeInterval(100_000)))
        #expect(all.first?.time == t0.addingTimeInterval(5))
        #expect(all.last?.time == t0.addingTimeInterval(20_004))
    }

    @Test func samplesComeBackInTimeOrderInsideTheWindowOnly() async {
        let buffer = RawEventBuffer(capacity: 4)
        for seconds in [30.0, 10, 400, 20] { await buffer.append(key(seconds)) }
        let got = await buffer.samples(for: .keyboard, in: DateInterval(start: t0, duration: 300))
        #expect(got.map { $0.time.timeIntervalSince(t0) } == [10, 20, 30])
    }

    @Test func removeBeforeKeepsLaterSamples() async {
        let buffer = RawEventBuffer(capacity: 4)
        for seconds in [10.0, 20, 400] { await buffer.append(key(seconds)) }
        await buffer.removeSamples(for: .keyboard, before: t0.addingTimeInterval(300))
        #expect(await buffer.count(for: .keyboard) == 1)
        await buffer.removeAll()
        #expect(await buffer.count(for: .keyboard) == 0)
    }
}
