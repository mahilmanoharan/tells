import Foundation
import Testing
import TellsCore
@testable import Tells

private actor FakeHub: CollectionControlling {
    private(set) var pausedCalls: [Bool] = []
    private(set) var runCount = 0
    func run() async { runCount += 1 }
    func setPaused(_ paused: Bool) async { pausedCalls.append(paused) }
    func retryUnstarted() async {}

    /// Waits until the hub has seen `count` pause calls.
    func waitForPauseCalls(_ count: Int) async -> [Bool] {
        for _ in 0..<400 where pausedCalls.count < count { try? await Task.sleep(for: .milliseconds(5)) }
        return pausedCalls
    }
}

@MainActor
struct AppModelTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private func makeModel(at date: Date) -> (AppModel, Clock) {
        let clock = Clock(date)
        return (AppModel(now: { clock.date }, calendar: Self.utc), clock)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        Self.utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
    }

    // DEFAULT: D-076
    @Test func todayChangesAt0400() {
        let (model, clock) = makeModel(at: date(2026, 11, 22, 1))
        #expect(model.today == TellsDay(yyyymmdd: 20261121))
        clock.date = date(2026, 11, 22, 3, 59)
        #expect(model.today == TellsDay(yyyymmdd: 20261121))
        clock.date = date(2026, 11, 22, 4)
        #expect(model.today == TellsDay(yyyymmdd: 20261122))
    }

    @Test func checkInIsOffWithoutAStore() {
        let (model, _) = makeModel(at: date(2026, 11, 22, 9))
        #expect(!model.canCheckIn)
        #expect(model.makeInsightContext() == nil)
        model.store = InMemoryFeatureStore()
        #expect(model.canCheckIn)
    }

    @Test func companionIsVisibleAtStart() {
        #expect(AppModel().isCompanionVisible)
    }

    @Test func toggleHidesThenShowsCompanion() {
        let model = AppModel()
        model.toggleCompanion()
        #expect(!model.isCompanionVisible)
        model.toggleCompanion()
        #expect(model.isCompanionVisible)
    }

    @Test func visibilityChangeIsReported() {
        let model = AppModel()
        var seen: [Bool] = []
        model.onCompanionVisibilityChange = { seen.append($0) }
        model.toggleCompanion()
        model.toggleCompanion()
        #expect(seen == [false, true])
    }

    @Test func notPausedAtStart() {
        #expect(!AppModel().isPaused)
    }

    @Test func pauseForOneHourEndsAfterOneHour() {
        let start = date(2026, 3, 10, 14)
        let (model, clock) = makeModel(at: start)
        model.pause(for: 3600)
        #expect(model.isPaused)
        clock.date = start.addingTimeInterval(3599)
        #expect(model.isPaused)
        clock.date = start.addingTimeInterval(3600)
        #expect(!model.isPaused)
    }

    @Test func pauseUntilTomorrowEndsAtFourNextDay() {
        let (model, clock) = makeModel(at: date(2026, 3, 10, 14))
        model.pauseUntilTomorrow()
        #expect(model.pauseState == .pausedUntil(date(2026, 3, 11, 4)))
        clock.date = date(2026, 3, 11, 3, 59)
        #expect(model.isPaused)
        clock.date = date(2026, 3, 11, 4)
        #expect(!model.isPaused)
    }

    @Test func pauseUntilTomorrowAfterMidnightEndsAtFourSameDay() {
        let (model, _) = makeModel(at: date(2026, 3, 11, 2))
        model.pauseUntilTomorrow()
        #expect(model.pauseState == .pausedUntil(date(2026, 3, 11, 4)))
    }

    @Test func pauseUntilResumedNeverEnds() {
        let start = date(2026, 3, 10, 14)
        let (model, clock) = makeModel(at: start)
        model.pauseUntilResumed()
        #expect(model.isPaused)
        clock.date = start.addingTimeInterval(86400 * 365)
        #expect(model.isPaused)
    }

    @Test func resumeClearsEveryPause() {
        let (model, _) = makeModel(at: date(2026, 3, 10, 14))
        model.pauseUntilResumed()
        model.resume()
        #expect(!model.isPaused)
        model.pause(for: 3600)
        model.resume()
        #expect(!model.isPaused)
        #expect(model.pauseState == .notPaused)
    }

    @Test func deleteAllDataClearsTheStore() async throws {
        let (model, _) = makeModel(at: date(2026, 11, 21, 10))
        let store = InMemoryFeatureStore()
        let day = TellsDay(yyyymmdd: 20261121)
        try await store.save(DailySummary(day: day, values: [:]))
        try await store.save(CheckIn(day: day, savedAt: date(2026, 11, 21, 9), scores: [.energy: 3]))
        model.store = store

        try await model.deleteAllData()

        #expect(try await store.dailySummaries(day...day).isEmpty)
        #expect(try await store.checkIns(day...day).isEmpty)
    }

    @Test func deleteAllDataWithoutAStoreDoesNothing() async throws {
        let (model, _) = makeModel(at: date(2026, 11, 21, 10))
        try await model.deleteAllData()
    }

    @Test func pauseAndResumeStopAndStartTheHub() async {
        let hub = FakeHub()
        let model = AppModel(hub: hub)
        model.startCollection()
        #expect(await hub.waitForPauseCalls(1) == [false])
        model.pauseUntilResumed()
        #expect(await hub.waitForPauseCalls(2) == [false, true])
        model.resume()
        #expect(await hub.waitForPauseCalls(3) == [false, true, false])
        model.pause(for: 3600)
        #expect(await hub.waitForPauseCalls(4) == [false, true, false, true])
        #expect(await hub.runCount == 1)
    }

    @Test func failedStoreOpenSetsTheStartupFailure() {
        struct OpenError: Error {}
        let model = AppModel.live(isTestProcess: false, openStore: { throw OpenError() })
        #expect(model.startupFailure?.hasPrefix("Tells could not open its store") == true)
        #expect(model.store == nil)
        #expect(AppModel.live(isTestProcess: true).startupFailure == nil)
    }

    @Test func stopCollectionCancelsEveryTask() async {
        let model = AppModel(hub: FakeHub())
        model.startCollection()
        #expect(!model.collectionTasks.isEmpty)
        #expect(model.collectionTasks.allSatisfy { !$0.isCancelled })
        model.stopCollection()
        #expect(model.collectionTasks.allSatisfy { $0.isCancelled })
    }

    @Test func timedPauseResumesTheHubAtItsEnd() async {
        let hub = FakeHub()
        let model = AppModel(hub: hub, pauseSleep: { _ in })   // the pause ends at once
        model.startCollection()
        model.pause(for: 3600)
        #expect(await hub.waitForPauseCalls(3) == [false, true, false])
        #expect(model.pauseState == .notPaused)
        model.stopCollection()
    }

    // P2.7 failure case (check 4): no store.
    @Test func exportWithoutAStoreFailsWithAMessage() async {
        let (model, _) = makeModel(at: date(2026, 11, 22, 9))
        let result = await model.exportGateCSV(to: FileManager.default.temporaryDirectory)
        #expect(result == "Export failed: no store.")
    }

    // P2.7 failure case (check 4): a folder that cannot be written.
    @Test func exportToAFolderThatCannotBeWrittenFailsWithAMessage() async {
        let (model, _) = makeModel(at: date(2026, 11, 22, 9))
        model.store = InMemoryFeatureStore()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("none")
        let result = await model.exportGateCSV(to: missing)
        #expect(result.hasPrefix("Export failed:"))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
