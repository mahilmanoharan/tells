import Foundation
import Synchronization
import Testing
@testable import TellsCore

struct DayCloserTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
    private let day = TellsDay(yyyymmdd: 20261118)

    private func date(_ d: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.utc.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour, minute: minute)) ?? .distantPast
    }

    private func dayRow(_ sensor: SensorID, _ values: [String: Double], at start: Date, day rowDay: TellsDay? = nil) throws -> FeatureRow {
        FeatureRow(sensor: sensor, schemaVersion: 1, windowStart: start, utcOffsetMinutes: 0, day: rowDay ?? day,
                   coverageSeconds: 300,
                   values: Dictionary(uniqueKeysWithValues: try values.map { (try name($0.key), $0.value) }))
    }

    private func fill(_ store: InMemoryFeatureStore) async throws {
        try await store.save(dayRow(.keyboard, ["keyboard.key_count": 30], at: date(18, 9)))
        try await store.save(dayRow(.keyboard, ["keyboard.key_count": 20], at: date(18, 9, 5)))
        try await store.save(dayRow(.activity, ["activity.input_s": 120, "activity.leading_idle_s": 60,
                                                "activity.trailing_idle_s": 60], at: date(18, 10)))
        try await store.save(dayRow(.appswitch, ["appswitch.switch_count": 5], at: date(18, 10)))
    }

    private func closer(_ store: InMemoryFeatureStore, now: Date,
                        sleepUntil: @escaping @Sendable (Date) async throws -> Void = { _ in throw CancellationError() }) -> DayCloser {
        DayCloser(extractors: [KeyboardExtractor(), ActivityExtractor(), AppSwitchExtractor()], store: store,
                  calendar: Self.utc, now: { now }, sleepUntil: sleepUntil)
    }

    @Test func closesTheDayWithOneDailyRowAndOneSummary() async throws {
        let store = InMemoryFeatureStore()
        try await fill(store)
        await closer(store, now: date(19, 4)).close(day: day)

        let dailyRows = try await store.dailyRows(day...day)
        let summaries = try await store.dailySummaries(day...day)
        #expect(dailyRows.count == 1)
        #expect(summaries.count == 1)
        let daily = try #require(dailyRows.first)
        #expect(daily.schemaVersions == [.keyboard: 1, .activity: 1, .appswitch: 1])
        #expect(daily.values[try name("keyboard.day_key_count")] == 50)
        #expect(daily.values[try name("appswitch.day_switch_count")] == 5)
        #expect(daily.values[try name("activity.input_min")] == 2)
    }

    @Test func summaryHasOnlyTheSixNamesAndAbsentNamesStayAbsent() async throws {
        let store = InMemoryFeatureStore()
        try await fill(store)
        await closer(store, now: date(19, 4)).close(day: day)

        let summary = try #require(try await store.dailySummaries(day...day).first)
        let expected: [String: Double] = ["keyboard.day_key_count": 50, "activity.input_min": 2,
                                          "activity.first_input_min": 601, "activity.last_input_min": 604,
                                          "appswitch.day_switch_count": 5]
        #expect(Dictionary(uniqueKeysWithValues: summary.values.map { ($0.key.rawValue, $0.value) }) == expected)
        // keyboard.day_iki_median_ms is one of the 6 names. 2 typing windows are too few, so it is absent.
        #expect(summary.values[try name("keyboard.day_iki_median_ms")] == nil)
        #expect(Set(DayCloser.summaryNames.map(\.rawValue)).count == 6)
    }

    @Test func closeDeletesExpiredRowsButKeepsSummaries() async throws {
        let store = InMemoryFeatureStore()
        let old = day.adding(days: -40)
        try await store.save(row(.keyboard, minute: 0, day: old))
        try await store.save(DailySummary(day: old, values: [:]))
        await closer(store, now: date(19, 4)).close(day: day)

        #expect(try await store.featureRows(nil, in: DateInterval(start: .distantPast, end: .distantFuture)).isEmpty)
        #expect(try await store.dailySummaries(old...old).count == 1)
    }

    @Test func startDeletesExpiredDataOnceAndLoopClosesAtFourOnTheNextDay() async throws {
        let store = InMemoryFeatureStore()
        try await fill(store)
        let old = day.adding(days: -40)
        try await store.save(DailyRow(day: old, schemaVersions: [:], values: [:]))
        let waits = Mutex<[Date]>([])
        let target = closer(store, now: date(18, 20)) { until in
            let count = waits.withLock { $0.append(until); return $0.count }
            if count > 1 { throw CancellationError() }
        }

        await target.start()
        #expect(try await store.dailyRows(old...old).isEmpty)          // deleted at start, before any close
        await target.waitForLoop()

        #expect(waits.withLock { $0 }.first == date(19, 4))
        #expect(try await store.dailyRows(day...day).count == 1)
        #expect(try await store.dailySummaries(day...day).count == 1)
    }

    @Test func spanRunsFrom1800OnTheDayBeforeTo0400OnTheDayAfter() {
        let span = DayCloser.span(of: day, calendar: Self.utc)
        #expect(span.start == date(17, 18))
        #expect(span.end == date(19, 4))
    }
}
