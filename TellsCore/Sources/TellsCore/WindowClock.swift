import Foundation

/// Closes each 5-minute window and turns its raw samples into one `FeatureRow` for each sensor
/// (SPEC.md 1.2 steps 3 to 6). It has no timer of its own: the injected `sleepUntil` waits.
public actor WindowClock {
    public static let windowLength: TimeInterval = 300

    // DEFAULT: D-036
    public static let minimumCoverage: TimeInterval = 60

    private let buffer: RawEventBuffer
    private let extractors: [SensorID: any FeatureExtractor]
    private let store: any FeatureStore
    private let calendar: Calendar
    private let sleepUntil: @Sendable (Date) async throws -> Void
    private let onSaveFailure: @Sendable (any Error) -> Void
    private let onWindowClosed: @Sendable (Date) -> Void

    private var running: Set<SensorID> = []
    private var windowStart: Date?
    private var sensorStart: [SensorID: Date] = [:]   // late sensors, until the window closes
    private var lastAppCategory: Double?      // in memory only; stop clears it (D-066)
    private var loop: Task<Void, Never>?

    public init(buffer: RawEventBuffer, extractors: [any FeatureExtractor], store: any FeatureStore,
                calendar: Calendar = .current,
                sleepUntil: @escaping @Sendable (Date) async throws -> Void = { date in
                    try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                },
                onSaveFailure: @escaping @Sendable (any Error) -> Void = { _ in },
                onWindowClosed: @escaping @Sendable (Date) -> Void = { _ in }) {
        self.buffer = buffer
        self.extractors = Dictionary(extractors.map { ($0.sensor, $0) }, uniquingKeysWith: { first, _ in first })
        self.store = store
        self.calendar = calendar
        self.sleepUntil = sleepUntil
        self.onSaveFailure = onSaveFailure
        self.onWindowClosed = onWindowClosed
    }

    /// Opens a window at `time` for the sensors that run. It ends at the next 5-minute boundary.
    // DEFAULT: D-067
    public func start(sensors: Set<SensorID>, at time: Date) async {
        await endLoop()
        running = sensors
        sensorStart = [:]
        windowStart = time
        lastAppCategory = nil
        guard !sensors.isEmpty else { return }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    /// Adds sensors that started at `time`, after the window opened. Their row in this window covers
    /// only the time from `time` to the close, and is skipped under 60 s.
    // DEFAULT: D-080
    public func add(sensors: Set<SensorID>, at time: Date) {
        guard windowStart != nil else { return }
        running.formUnion(sensors)
        for sensor in sensors { sensorStart[sensor] = time }
        if loop == nil { loop = Task { [weak self] in await self?.runLoop() } }
    }

    /// Closes the current window as a partial window. It clears the buffer and the last app category.
    public func stop(at time: Date) async {
        await endLoop()
        if let start = windowStart, !running.isEmpty {
            await close(window: DateInterval(start: start, end: max(start, time)), carryOver: false)
        }
        running = []
        sensorStart = [:]
        windowStart = nil
        lastAppCategory = nil
        await buffer.removeAll()
    }

    /// Closes the window at `boundary` and opens the next one. The loop calls it. Tests call it too.
    func closeWindow(at boundary: Date) async {
        guard let start = windowStart, !running.isEmpty else { return }
        await close(window: DateInterval(start: start, end: max(start, boundary)), carryOver: true)
        windowStart = boundary
    }

    public var isRunning: Bool { windowStart != nil }

    func waitForLoop() async { await loop?.value }

    func nextBoundary(after time: Date) -> Date {
        // DEFAULT: D-068
        let length = Self.windowLength
        return Date(timeIntervalSince1970: ((time.timeIntervalSince1970 / length).rounded(.down) + 1) * length)
    }

    private func runLoop() async {
        while !Task.isCancelled, let start = windowStart {
            let boundary = nextBoundary(after: start)
            do { try await sleepUntil(boundary) } catch { return }
            if Task.isCancelled { return }
            await closeWindow(at: boundary)
        }
    }

    /// Cancels the loop and waits for a close that it has started. Actors are reentrant, so start and stop
    /// must not run their own work while a close is suspended (check 2).
    private func endLoop() async {
        let old = loop
        loop = nil
        old?.cancel()
        await old?.value
    }

    private func close(window: DateInterval, carryOver: Bool) async {
        let sensors = running
        var inputs: [(any FeatureExtractor, [SensorSample], DateInterval)] = []
        for sensor in sensors.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let extractor = extractors[sensor] else { continue }
            let own = DateInterval(start: min(window.end, max(window.start, sensorStart[sensor] ?? window.start)), end: window.end)
            inputs.append((extractor, await buffer.samples(for: sensor, in: own), own))
        }
        sensorStart = [:]
        if let category = Self.lastCategory(in: inputs.first { $0.0.sensor == .appswitch }?.1 ?? []) {
            lastAppCategory = category
        }
        for row in await extractRows(inputs.filter { $0.2.duration >= Self.minimumCoverage }) { await save(row) }
        for sensor in sensors { await buffer.removeSamples(for: sensor, before: window.end) }
        onWindowClosed(window.end)   // the rows are saved
        if carryOver, sensors.contains(.appswitch), let category = lastAppCategory {
            // D-066: the next window starts with the app that is in front.
            await buffer.append(SensorSample(sensor: .appswitch, time: window.end, kind: .appFrontmost, value: category))
        }
    }

    private static func lastCategory(in samples: [SensorSample]) -> Double? {
        samples.last { $0.kind == .appActivated || $0.kind == .appFrontmost }?.value
    }

    /// Each extractor runs on its own background task.
    private func extractRows(_ inputs: [(any FeatureExtractor, [SensorSample], DateInterval)]) async -> [FeatureRow] {
        let calendar = calendar
        return await withTaskGroup(of: FeatureRow.self) { group in
            for (extractor, samples, window) in inputs {
                let offset = calendar.timeZone.secondsFromGMT(for: window.start) / 60
                let day = TellsDay(window.start, calendar: calendar)
                group.addTask {
                    FeatureRow(sensor: extractor.sensor, schemaVersion: extractor.schemaVersion,
                               windowStart: window.start, utcOffsetMinutes: offset, day: day,
                               coverageSeconds: window.duration,
                               values: extractor.extractWindow(samples, window: window))
                }
            }
            var rows: [FeatureRow] = []
            for await row in group { rows.append(row) }
            return rows
        }
    }

    private func save(_ row: FeatureRow) async {
        do { try await store.save(row) } catch { onSaveFailure(error) }
    }
}
