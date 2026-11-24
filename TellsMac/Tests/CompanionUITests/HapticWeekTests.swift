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

@MainActor
private final class FakeHaptics: HapticPlaying {
    var isAvailable = true
    var bumpCount = 0
    var stopCount = 0
    func bump() { bumpCount += 1 }
    func stop() { stopCount += 1 }
}

@Suite("HapticWeek", .serialized)
@MainActor
struct HapticWeekTests {
    // Saturday 2026-11-21.
    let today = TellsDay(yyyymmdd: 20261121)

    private func save(_ store: InMemoryFeatureStore, offsets: [Int: Int], item: CheckInItem = .energy) async throws {
        for (offset, score) in offsets {
            try await store.save(CheckIn(day: today.adding(days: offset), savedAt: Date(timeIntervalSince1970: 1),
                                         scores: [item: score]))
        }
    }

    /// 30 days of score 4, except the week days given in `week` (offset from today, 0 to -6).
    private func store(week: [Int: Int]) async throws -> InMemoryFeatureStore {
        let store = InMemoryFeatureStore()
        var scores: [Int: Int] = [:]
        for offset in -29...0 { scores[offset] = 4 }
        for (offset, score) in week { scores[offset] = score }
        try await save(store, offsets: scores)
        return store
    }

    private func open(_ experience: HapticWeekExperience, _ context: InsightContext) async -> HapticWeekModel? {
        _ = experience.makeView(in: context)
        guard let model = experience.currentModel else { return nil }
        for _ in 0..<300 where model.phase == .loading { try? await Task.sleep(for: .milliseconds(10)) }
        return model
    }

    private func context(_ store: InMemoryFeatureStore, model: any ModelProvider = RealModel()) -> InsightContext {
        InsightContext(store: store, model: model, today: today)
    }

    // MARK: identity and text

    @Test func idAndOrderMatchTheSpec() {
        let item = HapticWeekExperience(player: FakeHaptics())
        #expect(item.id == "hapticWeek")
        #expect(item.menuOrder == 5)
        #expect(item.displayName == "Haptic week")
    }

    @Test func weekdayNamesFollowTheCalendarDay() {
        #expect(HapticWeekText.weekday(today) == "Saturday")
        #expect(HapticWeekText.weekday(today.adding(days: -4)) == "Tuesday")
        #expect(HapticWeekText.columnLabel(target: "energy", weekday: "Tuesday", score: 2, isLow: true)
            == "Tuesday, energy check-in 2, low day")
        #expect(HapticWeekText.columnLabel(target: "energy", weekday: "Tuesday", score: nil, isLow: false)
            == "Tuesday, no check-in")
    }

    @Test func textHasNoMedicalWordsAndNoBadDay() {
        let all = [HapticWeekText.practiceBanner, HapticWeekText.unreadable, HapticWeekText.explanation,
                   HapticWeekText.noTrackpad, HapticWeekText.notEnoughWeek(have: 3, need: 4),
                   HapticWeekText.notEnoughMonth(have: 5, need: 7), HapticWeekText.average(3.4),
                   HapticWeekText.dayLine(target: "energy", weekday: "Monday", score: 2),
                   HapticWeekText.dayLine(target: "energy", weekday: "Monday", score: nil)]
            .joined(separator: " ").lowercased()
        for word in ["diagnose", "disorder", "symptom", "illness", "disease", "treatment", "therapy", "health",
                     "burnout", "depression", "anxiety", "fatigue", "sleep quality", "causes", "bad day"] {
            #expect(!all.contains(word), "\(word)")
        }
        #expect(HapticWeekText.explanation == "Bumps show days with a check-in 1 point or more below your 30-day average.")
        #expect(HapticWeekText.notEnoughWeek(have: 3, need: 4) == "Not enough check-ins this week. 3 of 4 days.")
        #expect(HapticWeekText.notEnoughMonth(have: 5, need: 7) == "Not enough check-ins to make an average. 5 of 7 days.")
    }

    // MARK: rules

    @Test func lowDaysAreOnePointBelowTheAverageAndTheLowestGivesTwoBumps() async throws {
        // 30-day scores: 23 days of 4, plus week: -1 is 3, -2 is 1, -3 is 1, others 4. Mean is about 3.8.
        let store = try await store(week: [-1: 3, -2: 1, -3: 1])
        let content = try await HapticWeekLoader.load(in: context(store))
        #expect(content.status == .ready)
        #expect(content.days.count == 7)
        #expect(content.days.first?.day == today.adding(days: -6))
        #expect(content.days.last?.day == today)
        let byOffset = Dictionary(uniqueKeysWithValues: content.days.enumerated().map { (index, day) in (index - 6, day) })
        #expect(byOffset[0]?.bumps == 0)
        #expect(byOffset[-1]?.isLow == false)      // 3 is under 1 point below 3.8
        #expect(byOffset[-2]?.bumps == 2)
        #expect(byOffset[-3]?.bumps == 2)          // a tie: both give two bumps
    }

    @Test func exactlyOnePointBelowCountsAndLessDoesNot() {
        // Mean 3.0 over 8 days: 4 labeled days of 3 and the rest set so the mean is 3.0.
        let checkIns = [(0, 4), (-1, 2), (-2, 3), (-3, 3), (-4, 3), (-5, 3), (-6, 3), (-7, 3)].map { offset, score in
            CheckIn(day: today.adding(days: offset), savedAt: Date(timeIntervalSince1970: 1), scores: [.energy: score])
        }
        let content = HapticWeekRules.build(checkIns: checkIns, target: .energy, today: today)
        #expect(content.mean == 24.0 / 8.0)
        let two = content.days.first { $0.day == today.adding(days: -1) }
        #expect(two?.isLow == true)                // 2 is exactly 1 below 3.0
        #expect(content.days.filter(\.isLow).count == 1)
    }

    @Test func dayBoundariesOfTheThirtyDaysAndTheWeekUseTheTellsDay() {
        var checkIns: [CheckIn] = []
        for offset in -29...0 {
            checkIns.append(CheckIn(day: today.adding(days: offset), savedAt: Date(timeIntervalSince1970: 1), scores: [.energy: 4]))
        }
        // Day -30 and day +1 are not in the average.
        checkIns.append(CheckIn(day: today.adding(days: -30), savedAt: Date(timeIntervalSince1970: 1), scores: [.energy: 1]))
        checkIns.append(CheckIn(day: today.adding(days: 1), savedAt: Date(timeIntervalSince1970: 1), scores: [.energy: 1]))
        let content = HapticWeekRules.build(checkIns: checkIns, target: .energy, today: today)
        #expect(content.monthLabeled == 30)
        #expect(content.mean == 4.0)
    }

    @Test func checkInsOfAnotherItemDoNotCount() async throws {
        let store = InMemoryFeatureStore()
        try await save(store, offsets: Dictionary(uniqueKeysWithValues: (-29...0).map { ($0, 3) }), item: .mood)
        let content = try await HapticWeekLoader.load(in: context(store))
        #expect(content.weekLabeled == 0)
        #expect(content.status == .notEnoughWeek(have: 0))
    }

    // MARK: states

    @Test func practiceStateWithTheMockModelAndReadyWithARealModelWithRealValues() async throws {
        let store = try await store(week: [-2: 1])
        let item = HapticWeekExperience(player: FakeHaptics())
        #expect(await item.state(in: context(store, model: MockModelProvider())) == .practice)
        #expect(await item.state(in: context(store)) == .ready)
        let model = try #require(await open(item, context(store, model: MockModelProvider())))
        #expect(model.isPractice)
        let content = try #require(model.content)
        #expect(content.days.first { $0.day == today.adding(days: -2) }?.score == 1)
        #expect(content.days.first { $0.day == today.adding(days: -2) }?.isLowest == true)
        item.stop()
    }

    @Test func notEnoughDataWithFewerThanFourDaysThisWeek() async throws {
        let store = InMemoryFeatureStore()
        var scores: [Int: Int] = [:]
        for offset in -29...(-7) { scores[offset] = 4 }
        for offset in [0, -1, -2] { scores[offset] = 4 }
        try await save(store, offsets: scores)
        let item = HapticWeekExperience(player: FakeHaptics())
        #expect(await item.state(in: context(store)) == .notEnoughData(have: 3, need: 4, unit: "days"))
        let model = try #require(await open(item, context(store)))
        #expect(model.content?.status == .notEnoughWeek(have: 3))
        #expect(model.content?.days.allSatisfy { !$0.isLow && $0.bumps == 0 } == true)
        item.stop()
    }

    @Test func notEnoughDataWithFewerThanSevenDaysInThirtyDays() async throws {
        let store = InMemoryFeatureStore()
        try await save(store, offsets: [0: 4, -1: 4, -2: 4, -3: 4, -4: 2])
        let item = HapticWeekExperience(player: FakeHaptics())
        #expect(await item.state(in: context(store)) == .notEnoughData(have: 5, need: 7, unit: "days"))
        let model = try #require(await open(item, context(store)))
        #expect(model.content?.status == .notEnoughMonth(have: 5))
        #expect(model.content?.days.allSatisfy { !$0.isLow } == true)
        item.stop()
    }

    @Test func notOnThisMacWhenThereIsNoTrackpad() async throws {
        let store = try await store(week: [-2: 1])
        let player = FakeHaptics()
        player.isAvailable = false
        let item = HapticWeekExperience(player: player)
        #expect(await item.state(in: context(store)) == .notOnThisMac(hardware: "Force Touch trackpad"))
        let model = try #require(await open(item, context(store)))
        #expect(!model.hasTrackpad)
        // The visual fallback still has the low-day marks.
        #expect(model.content?.days.contains { $0.isLow } == true)
        model.hover(column: 4)
        #expect(player.bumpCount == 0)
        item.stop()
    }

    @Test func noPredictionIsAskedForAndNoCheckInGate() async throws {
        let store = try await store(week: [-2: 1])
        let real = RealModel()
        let item = HapticWeekExperience(player: FakeHaptics())
        _ = await item.state(in: context(store, model: real))
        _ = await open(item, context(store, model: real))
        #expect(real.counter.count == 0)
        // Without today's check-in the experience still opens, and it shows only past and saved labels.
        let noToday = InMemoryFeatureStore()
        var scores: [Int: Int] = [:]
        for offset in -29...(-1) { scores[offset] = 4 }
        try await save(noToday, offsets: scores)
        let model = try #require(await open(item, context(noToday, model: real)))
        #expect(model.content?.days.last?.score == nil)
        #expect(real.counter.count == 0)
        item.stop()
    }

    // MARK: haptics

    @Test func enteringALowDayGivesOneBumpAndTheLowestGivesTwo() async throws {
        let store = try await store(week: [-1: 2, -3: 1])
        let player = FakeHaptics()
        let item = HapticWeekExperience(player: player)
        let model = try #require(await open(item, context(store)))
        // Columns: 0 is day -6 ... 6 is today. Day -1 is column 5, day -3 is column 3.
        model.hover(column: 6)
        #expect(player.bumpCount == 0)
        model.hover(column: 5)
        #expect(player.bumpCount == 1)
        model.hover(column: 5)
        #expect(player.bumpCount == 1)
        model.hover(column: nil)
        model.hover(column: 3)
        #expect(player.bumpCount == 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.bumpCount == 3)
        item.stop()
    }

    @Test func notEnoughDataGivesNoBump() async throws {
        let store = InMemoryFeatureStore()
        try await save(store, offsets: [0: 4, -1: 1])
        let player = FakeHaptics()
        let item = HapticWeekExperience(player: player)
        let model = try #require(await open(item, context(store)))
        model.hover(column: 5)
        #expect(player.bumpCount == 0)
        item.stop()
    }

    @Test func clickShowsTheScoreOfThatDay() async throws {
        let store = try await store(week: [-2: 2])
        let item = HapticWeekExperience(player: FakeHaptics())
        let model = try #require(await open(item, context(store)))
        model.select(column: 4)
        #expect(model.selectedLine == "Thursday: your energy check-in was 2.")
        model.select(column: 99)
        #expect(model.selectedLine == "Thursday: your energy check-in was 2.")
        item.stop()
    }

    // MARK: stop

    @Test func stopEndsTaskWorkAndHaptics() async throws {
        let store = try await store(week: [-3: 1])
        let player = FakeHaptics()
        let item = HapticWeekExperience(player: player)
        let model = try #require(await open(item, context(store)))
        model.hover(column: 3)
        #expect(player.bumpCount == 1)
        let pending = try #require(model.currentBumpTask)
        item.stop()
        item.stop()
        #expect(pending.isCancelled)
        #expect(model.currentBumpTask == nil)
        #expect(model.currentLoadTask == nil)
        #expect(player.stopCount >= 1)
        #expect(item.currentModel == nil)
        // The second bump of the pair never plays, and a late hover or click changes nothing.
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.bumpCount == 1)
        model.hover(column: nil)
        model.hover(column: 3)
        model.select(column: 3)
        model.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(player.bumpCount == 1)
        #expect(model.selected == nil)
        #expect(model.currentLoadTask == nil)
    }

    @Test func stopDuringLoadIgnoresTheLateResult() async throws {
        let store = try await store(week: [:])
        let item = HapticWeekExperience(player: FakeHaptics())
        _ = item.makeView(in: context(store))
        let model = try #require(item.currentModel)
        item.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .loading)
    }

    @Test func aNewViewStopsTheOldModel() async throws {
        let store = try await store(week: [:])
        let player = FakeHaptics()
        let item = HapticWeekExperience(player: player)
        _ = item.makeView(in: context(store))
        let first = try #require(item.currentModel)
        _ = item.makeView(in: context(store))
        #expect(item.currentModel !== first)
        #expect(player.stopCount >= 1)
        item.stop()
    }
}
