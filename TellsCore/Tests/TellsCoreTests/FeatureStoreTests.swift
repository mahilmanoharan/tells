import Foundation
import Synchronization
import Testing
@testable import TellsCore

/// Both stores must give the same results (InMemoryFeatureStore is the reference).
enum StoreKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case inMemory, swiftData

    var testDescription: String { rawValue }

    func make() throws -> any FeatureStore {
        switch self {
        case .inMemory: InMemoryFeatureStore()
        case .swiftData: try SwiftDataFeatureStore.inMemory()
        }
    }
}

private let everything = DateInterval(start: .distantPast, end: .distantFuture)

@Suite("FeatureStore")
struct FeatureStoreTests {
    let today = TellsDay(yyyymmdd: 20261121)

    private func name(_ text: String) throws -> FeatureName { try #require(FeatureName(text)) }

    @Test(arguments: StoreKind.allCases)
    func savesAndReadsEachKind(_ kind: StoreKind) async throws {
        let store = try kind.make()
        let key = try name("keyboard.key_count")
        let featureRow = FeatureRow(sensor: .keyboard, schemaVersion: 3, windowStart: Date(timeIntervalSince1970: 1_795_000_200),
                                    utcOffsetMinutes: -300, day: today, coverageSeconds: 123.5, values: [key: 42.5])
        let dailyRow = DailyRow(day: today, schemaVersions: [.keyboard: 3, .activity: 1], values: [key: 7])
        let summary = DailySummary(day: today, values: [key: 9])
        let checkIn = CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 55), scores: [.energy: 4, .social: 2])

        try await store.save(featureRow)
        try await store.save(dailyRow)
        try await store.save(summary)
        try await store.save(checkIn)

        #expect(try await store.featureRows(nil, in: everything) == [featureRow])
        #expect(try await store.dailyRows(today...today) == [dailyRow])
        #expect(try await store.dailySummaries(today...today) == [summary])
        #expect(try await store.checkIns(today...today) == [checkIn])
    }

    @Test(arguments: StoreKind.allCases)
    func schemaVersionAndCoverageSurviveARoundTrip(_ kind: StoreKind) async throws {
        let store = try kind.make()
        try await store.save(row(.activity, minute: 0))
        let saved = try await store.featureRows(nil, in: everything)
        let expected = row(.activity, minute: 0)
        #expect(saved.first?.schemaVersion == expected.schemaVersion)
        #expect(saved.first?.coverageSeconds == expected.coverageSeconds)
        #expect(saved.first?.utcOffsetMinutes == expected.utcOffsetMinutes)
    }

    @Test(arguments: StoreKind.allCases)
    func replacesTheCheckInOfTheSameDay(_ kind: StoreKind) async throws {
        let store = try kind.make()
        try await store.save(CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 1), scores: [.energy: 2]))
        try await store.save(CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 2), scores: [.energy: 4, .mood: 3]))
        try await store.save(CheckIn(day: today.adding(days: -1), savedAt: Date(timeIntervalSince1970: 0), scores: [.social: 5]))

        let todays = try await store.checkIns(today...today)
        #expect(todays.count == 1)
        #expect(todays.first?.scores == [.energy: 4, .mood: 3])
        #expect(try await store.checkIns(today.adding(days: -1)...today).count == 2)
    }

    @Test(arguments: StoreKind.allCases)
    func filtersRowsBySensorAndInterval(_ kind: StoreKind) async throws {
        let store = try kind.make()
        try await store.save(row(.activity, minute: 5))
        try await store.save(row(.keyboard, minute: 0))
        try await store.save(row(.activity, minute: 0))
        try await store.save(row(.activity, minute: 100))
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_795_000_000), duration: 600)

        let activity = try await store.featureRows(.activity, in: interval)
        #expect(activity.map(\.windowStart.timeIntervalSince1970) == [1_795_000_000, 1_795_000_300])
        #expect(try await store.featureRows(nil, in: interval).count == 3)
    }

    @Test(arguments: StoreKind.allCases)
    func deleteExpiredKeeps30DaysAndAllSummaries(_ kind: StoreKind) async throws {
        let store = try kind.make()
        let oldDay = today.adding(days: -31)
        let edgeDay = today.adding(days: -30)
        for day in [oldDay, edgeDay] {
            try await store.save(row(.activity, minute: 0, day: day))
            try await store.save(DailyRow(day: day, schemaVersions: [.activity: 1], values: [:]))
            try await store.save(DailySummary(day: day, values: [:]))
            try await store.save(CheckIn(day: day, savedAt: Date(timeIntervalSince1970: 0), scores: [:]))
        }

        try await store.deleteExpired(today: today)

        let all = oldDay...today
        #expect(try await store.dailyRows(all).map(\.day) == [edgeDay])
        #expect(try await store.checkIns(all).map(\.day) == [edgeDay])
        #expect(try await store.dailySummaries(all).map(\.day) == [oldDay, edgeDay])
        #expect(try await store.featureRows(nil, in: everything).map(\.day) == [edgeDay])
    }

    @Test(arguments: StoreKind.allCases)
    func deleteAllRemovesEveryKind(_ kind: StoreKind) async throws {
        let store = try kind.make()
        try await store.save(row(.activity, minute: 0))
        try await store.save(DailyRow(day: today, schemaVersions: [.activity: 1], values: [:]))
        try await store.save(DailySummary(day: today, values: [:]))
        try await store.save(CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 0), scores: [.energy: 3]))

        try await store.deleteAll()

        #expect(try await store.featureRows(nil, in: everything).isEmpty)
        #expect(try await store.dailyRows(today...today).isEmpty)
        #expect(try await store.dailySummaries(today...today).isEmpty)
        #expect(try await store.checkIns(today...today).isEmpty)
    }
}

@Suite("SwiftDataFeatureStore file")
struct SwiftDataFeatureStoreFileTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tells-test-\(UUID().uuidString)/Tells.store")
    }

    @Test func rowsSurviveARestart() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = row(.keyboard, minute: 0)
        do {
            let first = try SwiftDataFeatureStore.open(at: url)
            try await first.save(saved)
            try await first.save(DailySummary(day: saved.day, values: [:]))
        }
        let second = try SwiftDataFeatureStore.open(at: url)
        #expect(try await second.featureRows(nil, in: everything) == [saved])
        #expect(try await second.dailySummaries(saved.day...saved.day).count == 1)
    }

    @Test func aCancelledTaskStillSavesItsRow() async throws {
        let store = try SwiftDataFeatureStore.inMemory()
        let saved = row(.activity, minute: 0)
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream {}          // ends when the gate is finished
            let wasCancelled = Task.isCancelled
            try await store.save(saved)            // runs inside a cancelled task
            return wasCancelled
        }
        task.cancel()
        gate.continuation.finish()
        #expect(try await task.value == true)
        #expect(try await store.featureRows(nil, in: everything) == [saved])
    }
}

/// An extractor that holds `extractWindow` until the test opens the gate.
private final class HeldExtractor: FeatureExtractor, @unchecked Sendable {
    let sensor: SensorID = .keyboard
    let schemaVersion = 1
    let windowFeatures: [FeatureName] = []
    let dayFeatures: [FeatureName] = []
    let entered = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)

    func waitUntilEntered() { entered.wait() }

    func extractWindow(_ samples: [SensorSample], window: DateInterval) -> FeatureVector {
        entered.signal()
        gate.wait()
        return [:]
    }

    func extractDay(_ rows: [FeatureRow], day: TellsDay) -> FeatureVector { [:] }
}

@Suite("WindowClock with SwiftDataFeatureStore")
struct WindowClockSwiftDataTests {
    @Test func aCloseThatRunsWhileTheLoopIsCancelledStillSavesItsRow() async throws {
        let store = try SwiftDataFeatureStore.inMemory()
        let extractor = HeldExtractor()
        let t0 = Date(timeIntervalSince1970: 1_795_000_200)
        let calls = Mutex<Int>(0)
        let clock = WindowClock(buffer: RawEventBuffer(), extractors: [extractor], store: store) { _ in
            if calls.withLock({ $0 += 1; return $0 }) > 1 { try await Task.sleep(for: .seconds(3600)) }
        }
        await clock.start(sensors: [.keyboard], at: t0)
        await Task.detached { extractor.waitUntilEntered() }.value  // the close is now held
        let stopping = Task { await clock.stop(at: t0.addingTimeInterval(300)) }
        try await Task.sleep(for: .milliseconds(100))              // stop() has cancelled the loop
        extractor.gate.signal()
        await stopping.value

        let rows = try await store.featureRows(.keyboard, in: DateInterval(start: .distantPast, end: .distantFuture))
        #expect(rows.map(\.windowStart) == [t0])
    }
}
