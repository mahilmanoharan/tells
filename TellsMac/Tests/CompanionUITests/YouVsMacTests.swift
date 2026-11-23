import Foundation
import SwiftUI
import Testing
@testable import CompanionUI
import TellsCore

/// A model that is not a mock. It gives a fixed guess when it has 12 windows.
private struct RealModel: ModelProvider {
    let target: CheckInItem = .energy
    let featureNames: [FeatureName] = []
    let isMock = false
    let modelVersion = "real-test"
    let value: Double
    func predict(_ features: FeatureVector, day: TellsDay, windowCount: Int) async -> Prediction? {
        windowCount >= DataThreshold.minimumWindowsToday ? Prediction(day: day, target: target, value: value) : nil
    }
}

@Suite("YouVsMac", .serialized)
@MainActor
struct YouVsMacTests {
    let today = TellsDay(yyyymmdd: 20261121)

    private func defaults() throws -> UserDefaults {
        let name = "tells.youVsMac.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func midnight() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = DateComponents(year: 2026, month: 11, day: 21)
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    private func row(_ sensor: SensorID, at date: Date, day: TellsDay, values: FeatureVector) -> FeatureRow {
        FeatureRow(sensor: sensor, schemaVersion: 1, windowStart: date, utcOffsetMinutes: 0,
                   day: day, coverageSeconds: 300, values: values)
    }

    /// 12 windows today, and one at 23:00 the evening before. Activity day features exist, so the mock model predicts.
    private func fillWindows(_ store: InMemoryFeatureStore, count: Int = 12) async throws {
        guard let input = FeatureName("activity.input_s"), let lead = FeatureName("activity.leading_idle_s"),
              let trail = FeatureName("activity.trailing_idle_s") else { return }
        let busy: FeatureVector = [input: 60, lead: 0, trail: 0]
        try await store.save(row(.activity, at: midnight().addingTimeInterval(-3600), day: today.adding(days: -1), values: busy))
        for index in 0..<count {
            let start = midnight().addingTimeInterval(8 * 3600 + Double(index) * 300)
            try await store.save(row(.activity, at: start, day: today, values: busy))
        }
    }

    private func saveCheckIn(_ store: InMemoryFeatureStore, energy: Int? = 4) async throws {
        let scores: [CheckInItem: Int] = energy.map { [.energy: $0] } ?? [.mood: 3]
        try await store.save(CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 1), scores: scores))
    }

    private func settle(_ model: YouVsMacModel) async {
        for _ in 0..<200 where model.phase == .loading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func open(_ experience: YouVsMacExperience, _ context: InsightContext) async -> YouVsMacModel? {
        _ = experience.makeView(in: context)
        guard let model = experience.currentModel else { return nil }
        await settle(model)
        return model
    }

    // MARK: rules

    @Test func theCloserGuessWinsAndWithin025IsATie() {
        #expect(YouVsMacRules.winner(forecast: 3, mac: 3.6, label: 4) == .mac)
        #expect(YouVsMacRules.winner(forecast: 4, mac: 2.0, label: 4) == .you)
        #expect(YouVsMacRules.winner(forecast: 3, mac: 3.8, label: 4) == .mac)
        #expect(YouVsMacRules.winner(forecast: 3, mac: 3.0, label: 4) == .tie)     // equal errors
        #expect(YouVsMacRules.winner(forecast: 4, mac: 3.8, label: 4) == .tie)     // errors 0 and 0.2
        #expect(YouVsMacRules.winner(forecast: 4, mac: 3.7, label: 4) == .you)     // errors 0 and 0.3
    }

    @Test func tieMarginIsInclusive() {
        #expect(YouVsMacRules.winner(forecast: 4, mac: 3.75, label: 4) == .tie)    // errors 0 and 0.25
        #expect(YouVsMacRules.winner(forecast: 4, mac: 3.74, label: 4) == .you)
    }

    @Test func scoreTextShowsTheTotals() {
        #expect(YouVsMacScore(you: 6, mac: 4, tie: 2).text == "You 6, Mac 4, Tie 2")
    }

    @Test func textHasNoMedicalWordsAndNoCauses() {
        let all = [YouVsMacText.practiceBanner, YouVsMacText.unreadable, YouVsMacText.notEnoughData,
                   YouVsMacText.noTargetScore, YouVsMacText.noForecast, YouVsMacText.tie, YouVsMacText.macCloser,
                   YouVsMacText.youCloser, YouVsMacText.ask(target: "energy"),
                   YouVsMacText.values(target: "energy", forecast: 3, label: 4, mac: 3.6)].joined(separator: " ").lowercased()
        for word in ["diagnose", "disorder", "symptom", "illness", "disease", "treatment", "therapy", "health",
                     "burnout", "depression", "anxiety", "fatigue", "sleep quality", "cause", "knows"] {
            #expect(!all.contains(word), "\(word)")
        }
        #expect(YouVsMacText.values(target: "energy", forecast: 3, label: 4, mac: 3.6)
                == "The Mac predicted 3.6. Your energy check-in was 4. Your forecast was 3.")
    }

    // MARK: states

    @Test func stateBeforeCheckInIsReadyOrPracticeAndReadsNoPrediction() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        let experience = YouVsMacExperience(defaults: try defaults())
        let mock = InsightContext(store: store, model: MockModelProvider(), today: today)
        let real = InsightContext(store: store, model: RealModel(value: 3), today: today)
        #expect(await experience.state(in: mock) == .practice)
        #expect(await experience.state(in: real) == .ready)
    }

    @Test func mockModelWithDataAfterCheckInShowsPractice() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        try await saveCheckIn(store)
        let experience = YouVsMacExperience(defaults: try defaults())
        let context = InsightContext(store: store, model: MockModelProvider(), today: today)
        #expect(await experience.state(in: context) == .practice)
    }

    @Test func realModelWithDataShowsRealValuesAndReady() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        try await saveCheckIn(store, energy: 4)
        let suite = try defaults()
        YouVsMacStorage(defaults: suite).saveForecast(3, day: today)
        let experience = YouVsMacExperience(defaults: suite)
        let context = InsightContext(store: store, model: RealModel(value: 3.64), today: today)
        #expect(await experience.state(in: context) == .ready)
        let model = try #require(await open(experience, context))
        #expect(!model.isPractice)
        #expect(model.phase == .reveal(YouVsMacReveal(forecast: 3, label: 4, mac: 3.6, windowCount: 12, winner: .mac)))
        #expect(model.score == YouVsMacScore(you: 0, mac: 1, tie: 0))
        experience.stop()
    }

    @Test func mockModelShowsThePracticeRevealWithMockData() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        try await saveCheckIn(store, energy: 4)
        let suite = try defaults()
        YouVsMacStorage(defaults: suite).saveForecast(2, day: today)
        let experience = YouVsMacExperience(defaults: suite)
        let context = InsightContext(store: store, model: MockModelProvider(), today: today)
        let rows = try await store.featureRows(nil, in: DateInterval(start: .distantPast, end: .distantFuture))
        let features = TodayFeatures.build(day: today, rows: rows,
                                           extractors: [KeyboardExtractor(), ActivityExtractor(), AppSwitchExtractor()])
        let expected = try #require(await MockModelProvider().predict(features.values, day: today, windowCount: features.windowCount))
        let model = try #require(await open(experience, context))
        #expect(model.isPractice)
        guard case .reveal(let reveal) = model.phase else { Issue.record("no reveal"); return }
        #expect(reveal.mac == YouVsMacRules.rounded(expected.value))
        #expect(YouVsMacStorage(defaults: suite).score(practice: false) == YouVsMacScore())
        #expect(YouVsMacStorage(defaults: suite).score(practice: true).you
                + YouVsMacStorage(defaults: suite).score(practice: true).mac
                + YouVsMacStorage(defaults: suite).score(practice: true).tie == 1)
        experience.stop()
    }

    @Test func notEnoughDataKeepsTheScoreAndShowsNoGuess() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store, count: 5)
        try await saveCheckIn(store)
        let suite = try defaults()
        YouVsMacStorage(defaults: suite).saveForecast(3, day: today)
        let experience = YouVsMacExperience(defaults: suite)
        let context = InsightContext(store: store, model: RealModel(value: 3), today: today)
        #expect(await experience.state(in: context) == .notEnoughData(have: 5, need: 12, unit: "windows"))
        let model = try #require(await open(experience, context))
        #expect(model.phase == .reveal(YouVsMacReveal(forecast: 3, label: 4, mac: nil, windowCount: 5, winner: nil)))
        #expect(model.score == YouVsMacScore())
        experience.stop()
    }

    // MARK: check-in before prediction

    @Test func noGuessAndNoPredictionCallBeforeTheCheckIn() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        let suite = try defaults()
        let experience = YouVsMacExperience(defaults: suite)
        let context = InsightContext(store: store, model: RealModel(value: 3), today: today)
        let model = try #require(await open(experience, context))
        #expect(model.phase == .askForecast)
        model.selectForecast(3)
        await settle(model)
        for _ in 0..<200 where model.phase == .askForecast { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .checkIn)
        #expect(model.checkInModel != nil)
        experience.stop()
    }

    @Test func savingTheCheckInShowsTheRevealAndScoresOnce() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        let suite = try defaults()
        let experience = YouVsMacExperience(defaults: suite)
        let context = InsightContext(store: store, model: RealModel(value: 4), today: today)
        let model = try #require(await open(experience, context))
        model.selectForecast(2)
        for _ in 0..<200 where model.phase != .checkIn { try await Task.sleep(for: .milliseconds(10)) }
        let checkIn = try #require(model.checkInModel)
        checkIn.select(4, for: .energy)
        await checkIn.save()
        for _ in 0..<200 {
            if case .reveal = model.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.phase == .reveal(YouVsMacReveal(forecast: 2, label: 4, mac: 4.0, windowCount: 12, winner: .mac)))
        #expect(model.score == YouVsMacScore(you: 0, mac: 1, tie: 0))
        // A second open the same day does not add the day again.
        experience.stop()
        let again = try #require(await open(experience, context))
        #expect(again.score == YouVsMacScore(you: 0, mac: 1, tie: 0))
        experience.stop()
    }

    @Test func noForecastShowsTheGuessWithoutScoring() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        try await saveCheckIn(store)
        let experience = YouVsMacExperience(defaults: try defaults())
        let context = InsightContext(store: store, model: RealModel(value: 3.2), today: today)
        let model = try #require(await open(experience, context))
        #expect(model.phase == .reveal(YouVsMacReveal(forecast: nil, label: 4, mac: 3.2, windowCount: 12, winner: nil)))
        #expect(model.score == YouVsMacScore())
        experience.stop()
    }

    @Test func aCheckInWithoutTheTargetHasNoScore() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        try await saveCheckIn(store, energy: nil)
        let suite = try defaults()
        YouVsMacStorage(defaults: suite).saveForecast(3, day: today)
        let experience = YouVsMacExperience(defaults: suite)
        let context = InsightContext(store: store, model: RealModel(value: 3.2), today: today)
        let model = try #require(await open(experience, context))
        #expect(model.phase == .reveal(YouVsMacReveal(forecast: 3, label: nil, mac: 3.2, windowCount: 12, winner: nil)))
        #expect(model.score == YouVsMacScore())
        experience.stop()
    }

    @Test func aForecastOfAnEarlierDayIsDeleted() async throws {
        let suite = try defaults()
        let storage = YouVsMacStorage(defaults: suite)
        storage.saveForecast(5, day: today.adding(days: -1))
        let experience = YouVsMacExperience(defaults: suite)
        let context = InsightContext(store: InMemoryFeatureStore(), model: RealModel(value: 3), today: today)
        let model = try #require(await open(experience, context))
        #expect(model.phase == .askForecast)
        #expect(storage.forecast(for: today) == nil)
        #expect(suite.object(forKey: "tells.youVsMac.forecastValue") == nil)
        experience.stop()
    }

    @Test func noStaleForecastRemainsAfterTheDayEnds() async throws {
        let suite = try defaults()
        let storage = YouVsMacStorage(defaults: suite)
        storage.saveForecast(4, day: today)
        // Same day: the forecast stays for the reveal.
        YouVsMacExperience.purgeStaleForecast(today: today, defaults: suite)
        #expect(storage.forecast(for: today) == 4)
        // The next day: the app start and the window close delete it, with no view opened.
        YouVsMacExperience.purgeStaleForecast(today: today.adding(days: 1), defaults: suite)
        #expect(!storage.hasForecast())
        // The menu state read deletes it too.
        storage.saveForecast(2, day: today)
        let context = InsightContext(store: InMemoryFeatureStore(), model: RealModel(value: 3), today: today.adding(days: 1))
        _ = await YouVsMacExperience(defaults: suite).state(in: context)
        #expect(!storage.hasForecast())
    }

    @Test func idsMatchSpecSection6() {
        #expect(YouVsMacExperience(defaults: .standard).id == "youVsMac")
        #expect(PlaceholderExperience.all().map(\.id)
                == ["youVsMac", "typingSound", "ghostRacer", "whatIf", "hapticWeek", "experiment", "nudge"])
    }

    @Test func practiceScoreIsSeparateAndEndsWithTheMock() async throws {
        let suite = try defaults()
        let storage = YouVsMacStorage(defaults: suite)
        _ = storage.addDay(.you, day: today.adding(days: -1), practice: true)
        #expect(storage.score(practice: false) == YouVsMacScore())
        #expect(storage.score(practice: true) == YouVsMacScore(you: 1))
        let experience = YouVsMacExperience(defaults: suite)
        let context = InsightContext(store: InMemoryFeatureStore(), model: RealModel(value: 3), today: today)
        _ = await open(experience, context)
        #expect(storage.score(practice: true) == YouVsMacScore())
        experience.stop()
    }

    @Test func anUnreadableStoreShowsItsOwnState() async throws {
        struct Broken: FeatureReader {
            struct Failure: Error {}
            func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow] { throw Failure() }
            func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow] { throw Failure() }
            func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary] { throw Failure() }
            func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn] { throw Failure() }
        }
        let experience = YouVsMacExperience(defaults: try defaults())
        let context = InsightContext(store: Broken(), model: RealModel(value: 3), today: today) { _ in }
        let model = try #require(await open(experience, context))
        #expect(model.phase == .unreadable)
        experience.stop()
    }

    // MARK: stop

    @Test func stopEndsTheTaskAndIgnoresLateResults() async throws {
        let store = InMemoryFeatureStore()
        let experience = YouVsMacExperience(defaults: try defaults())
        let context = InsightContext(store: store, model: RealModel(value: 3), today: today)
        _ = experience.makeView(in: context)
        let model = try #require(experience.currentModel)
        let task = try #require(model.currentTask)
        experience.stop()
        experience.stop()
        #expect(task.isCancelled)
        #expect(model.currentTask == nil)
        #expect(experience.currentModel == nil)
        model.selectForecast(3)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.currentTask == nil)
        #expect(model.phase != .reveal(YouVsMacReveal(forecast: 3, label: nil, mac: nil, windowCount: 0, winner: nil)))
    }

    @Test func aNewViewStopsTheOldModel() async throws {
        let experience = YouVsMacExperience(defaults: try defaults())
        let context = InsightContext(store: InMemoryFeatureStore(), model: RealModel(value: 3), today: today)
        _ = experience.makeView(in: context)
        let first = try #require(experience.currentModel)
        _ = experience.makeView(in: context)
        #expect(first.currentTask == nil)
        #expect(experience.currentModel !== first)
        experience.stop()
    }
}
