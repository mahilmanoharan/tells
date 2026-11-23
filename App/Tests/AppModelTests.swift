import AppKit
import CompanionUI
import Foundation
import Testing
import TellsCore
@testable import Tells

private actor FakeHub: CollectionControlling {
    private(set) var pausedCalls: [Bool] = []
    private(set) var runCount = 0
    func run() async { runCount += 1 }
    func setPaused(_ paused: Bool) async { pausedCalls.append(paused) }
    private(set) var retryCount = 0
    var unstarted = false
    func setUnstarted(_ value: Bool) { unstarted = value }
    func retryUnstarted() async { retryCount += 1 }
    func hasUnstartedSensors() async -> Bool { unstarted }

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

    // D-088: no poll when no sensor waits.
    @Test func permissionPollStopsWhenNoSensorWaits() async {
        let hub = FakeHub()
        let model = AppModel(hub: hub, permissionPollInterval: .milliseconds(10))
        model.startCollection()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await hub.retryCount == 1)   // one check at start, then no timer
        model.stopCollection()
    }

    // D-088: a waiting sensor is retried each interval, never while paused, and again after the resume.
    @Test func permissionPollRunsOnlyWhileASensorWaitsAndNotWhilePaused() async {
        let hub = FakeHub()
        await hub.setUnstarted(true)
        let model = AppModel(hub: hub, permissionPollInterval: .milliseconds(10))
        model.startCollection()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await hub.retryCount > 3)
        model.pauseUntilResumed()
        try? await Task.sleep(for: .milliseconds(50))
        let atPause = await hub.retryCount
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await hub.retryCount == atPause)   // no work while paused (check 8)
        model.resume()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await hub.retryCount > atPause)
        model.stopCollection()
        try? await Task.sleep(for: .milliseconds(50))
        let atStop = await hub.retryCount
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await hub.retryCount == atStop)
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

@MainActor
struct CompanionStateTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static let noon = utc.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12)) ?? .distantPast

    private let switchCount = FeatureName("appswitch.switch_count")!

    private func switchRow(minutesBefore: Double, count: Double) -> FeatureRow {
        let start = Self.noon.addingTimeInterval(-minutesBefore * 60)
        return FeatureRow(sensor: .appswitch, schemaVersion: 1, windowStart: start, utcOffsetMinutes: 0,
                          day: TellsDay(start, calendar: Self.utc), coverageSeconds: 300,
                          values: [switchCount: count])
    }

    private func makeModel() -> (AppModel, InMemoryFeatureStore, StateLog) {
        let model = AppModel(now: { Self.noon }, calendar: Self.utc)
        let store = InMemoryFeatureStore()
        model.store = store
        let log = StateLog()
        model.onCompanionStateChange = { log.states.append($0) }
        return (model, store, log)
    }

    final class StateLog { var states: [CompanionState] = [] }

    @Test func manySwitchesGiveScattered() async throws {
        let (model, store, log) = makeModel()
        try await store.save(switchRow(minutesBefore: 5, count: 15))
        await model.refreshCompanionState()
        #expect(model.companionState == .scattered)
        #expect(log.states == [.scattered])
    }

    @Test func noDataGivesNormalAndNoChange() async {
        let (model, _, log) = makeModel()
        await model.refreshCompanionState()
        #expect(model.companionState == .normal)
        #expect(log.states.isEmpty)
    }

    @Test func pauseGivesAsleepAndResumeGivesTheDataState() async throws {
        let (model, store, _) = makeModel()
        try await store.save(switchRow(minutesBefore: 5, count: 15))
        model.pauseUntilResumed()
        await model.refreshCompanionState()
        #expect(model.companionState == .asleep)
        model.resume()
        await model.refreshCompanionState()
        #expect(model.companionState == .scattered)
    }

    // MARK: real triggers

    private func waitFor(_ state: CompanionState, _ model: AppModel) async -> Bool {
        for _ in 0..<400 where model.companionState != state { try? await Task.sleep(for: .milliseconds(5)) }
        return model.companionState == state
    }

    private func makeRunningModel() throws -> (AppModel, InMemoryFeatureStore, AsyncStream<Date>.Continuation) {
        let (closes, signal) = AsyncStream<Date>.makeStream()
        let model = AppModel(now: { Self.noon }, calendar: Self.utc, hub: FakeHub(), windowCloses: closes)
        let store = InMemoryFeatureStore()
        model.store = store
        model.startCollection()
        return (model, store, signal)
    }

    private func post(_ name: Notification.Name) {
        NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
    }

    @Test func aClosedWindowUpdatesTheCompanion() async throws {
        let (model, store, signal) = try makeRunningModel()
        defer { model.stopCollection() }
        try await store.save(switchRow(minutesBefore: 5, count: 15))
        signal.yield(Self.noon)
        #expect(await waitFor(.scattered, model))
    }

    @Test func pauseGivesAsleepAndResumeGoesBack() async throws {
        let (model, store, _) = try makeRunningModel()
        defer { model.stopCollection() }
        try await store.save(switchRow(minutesBefore: 5, count: 15))
        model.pauseUntilResumed()
        #expect(await waitFor(.asleep, model))
        model.resume()
        #expect(await waitFor(.scattered, model))
    }

    @Test func sleepAndWakeChangeTheCompanion() async throws {
        let (model, _, _) = try makeRunningModel()
        defer { model.stopCollection() }
        post(NSWorkspace.willSleepNotification)
        #expect(await waitFor(.asleep, model))
        post(NSWorkspace.didWakeNotification)
        #expect(await waitFor(.normal, model))
    }

    @Test func displaySleepAndSessionChangeGiveAsleep() async throws {
        let (model, _, _) = try makeRunningModel()
        defer { model.stopCollection() }
        post(NSWorkspace.screensDidSleepNotification)
        #expect(await waitFor(.asleep, model))
        post(NSWorkspace.screensDidWakeNotification)
        #expect(await waitFor(.normal, model))
        post(NSWorkspace.sessionDidResignActiveNotification)
        #expect(await waitFor(.asleep, model))
        post(NSWorkspace.sessionDidBecomeActiveNotification)
        #expect(await waitFor(.normal, model))
    }

    @Test func aSlowRefreshCannotOverwriteAsleep() async throws {
        let slow = GatedStore()
        let model = AppModel(now: { Self.noon }, calendar: Self.utc)
        model.store = slow
        try await slow.save(switchRow(minutesBefore: 5, count: 15))
        await slow.closeGate()
        let refresh = Task { await model.refreshCompanionState() }
        await slow.waitUntilBlocked()
        model.pauseUntilResumed()   // the pause comes while the read waits
        #expect(await waitFor(.asleep, model))
        await slow.openGate()
        await refresh.value
        #expect(model.companionState == .asleep)
    }
}

/// A store whose `appswitch` read waits at a gate. It makes a refresh slow, for the race test.
private actor GatedStore: FeatureStore {
    private let inner = InMemoryFeatureStore()
    private var isClosed = false
    private var isBlocked = false
    private var waiter: CheckedContinuation<Void, Never>?

    func closeGate() { isClosed = true }
    func openGate() { isClosed = false; waiter?.resume(); waiter = nil }
    func waitUntilBlocked() async { while !isBlocked { try? await Task.sleep(for: .milliseconds(2)) } }

    func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow] {
        let rows = try await inner.featureRows(sensor, in: interval)
        if sensor == .appswitch, isClosed {
            isBlocked = true
            await withCheckedContinuation { waiter = $0 }
        }
        return rows
    }
    func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow] { try await inner.dailyRows(days) }
    func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary] { try await inner.dailySummaries(days) }
    func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn] { try await inner.checkIns(days) }
    func save(_ row: FeatureRow) async throws { try await inner.save(row) }
    func save(_ row: DailyRow) async throws { try await inner.save(row) }
    func save(_ summary: DailySummary) async throws { try await inner.save(summary) }
    func save(_ checkIn: CheckIn) async throws { try await inner.save(checkIn) }
    func deleteExpired(today: TellsDay) async throws { try await inner.deleteExpired(today: today) }
    func deleteAll() async throws { try await inner.deleteAll() }
}
