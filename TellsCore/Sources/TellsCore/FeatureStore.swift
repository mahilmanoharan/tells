import Foundation

public struct FeatureRow: Sendable, Equatable {
    public let sensor: SensorID
    public let schemaVersion: Int
    public let windowStart: Date          // UTC instant
    public let utcOffsetMinutes: Int      // local offset at windowStart
    public let day: TellsDay              // local calendar day of windowStart
    public let coverageSeconds: Double    // 60...300
    public let values: FeatureVector

    public init(sensor: SensorID, schemaVersion: Int, windowStart: Date, utcOffsetMinutes: Int,
                day: TellsDay, coverageSeconds: Double, values: FeatureVector) {
        self.sensor = sensor
        self.schemaVersion = schemaVersion
        self.windowStart = windowStart
        self.utcOffsetMinutes = utcOffsetMinutes
        self.day = day
        self.coverageSeconds = coverageSeconds
        self.values = values
    }
}

public struct DailyRow: Sendable, Equatable {        // day features, 30 days
    public let day: TellsDay
    public let schemaVersions: [SensorID: Int]
    public let values: FeatureVector

    public init(day: TellsDay, schemaVersions: [SensorID: Int], values: FeatureVector) {
        self.day = day
        self.schemaVersions = schemaVersions
        self.values = values
    }
}

public struct DailySummary: Sendable, Equatable {    // kept until the user deletes it (DEC-6)
    public let day: TellsDay
    public let values: FeatureVector                 // only the names in SPEC.md Section 3.5

    public init(day: TellsDay, values: FeatureVector) {
        self.day = day
        self.values = values
    }
}

public enum CheckInItem: String, Sendable, CaseIterable, Codable { case energy, mood, social }

public struct CheckIn: Sendable, Equatable {         // 30 days (DEC-5)
    public let day: TellsDay
    public let savedAt: Date
    public let scores: [CheckInItem: Int]            // each 1...5; an absent item = skipped

    public init(day: TellsDay, savedAt: Date, scores: [CheckInItem: Int]) {
        self.day = day
        self.savedAt = savedAt
        self.scores = scores
    }
}

/// Read-only access. Insight experiences get only this part (SPEC.md Section 2.7, DEC-16).
public protocol FeatureReader: Sendable {
    func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow]
    func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow]
    func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary]
    func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn]
}

public protocol FeatureStore: FeatureReader {
    func save(_ row: FeatureRow) async throws
    func save(_ row: DailyRow) async throws
    func save(_ summary: DailySummary) async throws
    func save(_ checkIn: CheckIn) async throws       // replaces the check-in of the same day
    func deleteExpired(today: TellsDay) async throws  // SPEC.md Section 4.3
    func deleteAll() async throws
}

/// The days that `deleteExpired(today:)` keeps (DEC-13).
public enum Retention {
    public static let days = 30

    public static func isExpired(_ day: TellsDay, today: TellsDay) -> Bool {
        day < today.adding(days: -days)
    }
}

/// The test conformer. It keeps all values in memory.
public actor InMemoryFeatureStore: FeatureStore {
    private var rows: [FeatureRow] = []
    private var daily: [TellsDay: DailyRow] = [:]
    private var summaries: [TellsDay: DailySummary] = [:]
    private var checkInsByDay: [TellsDay: CheckIn] = [:]

    public init() {}

    public func save(_ row: FeatureRow) async throws { rows.append(row) }
    public func save(_ row: DailyRow) async throws { daily[row.day] = row }
    public func save(_ summary: DailySummary) async throws { summaries[summary.day] = summary }
    public func save(_ checkIn: CheckIn) async throws { checkInsByDay[checkIn.day] = checkIn }

    public func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow] {
        rows
            .filter { row in (sensor == nil || row.sensor == sensor) && interval.contains(row.windowStart) }
            .sorted { $0.windowStart < $1.windowStart }
    }

    public func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow] {
        Self.values(daily, in: days)
    }

    public func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary] {
        Self.values(summaries, in: days)
    }

    public func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn] {
        Self.values(checkInsByDay, in: days)
    }

    public func deleteExpired(today: TellsDay) async throws {
        rows.removeAll { Retention.isExpired($0.day, today: today) }
        daily = daily.filter { !Retention.isExpired($0.key, today: today) }
        checkInsByDay = checkInsByDay.filter { !Retention.isExpired($0.key, today: today) }
    }

    public func deleteAll() async throws {
        rows.removeAll()
        daily.removeAll()
        summaries.removeAll()
        checkInsByDay.removeAll()
    }

    private static func values<Value>(_ byDay: [TellsDay: Value], in days: ClosedRange<TellsDay>) -> [Value] {
        byDay.filter { days.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
    }
}
