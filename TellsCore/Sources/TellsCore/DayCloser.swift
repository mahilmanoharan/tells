import Foundation

/// Closes a day at 04:00 local on the next day (DEC-3). It runs each extractor on the rows of the day,
/// saves one `DailyRow` and one `DailySummary`, and then deletes expired data (SPEC.md 4.3).
/// It has no timer of its own: the injected `sleepUntil` waits, as in `WindowClock`.
public actor DayCloser {
    /// The only names that a `DailySummary` keeps (SPEC.md 3.5, DEC-6).
    public static let summaryNames: [FeatureName] = [
        "keyboard.day_key_count", "keyboard.day_iki_median_ms",
        "activity.input_min", "activity.first_input_min", "activity.last_input_min",
        "appswitch.day_switch_count",
    ].compactMap { FeatureName($0) }

    private let extractors: [any FeatureExtractor]
    private let store: any FeatureStore
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let sleepUntil: @Sendable (Date) async throws -> Void
    private let onFailure: @Sendable (any Error) -> Void
    private var loop: Task<Void, Never>?

    public init(extractors: [any FeatureExtractor], store: any FeatureStore, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() },
                sleepUntil: @escaping @Sendable (Date) async throws -> Void = { date in
                    try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                },
                onFailure: @escaping @Sendable (any Error) -> Void = { _ in }) {
        self.extractors = extractors
        self.store = store
        self.calendar = calendar
        self.now = now
        self.sleepUntil = sleepUntil
        self.onFailure = onFailure
    }

    /// Deletes expired data once, then closes each day at its 04:00 boundary until `stop()`.
    public func start() async {
        loop?.cancel()
        await expire()
        loop = Task { [weak self] in await self?.runLoop() }
    }

    public func stop() async {
        let old = loop
        loop = nil
        old?.cancel()
        await old?.value
    }

    func waitForLoop() async { await loop?.value }

    /// The day that closes next: the day before the one that holds the 04:00 boundary after `time`.
    func nextClose(after time: Date) -> (day: TellsDay, at: Date) {
        // DEFAULT: D-072
        let boundary = calendar.nextDate(after: time, matching: DateComponents(hour: 4, minute: 0),
                                         matchingPolicy: .nextTime) ?? time.addingTimeInterval(86_400)
        return (TellsDay(boundary, calendar: calendar).adding(days: -1), boundary)
    }

    /// Makes the day rows of `day`, saves them and deletes expired data.
    func close(day: TellsDay) async {
        let span = Self.span(of: day, calendar: calendar)
        do {
            let rows = try await store.featureRows(nil, in: span)
            var values = FeatureVector()
            var versions: [SensorID: Int] = [:]
            for extractor in extractors {
                // Each extractor takes the rows it needs. `AppSwitchExtractor` also reads `activity` rows (D-066).
                values.merge(extractor.extractDay(rows, day: day)) { first, _ in first }
                if rows.contains(where: { $0.sensor == extractor.sensor }) { versions[extractor.sensor] = extractor.schemaVersion }
            }
            try await store.save(DailyRow(day: day, schemaVersions: versions, values: values))
            try await store.save(DailySummary(day: day, values: values.filter { Self.summaryNames.contains($0.key) }))
        } catch {
            onFailure(error)
        }
        await expire(today: day.adding(days: 1))
    }

    /// DEC-3: from 18:00 on day-1 to 04:00 on day+1, local time.
    static func span(of day: TellsDay, calendar: Calendar) -> DateInterval {
        func local(_ day: TellsDay, hour: Int) -> Date {
            calendar.date(from: DateComponents(year: day.yyyymmdd / 10_000, month: day.yyyymmdd / 100 % 100,
                                               day: day.yyyymmdd % 100, hour: hour)) ?? .distantPast
        }
        return DateInterval(start: local(day.adding(days: -1), hour: 18), end: local(day.adding(days: 1), hour: 4))
    }

    private func runLoop() async {
        var after = now()
        while !Task.isCancelled {
            let next = nextClose(after: after)
            after = next.at
            do { try await sleepUntil(next.at) } catch { return }
            if Task.isCancelled { return }
            await close(day: next.day)
        }
    }

    private func expire(today: TellsDay? = nil) async {
        do { try await store.deleteExpired(today: today ?? TellsDay(now(), calendar: calendar)) } catch { onFailure(error) }
    }
}
