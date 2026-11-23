import Foundation
import SwiftUI
import Testing
@testable import CompanionUI
import TellsCore

/// A model that is not a mock.
private struct RealModel: ModelProvider {
    let target: CheckInItem = .energy
    let featureNames: [FeatureName] = []
    let isMock = false
    let modelVersion = "real-test"
    func predict(_ features: FeatureVector, day: TellsDay, windowCount: Int) async -> Prediction? { nil }
}

@MainActor
private final class FakePlayer: RhythmPlaying {
    var isAvailable = true
    var isPlaying = false
    var progress = 0.0
    var lastLeft: [Float] = []
    var lastRight: [Float] = []
    var playCount = 0
    var stopCount = 0
    var failPlay = false

    struct Failure: Error {}

    func play(left: [Float], right: [Float]) throws {
        if failPlay { throw Failure() }
        playCount += 1
        lastLeft = left
        lastRight = right
        isPlaying = true
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }
}

@Suite("TypingSound", .serialized)
@MainActor
struct TypingSoundTests {
    let today = TellsDay(yyyymmdd: 20261121)

    private func midnight(_ day: TellsDay) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = DateComponents(year: day.yyyymmdd / 10_000, month: day.yyyymmdd / 100 % 100, day: day.yyyymmdd % 100)
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    private func keyboardRow(day: TellsDay, at seconds: TimeInterval, keys: Double = 100,
                             mean: Double = 200, sd: Double = 80) -> FeatureRow {
        let values: FeatureVector = [
            FeatureName("keyboard.key_count"), FeatureName("keyboard.iki_mean_ms"), FeatureName("keyboard.iki_sd_ms"),
        ].enumerated().reduce(into: [:]) { result, item in
            if let name = item.element { result[name] = [keys, mean, sd][item.offset] }
        }
        return FeatureRow(sensor: .keyboard, schemaVersion: 1, windowStart: midnight(day).addingTimeInterval(seconds),
                          utcOffsetMinutes: 0, day: day, coverageSeconds: 300, values: values)
    }

    /// `count` typing windows from 08:00 on `day`.
    private func fillDay(_ store: InMemoryFeatureStore, _ day: TellsDay, count: Int = 12, keys: Double = 100) async throws {
        for index in 0..<count {
            try await store.save(keyboardRow(day: day, at: 8 * 3600 + Double(index) * 300, keys: keys))
        }
    }

    private func checkIn(_ store: InMemoryFeatureStore, _ day: TellsDay, energy: Int) async throws {
        try await store.save(CheckIn(day: day, savedAt: Date(timeIntervalSince1970: 1), scores: [.energy: energy]))
    }

    private func settle(_ model: TypingSoundModel) async {
        for _ in 0..<200 where model.phase == .loading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func open(_ experience: TypingSoundExperience, _ context: InsightContext) async -> TypingSoundModel? {
        _ = experience.makeView(in: context)
        guard let model = experience.currentModel else { return nil }
        await settle(model)
        return model
    }

    private func experience(_ player: FakePlayer = FakePlayer(),
                            availability: SensorAvailability = .available,
                            onPermissions: @escaping @MainActor () -> Void = {}) -> TypingSoundExperience {
        TypingSoundExperience(player: player, availability: { availability }, openPermissions: onPermissions)
    }

    // MARK: sound mapping

    @Test func fasterTypingGivesMoreTicksWithinTwoToEight() {
        func ticks(_ mean: Double) -> Int {
            TypingRhythm.bar(for: TypingBar(dayFraction: 0, keyCount: 100, ikiMean: mean, ikiSD: 50)).ticks
        }
        #expect(ticks(50) == 8)
        #expect(ticks(100) == 8)
        #expect(ticks(400) == 2)
        #expect(ticks(900) == 2)
        #expect(ticks(250) == 5)
        #expect(ticks(150) >= ticks(300))
    }

    @Test func variationSetsSwingAndKeyCountSetsVolume() {
        func bar(keys: Double, sd: Double) -> RhythmBar {
            TypingRhythm.bar(for: TypingBar(dayFraction: 0, keyCount: keys, ikiMean: 200, ikiSD: sd))
        }
        #expect(bar(keys: 20, sd: 0).swing == 0)
        #expect(bar(keys: 20, sd: 600).swing == 1)
        #expect(bar(keys: 20, sd: 150).swing == 0.5)
        #expect(abs(bar(keys: 20, sd: 0).volume - 0.3) < 1e-9)
        #expect(bar(keys: 400, sd: 0).volume == 1)
        #expect(bar(keys: 5_000, sd: 0).volume == 1)
    }

    @Test func windowsWithoutTypingAreSilentBars() {
        #expect(TypingRhythm.bar(for: TypingBar(dayFraction: 0, keyCount: 19, ikiMean: 200, ikiSD: 50)) == .silent)
        #expect(TypingRhythm.bar(for: TypingBar(dayFraction: 0, keyCount: nil, ikiMean: nil, ikiSD: nil)) == .silent)
        #expect(TypingRhythm.bar(for: TypingBar(dayFraction: 0, keyCount: 100, ikiMean: nil, ikiSD: nil)) == .silent)
    }

    @Test func theBeatIsThirtySecondsOfShortOneKilohertzClicks() {
        let rate = 44_100.0
        let samples = TypingRhythm.render([RhythmBar(ticks: 2, swing: 0, volume: 1), .silent], sampleRate: rate)
        #expect(samples.count == Int(30 * rate))
        let loud = samples.indices.filter { samples[$0] != 0 }
        #expect(!loud.isEmpty)
        // All sound is in the first bar (the second bar is silent).
        #expect((loud.last ?? Int.max) < samples.count / 2)
        // Each tick lasts 5 ms.
        #expect(loud.count <= 2 * Int(0.005 * rate))
        #expect((samples.map { abs($0) }.max() ?? 2) <= 1)
        // About 1 kHz: a 5 ms sine has 5 cycles, so about 10 sign changes for one tick.
        let firstTick = Array(samples[loud[0]..<(loud[0] + Int(0.005 * rate))])
        var crossings = 0
        for index in 1..<firstTick.count where (firstTick[index - 1] < 0) != (firstTick[index] < 0) { crossings += 1 }
        #expect((8...12).contains(crossings))
    }

    @Test func theRenderIsTheSameEachTime() {
        let bars = [RhythmBar(ticks: 5, swing: 0.8, volume: 0.7), RhythmBar(ticks: 3, swing: 1, volume: 0.4)]
        #expect(TypingRhythm.render(bars) == TypingRhythm.render(bars))
        #expect(TypingRhythm.render([]).allSatisfy { $0 == 0 })
    }

    @Test func swingMovesTicksButKeepsThemInTheFile() {
        let steady = TypingRhythm.render([RhythmBar(ticks: 4, swing: 0, volume: 1)])
        let swung = TypingRhythm.render([RhythmBar(ticks: 4, swing: 1, volume: 1)])
        #expect(steady != swung)
        #expect(swung.count == steady.count)
    }

    // MARK: text

    @Test func textHasNoMedicalWordsAndNoCauses() {
        let all = [TypingSoundText.name, TypingSoundText.practiceBanner, TypingSoundText.unreadable,
                   TypingSoundText.noReference, TypingSoundText.noSound, TypingSoundText.playFailed,
                   TypingSoundText.noKeyboard, TypingSoundText.openPermissions, TypingSoundText.intro(target: "energy"),
                   TypingSoundText.notEnoughToday(have: 5, need: 12), TypingSoundText.needsPermission(.inputMonitoring),
                   TypingSoundText.referenceLine(target: "energy", day: today, score: 4)].joined(separator: " ").lowercased()
        for word in ["diagnose", "disorder", "symptom", "illness", "disease", "treatment", "therapy", "health",
                     "burnout", "depression", "anxiety", "fatigue", "sleep quality", "cause"] {
            #expect(!all.contains(word), "\(word)")
        }
        #expect(TypingSoundText.intro(target: "energy") == "Today's rhythm, next to your highest energy day of the last 30 days.")
        #expect(TypingSoundText.notEnoughToday(have: 5, need: 12) == "Not enough typing today. 5 of 12 windows.")
        #expect(TypingSoundText.referenceLine(target: "energy", day: today, score: 4)
                == "Reference day: 2026-11-21. Your energy check-in was 4.")
    }

    @Test func idAndOrderMatchSpecSection6() {
        let item = experience()
        #expect(item.id == "typingSound")
        #expect(item.displayName == "Typing rhythm sound")
        #expect(item.menuOrder == 2)
        #expect(PlaceholderExperience.all()[1].id == item.id)
        #expect(PlaceholderExperience.all()[1].displayName == item.displayName)
    }

    // MARK: reference day

    @Test func theReferenceDayHasTheHighestScoreAndATieGoesToTheNewerDay() async throws {
        let store = InMemoryFeatureStore()
        let days = [3, 5, 9].map { today.adding(days: -$0) }   // scores below
        for day in days { try await fillDay(store, day) }
        try await checkIn(store, days[0], energy: 4)
        try await checkIn(store, days[1], energy: 5)
        try await checkIn(store, days[2], energy: 5)
        let content = try await TypingSoundLoader.load(in: InsightContext(store: store, model: RealModel(), today: today))
        #expect(content.reference?.day.day == days[1])      // 5 days back is newer than 9 days back
        #expect(content.reference?.score == 5)
    }

    @Test func theReferenceDaySkipsTodayShortDaysOldDaysAndOtherItems() async throws {
        let store = InMemoryFeatureStore()
        let short = today.adding(days: -2)
        let old = today.adding(days: -31)
        let other = today.adding(days: -4)
        let valid = today.adding(days: -6)
        try await fillDay(store, today)
        try await fillDay(store, short, count: 11)
        try await fillDay(store, old)
        try await fillDay(store, other)
        try await fillDay(store, valid)
        try await checkIn(store, today, energy: 5)
        try await checkIn(store, short, energy: 5)
        try await checkIn(store, old, energy: 5)
        try await store.save(CheckIn(day: other, savedAt: Date(timeIntervalSince1970: 1), scores: [.mood: 5]))
        try await checkIn(store, valid, energy: 2)
        let content = try await TypingSoundLoader.load(in: InsightContext(store: store, model: RealModel(), today: today))
        #expect(content.reference?.day.day == valid)
        #expect(content.reference?.score == 2)
    }

    @Test func theThirtiethDayBackCanBeTheReference() async throws {
        let store = InMemoryFeatureStore()
        let edge = today.adding(days: -30)
        try await fillDay(store, edge)
        try await checkIn(store, edge, energy: 3)
        let content = try await TypingSoundLoader.load(in: InsightContext(store: store, model: RealModel(), today: today))
        #expect(content.reference?.day.day == edge)
    }

    @Test func aWindowCountsForTheDayOfItsRowAndTheTimelineStartsAt0400() {
        // 02:00 local time still belongs to the day before (DEC-3). The row carries that day.
        let yesterday = today.adding(days: -1)
        let late = keyboardRow(day: yesterday, at: 26 * 3600)      // 02:00 on today's date
        let morning = keyboardRow(day: today, at: 4 * 3600)       // 04:00
        let days = TypingDay.group([late, morning])
        #expect(days[yesterday]?.bars.count == 1)
        #expect(days[today]?.bars.count == 1)
        #expect(days[yesterday]?.bars.first?.dayFraction == 22.0 / 24)
        #expect(days[today]?.bars.first?.dayFraction == 0)
    }

    @Test func theTimelineUsesTheRowOffset() {
        var row = keyboardRow(day: today, at: 2 * 3600)             // 02:00 UTC
        row = FeatureRow(sensor: row.sensor, schemaVersion: 1, windowStart: row.windowStart, utcOffsetMinutes: 120,
                         day: today, coverageSeconds: 300, values: row.values)       // 04:00 local
        #expect(TypingDay.group([row])[today]?.bars.first?.dayFraction == 0)
    }

    // MARK: states

    @Test func practiceStateWithTheMockModel() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let context = InsightContext(store: store, model: MockModelProvider(), today: today)
        #expect(await experience().state(in: context) == .practice)
    }

    @Test func readyStateWithARealModel() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let context = InsightContext(store: store, model: RealModel(), today: today)
        #expect(await experience().state(in: context) == .ready)
    }

    @Test func notEnoughDataStateNamesTheTypingWindows() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today, count: 5)
        // Windows with fewer than 20 key presses are not typing windows.
        try await store.save(keyboardRow(day: today, at: 20_000, keys: 3))
        let context = InsightContext(store: store, model: RealModel(), today: today)
        #expect(await experience().state(in: context) == .notEnoughData(have: 5, need: 12, unit: "windows"))
        let model = try #require(await open(experience(), context))
        #expect(model.content?.today.typingWindowCount == 5)
        #expect(!model.canPlay(.today))
        #expect(!model.canPlay(.both))
    }

    @Test func permissionDeniedAndNotAskedStates() async throws {
        let context = InsightContext(store: InMemoryFeatureStore(), model: RealModel(), today: today)
        #expect(await experience(availability: .permissionDenied(.inputMonitoring)).state(in: context)
                == .permissionDenied(.inputMonitoring))
        #expect(await experience(availability: .permissionNotAsked(.inputMonitoring)).state(in: context)
                == .permissionDenied(.inputMonitoring))
        var opened = 0
        let item = experience(availability: .permissionDenied(.inputMonitoring), onPermissions: { opened += 1 })
        let model = try #require(await open(item, context))
        #expect(model.phase == .permission(.inputMonitoring))
        model.openPermissions()
        #expect(opened == 1)
        item.stop()
    }

    @Test func notOnThisMacState() async throws {
        let context = InsightContext(store: InMemoryFeatureStore(), model: RealModel(), today: today)
        let item = experience(availability: .notOnThisMac)
        #expect(await item.state(in: context) == .notOnThisMac(hardware: "keyboard"))
        let model = try #require(await open(item, context))
        #expect(model.phase == .notOnThisMac)
        item.stop()
    }

    @Test func anUnreadableStoreShowsItsOwnState() async throws {
        struct Broken: FeatureReader {
            struct Failure: Error {}
            func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow] { throw Failure() }
            func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow] { throw Failure() }
            func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary] { throw Failure() }
            func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn] { throw Failure() }
        }
        let context = InsightContext(store: Broken(), model: RealModel(), today: today) { _ in }
        let item = experience()
        let model = try #require(await open(item, context))
        #expect(model.phase == .unreadable)
        item.stop()
    }

    @Test func practiceViewUsesMockModelAndRealDataShowsRealValues() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today, count: 14)
        let reference = today.adding(days: -3)
        try await fillDay(store, reference, count: 13)
        try await checkIn(store, reference, energy: 4)
        let mockItem = experience()
        let mock = try #require(await open(mockItem, InsightContext(store: store, model: MockModelProvider(), today: today)))
        #expect(mock.isPractice)
        mockItem.stop()
        let realItem = experience()
        let real = try #require(await open(realItem, InsightContext(store: store, model: RealModel(), today: today)))
        #expect(!real.isPractice)
        #expect(real.target == "energy")
        #expect(real.content?.today.typingWindowCount == 14)
        #expect(real.content?.reference?.day.day == reference)
        #expect(real.content?.reference?.day.typingWindowCount == 13)
        #expect(real.content?.reference?.score == 4)
        #expect(real.canPlay(.today) && real.canPlay(.reference) && real.canPlay(.both))
        realItem.stop()
    }

    // MARK: playing

    @Test func noReferenceDayBlocksReferenceAndBoth() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let model = try #require(await open(experience(), InsightContext(store: store, model: RealModel(), today: today)))
        #expect(model.content?.reference == nil)
        #expect(model.canPlay(.today))
        #expect(!model.canPlay(.reference))
        #expect(!model.canPlay(.both))
    }

    @Test func noOutputDeviceBlocksAllSound() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let player = FakePlayer()
        player.isAvailable = false
        let model = try #require(await open(experience(player), InsightContext(store: store, model: RealModel(), today: today)))
        #expect(!model.audioAvailable)
        #expect(!model.canPlay(.today))
        model.play(.today)
        #expect(player.playCount == 0)
        #expect(model.content?.today.typingWindowCount == 12)   // the timeline still has data
    }

    @Test func playBothPutsTodayLeftAndTheReferenceDayRight() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today, count: 12, keys: 400)
        let reference = today.adding(days: -2)
        try await fillDay(store, reference, count: 13, keys: 30)
        try await checkIn(store, reference, energy: 5)
        let player = FakePlayer()
        let item = experience(player)
        let model = try #require(await open(item, InsightContext(store: store, model: RealModel(), today: today)))
        model.play(.both)
        #expect(player.playCount == 1)
        #expect(model.playing == .both)
        #expect(player.lastLeft.count == Int(30 * 44_100))
        #expect(player.lastLeft != player.lastRight)
        let leftPeak = player.lastLeft.map { abs($0) }.max() ?? 0
        let rightPeak = player.lastRight.map { abs($0) }.max() ?? 0
        #expect(leftPeak > rightPeak)       // 400 key presses is louder than 30
        model.play(.today)
        #expect(player.lastLeft == player.lastRight)
        item.stop()
    }

    @Test func theMarkerFollowsTheProgressAndTheSoundEndsByItself() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let player = FakePlayer()
        let item = experience(player)
        let model = try #require(await open(item, InsightContext(store: store, model: RealModel(), today: today)))
        model.play(.today)
        #expect(model.markerFraction(for: .today) == model.content?.today.bars.first?.dayFraction)
        #expect(model.markerFraction(for: .reference) == nil)
        player.progress = 0.5
        for _ in 0..<100 where model.progress == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.progress == 0.5)
        player.isPlaying = false
        for _ in 0..<100 where model.playing != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.playing == nil)
        #expect(model.currentProgressTask == nil)
        item.stop()
    }

    @Test func aFailedPlayShowsAnErrorAndNoSound() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let player = FakePlayer()
        player.failPlay = true
        let model = try #require(await open(experience(player), InsightContext(store: store, model: RealModel(), today: today)))
        model.play(.today)
        #expect(model.playbackFailed)
        #expect(model.playing == nil)
        #expect(!player.isPlaying)
    }

    // MARK: stop

    @Test func stopEndsTheSoundAndAllTaskWork() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let player = FakePlayer()
        let item = experience(player)
        let model = try #require(await open(item, InsightContext(store: store, model: RealModel(), today: today)))
        model.play(.today)
        let progressTask = try #require(model.currentProgressTask)
        #expect(player.isPlaying)
        item.stop()
        item.stop()
        #expect(!player.isPlaying)
        #expect(progressTask.isCancelled)
        #expect(model.currentProgressTask == nil)
        #expect(model.currentLoadTask == nil)
        #expect(model.playing == nil)
        #expect(item.currentModel == nil)
        // A late play or a late load changes nothing.
        let before = player.playCount
        model.play(.today)
        model.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(player.playCount == before)
        #expect(model.currentLoadTask == nil)
        #expect(!player.isPlaying)
    }

    @Test func stopDuringLoadIgnoresTheLateResult() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let item = experience()
        _ = item.makeView(in: InsightContext(store: store, model: RealModel(), today: today))
        let model = try #require(item.currentModel)
        item.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .loading)
    }

    @Test func aNewViewStopsTheOldSound() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let player = FakePlayer()
        let item = experience(player)
        let context = InsightContext(store: store, model: RealModel(), today: today)
        let first = try #require(await open(item, context))
        first.play(.today)
        #expect(player.isPlaying)
        _ = item.makeView(in: context)
        #expect(!player.isPlaying)
        #expect(first.currentProgressTask == nil)
        #expect(item.currentModel !== first)
        item.stop()
    }

    @Test func theUserCanStopThePlayback() async throws {
        let store = InMemoryFeatureStore()
        try await fillDay(store, today)
        let player = FakePlayer()
        let item = experience(player)
        let model = try #require(await open(item, InsightContext(store: store, model: RealModel(), today: today)))
        model.play(.today)
        model.stopPlayback()
        #expect(!player.isPlaying)
        #expect(model.playing == nil)
        #expect(model.currentProgressTask == nil)
        item.stop()
    }

    @Test func theRealPlayerHoldsNoEngineAtIdleAndStopIsSafe() {
        let player = EngineRhythmPlayer()
        #expect(!player.isPlaying)
        #expect(player.progress == 0)
        player.stop()
        player.stop()
        #expect(!player.isPlaying)
    }

    @Test func beatSourceWritesBothChannelsAndThenSilence() {
        let source = BeatSource(left: [1, 2, 3], right: [4, 5, 6])
        var left = [Float](repeating: 9, count: 5)
        var right = [Float](repeating: 9, count: 5)
        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                guard let leftBase = leftPointer.baseAddress, let rightBase = rightPointer.baseAddress else { return }
                source.render(frames: 5, channels: [leftBase, rightBase])
            }
        }
        #expect(left == [1, 2, 3, 0, 0])
        #expect(right == [4, 5, 6, 0, 0])
        #expect(source.isFinished)
        #expect(source.progress == 1)
    }
}
