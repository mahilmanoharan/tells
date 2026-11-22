import Foundation
import Testing
@testable import CompanionUI
import TellsCore

@Suite("CheckIn")
@MainActor
struct CheckInTests {
    let today = TellsDay(yyyymmdd: 20261121)

    private func context(_ store: InMemoryFeatureStore) -> InsightContext {
        InsightContext(store: store, model: MockModelProvider(), today: today)
    }

    @Test func savesTheSelectedScoresAndSkipsTheRest() async throws {
        let store = InMemoryFeatureStore()
        let model = CheckInModel(context: context(store), now: { Date(timeIntervalSince1970: 9) })
        model.select(4, for: .energy)
        model.select(2, for: .social)
        await model.save()
        let saved = try await store.checkIns(today...today)
        #expect(saved == [CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 9), scores: [.energy: 4, .social: 2])])
        #expect(model.isSaved)
    }

    @Test func selectingTheSameScoreAgainSkipsTheItem() {
        let model = CheckInModel(context: context(InMemoryFeatureStore()))
        model.select(3, for: .mood)
        model.select(3, for: .mood)
        #expect(model.scores.isEmpty)
        #expect(!model.canSave)
    }

    @Test func ignoresScoresOutsideOneToFive() {
        let model = CheckInModel(context: context(InMemoryFeatureStore()))
        model.select(0, for: .mood)
        model.select(6, for: .mood)
        #expect(model.scores.isEmpty)
    }

    @Test func aSecondSaveOnTheSameDayReplacesTheFirst() async throws {
        let store = InMemoryFeatureStore()
        let first = CheckInModel(context: context(store), now: { Date(timeIntervalSince1970: 1) })
        first.select(2, for: .energy)
        await first.save()
        let second = CheckInModel(context: context(store), now: { Date(timeIntervalSince1970: 2) })
        second.select(5, for: .mood)
        await second.save()
        let saved = try await store.checkIns(today...today)
        #expect(saved == [CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 2), scores: [.mood: 5])])
    }

    @Test func aFailedSaveShowsAnErrorAndDoesNotMarkSaved() async {
        struct Failure: Error {}
        let context = InsightContext(store: InMemoryFeatureStore(), model: MockModelProvider(), today: today) { _ in
            throw Failure()
        }
        let model = CheckInModel(context: context)
        model.select(1, for: .energy)
        await model.save()
        #expect(model.saveFailed)
        #expect(!model.isSaved)
    }

    @Test func noPredictionBeforeTodaysCheckInIsSaved() async throws {
        let store = InMemoryFeatureStore()
        let context = context(store)
        let model = MockModelProvider()
        let features: FeatureVector = Dictionary(uniqueKeysWithValues: model.featureNames.map { ($0, 10.0) })
        // The model has a value for these inputs, so only the gate can hide it.
        #expect(await model.predict(features, day: today, windowCount: 12) != nil)

        #expect(await PredictionGate.todaysPrediction(in: context, features: features, windowCount: 12) == nil)

        // A check-in for another day does not open the gate.
        try await store.save(CheckIn(day: today.adding(days: -1), savedAt: Date(), scores: [.energy: 3]))
        #expect(await PredictionGate.todaysPrediction(in: context, features: features, windowCount: 12) == nil)

        let checkIn = CheckInModel(context: context)
        checkIn.select(3, for: .energy)
        await checkIn.save()
        #expect(await PredictionGate.todaysPrediction(in: context, features: features, windowCount: 12) != nil)
    }

    @Test func viewTextHasNoMedicalWordsAndSaysPredicts() {
        let banned = ["diagnose", "disorder", "symptom", "illness", "disease", "treatment", "therapy",
                      "health", "burnout", "depression", "anxiety", "fatigue", "sleep quality", "causes"]
        let text = ([CheckInText.title, CheckInText.intro, CheckInText.save, CheckInText.saved, CheckInText.failed]
            + CheckInItem.allCases.map(CheckInText.label)).joined(separator: " ").lowercased()
        for word in banned { #expect(!text.contains(word), "\(word)") }
        #expect(text.contains("predicts"))
    }

    @Test func aReadErrorFailsClosedAndHasItsOwnState() async throws {
        let store = InMemoryFeatureStore()
        try await store.save(CheckIn(day: today, savedAt: Date(), scores: [.energy: 3]))
        let model = MockModelProvider()
        let features: FeatureVector = Dictionary(uniqueKeysWithValues: model.featureNames.map { ($0, 10.0) })
        let context = InsightContext(store: UnreadableReader(), model: model, today: today) { _ in }
        #expect(await PredictionGate.state(in: context) == .unreadable)
        #expect(await PredictionGate.todaysPrediction(in: context, features: features, windowCount: 12) == nil)
        #expect(await PredictionGate.state(in: self.context(store)) == .saved)
        #expect(await PredictionGate.state(in: self.context(InMemoryFeatureStore())) == .notSaved)
    }
}

struct UnreadableReader: FeatureReader {
    struct Failure: Error {}
    func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow] { throw Failure() }
    func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow] { throw Failure() }
    func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary] { throw Failure() }
    func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn] { throw Failure() }
}
