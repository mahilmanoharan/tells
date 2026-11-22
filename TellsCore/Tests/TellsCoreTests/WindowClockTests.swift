import Foundation
import Synchronization
import Testing
@testable import TellsCore

struct WindowClockTests {
    private static let boundary = Date(timeIntervalSince1970: 1_795_000_200)   // multiple of 300
    private var t0: Date { Self.boundary }

    private struct Rig {
        let buffer = RawEventBuffer()
        let store = InMemoryFeatureStore()
        let clock: WindowClock
        init(sleepUntil: @escaping @Sendable (Date) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            clock = WindowClock(buffer: buffer,
                                extractors: [KeyboardExtractor(), ActivityExtractor(), AppSwitchExtractor()],
                                store: store, calendar: calendar, sleepUntil: sleepUntil)
        }

        func rows(_ sensor: SensorID? = nil) async throws -> [FeatureRow] {
            try await store.featureRows(sensor, in: DateInterval(start: .distantPast, end: .distantFuture))
        }
    }

    private func sample(_ sensor: SensorID, _ kind: SampleKind, at seconds: Double, value: Double = 0) -> SensorSample {
        SensorSample(sensor: sensor, time: t0.addingTimeInterval(seconds), kind: kind, value: value)
    }

    @Test func fullWindowGivesOneRowForEachRunningSensor() async throws {
        let rig = Rig()
        await rig.clock.start(sensors: [.keyboard, .activity], at: t0)
        await rig.buffer.append(sample(.keyboard, .keyDown, at: 10))
        await rig.clock.closeWindow(at: t0.addingTimeInterval(300))
        let rows = try await rig.rows()
        #expect(Set(rows.map(\.sensor)) == [.keyboard, .activity])
        #expect(rows.allSatisfy { $0.coverageSeconds == 300 && $0.windowStart == t0 && $0.day == TellsDay(yyyymmdd: 20261118) })
        await rig.clock.stop(at: t0.addingTimeInterval(300))
    }

    // DEFAULT: D-080
    @Test func lateSensorCoversOnlyTheTimeSinceItStarted() async throws {
        let rig = Rig()
        await rig.clock.start(sensors: [.activity], at: t0)
        await rig.clock.add(sensors: [.keyboard], at: t0.addingTimeInterval(240))
        await rig.clock.closeWindow(at: t0.addingTimeInterval(300))
        let late = try await rig.rows(.keyboard)
        #expect(late.count == 1)
        #expect(late.first?.coverageSeconds == 60)
        #expect(late.first?.windowStart == t0.addingTimeInterval(240))
        #expect(try await rig.rows(.activity).first?.coverageSeconds == 300)
        await rig.clock.stop(at: t0.addingTimeInterval(300))
    }

    @Test func sensorThatStartsUnder60SecondsBeforeTheCloseGivesNoRow() async throws {
        let rig = Rig()
        await rig.clock.start(sensors: [.activity], at: t0)
        await rig.clock.add(sensors: [.keyboard], at: t0.addingTimeInterval(270))
        await rig.clock.closeWindow(at: t0.addingTimeInterval(300))
        #expect(try await rig.rows(.keyboard).isEmpty)
        #expect(try await rig.rows(.activity).count == 1)
        await rig.clock.closeWindow(at: t0.addingTimeInterval(600))
        #expect(try await rig.rows(.keyboard).last?.coverageSeconds == 300)   // entry cleared after the close
        await rig.clock.stop(at: t0.addingTimeInterval(600))
    }

    @Test func windowUnder60SecondsOfCoverageGivesNoRow() async throws {
        let short = Rig()
        await short.clock.start(sensors: [.keyboard], at: t0)
        await short.buffer.append(sample(.keyboard, .keyDown, at: 5))
        await short.clock.stop(at: t0.addingTimeInterval(59.9))
        #expect(try await short.rows().isEmpty)

        let enough = Rig()
        await enough.clock.start(sensors: [.keyboard], at: t0)
        await enough.clock.stop(at: t0.addingTimeInterval(60))
        let rows = try await enough.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.coverageSeconds == 60)
    }

    @Test func closedWindowSamplesAreGoneFromTheBuffer() async throws {
        let rig = Rig()
        await rig.clock.start(sensors: [.keyboard], at: t0)
        await rig.buffer.append(sample(.keyboard, .keyDown, at: 10))
        await rig.buffer.append(sample(.keyboard, .keyUp, at: 20))
        await rig.buffer.append(sample(.keyboard, .keyDown, at: 310))      // next window
        await rig.clock.closeWindow(at: t0.addingTimeInterval(300))
        #expect(await rig.buffer.count(for: .keyboard) == 1)
        let left = await rig.buffer.samples(for: .keyboard, in: DateInterval(start: t0, duration: 1000))
        #expect(left.map(\.time) == [t0.addingTimeInterval(310)])
        await rig.clock.stop(at: t0.addingTimeInterval(400))
    }

    @Test func nextWindowStartsWithTheLastAppCategoryAndStopClearsIt() async throws {
        let rig = Rig()
        let window = DateInterval(start: t0, duration: 1000)
        await rig.clock.start(sensors: [.appswitch], at: t0)
        await rig.buffer.append(sample(.appswitch, .appFrontmost, at: 0, value: 1))
        await rig.buffer.append(sample(.appswitch, .appActivated, at: 100, value: 2))
        await rig.clock.closeWindow(at: t0.addingTimeInterval(300))
        let seed = await rig.buffer.samples(for: .appswitch, in: window)
        #expect(seed == [sample(.appswitch, .appFrontmost, at: 300, value: 2)])

        // A window with no new sample keeps the category.
        await rig.clock.closeWindow(at: t0.addingTimeInterval(600))
        let carried = await rig.buffer.samples(for: .appswitch, in: window)
        #expect(carried == [sample(.appswitch, .appFrontmost, at: 600, value: 2)])

        await rig.clock.stop(at: t0.addingTimeInterval(700))
        await rig.clock.start(sensors: [.appswitch], at: t0.addingTimeInterval(800))
        await rig.clock.closeWindow(at: t0.addingTimeInterval(900))
        #expect(await rig.buffer.count(for: .appswitch) == 0)
        await rig.clock.stop(at: t0.addingTimeInterval(900))
    }

    @Test func loopClosesWindowsOnFiveMinuteBoundaries() async throws {
        let calls = Mutex<[Date]>([])
        let rig = Rig(sleepUntil: { date in
            let count = calls.withLock { $0.append(date); return $0.count }
            if count > 2 { throw CancellationError() }
        })
        await rig.clock.start(sensors: [.keyboard], at: t0.addingTimeInterval(130))
        await rig.clock.waitForLoop()
        #expect(calls.withLock { $0 } == [t0.addingTimeInterval(300), t0.addingTimeInterval(600), t0.addingTimeInterval(900)])
        let rows = try await rig.rows()
        #expect(rows.map(\.coverageSeconds) == [170, 300])
    }

    @Test func stopDuringACloseWaitsForTheCloseAndLeavesNoSecondRowOrCarrySample() async throws {
        let store = GatedStore()
        let buffer = RawEventBuffer()
        let calls = Mutex(0)
        let clock = WindowClock(buffer: buffer, extractors: [KeyboardExtractor(), AppSwitchExtractor()], store: store,
                                sleepUntil: { _ in
            if calls.withLock({ $0 += 1; return $0 }) > 1 { try await Task.sleep(for: .seconds(3600)) }
        })
        await clock.start(sensors: [.keyboard, .appswitch], at: t0)
        await buffer.append(sample(.appswitch, .appActivated, at: 10, value: 2))
        for _ in 0..<2000 where !store.entered { try await Task.sleep(for: .milliseconds(2)) }
        #expect(store.entered)                      // the loop is closing the window and waits in save
        let stopping = Task { await clock.stop(at: t0.addingTimeInterval(400)) }
        try await Task.sleep(for: .milliseconds(20))
        store.release()
        await stopping.value
        let rows = try await store.inner.featureRows(nil, in: DateInterval(start: .distantPast, end: .distantFuture))
        #expect(rows.filter { $0.windowStart == t0 }.count == 2)   // one for each running sensor, no repeat
        #expect(!(await clock.isRunning))
        #expect(await buffer.count(for: .appswitch) == 0)
    }
}

private final class GatedStore: FeatureStore {
    let inner = InMemoryFeatureStore()
    private let state = Mutex<(entered: Bool, first: Bool, waiter: CheckedContinuation<Void, Never>?, released: Bool)>(
        (false, true, nil, false))
    var entered: Bool { state.withLock { $0.entered } }

    func release() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.released = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }

    func save(_ row: FeatureRow) async throws {
        let blocks = state.withLock { s -> Bool in
            defer { s.first = false }
            if s.first { s.entered = true }
            return s.first
        }
        if blocks {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { s -> Bool in
                    if s.released { return true }
                    s.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        try await inner.save(row)
    }

    func save(_ row: DailyRow) async throws { try await inner.save(row) }
    func save(_ summary: DailySummary) async throws { try await inner.save(summary) }
    func save(_ checkIn: CheckIn) async throws { try await inner.save(checkIn) }
    func deleteExpired(today: TellsDay) async throws { try await inner.deleteExpired(today: today) }
    func deleteAll() async throws { try await inner.deleteAll() }
    func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow] {
        try await inner.featureRows(sensor, in: interval)
    }
    func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow] { try await inner.dailyRows(days) }
    func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary] { try await inner.dailySummaries(days) }
    func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn] { try await inner.checkIns(days) }
}
