import Foundation

/// CSV text for the gate export (SPEC.md 4.4, D-043). The text has no bundle IDs, key data or text.
/// Pure functions: the same input gives the same text.
public enum CSVExport {
    // DEFAULT: D-077
    public static let windowsFile = "windows.csv"
    public static let daysFile = "days.csv"
    public static let checkInsFile = "checkins.csv"

    public static func windowsCSV(_ rows: [FeatureRow]) -> String {
        let sorted = rows.sorted { ($0.windowStart, $0.sensor.rawValue) < ($1.windowStart, $1.sensor.rawValue) }
        let features = featureColumns(sorted.map(\.values))
        let header = ["day", "window_start", "sensor", "schema_version", "coverage_s"] + features.map(\.rawValue)
        let lines = sorted.map { row in
            [
                dayText(row.day),
                isoText(row.windowStart, offsetMinutes: row.utcOffsetMinutes),
                row.sensor.rawValue,
                String(row.schemaVersion),
                numberText(row.coverageSeconds),
            ] + features.map { numberCell(row.values[$0]) }
        }
        return text([header] + lines)
    }

    public static func daysCSV(_ rows: [DailyRow]) -> String {
        let sorted = rows.sorted { $0.day < $1.day }
        let sensors = Set(sorted.flatMap { $0.schemaVersions.keys }).sorted { $0.rawValue < $1.rawValue }
        let features = featureColumns(sorted.map(\.values))
        let header = ["day"] + sensors.map { "schema_version.\($0.rawValue)" } + features.map(\.rawValue)
        let lines = sorted.map { row in
            [dayText(row.day)]
                + sensors.map { row.schemaVersions[$0].map(String.init) ?? "" }
                + features.map { numberCell(row.values[$0]) }
        }
        return text([header] + lines)
    }

    /// `timeZone` sets the offset of `saved_at`.
    public static func checkInsCSV(_ checkIns: [CheckIn], timeZone: TimeZone = .current) -> String {
        let header = ["day", "saved_at"] + CheckInItem.allCases.map(\.rawValue)
        let lines = checkIns.sorted { $0.day < $1.day }.map { checkIn in
            let offset = timeZone.secondsFromGMT(for: checkIn.savedAt) / 60
            return [dayText(checkIn.day), isoText(checkIn.savedAt, offsetMinutes: offset)]
                + CheckInItem.allCases.map { checkIn.scores[$0].map(String.init) ?? "" }
        }
        return text([header] + lines)
    }

    /// Reads all rows of `days` and writes the 3 files into `folder`. Each file is written atomically.
    /// Returns the URLs that were written.
    @discardableResult
    public static func exportAll(from reader: any FeatureReader, days: ClosedRange<TellsDay>, to folder: URL) async throws -> [URL] {
        let everything = DateInterval(start: .distantPast, end: .distantFuture)
        let windows = try await reader.featureRows(nil, in: everything).filter { days.contains($0.day) }
        let daily = try await reader.dailyRows(days)
        let checkIns = try await reader.checkIns(days)
        let files = [
            (windowsFile, windowsCSV(windows)),
            (daysFile, daysCSV(daily)),
            (checkInsFile, checkInsCSV(checkIns)),
        ]
        return try files.map { name, content in
            let url = folder.appendingPathComponent(name)
            try Data(content.utf8).write(to: url, options: .atomic)
            return url
        }
    }

    // MARK: Cells

    private static func featureColumns(_ vectors: [FeatureVector]) -> [FeatureName] {
        Set(vectors.flatMap { $0.keys }).sorted { $0.rawValue < $1.rawValue }
    }

    private static func text(_ table: [[String]]) -> String {
        table.map { $0.map(quoted).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ cell: String) -> String {
        guard cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func dayText(_ day: TellsDay) -> String {
        String(format: "%04d-%02d-%02d", day.yyyymmdd / 10_000, day.yyyymmdd / 100 % 100, day.yyyymmdd % 100)
    }

    private static func numberCell(_ value: Double?) -> String {
        value.map(numberText) ?? ""
    }

    /// Plain decimal, up to 6 digits after the point, no trailing zeros. A value that is not finite is an empty cell.
    private static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        var result = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result == "-0" ? "0" : result
    }

    private static func isoText(_ date: Date, offsetMinutes: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let sign = offsetMinutes < 0 ? "-" : "+"
        let magnitude = abs(offsetMinutes)
        return formatter.string(from: date) + sign + String(format: "%02d:%02d", magnitude / 60, magnitude % 60)
    }
}
