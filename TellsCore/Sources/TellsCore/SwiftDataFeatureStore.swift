import Foundation
import SwiftData
import Synchronization

/// The store on disk (SPEC.md 4.1). All access runs on this actor, not on the main actor.
/// `save` has no suspension point and does not check for cancellation, so a cancelled task still saves its row.
@ModelActor
public actor SwiftDataFeatureStore: FeatureStore {
    // DEFAULT: D-071
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Tells/Tells.store")
    }

    private static let schema = Schema(versionedSchema: TellsSchemaV1.self)

    /// A store in the file at `url`. The folder is made if it is missing.
    public static func open(at url: URL = defaultURL) throws -> SwiftDataFeatureStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try make(ModelConfiguration(schema: schema, url: url))
    }

    /// A store that keeps its values in memory. For tests.
    public static func inMemory() throws -> SwiftDataFeatureStore {
        try make(ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    /// Core Data is not safe when many containers load from one schema at once (a crash in parallel tests).
    private static let containerLock = Mutex(())

    private static func make(_ configuration: ModelConfiguration) throws -> SwiftDataFeatureStore {
        let container = try containerLock.withLock { _ in
            try ModelContainer(for: schema, migrationPlan: TellsMigrationPlan.self, configurations: configuration)
        }
        return SwiftDataFeatureStore(modelContainer: container)
    }

    // MARK: Save

    public func save(_ row: FeatureRow) async throws {
        modelContext.insert(FeatureRowRecord(
            sensor: row.sensor.rawValue, schemaVersion: row.schemaVersion, windowStart: row.windowStart,
            utcOffsetMinutes: row.utcOffsetMinutes, day: row.day.yyyymmdd, coverageSeconds: row.coverageSeconds,
            values: try Self.encode(row.values)))
        try modelContext.save()
    }

    public func save(_ row: DailyRow) async throws {
        let day = row.day.yyyymmdd
        try modelContext.delete(model: DailyRowRecord.self, where: #Predicate { $0.day == day })
        modelContext.insert(DailyRowRecord(
            day: row.day.yyyymmdd,
            schemaVersions: try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: row.schemaVersions.map { ($0.key.rawValue, $0.value) })),
            values: try Self.encode(row.values)))
        try modelContext.save()
    }

    public func save(_ summary: DailySummary) async throws {
        let day = summary.day.yyyymmdd
        try modelContext.delete(model: DailySummaryRecord.self, where: #Predicate { $0.day == day })
        modelContext.insert(DailySummaryRecord(day: summary.day.yyyymmdd, values: try Self.encode(summary.values)))
        try modelContext.save()
    }

    public func save(_ checkIn: CheckIn) async throws {
        let day = checkIn.day.yyyymmdd
        try modelContext.delete(model: CheckInRecord.self, where: #Predicate { $0.day == day })
        let scores = Dictionary(uniqueKeysWithValues: checkIn.scores.map { ($0.key.rawValue, $0.value) })
        modelContext.insert(CheckInRecord(day: checkIn.day.yyyymmdd, savedAt: checkIn.savedAt,
                                          scores: try JSONEncoder().encode(scores)))
        try modelContext.save()
    }

    // MARK: Read

    public func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow] {
        let start = interval.start, end = interval.end
        let records = try modelContext.fetch(FetchDescriptor<FeatureRowRecord>(
            predicate: #Predicate { $0.windowStart >= start && $0.windowStart <= end },
            sortBy: [SortDescriptor(\.windowStart)]))
        return try records
            .filter { sensor == nil || $0.sensor == sensor?.rawValue }
            .compactMap { record in
                guard let id = SensorID(rawValue: record.sensor) else { return nil }
                return FeatureRow(sensor: id, schemaVersion: record.schemaVersion, windowStart: record.windowStart,
                                  utcOffsetMinutes: record.utcOffsetMinutes, day: TellsDay(yyyymmdd: record.day),
                                  coverageSeconds: record.coverageSeconds, values: try Self.decode(record.values))
            }
    }

    public func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow] {
        let low = days.lowerBound.yyyymmdd, high = days.upperBound.yyyymmdd
        return try modelContext.fetch(FetchDescriptor<DailyRowRecord>(
            predicate: #Predicate { $0.day >= low && $0.day <= high }, sortBy: [SortDescriptor(\.day)]))
            .map { record in
                let versions = try JSONDecoder().decode([String: Int].self, from: record.schemaVersions)
                return DailyRow(day: TellsDay(yyyymmdd: record.day),
                                schemaVersions: Dictionary(uniqueKeysWithValues: versions.compactMap { key, value in
                                    SensorID(rawValue: key).map { ($0, value) } }),
                                values: try Self.decode(record.values))
            }
    }

    public func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary] {
        let low = days.lowerBound.yyyymmdd, high = days.upperBound.yyyymmdd
        return try modelContext.fetch(FetchDescriptor<DailySummaryRecord>(
            predicate: #Predicate { $0.day >= low && $0.day <= high }, sortBy: [SortDescriptor(\.day)]))
            .map { DailySummary(day: TellsDay(yyyymmdd: $0.day), values: try Self.decode($0.values)) }
    }

    public func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn] {
        let low = days.lowerBound.yyyymmdd, high = days.upperBound.yyyymmdd
        return try modelContext.fetch(FetchDescriptor<CheckInRecord>(
            predicate: #Predicate { $0.day >= low && $0.day <= high }, sortBy: [SortDescriptor(\.day)]))
            .map { record in
                let raw = try JSONDecoder().decode([String: Int].self, from: record.scores)
                return CheckIn(day: TellsDay(yyyymmdd: record.day), savedAt: record.savedAt,
                               scores: Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                                   CheckInItem(rawValue: key).map { ($0, value) } }))
            }
    }

    // MARK: Delete

    public func deleteExpired(today: TellsDay) async throws {
        let limit = today.adding(days: -Retention.days).yyyymmdd   // a day below this is expired
        try modelContext.delete(model: FeatureRowRecord.self, where: #Predicate { $0.day < limit })
        try modelContext.delete(model: DailyRowRecord.self, where: #Predicate { $0.day < limit })
        try modelContext.delete(model: CheckInRecord.self, where: #Predicate { $0.day < limit })
        try modelContext.save()
    }

    public func deleteAll() async throws {
        try modelContext.delete(model: FeatureRowRecord.self)
        try modelContext.delete(model: DailyRowRecord.self)
        try modelContext.delete(model: DailySummaryRecord.self)
        try modelContext.delete(model: CheckInRecord.self)
        try modelContext.save()
    }

    // MARK: Helpers

    private static func encode(_ vector: FeatureVector) throws -> Data {
        try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: vector.map { ($0.key.rawValue, $0.value) }))
    }

    private static func decode(_ data: Data) throws -> FeatureVector {
        let raw = try JSONDecoder().decode([String: Double].self, from: data)
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in FeatureName(key).map { ($0, value) } })
    }
}
