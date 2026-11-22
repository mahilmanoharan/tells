import Foundation
import SwiftData

// DEC-2: these model names and field types are the on-disk schema of `Tells.store`.
// Values are JSON `[String: Double]` in `Data`. A day is an Int, for example 20261121.
// The check-in scores are JSON `[String: Int]`. No model keeps text from the user (hard rule 3).

@Model
final class FeatureRowRecord {
    var sensor: String
    var schemaVersion: Int
    var windowStart: Date
    var utcOffsetMinutes: Int
    var day: Int
    var coverageSeconds: Double
    var values: Data

    init(sensor: String, schemaVersion: Int, windowStart: Date, utcOffsetMinutes: Int,
         day: Int, coverageSeconds: Double, values: Data) {
        self.sensor = sensor
        self.schemaVersion = schemaVersion
        self.windowStart = windowStart
        self.utcOffsetMinutes = utcOffsetMinutes
        self.day = day
        self.coverageSeconds = coverageSeconds
        self.values = values
    }
}

@Model
final class DailyRowRecord {
    var day: Int
    var schemaVersions: Data      // JSON [String: Int], key = sensor raw value
    var values: Data

    init(day: Int, schemaVersions: Data, values: Data) {
        self.day = day
        self.schemaVersions = schemaVersions
        self.values = values
    }
}

@Model
final class DailySummaryRecord {
    var day: Int
    var values: Data

    init(day: Int, values: Data) {
        self.day = day
        self.values = values
    }
}

@Model
final class CheckInRecord {
    var day: Int
    var savedAt: Date
    var scores: Data              // JSON [String: Int], key = item raw value

    init(day: Int, savedAt: Date, scores: Data) {
        self.day = day
        self.savedAt = savedAt
        self.scores = scores
    }
}

/// Version 1 of the on-disk schema. A later change to a record needs a new `VersionedSchema`
/// and a migration stage in `TellsMigrationPlan`.
enum TellsSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [FeatureRowRecord.self, DailyRowRecord.self, DailySummaryRecord.self, CheckInRecord.self]
    }
}

enum TellsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TellsSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
