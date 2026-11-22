import Foundation
import Testing
@testable import TellsCore

@Suite("InMemoryFeatureStore")
struct InMemoryFeatureStoreTests {
    let today = TellsDay(yyyymmdd: 20261121)

    @Test func replacesTheCheckInOfTheSameDay() async throws {
        let store = InMemoryFeatureStore()
        try await store.save(CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 1), scores: [.energy: 2]))
        try await store.save(CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 2), scores: [.energy: 4, .mood: 3]))
        try await store.save(CheckIn(day: today.adding(days: -1), savedAt: Date(timeIntervalSince1970: 0), scores: [.social: 5]))

        let todays = try await store.checkIns(today...today)
        #expect(todays.count == 1)
        #expect(todays.first?.scores == [.energy: 4, .mood: 3])
        #expect(try await store.checkIns(today.adding(days: -1)...today).count == 2)
    }

    @Test func filtersRowsBySensorAndInterval() async throws {
        let store = InMemoryFeatureStore()
        try await store.save(row(.activity, minute: 5))
        try await store.save(row(.keyboard, minute: 0))
        try await store.save(row(.activity, minute: 0))
        try await store.save(row(.activity, minute: 100))
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_795_000_000), duration: 600)

        let activity = try await store.featureRows(.activity, in: interval)
        #expect(activity.map(\.windowStart.timeIntervalSince1970) == [1_795_000_000, 1_795_000_300])
        #expect(try await store.featureRows(nil, in: interval).count == 3)
    }

    @Test func deleteExpiredKeeps30DaysAndAllSummaries() async throws {
        let store = InMemoryFeatureStore()
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
        let everything = DateInterval(start: .distantPast, end: .distantFuture)
        #expect(try await store.featureRows(nil, in: everything).map(\.day) == [edgeDay])
    }

    @Test func deleteAllRemovesEverything() async throws {
        let store = InMemoryFeatureStore()
        try await store.save(row(.activity, minute: 0))
        try await store.save(DailySummary(day: today, values: [:]))
        try await store.save(CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 0), scores: [.energy: 3]))

        try await store.deleteAll()

        #expect(try await store.featureRows(nil, in: DateInterval(start: .distantPast, end: .distantFuture)).isEmpty)
        #expect(try await store.dailySummaries(today...today).isEmpty)
        #expect(try await store.checkIns(today...today).isEmpty)
    }
}
