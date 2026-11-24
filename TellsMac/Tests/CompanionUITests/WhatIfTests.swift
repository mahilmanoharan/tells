import Foundation
import SwiftUI
import Testing
@testable import CompanionUI
import TellsCore

private let sleepName = FeatureName("activity.sleep_start_min")
private let lateName = FeatureName("activity.late_input_min")

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A model that is not a mock. A fixed linear function, so a test knows the answer.
private struct LinearModel: ModelProvider {
    let target: CheckInItem = .energy
    let featureNames: [FeatureName]
    let isMock = false
    let modelVersion = "linear-test"
    let counter = Counter()
    let delayMs: Int

    init(featureNames: [FeatureName?] = [sleepName, lateName], delayMs: Int = 0) {
        self.featureNames = featureNames.compactMap { $0 }
        self.delayMs = delayMs
    }

    func predict(_ features: FeatureVector, day: TellsDay, windowCount: Int) async -> Prediction? {
        counter.increment()
        if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
        guard windowCount >= DataThreshold.minimumWindowsToday else { return nil }
        var value = 4.0
        for name in featureNames {
            guard let feature = features[name] else { return nil }
            value -= 0.01 * feature
        }
        return Prediction(day: day, target: target, value: value)
    }
}

/// Gives fixed day features when the day has rows. The window count comes from the rows of today.
private struct StubExtractor: FeatureExtractor {
    let sensor: SensorID = .activity
    let schemaVersion = 1
    let windowFeatures: [FeatureName] = []
    let dayFeatures: [FeatureName] = []
    let values: FeatureVector
    func extractWindow(_ samples: [SensorSample], window: DateInterval) -> FeatureVector { [:] }
    func extractDay(_ rows: [FeatureRow], day: TellsDay) -> FeatureVector {
        rows.contains { $0.day == day } ? values : [:]
    }
}

@Suite("WhatIf", .serialized)
@MainActor
struct WhatIfTests {
    let today = TellsDay(yyyymmdd: 20261121)

    private func vector(sleep: Double?, late: Double?) -> FeatureVector {
        var result: FeatureVector = [:]
        if let sleepName, let sleep { result[sleepName] = sleep }
        if let lateName, let late { result[lateName] = late }
        return result
    }

    private func experience(sleep: Double? = 30, late: Double? = 20) -> WhatIfExperience {
        WhatIfExperience(extractors: [StubExtractor(values: vector(sleep: sleep, late: late))])
    }

    private func midnight() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 21)) ?? Date(timeIntervalSince1970: 0)
    }

    private func fillWindows(_ store: InMemoryFeatureStore, count: Int = 12) async throws {
        for index in 0..<count {
            let start = midnight().addingTimeInterval(8 * 3600 + Double(index) * 300)
            try await store.save(FeatureRow(sensor: .activity, schemaVersion: 1, windowStart: start, utcOffsetMinutes: 0,
                                            day: today, coverageSeconds: 300, values: [:]))
        }
    }

    /// Past days 1...days. Sleep 10, 20, ... and late 5, 10, ...
    private func fillDaily(_ store: InMemoryFeatureStore, sleepDays: Int = 10, lateDays: Int = 10, flat: Bool = false) async throws {
        for index in 1...10 {
            var values: FeatureVector = [:]
            if let sleepName, index <= sleepDays { values[sleepName] = flat ? 50 : Double(index * 10) }
            if let lateName, index <= lateDays { values[lateName] = Double(index * 5) }
            try await store.save(DailyRow(day: today.adding(days: -index), schemaVersions: [:], values: values))
        }
    }

    private func saveCheckIn(_ store: InMemoryFeatureStore, energy: Int? = 3) async throws {
        let scores: [CheckInItem: Int] = energy.map { [.energy: $0] } ?? [.mood: 3]
        try await store.save(CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 1), scores: scores))
    }

    private func settle(_ model: WhatIfModel) async {
        for _ in 0..<300 where model.phase == .loading { try? await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where model.phase == .ready && model.curve.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func open(_ experience: WhatIfExperience, _ context: InsightContext) async -> WhatIfModel? {
        _ = experience.makeView(in: context)
        guard let model = experience.currentModel else { return nil }
        await settle(model)
        return model
    }

    private func fullStore(checkIn: Bool = true, windows: Int = 12) async throws -> InMemoryFeatureStore {
        let store = InMemoryFeatureStore()
        try await fillWindows(store, count: windows)
        try await fillDaily(store)
        if checkIn { try await saveCheckIn(store) }
        return store
    }

    // MARK: identity and text

    @Test func idAndOrderMatchTheSpec() {
        let experience = WhatIfExperience()
        #expect(experience.id == "whatIf")
        #expect(experience.menuOrder == 4)
        #expect(experience.displayName == "What-if sliders")
    }

    @Test func clockAndLabelsUseTheDayBoundary() {
        #expect(WhatIfSliderKind.clock(30) == "00:30")
        #expect(WhatIfSliderKind.clock(-60) == "23:00")
        #expect(WhatIfSliderKind.clock(1440 + 15) == "00:15")
        #expect(WhatIfSliderKind.lateScrolling.label(20.4) == "20 min")
    }

    @Test func summaryFollowsTheSpecText() {
        let text = WhatIfText.summary(target: "energy", kind: .bedtime, sliderValue: -60, atSlider: 3.8,
                                      startValue: 30, atStart: 3.4, usesToday: true, checkInScore: 3)
        #expect(text == "The model predicts an energy check-in of 3.8 with a 23:00 bedtime. With today's 00:30 bedtime, it predicts 3.4. Your energy check-in today was 3.")
        let mood = WhatIfText.summary(target: "mood", kind: .bedtime, sliderValue: nil, atSlider: nil,
                                      startValue: 30, atStart: 3.4, usesToday: true, checkInScore: nil)
        #expect(mood == "With today's 00:30 bedtime, the model predicts a mood check-in of 3.4.")
    }

    @Test func textHasNoMedicalWordsAndSaysPredictsNotCauses() {
        let all = [WhatIfText.practiceBanner, WhatIfText.unreadable, WhatIfText.notEnoughToday, WhatIfText.unusedModel,
                   WhatIfText.noRange, WhatIfText.disclaimer, WhatIfText.notEnoughDays(have: 4, need: 7),
                   WhatIfText.windowsProgress(have: 3, need: 12),
                   WhatIfText.summary(target: "energy", kind: .lateScrolling, sliderValue: 40, atSlider: 3.1,
                                      startValue: 20, atStart: 3.5, usesToday: false, checkInScore: 2)]
            .joined(separator: " ").lowercased()
        for word in ["diagnose", "disorder", "symptom", "illness", "disease", "treatment", "therapy", "health",
                     "burnout", "depression", "anxiety", "fatigue", "sleep quality", "causes", "improve"] {
            #expect(!all.contains(word), "\(word)")
        }
        #expect(all.contains("predicts"))
        #expect(WhatIfText.disclaimer.hasSuffix("To test a change, use Experiment."))
    }

    // MARK: states

    @Test func practiceStateWithTheMockModelAndReadyWithARealModel() async throws {
        let store = try await fullStore()
        let experience = experience()
        let mock = InsightContext(store: store, model: MockModelProvider(), today: today)
        let real = InsightContext(store: store, model: LinearModel(), today: today)
        #expect(await experience.state(in: mock) == .practice)
        #expect(await experience.state(in: real) == .ready)
    }

    @Test func notEnoughDataWithoutAPredictionToday() async throws {
        let store = try await fullStore(windows: 5)
        let experience = experience()
        let context = InsightContext(store: store, model: LinearModel(), today: today)
        #expect(await experience.state(in: context) == .notEnoughData(have: 5, need: 12, unit: "windows"))
        let model = try #require(await open(experience, context))
        #expect(model.phase == .noPrediction(windows: 5))
        experience.stop()
    }

    @Test func notEnoughDataWhenTheModelUsesNoSliderFeature() async throws {
        let store = try await fullStore()
        let experience = experience()
        let context = InsightContext(store: store, model: LinearModel(featureNames: []), today: today)
        #expect(await experience.state(in: context) == .notEnoughData(have: 0, need: 1, unit: "slider features"))
        let model = try #require(await open(experience, context))
        #expect(model.phase == .unusedModel)
        #expect(model.curve.isEmpty)
        experience.stop()
    }

    @Test func notEnoughDataWithFewerThan7Days() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        try await fillDaily(store, sleepDays: 4, lateDays: 4)
        try await saveCheckIn(store)
        let experience = experience()
        let context = InsightContext(store: store, model: LinearModel(), today: today)
        #expect(await experience.state(in: context) == .notEnoughData(have: 4, need: 7, unit: "days"))
        let model = try #require(await open(experience, context))
        #expect(model.phase == .notEnoughDays(have: 4))
        experience.stop()
    }

    @Test func aSliderWithFewerThan7DaysIsHidden() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        try await fillDaily(store, sleepDays: 10, lateDays: 4)
        try await saveCheckIn(store)
        let experience = experience()
        let context = InsightContext(store: store, model: MockModelProvider(), today: today)
        let model = try #require(await open(experience, context))
        #expect(model.phase == .ready)
        #expect(model.sliders == [.bedtime])
        experience.stop()
    }

    @Test func aFlatRangeShowsNoSlider() async throws {
        let store = InMemoryFeatureStore()
        try await fillWindows(store)
        try await fillDaily(store, lateDays: 0, flat: true)
        try await saveCheckIn(store)
        let experience = experience(sleep: 50, late: nil)
        let context = InsightContext(store: store, model: LinearModel(featureNames: [sleepName]), today: today)
        #expect(await experience.state(in: context) == .notEnoughData(have: 1, need: 2, unit: "different values"))
        let model = try #require(await open(experience, context))
        #expect(model.phase == .noRange)
        experience.stop()
    }

    // MARK: check-in before prediction

    @Test func noPredictionCallBeforeTheCheckIn() async throws {
        let store = try await fullStore(checkIn: false)
        let linear = LinearModel()
        let experience = experience()
        let context = InsightContext(store: store, model: linear, today: today)
        #expect(await experience.state(in: context) == .ready)
        let model = try #require(await open(experience, context))
        #expect(model.phase == .checkIn)
        #expect(model.checkInModel != nil)
        #expect(model.curve.isEmpty)
        #expect(model.summaryText == nil)
        #expect(linear.counter.count == 0)
        try await saveCheckIn(store)
        model.start()
        for _ in 0..<300 where model.phase == .checkIn { try await Task.sleep(for: .milliseconds(10)) }
        await settle(model)
        #expect(model.phase == .ready)
        #expect(linear.counter.count > 0)
        experience.stop()
    }

    // MARK: practice and real values

    @Test func mockModelShowsThePracticeStateWithMockValues() async throws {
        let store = try await fullStore()
        let experience = experience()
        let context = InsightContext(store: store, model: MockModelProvider(), today: today)
        let model = try #require(await open(experience, context))
        #expect(model.isPractice)
        #expect(model.phase == .ready)
        #expect(model.sliders == [.bedtime, .lateScrolling])
        #expect(model.curve.count == 21)
        let expected = 4.0 - 0.002 * 30 - 0.01 * 20
        #expect(abs((model.baseline ?? 0) - expected) < 1e-9)
        #expect(abs((model.predictionAtValue ?? 0) - expected) < 1e-9)
        experience.stop()
    }

    @Test func realDataShowsRealValuesAndTheSliderMovesThePoint() async throws {
        let store = try await fullStore()
        let experience = experience()
        let context = InsightContext(store: store, model: LinearModel(), today: today)
        let model = try #require(await open(experience, context))
        #expect(!model.isPractice)
        #expect(model.selected == .bedtime)
        #expect(model.range == 10...100)
        #expect(model.value == 30)
        #expect(abs((model.baseline ?? 0) - (4.0 - 0.3 - 0.2)) < 1e-9)
        #expect(abs((model.curve.first?.y ?? 0) - (4.0 - 0.1 - 0.2)) < 1e-9)
        #expect(abs((model.curve.last?.y ?? 0) - (4.0 - 1.0 - 0.2)) < 1e-9)
        model.setValue(80)
        await model.currentPointTask?.value
        #expect(abs((model.predictionAtValue ?? 0) - (4.0 - 0.8 - 0.2)) < 1e-9)
        let text = try #require(model.summaryText)
        #expect(text.contains("predicts"))
        #expect(text.contains("Your energy check-in today was 3."))
        model.reset()
        await model.currentPointTask?.value
        #expect(model.value == 30)
        #expect(abs((model.predictionAtValue ?? 0) - 3.5) < 1e-9)
        experience.stop()
    }

    @Test func theSliderStaysInsideTheUsersRange() async throws {
        let store = try await fullStore()
        let experience = experience()
        let context = InsightContext(store: store, model: LinearModel(), today: today)
        let model = try #require(await open(experience, context))
        model.setValue(5000)
        #expect(model.value == 100)
        model.setValue(-5000)
        #expect(model.value == 10)
        experience.stop()
    }

    @Test func aMissingTodayValueStartsAtTheMedian() async throws {
        let store = try await fullStore()
        let experience = experience(sleep: nil, late: 20)
        let context = InsightContext(store: store, model: LinearModel(featureNames: [sleepName, lateName]), today: today)
        let model = try #require(await open(experience, context))
        #expect(model.phase == .ready)
        #expect(model.value == 55)      // the median of 10...100 in steps of 10
        #expect(model.summaryText?.contains("your usual") == true)
        experience.stop()
    }

    @Test func theCheckInWithoutATargetScoreDropsThatSentence() async throws {
        let store = try await fullStore(checkIn: false)
        try await saveCheckIn(store, energy: nil)
        let experience = experience()
        let context = InsightContext(store: store, model: LinearModel(), today: today)
        let model = try #require(await open(experience, context))
        #expect(model.phase == .ready)
        #expect(model.summaryText?.contains("check-in today was") == false)
        experience.stop()
    }

    // MARK: test it and stop

    @Test func testItGivesTheSliderIdUntilStop() async throws {
        let store = try await fullStore()
        let experience = experience()
        var opened: [String] = []
        experience.openExperiment = { opened.append($0) }
        let context = InsightContext(store: store, model: LinearModel(), today: today)
        let model = try #require(await open(experience, context))
        model.testIt()
        model.select(.lateScrolling)
        model.testIt()
        #expect(opened == ["bedtime", "lateScrolling"])
        experience.stop()
        model.testIt()
        #expect(opened.count == 2)
    }

    @Test func stopEndsAllTaskWorkAndALateResultChangesNothing() async throws {
        let store = try await fullStore()
        let experience = experience()
        let context = InsightContext(store: store, model: LinearModel(delayMs: 20), today: today)
        _ = experience.makeView(in: context)
        let model = try #require(experience.currentModel)
        for _ in 0..<300 where model.phase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .ready)
        #expect(model.currentCurveTask != nil)
        experience.stop()
        #expect(experience.currentModel == nil)
        #expect(model.currentTask == nil)
        #expect(model.currentCurveTask == nil)
        #expect(model.currentPointTask == nil)
        let before = model.value
        model.setValue(90)
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.curve.isEmpty)
        #expect(model.value == before)
    }

    @Test func stopDuringTheLoadKeepsThePhase() async throws {
        let store = try await fullStore()
        let experience = experience()
        let context = InsightContext(store: store, model: LinearModel(), today: today)
        _ = experience.makeView(in: context)
        let model = try #require(experience.currentModel)
        experience.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.phase == .loading)
        #expect(model.curve.isEmpty)
    }
}
