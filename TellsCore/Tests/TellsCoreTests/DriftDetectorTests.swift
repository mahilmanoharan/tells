import Foundation
import Testing
@testable import TellsCore

struct DriftDetectorTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private static func name(_ text: String) -> FeatureName {
        guard let name = FeatureName(text) else { preconditionFailure("bad name") }
        return name
    }

    private static func typingRow(day: Int, hour: Int, minute: Int = 0, median: Double, keys: Double = 40) -> FeatureRow {
        let start = date(day, hour, minute)
        return FeatureRow(
            sensor: .keyboard, schemaVersion: 1, windowStart: start, utcOffsetMinutes: 0,
            day: TellsDay(start, calendar: utc), coverageSeconds: 300,
            values: [name("keyboard.key_count"): keys, name("keyboard.iki_median_ms"): median]
        )
    }

    /// Each day has 12 windows from 10:00 to 10:55. Medians alternate 100 and 200 ms.
    private static func baseline(days: [Int]) -> [FeatureRow] {
        days.flatMap { day in
            (0..<12).map { typingRow(day: day, hour: 10, minute: $0 * 5, median: $0 % 2 == 0 ? 100 : 200) }
        }
    }

    private func store(with rows: [FeatureRow]) async throws -> InMemoryFeatureStore {
        let store = InMemoryFeatureStore()
        for row in rows { try await store.save(row) }
        return store
    }

    @Test func zScoreMatchesKnownAnswer() async throws {
        let store = try await store(with: Self.baseline(days: [17, 18, 19]))
        let detector = DriftDetector(store: store, calendar: Self.utc)
        let row = Self.typingRow(day: 20, hour: 10, minute: 30, median: 400)
        let z = try #require(await detector.zScore(for: row))
        // 36 logs: half ln 100, half ln 200. Sample SD = (ln 2 / 2) * sqrt(36 / 35).
        let mean = (log(100.0) + log(200.0)) / 2
        let spread = (log(2.0) / 2) * (36.0 / 35.0).squareRoot()
        #expect(abs(z - (log(400.0) - mean) / spread) < 1e-9)
    }

    @Test func zScoreIsNilUnderThreeUsableDays() async throws {
        let store = try await store(with: Self.baseline(days: [18, 19]))
        let detector = DriftDetector(store: store, calendar: Self.utc)
        #expect(await detector.zScore(for: Self.typingRow(day: 20, hour: 10, median: 400)) == nil)
    }

    @Test func baselineUsesTheMostRecentUsableDaysEvenIfOlderThan14CalendarDays() async throws {
        // Nov 1, 2 and 3 are the only usable days. They are 17 to 19 calendar days before Nov 20.
        let store = try await store(with: Self.baseline(days: [1, 2, 3]))
        let detector = DriftDetector(store: store, calendar: Self.utc)
        #expect(await detector.zScore(for: Self.typingRow(day: 20, hour: 10, median: 400)) != nil)
    }

    @Test func baselineKeepsOnly14UsableDays() async throws {
        // 14 recent usable days, and 3 older usable days with 10 times the values. The old days must not count.
        let recent = Self.baseline(days: Array(6...19))
        let old = [1, 2, 3].flatMap { day in
            (0..<12).map { Self.typingRow(day: day, hour: 10, minute: $0 * 5, median: $0 % 2 == 0 ? 1000 : 2000) }
        }
        let row = Self.typingRow(day: 20, hour: 10, median: 400)
        let withOld = DriftDetector(store: try await store(with: recent + old), calendar: Self.utc)
        let withoutOld = DriftDetector(store: try await store(with: recent), calendar: Self.utc)
        let z = try #require(await withoutOld.zScore(for: row))
        #expect(await withOld.zScore(for: row) == z)
    }

    @Test func aDayWithUnder12TypingWindowsIsNotUsable() async throws {
        var rows = Self.baseline(days: [17, 18])
        rows += Self.baseline(days: [19]).dropLast()   // 11 windows
        let store = try await store(with: rows)
        let detector = DriftDetector(store: store, calendar: Self.utc)
        #expect(await detector.zScore(for: Self.typingRow(day: 20, hour: 10, median: 400)) == nil)
    }

    @Test func baselineUsesTheSameHourPlusOrMinusOne() async throws {
        let store = try await store(with: Self.baseline(days: [17, 18, 19]))
        let detector = DriftDetector(store: store, calendar: Self.utc)
        #expect(await detector.zScore(for: Self.typingRow(day: 20, hour: 11, median: 400)) != nil)
        #expect(await detector.zScore(for: Self.typingRow(day: 20, hour: 12, median: 400)) == nil)
    }

    @Test func aWindowUnder20KeysHasNoZScore() async throws {
        let store = try await store(with: Self.baseline(days: [17, 18, 19]))
        let detector = DriftDetector(store: store, calendar: Self.utc)
        #expect(await detector.zScore(for: Self.typingRow(day: 20, hour: 10, median: 400, keys: 19)) == nil)
    }

    @Test func driftNeedsNoCheckIn() async throws {
        // The store has no CheckIn row. Drift still starts.
        let hot = (0..<3).map { Self.typingRow(day: 20, hour: 10, minute: $0 * 5, median: 800) }
        let store = try await store(with: Self.baseline(days: [17, 18, 19]) + hot)
        #expect(try await store.checkIns(TellsDay(yyyymmdd: 20261101)...TellsDay(yyyymmdd: 20261130)).isEmpty)
        let detector = DriftDetector(store: store, calendar: Self.utc)
        #expect(await detector.update(now: Self.date(20, 10, 20)) == .drifting)
    }

    @Test func driftStartsAfterThreeHighWindowsInARow() async {
        let detector = DriftDetector(store: InMemoryFeatureStore(), calendar: Self.utc)
        await detector.advance(with: 2.5)
        await detector.advance(with: -2.0)
        #expect(await detector.state == .normal)
        await detector.advance(with: 2.0)
        #expect(await detector.state == .drifting)
    }

    @Test func aWindowUnderTheStartValueBreaksTheStart() async {
        let detector = DriftDetector(store: InMemoryFeatureStore(), calendar: Self.utc)
        await detector.advance(with: 3)
        await detector.advance(with: 3)
        await detector.advance(with: 1.9)
        await detector.advance(with: 3)
        #expect(await detector.state == .normal)
    }

    @Test func driftEndsAfterTwoLowWindowsInARow() async {
        let detector = DriftDetector(store: InMemoryFeatureStore(), calendar: Self.utc)
        for _ in 0..<3 { await detector.advance(with: 2.2) }
        await detector.advance(with: 0.5)
        await detector.advance(with: 1.2)   // not under 1: the count starts again
        await detector.advance(with: -0.9)
        #expect(await detector.state == .drifting)
        await detector.advance(with: 0.1)
        #expect(await detector.state == .normal)
    }

    @Test func sensitivityChangesTheStartRule() async {
        let low = DriftDetector(store: InMemoryFeatureStore(), sensitivity: .low, calendar: Self.utc)
        for _ in 0..<3 { await low.advance(with: 3) }
        #expect(await low.state == .normal)
        await low.advance(with: 3)
        #expect(await low.state == .drifting)
        let high = DriftDetector(store: InMemoryFeatureStore(), sensitivity: .high, calendar: Self.utc)
        for _ in 0..<3 { await high.advance(with: 1.6) }
        #expect(await high.state == .drifting)
    }
}

struct ScatteredTriggerTests {
    private static func row(day: Int, minute: Int, switches: Double) -> FeatureRow {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400 + Double(minute) * 60)
        return FeatureRow(sensor: .appswitch, schemaVersion: 1, windowStart: start, utcOffsetMinutes: 0,
                          day: TellsDay(yyyymmdd: 20261100 + day), coverageSeconds: 300,
                          values: [switchCount: switches])
    }

    private static let switchCount = FeatureName("appswitch.switch_count") ?? FeatureName("appswitch.x")!
    private static let today = TellsDay(yyyymmdd: 20261120)

    @Test func fewerThanTenSwitchesIsNeverScattered() {
        let rows = [Self.row(day: 19, minute: 0, switches: 1), Self.row(day: 20, minute: 0, switches: 9)]
        let now = rows[1].windowStart.addingTimeInterval(300)
        #expect(!ScatteredTrigger.isScattered(rows: rows, now: now, today: Self.today))
    }

    @Test func tenOrMoreAndOverThe90thPercentileIsScattered() {
        let history = (0..<10).map { Self.row(day: 19, minute: $0 * 5, switches: Double($0)) }   // p90 = 8.1
        let last = Self.row(day: 20, minute: 0, switches: 10)
        #expect(ScatteredTrigger.isScattered(rows: history + [last], now: last.windowStart.addingTimeInterval(300), today: Self.today))
    }

    @Test func tenSwitchesUnderTheUserPercentileIsNotScattered() {
        let history = (0..<10).map { Self.row(day: 19, minute: $0 * 5, switches: 20 + Double($0)) }
        let last = Self.row(day: 20, minute: 0, switches: 12)
        #expect(!ScatteredTrigger.isScattered(rows: history + [last], now: last.windowStart.addingTimeInterval(300), today: Self.today))
    }

    @Test func equalToThePercentileIsNotOver() {
        let history = (0..<5).map { Self.row(day: 19, minute: $0 * 5, switches: 12) }
        let last = Self.row(day: 20, minute: 0, switches: 12)
        #expect(!ScatteredTrigger.isScattered(rows: history + [last], now: last.windowStart.addingTimeInterval(300), today: Self.today))
    }

    @Test func withNoHistoryOnlyTheFloorApplies() {
        let last = Self.row(day: 20, minute: 0, switches: 10)
        #expect(ScatteredTrigger.isScattered(rows: [last], now: last.windowStart.addingTimeInterval(300), today: Self.today))
    }

    @Test func anOldLastWindowIsNotScattered() {
        let last = Self.row(day: 20, minute: 0, switches: 30)
        #expect(!ScatteredTrigger.isScattered(rows: [last], now: last.windowStart.addingTimeInterval(3600), today: Self.today))
    }
}
