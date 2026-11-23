import Foundation
import SwiftUI
import Testing
@testable import CompanionUI
import TellsCore

/// A model that is not a mock. It counts the prediction calls: the experience must make none.
private final class CountingModel: ModelProvider, @unchecked Sendable {
    let target: CheckInItem = .energy
    let featureNames: [FeatureName] = []
    let isMock = false
    let modelVersion = "real-test"
    private let lock = NSLock()
    private var count = 0
    var predictCalls: Int { lock.withLock { count } }
    func predict(_ features: FeatureVector, day: TellsDay, windowCount: Int) async -> Prediction? {
        lock.withLock { count += 1 }
        return nil
    }
}

@MainActor
private final class FakeClock {
    var seconds = 100.0
    func now() -> TimeInterval { seconds }
}

@Suite("GhostRacer", .serialized)
@MainActor
struct GhostRacerTests {
    let today = TellsDay(yyyymmdd: 20261121)

    private func midnight(_ day: TellsDay) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = DateComponents(year: day.yyyymmdd / 10_000, month: day.yyyymmdd / 100 % 100, day: day.yyyymmdd % 100)
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    private func row(day: TellsDay, at seconds: TimeInterval, keys: Double = 100, median: Double = 180, sd: Double = 60) -> FeatureRow {
        var values: FeatureVector = [:]
        for (name, value) in [("keyboard.key_count", keys), ("keyboard.iki_median_ms", median), ("keyboard.iki_sd_ms", sd)] {
            if let feature = FeatureName(name) { values[feature] = value }
        }
        return FeatureRow(sensor: .keyboard, schemaVersion: 1, windowStart: midnight(day).addingTimeInterval(seconds),
                          utcOffsetMinutes: 0, day: day, coverageSeconds: 300, values: values)
    }

    private func fillDay(_ store: InMemoryFeatureStore, _ day: TellsDay, count: Int = 12, median: Double = 180, sd: Double = 60) async throws {
        for index in 0..<count {
            try await store.save(row(day: day, at: 8 * 3600 + Double(index) * 300, median: median, sd: sd))
        }
    }

    private func checkIn(_ store: InMemoryFeatureStore, _ day: TellsDay, energy: Int) async throws {
        try await store.save(CheckIn(day: day, savedAt: Date(timeIntervalSince1970: 1), scores: [.energy: energy]))
    }

    /// 7 days that end 2 days before today. Each has a check-in and a usable typing day.
    private func fillWeek(_ store: InMemoryFeatureStore, end: TellsDay, energy: Int, median: Double = 180,
                          labeled: Int = 7, typing: Int = 7) async throws {
        for offset in 0..<7 {
            let day = end.adding(days: -offset)
            if offset < labeled { try await checkIn(store, day, energy: energy) }
            if offset < typing { try await fillDay(store, day, median: median) }
        }
    }

    private func settle(_ model: GhostRacerModel) async {
        for _ in 0..<200 where model.phase == .loading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func settleRound(_ model: GhostRacerModel, until done: (GhostRacerModel.Round) -> Bool) async {
        for _ in 0..<400 where !done(model.round) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func open(_ experience: GhostRacerExperience, _ context: InsightContext) async -> GhostRacerModel? {
        _ = experience.makeView(in: context)
        guard let model = experience.currentModel else { return nil }
        await settle(model)
        return model
    }

    private func readyModel(clock: FakeClock = FakeClock(), step: Duration = .milliseconds(5), ghost: Bool = true)
        async throws -> (GhostRacerModel, InMemoryFeatureStore) {
        let store = InMemoryFeatureStore()
        if ghost { try await fillWeek(store, end: today.adding(days: -2), energy: 4) }
        let context = InsightContext(store: store, model: CountingModel(), today: today)
        let model = GhostRacerModel(context: context, now: { clock.now() }, countdownStep: step, ghostTimeScale: 0.001)
        model.start()
        await settle(model)
        return (model, store)
    }

    private func runCountdown(_ model: GhostRacerModel) async {
        model.startRound()
        await settleRound(model) { $0 == .racing }
    }

    // MARK: text, sentences, ids

    @Test func twentySentencesOfFortyToSixtyCharactersAreUnique() {
        let sentences = GhostRacerText.sentences
        #expect(sentences.count == 20)
        #expect(Set(sentences).count == 20)
        for sentence in sentences { #expect((40...60).contains(sentence.count), "\(sentence)") }
    }

    @Test func textHasNoMedicalWordsAndNoCauses() {
        let all = ([GhostRacerText.name, GhostRacerText.practiceBanner, GhostRacerText.unreadable, GhostRacerText.start,
                    GhostRacerText.again, GhostRacerText.typeHere, GhostRacerText.intro(target: "energy"),
                    GhostRacerText.notEnoughForGhost(have: 3, need: 5, unit: "a check-in"),
                    GhostRacerText.yourTime(4.2), GhostRacerText.ghostTime(5.1)] + GhostRacerText.sentences)
            .joined(separator: " ").lowercased()
        for word in ["diagnose", "disorder", "symptom", "illness", "disease", "treatment", "therapy", "health",
                     "burnout", "depression", "anxiety", "fatigue", "sleep quality", "cause", "best week", "better score"] {
            #expect(!all.contains(word), "\(word)")
        }
        #expect(GhostRacerText.intro(target: "energy") == "The ghost types at the rhythm of your highest energy week.")
        #expect(GhostRacerText.notEnoughForGhost(have: 3, need: 5, unit: "a check-in")
                == "Not enough data for a ghost yet. 3 of 5 days with a check-in in one week.")
    }

    @Test func idAndOrderMatchSpecSection6() {
        let item = GhostRacerExperience()
        #expect(item.id == "ghostRacer")
        #expect(item.displayName == "Ghost racer")
        #expect(item.glyph == "keyboard")
        #expect(item.menuOrder == 3)
        #expect(PlaceholderExperience.all()[2].id == item.id)
        #expect(PlaceholderExperience.all()[2].displayName == item.displayName)
    }

    // MARK: reference week

    @Test func theReferenceWeekHasTheHighestMeanAndATieGoesToTheNewerWeek() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 3, median: 150)
        try await fillWeek(store, end: today.adding(days: -9), energy: 5, median: 250)
        let context = InsightContext(store: store, model: CountingModel(), today: today)
        let outcome = try await GhostLoader.load(in: context)
        // The weeks overlap by none. The week of 5s ends 9 days back, but a window slides over it too.
        guard case .ghost(let rhythm) = outcome else { Issue.record("no ghost"); return }
        #expect(rhythm.medianMs == 250)

        let tied = InMemoryFeatureStore()
        try await fillWeek(tied, end: today.adding(days: -2), energy: 4, median: 150)
        try await fillWeek(tied, end: today.adding(days: -9), energy: 4, median: 250)
        let tiedOutcome = try await GhostLoader.load(in: InsightContext(store: tied, model: CountingModel(), today: today))
        guard case .ghost(let newer) = tiedOutcome else { Issue.record("no ghost"); return }
        #expect(newer.medianMs == 150)
    }

    @Test func theGhostRhythmIsTheMedianOfTheWeeksTypingWindows() async throws {
        let store = InMemoryFeatureStore()
        for offset in 0..<7 {
            let day = today.adding(days: -2 - offset)
            try await checkIn(store, day, energy: 4)
            try await fillDay(store, day, median: 100 + Double(offset) * 10, sd: 50 + Double(offset))
        }
        let outcome = try await GhostLoader.load(in: InsightContext(store: store, model: CountingModel(), today: today))
        // The 7 days end 2 days back. The newer week (it ends 1 day back) has 6 of them and the same mean, so it wins.
        // Its windows have medians 100 to 150 and variations 50 to 55.
        #expect(outcome == .ghost(GhostRhythm(medianMs: 125, sdMs: 52.5)))
    }

    @Test func todayAndWindowsWithFewKeysDoNotCount() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 4, median: 180)
        try await fillDay(store, today, median: 999)
        try await checkIn(store, today, energy: 5)
        for index in 0..<30 { try await store.save(row(day: today.adding(days: -3), at: 20 * 3600 + Double(index) * 300, keys: 5, median: 777)) }
        let outcome = try await GhostLoader.load(in: InsightContext(store: store, model: CountingModel(), today: today))
        guard case .ghost(let rhythm) = outcome else { Issue.record("no ghost"); return }
        #expect(rhythm.medianMs == 180)
    }

    @Test func aWeekNeedsFiveLabeledDaysAndThreeTypingDays() async throws {
        let few = InMemoryFeatureStore()
        try await fillWeek(few, end: today.adding(days: -2), energy: 4, labeled: 3, typing: 7)
        let fewOutcome = try await GhostLoader.load(in: InsightContext(store: few, model: CountingModel(), today: today))
        #expect(fewOutcome == .notEnough(have: 3, need: 5, unit: "a check-in"))

        let noTyping = InMemoryFeatureStore()
        try await fillWeek(noTyping, end: today.adding(days: -2), energy: 4, labeled: 7, typing: 2)
        let typingOutcome = try await GhostLoader.load(in: InsightContext(store: noTyping, model: CountingModel(), today: today))
        #expect(typingOutcome == .notEnough(have: 2, need: 3, unit: "typing"))

        let exact = InMemoryFeatureStore()
        try await fillWeek(exact, end: today.adding(days: -2), energy: 4, labeled: 5, typing: 3)
        let exactOutcome = try await GhostLoader.load(in: InsightContext(store: exact, model: CountingModel(), today: today))
        #expect(exactOutcome == .ghost(GhostRhythm(medianMs: 180, sdMs: 60)))
    }

    @Test func oldDaysBeyondThirtyAndOtherItemsDoNotMakeAWeek() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -31), energy: 5)   // too old
        for offset in 0..<7 {                                                  // another item
            let day = today.adding(days: -2 - offset)
            try await store.save(CheckIn(day: day, savedAt: Date(timeIntervalSince1970: 1), scores: [.mood: 5]))
            try await fillDay(store, day)
        }
        let outcome = try await GhostLoader.load(in: InsightContext(store: store, model: CountingModel(), today: today))
        guard case .notEnough(_, let need, let unit) = outcome else { Issue.record("a ghost"); return }
        #expect(need == 5 && unit == "a check-in")
    }

    @Test func theWeekUsesTheDayLogicOfTheRowNotTheClock() async throws {
        let store = InMemoryFeatureStore()
        // A row at 02:00 belongs to the row's own `day` (the window clock sets it with the 04:00 boundary, DEC-3).
        let day = today.adding(days: -2)
        try await store.save(row(day: day, at: 26 * 3600, median: 180))
        let rows = try await store.featureRows(.keyboard, in: DateInterval(start: .distantPast, end: .distantFuture))
        #expect(GhostWeek.group(rows)[day]?.typingCount == 1)
    }

    // MARK: ghost

    @Test func theGhostIsTheSameEachTimeAndDiffersBetweenSentences() {
        let rhythm = GhostRhythm(medianMs: 180, sdMs: 60)
        #expect(rhythm.steps(count: 45, seed: 7) == rhythm.steps(count: 45, seed: 7))
        #expect(rhythm.steps(count: 45, seed: 7) != rhythm.steps(count: 45, seed: 8))
        #expect(GhostRacerModel.seed(for: 1) != GhostRacerModel.seed(for: 2))
    }

    @Test func aStepIsNeverUnderTheMinimumAndTimesRise() {
        let rhythm = GhostRhythm(medianMs: 40, sdMs: 500)
        let steps = rhythm.steps(count: 200, seed: 3)
        #expect(steps.allSatisfy { $0 >= 0.03 })
        let times = rhythm.finishTimes(count: 200, seed: 3)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
        let flat = GhostRhythm(medianMs: 200, sdMs: 0).finishTimes(count: 5, seed: 1)
        #expect(flat.last.map { abs($0 - 1.0) < 1e-9 } == true)
    }

    // MARK: states

    @Test func practiceStateWithTheMockModelAndData() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 4)
        let state = await GhostRacerExperience().state(in: InsightContext(store: store, model: MockModelProvider(), today: today))
        #expect(state == .practice)
    }

    @Test func readyStateWithARealModelAndData() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 4)
        let state = await GhostRacerExperience().state(in: InsightContext(store: store, model: CountingModel(), today: today))
        #expect(state == .ready)
    }

    @Test func notEnoughDataStateNamesTheDays() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 4, labeled: 3)
        let item = GhostRacerExperience()
        #expect(await item.state(in: InsightContext(store: store, model: CountingModel(), today: today))
                == .notEnoughData(have: 3, need: 5, unit: "days"))
        #expect(await item.state(in: InsightContext(store: InMemoryFeatureStore(), model: MockModelProvider(), today: today))
                == .notEnoughData(have: 0, need: 5, unit: "days"))
    }

    @Test func anUnreadableStoreShowsItsOwnState() async throws {
        struct Broken: FeatureReader {
            struct Failure: Error {}
            func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow] { throw Failure() }
            func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow] { throw Failure() }
            func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary] { throw Failure() }
            func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn] { throw Failure() }
        }
        let item = GhostRacerExperience()
        let model = try #require(await open(item, InsightContext(store: Broken(), model: CountingModel(), today: today) { _ in }))
        #expect(model.phase == .unreadable)
        item.stop()
    }

    @Test func practiceViewUsesMockModelAndRealDataShowsRealValues() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 4, median: 210)
        let mockItem = GhostRacerExperience()
        let mock = try #require(await open(mockItem, InsightContext(store: store, model: MockModelProvider(), today: today)))
        #expect(mock.isPractice)
        mockItem.stop()
        let realItem = GhostRacerExperience()
        let real = try #require(await open(realItem, InsightContext(store: store, model: CountingModel(), today: today)))
        #expect(!real.isPractice)
        #expect(real.target == "energy")
        #expect(real.rhythm == GhostRhythm(medianMs: 210, sdMs: 60))
        realItem.stop()
    }

    @Test func noPredictionIsReadAndNothingIsSaved() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 4)
        let counting = CountingModel()
        let item = GhostRacerExperience()
        let context = InsightContext(store: store, model: counting, today: today)
        _ = await item.state(in: context)
        let model = try #require(await open(item, context))
        await runCountdown(model)
        #expect(counting.predictCalls == 0)
        item.stop()
        let defaults = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.lowercased().contains("ghost") }
        #expect(defaults.isEmpty)
    }

    // MARK: race

    @Test func theRaceCountsDownThenRunsAndFinishesWithBothTimes() async throws {
        let clock = FakeClock()
        let (model, _) = try await readyModel(clock: clock)
        #expect(model.round == .idle)
        model.startRound()
        #expect(model.round == .countdown(3))
        await settleRound(model) { $0 == .racing }
        #expect(model.round == .racing)
        clock.seconds += 2.5
        for (offset, character) in model.sentence.enumerated() {
            clock.seconds += 0.05
            model.setTyped(String(model.sentence.prefix(offset + 1)))
            #expect(offset + 1 == model.sentenceCount || model.round == .racing)
            _ = character
        }
        guard case .finished(let result) = model.round else { Issue.record("not finished"); return }
        #expect(abs(result.yourSeconds - (2.5 + 0.05 * Double(model.sentenceCount))) < 1e-6)
        let expectedGhost = model.rhythm?.finishTimes(count: model.sentenceCount, seed: GhostRacerModel.seed(for: model.sentenceIndex)).last
        #expect(result.ghostSeconds == expectedGhost)
        #expect(model.typed.isEmpty)       // the round ended: the typed characters are gone
    }

    @Test func withoutAGhostTheUserTimeShowsAlone() async throws {
        let clock = FakeClock()
        let (model, _) = try await readyModel(clock: clock, ghost: false)
        #expect(model.rhythm == nil)
        await runCountdown(model)
        clock.seconds += 4
        model.setTyped(String(model.sentence.prefix(1)))
        for count in 2...model.sentenceCount { model.setTyped(String(model.sentence.prefix(count))) }
        guard case .finished(let result) = model.round else { Issue.record("not finished"); return }
        #expect(result.ghostSeconds == nil)
        #expect(abs(result.yourSeconds - 4) < 1e-6)
    }

    @Test func rightAndWrongCharactersAreColoredAndAPasteIsIgnored() async throws {
        let (model, _) = try await readyModel()
        await runCountdown(model)
        let sentence = Array(model.sentence)
        let wrong = sentence[1] == "x" ? "y" : "x"
        model.setTyped(String(sentence[0]))
        model.setTyped(String(sentence[0]) + wrong)
        #expect(model.correctness(at: 0) == true)
        #expect(model.correctness(at: 1) == false)
        #expect(model.correctness(at: 2) == nil)
        model.setTyped(model.sentence)                        // a paste
        #expect(model.round == .racing)
        #expect(model.typed.count == 2)
        model.setTyped(model.sentence + "z")                  // too long
        #expect(model.typed.count == 2)
    }

    @Test func typingBeforeTheRaceOrAfterItChangesNothing() async throws {
        let (model, _) = try await readyModel()
        model.setTyped("T")
        #expect(model.typed.isEmpty)
        model.startRound()
        model.setTyped("T")
        #expect(model.typed.isEmpty)
        await settleRound(model) { $0 == .racing }
    }

    @Test func againShowsANewSentenceAndClearsTheRound() async throws {
        let (model, _) = try await readyModel()
        let first = model.sentence
        model.again()                                         // not finished: no effect
        #expect(model.sentence == first)
        await runCountdown(model)
        for count in 1...model.sentenceCount { model.setTyped(String(model.sentence.prefix(count))) }
        guard case .finished = model.round else { Issue.record("not finished"); return }
        model.again()
        #expect(model.round == .idle)
        #expect(model.sentence != first)
        #expect(model.typed.isEmpty)
    }

    @Test func theGhostWalksAlongTheSentenceAndThenTheFrameTimerStops() async throws {
        let clock = FakeClock()
        let (model, _) = try await readyModel(clock: clock)
        await runCountdown(model)
        #expect(model.ghostPosition(elapsed: 0) == 0)
        #expect(model.ghostPosition(elapsed: 1_000) == model.sentenceCount)
        let times = try #require(model.rhythm).finishTimes(count: model.sentenceCount, seed: GhostRacerModel.seed(for: model.sentenceIndex))
        #expect(model.ghostPosition(elapsed: times[9] + 0.0001) == 10)
        await settleRound(model, until: { _ in model.ghostDone })
        #expect(model.ghostDone)
    }

    // MARK: stop

    @Test func stopEndsAllTaskWorkAndClearsTheTypedText() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 4)
        let item = GhostRacerExperience()
        let model = try #require(await open(item, InsightContext(store: store, model: CountingModel(), today: today)))
        await runCountdown(model)
        model.setTyped(String(model.sentence.prefix(1)))
        let roundTask = try #require(model.currentRoundTask)
        item.stop()
        item.stop()
        #expect(roundTask.isCancelled)
        #expect(model.currentRoundTask == nil)
        #expect(model.currentLoadTask == nil)
        #expect(model.typed.isEmpty)
        #expect(model.round == .idle)
        #expect(item.currentModel == nil)
        // Late input, a late start and a late load change nothing.
        model.setTyped("T")
        model.startRound()
        model.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.typed.isEmpty)
        #expect(model.round == .idle)
        #expect(model.currentRoundTask == nil && model.currentLoadTask == nil)
    }

    @Test func stopDuringTheCountdownEndsItWithNoRace() async throws {
        let (model, _) = try await readyModel(step: .milliseconds(30))
        model.startRound()
        let task = try #require(model.currentRoundTask)
        model.stop()
        #expect(task.isCancelled)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.round == .idle)
        #expect(model.currentRoundTask == nil)
    }

    @Test func stopDuringLoadIgnoresTheLateResult() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 4)
        let item = GhostRacerExperience()
        _ = item.makeView(in: InsightContext(store: store, model: CountingModel(), today: today))
        let model = try #require(item.currentModel)
        item.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .loading)
    }

    @Test func aNewViewStopsTheOldRound() async throws {
        let store = InMemoryFeatureStore()
        try await fillWeek(store, end: today.adding(days: -2), energy: 4)
        let item = GhostRacerExperience()
        let context = InsightContext(store: store, model: CountingModel(), today: today)
        let old = try #require(await open(item, context))
        await runCountdown(old)
        old.setTyped(String(old.sentence.prefix(1)))
        _ = item.makeView(in: context)
        #expect(old.typed.isEmpty)
        #expect(old.round == .idle)
        #expect(item.currentModel !== old)
        item.stop()
    }
}
