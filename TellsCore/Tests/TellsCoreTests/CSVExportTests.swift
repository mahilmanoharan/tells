import Foundation
import Testing
@testable import TellsCore

@Suite("CSVExport")
struct CSVExportTests {
    private func name(_ text: String) throws -> FeatureName { try #require(FeatureName(text)) }

    private func windowRows() throws -> [FeatureRow] {
        let key = try name("keyboard.key_count")
        let rate = try name("keyboard.median_iki_ms")
        let idle = try name("activity.idle_s")
        return [
            // 2026-11-21T13:00:00Z, local offset -05:00
            FeatureRow(sensor: .keyboard, schemaVersion: 3, windowStart: Date(timeIntervalSince1970: 1_795_266_000),
                       utcOffsetMinutes: -300, day: TellsDay(yyyymmdd: 20261121), coverageSeconds: 300,
                       values: [key: 42, rate: 118.5]),
            // 2026-11-21T13:05:00Z, local offset +05:30 (18:35 local)
            FeatureRow(sensor: .activity, schemaVersion: 1, windowStart: Date(timeIntervalSince1970: 1_795_266_300),
                       utcOffsetMinutes: 330, day: TellsDay(yyyymmdd: 20261121), coverageSeconds: 61.25,
                       values: [idle: 0.5]),
        ]
    }

    @Test func windowsText() throws {
        let expected = """
        day,window_start,sensor,schema_version,coverage_s,activity.idle_s,keyboard.key_count,keyboard.median_iki_ms
        2026-11-21,2026-11-21T08:00:00-05:00,keyboard,3,300,,42,118.5
        2026-11-21,2026-11-21T18:35:00+05:30,activity,1,61.25,0.5,,

        """
        #expect(CSVExport.windowsCSV(try windowRows()) == expected)
    }

    @Test func daysText() throws {
        let rows = [
            DailyRow(day: TellsDay(yyyymmdd: 20261122), schemaVersions: [.keyboard: 3],
                     values: [try name("keyboard.day_key_count"): 1234.5678912]),
            DailyRow(day: TellsDay(yyyymmdd: 20261121), schemaVersions: [.keyboard: 3, .activity: 1],
                     values: [try name("activity.first_input_min"): 480, try name("keyboard.day_key_count"): 1000]),
        ]
        let expected = """
        day,schema_version.activity,schema_version.keyboard,activity.first_input_min,keyboard.day_key_count
        2026-11-21,1,3,480,1000
        2026-11-22,,3,,1234.567891

        """
        #expect(CSVExport.daysCSV(rows) == expected)
    }

    @Test func checkInsText() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let rows = [
            CheckIn(day: TellsDay(yyyymmdd: 20261121), savedAt: Date(timeIntervalSince1970: 1_795_266_000),
                    scores: [.energy: 4, .social: 2]),   // mood skipped
        ]
        let expected = """
        day,saved_at,energy,mood,social
        2026-11-21,2026-11-21T14:00:00+01:00,4,,2

        """
        #expect(CSVExport.checkInsCSV(rows, timeZone: zone) == expected)
    }

    @Test func emptyInputGivesHeaderOnly() {
        #expect(CSVExport.windowsCSV([]) == "day,window_start,sensor,schema_version,coverage_s\n")
        #expect(CSVExport.daysCSV([]) == "day\n")
        #expect(CSVExport.checkInsCSV([]) == "day,saved_at,energy,mood,social\n")
    }

    @Test func nonFiniteValueIsEmptyCell() throws {
        let key = try name("keyboard.key_count")
        let row = FeatureRow(sensor: .keyboard, schemaVersion: 1, windowStart: Date(timeIntervalSince1970: 0),
                             utcOffsetMinutes: 0, day: TellsDay(yyyymmdd: 19700101), coverageSeconds: 60, values: [key: .nan])
        #expect(CSVExport.windowsCSV([row]).hasSuffix("keyboard,1,60,\n"))
    }

    @Test func dataLinesHaveNoLettersExceptSensorValues() async throws {
        let zone = try #require(TimeZone(secondsFromGMT: -300 * 60))
        let texts = [
            CSVExport.windowsCSV(try windowRows()),
            CSVExport.daysCSV([DailyRow(day: TellsDay(yyyymmdd: 20261121), schemaVersions: [.keyboard: 3, .appswitch: 1],
                                        values: [try name("appswitch.switch_count"): 12])]),
            CSVExport.checkInsCSV([CheckIn(day: TellsDay(yyyymmdd: 20261121), savedAt: Date(timeIntervalSince1970: 1_795_266_000),
                                           scores: [.mood: 3])], timeZone: zone),
        ]
        for text in texts {
            for line in text.split(separator: "\n").dropFirst() {
                var rest = String(line)
                rest = rest.replacing(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}/, with: "")
                for sensor in SensorID.allCases { rest = rest.replacingOccurrences(of: sensor.rawValue, with: "") }
                #expect(!rest.contains { $0.isLetter }, "letters in: \(line)")
            }
        }
    }

    @Test func exportAllWritesThreeFilesOfTheRange() async throws {
        let store = InMemoryFeatureStore()
        let inside = TellsDay(yyyymmdd: 20261121)
        let outside = TellsDay(yyyymmdd: 20261001)
        let key = try name("keyboard.key_count")
        for day in [inside, outside] {
            try await store.save(FeatureRow(sensor: .keyboard, schemaVersion: 1, windowStart: Date(timeIntervalSince1970: 1_795_266_000),
                                            utcOffsetMinutes: 0, day: day, coverageSeconds: 300, values: [key: 1]))
            try await store.save(DailyRow(day: day, schemaVersions: [.keyboard: 1], values: [key: 2]))
            try await store.save(CheckIn(day: day, savedAt: Date(timeIntervalSince1970: 5), scores: [.energy: 3]))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("csv-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try await CSVExport.exportAll(from: store, days: inside.adding(days: -29)...inside, to: folder)

        #expect(urls.map(\.lastPathComponent) == ["windows.csv", "days.csv", "checkins.csv"])
        for (url, expectedLines) in zip(urls, [2, 2, 2]) {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.split(separator: "\n").count == expectedLines)
            #expect(text.contains("2026-11-21"))
            #expect(!text.contains("2026-10-01"))
        }
    }
}
