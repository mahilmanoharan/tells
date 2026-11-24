import Foundation
import SwiftUI
import Testing
@testable import CompanionUI
import TellsCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A model that is not a mock. It counts the predictions, because this experience must ask for none.
private struct RealModel: ModelProvider {
    let target: CheckInItem = .energy
    let featureNames: [FeatureName] = []
    let isMock = false
    let modelVersion = "real-test"
    let counter = Counter()
    func predict(_ features: FeatureVector, day: TellsDay, windowCount: Int) async -> Prediction? {
        counter.increment()
        return nil
    }
}

/// A store whose reads wait, so a test can call stop() during a load.
private actor SlowReader: FeatureReader {
    let base: InMemoryFeatureStore
    init(base: InMemoryFeatureStore) { self.base = base }
    func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow] {
        try await base.featureRows(sensor, in: interval)
    }
    func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow] { try await base.dailyRows(days) }
    func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary] {
        try await base.dailySummaries(days)
    }
    func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn] {
        try await Task.sleep(for: .milliseconds(150))
        return try await base.checkIns(days)
    }
}

@Suite("Experiment", .serialized)
@MainActor
struct ExperimentTests {
    // Saturday 2026-11-21.
    let today = TellsDay(yyyymmdd: 20261121)

    private func defaults() throws -> UserDefaults {
        let name = "tells.experiment.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func context(_ store: any FeatureReader, model: any ModelProvider = RealModel(), today: TellsDay? = nil) -> InsightContext {
        InsightContext(store: store, model: model, today: today ?? self.today) { _ in }
    }

    private func saveScores(_ store: InMemoryFeatureStore, _ scores: [Int: Int], item: CheckInItem = .energy) async throws {
        for (offset, score) in scores {
            try await store.save(CheckIn(day: today.adding(days: offset), savedAt: Date(timeIntervalSince1970: 1), scores: [item: score]))
        }
    }

    /// Check-ins on the days `from...to` (offsets from today) with the same score.
    private func fill(_ store: InMemoryFeatureStore, _ from: Int, _ to: Int, score: Int, item: CheckInItem = .energy) async throws {
        try await saveScores(store, Dictionary(uniqueKeysWithValues: (from...to).map { ($0, score) }), item: item)
    }

    private func saveDaily(_ store: InMemoryFeatureStore, _ change: ExperimentChange, _ values: [Int: Double]) async throws {
        let name = try #require(change.feature)
        for (offset, value) in values {
            try await store.save(DailyRow(day: today.adding(days: offset), schemaVersions: [:], values: [name: value]))
        }
    }

    private func open(_ experience: ExperimentExperience, _ context: InsightContext) async -> ExperimentModel? {
        _ = experience.makeView(in: context)
        guard let model = experience.currentModel else { return nil }
        await model.currentTask?.value
        return model
    }

    private func save(_ record: ExperimentRecord, in defaults: UserDefaults) {
        ExperimentStorage(defaults: defaults).save(record)
    }

    // MARK: identity and text

    @Test func idAndOrderMatchTheSpec() throws {
        let item = ExperimentExperience(defaults: try defaults())
        #expect(item.id == "experiment")
        #expect(item.menuOrder == 6)
        #expect(item.displayName == "Experiment")
    }

    @Test func resultTextFollowsTheDesign() {
        #expect(ExperimentText.result(target: "energy", difference: 0.6, low: -0.1, high: 1.3, extended: false)
            == "During the change week, your energy check-ins were 0.6 higher on average (95% range: -0.1 to 1.3).")
        #expect(ExperimentText.result(target: "mood", difference: -0.4, low: -0.9, high: -0.2, extended: true)
            == "During the change period, your mood check-ins were 0.4 lower on average (95% range: -0.9 to -0.2).")
        #expect(ExperimentText.result(target: "energy", difference: 0.01, low: -0.01, high: 0.02, extended: false)
            == "During the change week, your energy check-ins were the same on average (95% range: 0.0 to 0.0).")
        #expect(ExperimentText.didChange(6, of: 7) == "You did the change on 6 of 7 days.")
        #expect(ExperimentText.smallTest
            == "One week is a small test. Other things in your week can also change your check-ins.")
        #expect(ExperimentText.notEnough(beforeHave: 4, changeHave: 3, need: 5)
            == "Not enough check-ins for a result. Week before: 4 of 5 days. Week of change: 3 of 5 days.")
        #expect(ExperimentText.notEnough(beforeHave: 4, changeHave: 7, need: 5)
            == "Not enough check-ins for a result. Week before: 4 of 5 days.")
        #expect(ExperimentText.notEnough(beforeHave: 7, changeHave: 3, need: 5)
            == "Not enough check-ins for a result. Week of change: 3 of 5 days.")
        #expect(ExperimentText.weakWeekBefore(have: 3) == "Your last 7 days have 3 check-ins. The result can be not enough data.")
        #expect(ExperimentText.weakWeekBefore(have: 1) == "Your last 7 days have 1 check-in. The result can be not enough data.")
    }

    @Test func textHasNoMedicalWordsAndNoCause() {
        var all = [ExperimentText.practiceBanner, ExperimentText.unreadable, ExperimentText.intro, ExperimentText.choose,
                   ExperimentText.startsTomorrow, ExperimentText.smallTest, ExperimentText.chance, ExperimentText.addWeek,
                   ExperimentText.dayLine(day: 2, of: 7), ExperimentText.weakWeekBefore(have: 2),
                   ExperimentText.result(target: "energy", difference: 0.6, low: 0, high: 1, extended: false)]
        all += ExperimentChange.allCases.map(\.title)
        let text = all.joined(separator: " ").lowercased()
        for word in ["diagnose", "disorder", "symptom", "illness", "disease", "treatment", "therapy", "health",
                     "burnout", "depression", "anxiety", "fatigue", "sleep quality", "causes", "improves", "treats"] {
            #expect(!text.contains(word), "\(word)")
        }
        #expect(ExperimentChange.allCases.map(\.title) == [
            "Stop Mac use by 23:00", "No Mac input after 22:00", "Take a 5-minute break each 90 minutes", "Fewer app switches"])
    }

    @Test func whatIfSlidersMapToTheMatchingChange() {
        #expect(ExperimentChange(sliderID: WhatIfSliderKind.bedtime.rawValue) == .stopByTwentyThree)
        #expect(ExperimentChange(sliderID: WhatIfSliderKind.lateScrolling.rawValue) == .noInputAfterTwentyTwo)
        #expect(ExperimentChange(sliderID: "other") == nil)
    }

    // MARK: rules

    @Test func eachChangeHasItsOwnDoneRule() throws {
        let day = today
        func rows(_ change: ExperimentChange, _ values: [Int: Double]) throws -> [TellsDay: DailyRow] {
            let name = try #require(change.feature)
            return Dictionary(uniqueKeysWithValues: values.map { offset, value in
                (day.adding(days: offset), DailyRow(day: day.adding(days: offset), schemaVersions: [:], values: [name: value]))
            })
        }
        let stop = try rows(.stopByTwentyThree, [0: 1380, 1: 1381])
        #expect(ExperimentRules.didChange(.stopByTwentyThree, day: day, rows: stop, baselineSwitchRate: nil) == true)
        #expect(ExperimentRules.didChange(.stopByTwentyThree, day: day.adding(days: 1), rows: stop, baselineSwitchRate: nil) == false)
        #expect(ExperimentRules.didChange(.stopByTwentyThree, day: day.adding(days: 2), rows: stop, baselineSwitchRate: nil) == nil)
        // The evening of day D is in `late_input_min` of day D+1.
        let late = try rows(.noInputAfterTwentyTwo, [1: 0, 2: 12])
        #expect(ExperimentRules.didChange(.noInputAfterTwentyTwo, day: day, rows: late, baselineSwitchRate: nil) == true)
        #expect(ExperimentRules.didChange(.noInputAfterTwentyTwo, day: day.adding(days: 1), rows: late, baselineSwitchRate: nil) == false)
        #expect(ExperimentRules.didChange(.noInputAfterTwentyTwo, day: day.adding(days: 2), rows: late, baselineSwitchRate: nil) == nil)
        let stretch = try rows(.breakEveryNinety, [0: 90, 1: 91])
        #expect(ExperimentRules.didChange(.breakEveryNinety, day: day, rows: stretch, baselineSwitchRate: nil) == true)
        #expect(ExperimentRules.didChange(.breakEveryNinety, day: day.adding(days: 1), rows: stretch, baselineSwitchRate: nil) == false)
        let rate = try rows(.fewerSwitches, [0: 20, 1: 30])
        #expect(ExperimentRules.didChange(.fewerSwitches, day: day, rows: rate, baselineSwitchRate: 25) == true)
        #expect(ExperimentRules.didChange(.fewerSwitches, day: day.adding(days: 1), rows: rate, baselineSwitchRate: 25) == false)
        #expect(ExperimentRules.didChange(.fewerSwitches, day: day, rows: rate, baselineSwitchRate: nil) == nil)
    }

    @Test func switchBaselineNeedsThreeDaysOfTheWeekBefore() async throws {
        let name = try #require(ExperimentChange.fewerSwitches.feature)
        let week = today.adding(days: -7)...today.adding(days: -1)
        func rows(_ offsets: [Int]) -> [TellsDay: DailyRow] {
            Dictionary(uniqueKeysWithValues: offsets.map { offset in
                (today.adding(days: offset), DailyRow(day: today.adding(days: offset), schemaVersions: [:], values: [name: 10]))
            })
        }
        #expect(ExperimentRules.baselineSwitchRate(rows: rows([-1, -2]), weekBefore: week) == nil)
        #expect(ExperimentRules.baselineSwitchRate(rows: rows([-1, -2, -3]), weekBefore: week) == 10)
        // A row outside the week before does not count.
        #expect(ExperimentRules.baselineSwitchRate(rows: rows([-1, -2, 0]), weekBefore: week) == nil)
    }

    @Test func bootstrapIsFixedAndHoldsTheMeanDifference() throws {
        let before: [Double] = [3, 2, 4, 3, 3, 2, 4]
        let change: [Double] = [4, 3, 5, 4, 4, 3, 5]
        let first = try #require(ExperimentRules.bootstrap(before: before, change: change, seed: 7))
        let second = try #require(ExperimentRules.bootstrap(before: before, change: change, seed: 7))
        #expect(first.low == second.low && first.high == second.high)
        let difference = ExperimentRules.mean(change) - ExperimentRules.mean(before)
        #expect(first.low < difference && difference < first.high)
        #expect(ExperimentRules.bootstrap(before: [], change: change, seed: 7) == nil)
        #expect(ExperimentRules.resamples == 2000)
    }

    @Test func recordDatesUseTheTellsDay() {
        let record = ExperimentRecord(change: .fewerSwitches, start: TellsDay(yyyymmdd: 20261129))
        #expect(record.lastDay == TellsDay(yyyymmdd: 20261205))
        #expect(record.weekBefore == TellsDay(yyyymmdd: 20261122)...TellsDay(yyyymmdd: 20261128))
        #expect(ExperimentRecord(change: .fewerSwitches, start: TellsDay(yyyymmdd: 20261129), extended: true).lastDay
            == TellsDay(yyyymmdd: 20261212))
        // The month end is a normal day step.
        #expect(TellsDay(yyyymmdd: 20261129).dayDistance(to: TellsDay(yyyymmdd: 20261201)) == 2)
        #expect(TellsDay(yyyymmdd: 20261201).dayDistance(to: TellsDay(yyyymmdd: 20261129)) == -2)
    }

    // MARK: states

    @Test func practiceStateWithTheMockModelAndReadyWithARealModel() async throws {
        let store = InMemoryFeatureStore()
        try await fill(store, -6, 0, score: 3)
        let item = ExperimentExperience(defaults: try defaults())
        #expect(await item.state(in: context(store, model: MockModelProvider())) == .practice)
        #expect(await item.state(in: context(store)) == .ready)
        let model = try #require(await open(item, context(store, model: MockModelProvider())))
        #expect(model.isPractice)
        #expect(model.phase == .choose(weekBeforeLabeled: 7))
        item.stop()
    }

    @Test func listShowsTheCountOfCheckInsInTheLastSevenDays() async throws {
        let store = InMemoryFeatureStore()
        try await fill(store, -6, -4, score: 3)
        try await fill(store, -3, 0, score: 2, item: .mood)     // another item: not labeled
        let item = ExperimentExperience(defaults: try defaults())
        let model = try #require(await open(item, context(store)))
        #expect(model.phase == .choose(weekBeforeLabeled: 3))
        item.stop()
    }

    @Test func startSavesARecordForTheNextDayAndEndRemovesIt() async throws {
        let store = InMemoryFeatureStore()
        let defaults = try defaults()
        let item = ExperimentExperience(defaults: defaults)
        let model = try #require(await open(item, context(store)))
        model.startExperiment()                                  // nothing selected
        #expect(ExperimentStorage(defaults: defaults).record() == nil)
        model.choose(.breakEveryNinety)
        model.startExperiment()
        await model.currentTask?.value
        let record = try #require(ExperimentStorage(defaults: defaults).record())
        #expect(record == ExperimentRecord(change: .breakEveryNinety, start: today.adding(days: 1)))
        #expect(model.phase == .waiting(record))
        model.endExperiment()
        await model.currentTask?.value
        #expect(ExperimentStorage(defaults: defaults).record() == nil)
        #expect(model.phase == .choose(weekBeforeLabeled: 0))
        item.stop()
    }

    @Test func runningShowsTheDayNumberAndTheMarks() async throws {
        let store = InMemoryFeatureStore()
        try await saveDaily(store, .stopByTwentyThree, [-2: 1300, -1: 1400])
        let defaults = try defaults()
        save(ExperimentRecord(change: .stopByTwentyThree, start: today.adding(days: -2)), in: defaults)
        let item = ExperimentExperience(defaults: defaults)
        #expect(await item.state(in: context(store)) == .ready)
        let model = try #require(await open(item, context(store)))
        guard case .running(let record, let number, let days) = model.phase else {
            Issue.record("expected running")
            return
        }
        #expect(number == 3)
        #expect(record.dayCount == 7)
        #expect(days.count == 7)
        #expect(days.prefix(3).map(\.mark) == [.done, .notDone, .noData])   // today has no closed row
        #expect(days.dropFirst(3).allSatisfy { $0.mark == .noData })
        item.stop()
    }

    @Test func aRecordThatStartsTomorrowShowsWaiting() async throws {
        let defaults = try defaults()
        save(ExperimentRecord(change: .fewerSwitches, start: today.adding(days: 1)), in: defaults)
        let item = ExperimentExperience(defaults: defaults)
        let model = try #require(await open(item, context(InMemoryFeatureStore())))
        #expect(model.phase == .waiting(ExperimentRecord(change: .fewerSwitches, start: today.adding(days: 1))))
        item.stop()
    }

    @Test func resultUsesRealValuesAndCountsDoneDays() async throws {
        let store = InMemoryFeatureStore()
        // The change week is day -7 to day -1. The week before is day -14 to day -8.
        try await fill(store, -14, -8, score: 3)
        try await fill(store, -7, -1, score: 4)
        try await saveDaily(store, .stopByTwentyThree, [-7: 1300, -6: 1300, -5: 1300, -4: 1500, -3: 1300, -2: 1300])
        let defaults = try defaults()
        save(ExperimentRecord(change: .stopByTwentyThree, start: today.adding(days: -7)), in: defaults)
        let item = ExperimentExperience(defaults: defaults)
        #expect(await item.state(in: context(store)) == .ready)
        let model = try #require(await open(item, context(store)))
        guard case .result(_, let result, _) = model.phase else {
            Issue.record("expected result")
            return
        }
        #expect(result.beforeMean == 3 && result.changeMean == 4 && result.difference == 1)
        #expect(result.low == 1 && result.high == 1)
        #expect(!result.includesZero)
        #expect(result.daysDone == 5)
        #expect(result.dayCount == 7)
        item.stop()
    }

    @Test func aRangeThatIncludesZeroIsMarked() async throws {
        let store = InMemoryFeatureStore()
        try await saveScores(store, [-14: 3, -13: 5, -12: 2, -11: 4, -10: 3, -9: 4, -8: 3])
        try await saveScores(store, [-7: 4, -6: 3, -5: 3, -4: 5, -3: 2, -2: 4, -1: 3])
        let defaults = try defaults()
        save(ExperimentRecord(change: .breakEveryNinety, start: today.adding(days: -7)), in: defaults)
        let item = ExperimentExperience(defaults: defaults)
        let model = try #require(await open(item, context(store)))
        guard case .result(_, let result, _) = model.phase else {
            Issue.record("expected result")
            return
        }
        #expect(result.low < 0 && result.high > 0)
        #expect(result.includesZero)
        item.stop()
    }

    @Test func notEnoughDataShowsTheCountsAndOffersOneMoreWeek() async throws {
        let store = InMemoryFeatureStore()
        try await fill(store, -14, -11, score: 3)               // 4 days in the week before
        try await fill(store, -8, -4, score: 4)                 // 5 days in the week of change
        let defaults = try defaults()
        // The week of change is day -8 to day -2. It is over. The week before is day -15 to day -9.
        save(ExperimentRecord(change: .breakEveryNinety, start: today.adding(days: -8)), in: defaults)
        let item = ExperimentExperience(defaults: defaults)
        #expect(await item.state(in: context(store)) == .notEnoughData(have: 4, need: 5, unit: "days"))
        let model = try #require(await open(item, context(store)))
        guard case .notEnough(let record, let before, let change, _) = model.phase else {
            Issue.record("expected not enough")
            return
        }
        #expect(!record.extended)
        #expect(before == 4 && change == 5)
        model.addWeek()
        await model.currentTask?.value
        let extended = try #require(ExperimentStorage(defaults: defaults).record())
        #expect(extended.extended)
        #expect(extended.dayCount == 14)
        guard case .running(_, let number, _) = model.phase else {
            Issue.record("expected running")
            return
        }
        #expect(number == 9)
        item.stop()
    }

    @Test func theExtraWeekIsOfferedOneTimeOnly() async throws {
        let store = InMemoryFeatureStore()
        try await fill(store, -20, -14, score: 3)
        try await fill(store, -13, -12, score: 4)
        let defaults = try defaults()
        // Extended: the change period is 14 days. Start at day -15 ends at day -2, so the period is over.
        save(ExperimentRecord(change: .breakEveryNinety, start: today.adding(days: -15), extended: true), in: defaults)
        let item = ExperimentExperience(defaults: defaults)
        let model = try #require(await open(item, context(store)))
        guard case .notEnough(let record, _, _, _) = model.phase else {
            Issue.record("expected not enough")
            return
        }
        #expect(record.extended)
        let before = model.phase
        model.addWeek()
        #expect(model.phase == before)
        #expect(ExperimentStorage(defaults: defaults).record()?.dayCount == 14)
        item.stop()
    }

    @Test func clearResultRemovesTheRecord() async throws {
        let store = InMemoryFeatureStore()
        try await fill(store, -14, -1, score: 3)
        let defaults = try defaults()
        save(ExperimentRecord(change: .fewerSwitches, start: today.adding(days: -7)), in: defaults)
        let item = ExperimentExperience(defaults: defaults)
        let model = try #require(await open(item, context(store)))
        model.endExperiment()
        await model.currentTask?.value
        #expect(ExperimentStorage(defaults: defaults).record() == nil)
        item.stop()
    }

    // MARK: stored data

    @Test func aRecordLeavesWhenItsWeekBeforeLeavesTheStore() async throws {
        let defaults = try defaults()
        let storage = ExperimentStorage(defaults: defaults)
        // The week before starts at day -27: the check-ins are still in the store.
        storage.save(ExperimentRecord(change: .fewerSwitches, start: today.adding(days: -20)))
        ExperimentExperience.purgeStaleRecord(today: today, defaults: defaults)
        #expect(storage.record() != nil)
        // The week before starts at day -31: the check-ins are gone.
        storage.save(ExperimentRecord(change: .fewerSwitches, start: today.adding(days: -24)))
        ExperimentExperience.purgeStaleRecord(today: today, defaults: defaults)
        #expect(storage.record() == nil)
        #expect(defaults.object(forKey: "tells.experiment.start") == nil)
        #expect(defaults.object(forKey: "tells.experiment.change") == nil)
        #expect(defaults.object(forKey: "tells.experiment.extended") == nil)
    }

    @Test func openingTheExperienceAndReadingTheStateAlsoPurge() async throws {
        let defaults = try defaults()
        let record = ExperimentRecord(change: .fewerSwitches, start: today.adding(days: -30))
        save(record, in: defaults)
        let item = ExperimentExperience(defaults: defaults)
        #expect(await item.state(in: context(InMemoryFeatureStore())) == .ready)
        #expect(ExperimentStorage(defaults: defaults).record() == nil)
        save(record, in: defaults)
        let model = try #require(await open(item, context(InMemoryFeatureStore())))
        #expect(model.phase == .choose(weekBeforeLabeled: 0))
        #expect(ExperimentStorage(defaults: defaults).record() == nil)
        item.stop()
    }

    @Test func aBadRecordIsDeleted() throws {
        let defaults = try defaults()
        defaults.set("unknownChange", forKey: "tells.experiment.change")
        defaults.set(20261122, forKey: "tells.experiment.start")
        ExperimentExperience.purgeStaleRecord(today: today, defaults: defaults)
        #expect(defaults.object(forKey: "tells.experiment.change") == nil)
        defaults.set("fewerSwitches", forKey: "tells.experiment.change")
        defaults.set(20269999, forKey: "tells.experiment.start")
        #expect(ExperimentStorage(defaults: defaults).record() == nil)
        ExperimentExperience.purgeStaleRecord(today: today, defaults: defaults)
        #expect(defaults.object(forKey: "tells.experiment.start") == nil)
    }

    @Test func deleteAllDataClearsTheRecord() throws {
        let defaults = try defaults()
        save(ExperimentRecord(change: .fewerSwitches, start: today, extended: true), in: defaults)
        ExperimentExperience.clearStoredState(defaults: defaults)
        #expect(ExperimentStorage(defaults: defaults).record() == nil)
        for key in ["change", "start", "extended"] { #expect(defaults.object(forKey: "tells.experiment.\(key)") == nil) }
    }

    // MARK: check-in gate

    @Test func noPredictionIsAskedForInAnyState() async throws {
        let real = RealModel()
        let defaults = try defaults()
        let item = ExperimentExperience(defaults: defaults)
        // No check-in today, no record: the list shows and the model is not used.
        let noToday = InMemoryFeatureStore()
        try await fill(noToday, -6, -1, score: 3)
        _ = await item.state(in: context(noToday, model: real))
        let first = try #require(await open(item, context(noToday, model: real)))
        #expect(first.phase == .choose(weekBeforeLabeled: 6))
        // Running, and finished.
        for offset in [-2, -8, -20] {
            save(ExperimentRecord(change: .noInputAfterTwentyTwo, start: today.adding(days: offset)), in: defaults)
            _ = await item.state(in: context(noToday, model: real))
            _ = await open(item, context(noToday, model: real))
        }
        #expect(real.counter.count == 0)
        item.stop()
    }

    // MARK: stop and races

    @Test func stopEndsTaskWorkAndLateActionsChangeNothing() async throws {
        let store = InMemoryFeatureStore()
        let defaults = try defaults()
        let item = ExperimentExperience(defaults: defaults)
        let model = try #require(await open(item, context(store)))
        model.start()
        let pending = try #require(model.currentTask)
        item.stop()
        item.stop()
        #expect(pending.isCancelled)
        #expect(model.currentTask == nil)
        #expect(item.currentModel == nil)
        model.choose(.fewerSwitches)
        model.startExperiment()
        model.endExperiment()
        model.addWeek()
        model.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.currentTask == nil)
        #expect(ExperimentStorage(defaults: defaults).record() == nil)
        #expect(model.selected == nil)
    }

    @Test func stopDuringLoadIgnoresTheLateResult() async throws {
        let base = InMemoryFeatureStore()
        let item = ExperimentExperience(defaults: try defaults())
        _ = item.makeView(in: context(SlowReader(base: base)))
        let model = try #require(item.currentModel)
        item.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.phase == .loading)
    }

    @Test func aNewViewStopsTheOldModel() async throws {
        let store = InMemoryFeatureStore()
        let item = ExperimentExperience(defaults: try defaults())
        _ = item.makeView(in: context(store))
        let first = try #require(item.currentModel)
        let pending = try #require(first.currentTask)
        _ = item.makeView(in: context(store))
        #expect(item.currentModel !== first)
        #expect(pending.isCancelled)
        #expect(first.currentTask == nil)
        item.stop()
    }

    // MARK: Test it from What-if

    @Test func testItSelectsTheMatchingChangeOneTime() async throws {
        let store = InMemoryFeatureStore()
        let item = ExperimentExperience(defaults: try defaults())
        item.preselect(sliderID: "lateScrolling")
        #expect(item.pending == .noInputAfterTwentyTwo)
        let first = try #require(await open(item, context(store)))
        #expect(first.selected == .noInputAfterTwentyTwo)
        #expect(item.pending == nil)
        let second = try #require(await open(item, context(store)))
        #expect(second.selected == nil)
        item.preselect(sliderID: "bedtime")
        let third = try #require(await open(item, context(store)))
        #expect(third.selected == .stopByTwentyThree)
        item.preselect(sliderID: "unknown")
        #expect(item.pending == nil)
        item.preselect(sliderID: "bedtime")
        item.stop()
        #expect(item.pending == nil)
    }
}
