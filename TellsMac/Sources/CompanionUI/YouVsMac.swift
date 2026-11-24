import Foundation
import Observation
import SwiftUI
import TellsCore

/// The text of "You vs. your Mac" (design/experiences.md Section 3).
/// No medical words. "Predicts", not "causes" (design/experiences.md 1.1).
public enum YouVsMacText {
    public static let name = "You vs. your Mac"
    public static let practiceBanner = "Practice mode. The Mac guess comes from a test model."
    public static let unreadable = "Tells could not read your data. Try again later."
    public static let notEnoughData = "Not enough data today for a Mac guess. Your check-in is saved."
    public static let noTargetScore = "Your check-in has no score for this item, so this day has no score."
    public static let noForecast = "You gave no forecast today, so this day has no score."
    public static let tie = "Today is a tie."
    public static let macCloser = "The Mac guess was closer today."
    public static let youCloser = "Your forecast was closer today."

    public static func ask(target: String) -> String { "What will your \(target) check-in be today?" }

    public static func progress(have: Int, need: Int) -> String { "\(have) of \(need) windows today" }

    public static func values(target: String, forecast: Int?, label: Int?, mac: Double?) -> String {
        var parts: [String] = []
        if let mac { parts.append("The Mac predicted \(format(mac)).") }
        if let label { parts.append("Your \(target) check-in was \(label).") }
        if let forecast { parts.append("Your forecast was \(forecast).") }
        return parts.joined(separator: " ")
    }

    public static func format(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// The result of one day.
public enum YouVsMacWinner: String, Sendable, Equatable { case you, mac, tie }

public struct YouVsMacScore: Sendable, Equatable {
    public var you = 0
    public var mac = 0
    public var tie = 0

    public init(you: Int = 0, mac: Int = 0, tie: Int = 0) {
        self.you = you
        self.mac = mac
        self.tie = tie
    }

    public var text: String { "You \(you), Mac \(mac), Tie \(tie)" }
}

public enum YouVsMacRules {
    /// If the two errors are within 0.25 of each other, the day is a tie.
    public static let tieMargin = 0.25
    /// The Mac guess has one decimal place.
    public static func rounded(_ prediction: Double) -> Double { (prediction * 10).rounded() / 10 }

    /// `mac` is the rounded guess. The closer guess wins.
    public static func winner(forecast: Int, mac: Double, label: Int) -> YouVsMacWinner {
        let youError = abs(Double(forecast) - Double(label))
        let macError = abs(mac - Double(label))
        if abs(youError - macError) <= tieMargin + 1e-9 { return .tie }
        return youError < macError ? .you : .mac
    }
}

/// The saved values: today's forecast and 2 scores (design/experiences.md Section 3, "Data inputs").
/// The practice score is separate from the real score. It is cleared when the model is not a mock.
// DEFAULT: D-094
@MainActor
struct YouVsMacStorage {
    let defaults: UserDefaults

    private enum Key {
        static let forecastDay = "tells.youVsMac.forecastDay"
        static let forecastValue = "tells.youVsMac.forecastValue"
        static func score(_ pool: String, _ part: String) -> String { "tells.youVsMac.\(pool).\(part)" }
    }

    static func pool(practice: Bool) -> String { practice ? "practice" : "real" }

    func forecast(for day: TellsDay) -> Int? {
        guard defaults.object(forKey: Key.forecastDay) != nil, defaults.integer(forKey: Key.forecastDay) == day.yyyymmdd,
              defaults.object(forKey: Key.forecastValue) != nil else { return nil }
        let value = defaults.integer(forKey: Key.forecastValue)
        return CheckInModel.scale.contains(value) ? value : nil
    }

    func saveForecast(_ value: Int, day: TellsDay) {
        guard CheckInModel.scale.contains(value) else { return }
        defaults.set(day.yyyymmdd, forKey: Key.forecastDay)
        defaults.set(value, forKey: Key.forecastValue)
    }

    /// Deletes a forecast of an earlier day.
    func purgeForecast(before day: TellsDay) {
        guard defaults.object(forKey: Key.forecastDay) != nil, defaults.integer(forKey: Key.forecastDay) != day.yyyymmdd else { return }
        defaults.removeObject(forKey: Key.forecastDay)
        defaults.removeObject(forKey: Key.forecastValue)
    }

    func score(practice: Bool) -> YouVsMacScore {
        let pool = Self.pool(practice: practice)
        return YouVsMacScore(
            you: defaults.integer(forKey: Key.score(pool, "you")),
            mac: defaults.integer(forKey: Key.score(pool, "mac")),
            tie: defaults.integer(forKey: Key.score(pool, "tie")))
    }

    /// Adds the day to the score one time only. Returns the score after the call.
    func addDay(_ winner: YouVsMacWinner, day: TellsDay, practice: Bool) -> YouVsMacScore {
        let pool = Self.pool(practice: practice)
        let scoredKey = Key.score(pool, "scoredDay")
        var score = self.score(practice: practice)
        guard defaults.integer(forKey: scoredKey) != day.yyyymmdd else { return score }
        switch winner {
        case .you: score.you += 1
        case .mac: score.mac += 1
        case .tie: score.tie += 1
        }
        defaults.set(score.you, forKey: Key.score(pool, "you"))
        defaults.set(score.mac, forKey: Key.score(pool, "mac"))
        defaults.set(score.tie, forKey: Key.score(pool, "tie"))
        defaults.set(day.yyyymmdd, forKey: scoredKey)
        return score
    }

    func hasForecast() -> Bool { defaults.object(forKey: Key.forecastDay) != nil || defaults.object(forKey: Key.forecastValue) != nil }

    /// Deletes the forecast and both scores ("Delete all data", SPEC.md 4.3).
    func clearAll() {
        for key in [Key.forecastDay, Key.forecastValue] { defaults.removeObject(forKey: key) }
        for pool in ["practice", "real"] {
            for part in ["you", "mac", "tie", "scoredDay"] { defaults.removeObject(forKey: Key.score(pool, part)) }
        }
    }

    func clearPracticeScore() {
        for part in ["you", "mac", "tie", "scoredDay"] { defaults.removeObject(forKey: Key.score("practice", part)) }
    }
}

/// What the experience reads about today. Check-ins, and features built from feature rows only (design/experiences.md 1.2).
struct YouVsMacSnapshot {
    let checkIn: CheckIn?
    let features: TodayFeatures

    static func read(in context: InsightContext, extractors: [any FeatureExtractor]) async throws -> YouVsMacSnapshot {
        let checkIns = try await context.store.checkIns(context.today...context.today)
        let rows = try await context.store.featureRows(nil, in: interval(around: context.today))
        return YouVsMacSnapshot(
            checkIn: checkIns.first,
            features: TodayFeatures.build(day: context.today, rows: rows, extractors: extractors))
    }

    /// 2 days before and 3 days after the day. A day feature reads rows of the evening before and the night after (DEC-3).
    private static func interval(around day: TellsDay) -> DateInterval {
        let calendar = Calendar.current
        let parts = DateComponents(year: day.yyyymmdd / 10_000, month: day.yyyymmdd / 100 % 100, day: day.yyyymmdd % 100)
        guard let start = calendar.date(from: parts),
              let from = calendar.date(byAdding: .day, value: -2, to: start),
              let to = calendar.date(byAdding: .day, value: 3, to: start) else {
            return DateInterval(start: .distantPast, end: .distantFuture)
        }
        return DateInterval(start: from, end: to)
    }
}

public struct YouVsMacReveal: Sendable, Equatable {
    public let forecast: Int?
    public let label: Int?
    public let mac: Double?              // rounded to one decimal place
    public let windowCount: Int
    public let winner: YouVsMacWinner?   // nil if a value is missing
}

/// The state of one open "You vs. your Mac" view.
@Observable
@MainActor
public final class YouVsMacModel {
    public enum Phase: Equatable {
        case loading
        case askForecast
        case checkIn
        case unreadable
        case reveal(YouVsMacReveal)
    }

    public private(set) var phase = Phase.loading
    public private(set) var score = YouVsMacScore()
    public let isPractice: Bool
    public let target: String
    public private(set) var checkInModel: CheckInModel?

    @ObservationIgnored private let context: InsightContext
    @ObservationIgnored private let storage: YouVsMacStorage
    @ObservationIgnored private let extractors: [any FeatureExtractor]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    var currentTask: Task<Void, Never>? { task }
    @ObservationIgnored private var isStopped = false

    init(context: InsightContext, storage: YouVsMacStorage, extractors: [any FeatureExtractor]) {
        self.context = context
        self.storage = storage
        self.extractors = extractors
        isPractice = context.model.isMock
        target = context.model.target.rawValue
    }

    /// Starts one load. A new load replaces the one that runs.
    public func start() {
        guard !isStopped else { return }
        task?.cancel()
        generation += 1
        let mine = generation
        task = Task { [weak self] in await self?.load(generation: mine) }
    }

    /// Ends all Task work. A late result changes nothing.
    public func stop() {
        isStopped = true
        generation += 1
        task?.cancel()
        task = nil
        checkInModel = nil
    }

    /// The user selects the forecast (1 to 5). It works only while the forecast question shows.
    public func selectForecast(_ value: Int) {
        guard phase == .askForecast, CheckInModel.scale.contains(value) else { return }
        storage.saveForecast(value, day: context.today)
        start()
    }

    private func isCurrent(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == generation }

    private func load(generation mine: Int) async {
        storage.purgeForecast(before: context.today)
        if !isPractice { storage.clearPracticeScore() }   // the practice score ends when G3 closes
        let snapshot: YouVsMacSnapshot
        do {
            snapshot = try await YouVsMacSnapshot.read(in: context, extractors: extractors)
        } catch {
            if isCurrent(mine) { phase = .unreadable }
            return
        }
        guard isCurrent(mine) else { return }
        guard let checkIn = snapshot.checkIn else {
            showCheckInSteps()
            return
        }
        // The prediction is read only after today's check-in is saved (design/experiences.md 1.6).
        let prediction = await PredictionGate.todaysPrediction(
            in: context, features: snapshot.features.values, windowCount: snapshot.features.windowCount)
        guard isCurrent(mine) else { return }
        reveal(checkIn: checkIn, prediction: prediction, windowCount: snapshot.features.windowCount)
    }

    private func showCheckInSteps() {
        score = storage.score(practice: isPractice)
        if storage.forecast(for: context.today) == nil {
            checkInModel = nil
            phase = .askForecast
        } else {
            checkInModel = CheckInModel(context: context, onSaved: { [weak self] in self?.start() })
            phase = .checkIn
        }
    }

    private func reveal(checkIn: CheckIn, prediction: Prediction?, windowCount: Int) {
        checkInModel = nil
        let forecast = storage.forecast(for: context.today)
        let label = checkIn.scores[context.model.target]
        let mac = prediction.map { YouVsMacRules.rounded($0.value) }
        var winner: YouVsMacWinner?
        if let forecast, let label, let mac {
            let result = YouVsMacRules.winner(forecast: forecast, mac: mac, label: label)
            winner = result
            score = storage.addDay(result, day: context.today, practice: isPractice)
        } else {
            score = storage.score(practice: isPractice)
        }
        phase = .reveal(YouVsMacReveal(forecast: forecast, label: label, mac: mac, windowCount: windowCount, winner: winner))
    }
}

struct YouVsMacView: View {
    let model: YouVsMacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPractice {
                Text(YouVsMacText.practiceBanner)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            content
            Spacer(minLength: 0)
            Text(model.score.text).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .unreadable:
            Text(YouVsMacText.unreadable)
        case .askForecast:
            VStack(alignment: .leading, spacing: 10) {
                Text(YouVsMacText.ask(target: model.target)).font(.title3)
                HStack {
                    ForEach(Array(CheckInModel.scale), id: \.self) { value in
                        Button("\(value)") { model.selectForecast(value) }
                            .accessibilityLabel("Forecast \(value)")
                    }
                }
            }
        case .checkIn:
            if let checkInModel = model.checkInModel { CheckInView(model: checkInModel) }
        case .reveal(let reveal):
            revealView(reveal)
        }
    }

    @ViewBuilder private func revealView(_ reveal: YouVsMacReveal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if reveal.mac == nil {
                Text(YouVsMacText.notEnoughData).font(.title3)
                Text(YouVsMacText.progress(have: reveal.windowCount, need: DataThreshold.minimumWindowsToday))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                value("Your forecast", reveal.forecast.map(String.init))
                if reveal.mac != nil { value("Mac guess", reveal.mac.map(YouVsMacText.format)) }
                value("Your check-in", reveal.label.map(String.init))
            }
            Text(YouVsMacText.values(target: model.target, forecast: reveal.forecast, label: reveal.label, mac: reveal.mac))
            if let winner = reveal.winner {
                Text(winnerText(winner)).font(.headline)
            } else if reveal.mac != nil {
                Text(reveal.label == nil ? YouVsMacText.noTargetScore : YouVsMacText.noForecast).foregroundStyle(.secondary)
            }
        }
    }

    private func winnerText(_ winner: YouVsMacWinner) -> String {
        switch winner {
        case .you: YouVsMacText.youCloser
        case .mac: YouVsMacText.macCloser
        case .tie: YouVsMacText.tie
        }
    }

    private func value(_ title: String, _ text: String?) -> some View {
        VStack {
            Text(text ?? "-").font(.largeTitle.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Menu item 1 (design/experiences.md Section 3).
// DEFAULT: D-094
@MainActor
public final class YouVsMacExperience: InsightExperience {
    public let id = "youVsMac"
    public let displayName = YouVsMacText.name
    public let glyph = "questionmark.circle"
    public let menuOrder = 1

    private let storage: YouVsMacStorage
    private let extractors: [any FeatureExtractor]
    private var model: YouVsMacModel?
    var currentModel: YouVsMacModel? { model }

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, extractors: [KeyboardExtractor(), ActivityExtractor(), AppSwitchExtractor()])
    }

    init(defaults: UserDefaults, extractors: [any FeatureExtractor]) {
        storage = YouVsMacStorage(defaults: defaults)
        self.extractors = extractors
    }

    /// Deletes a forecast of an earlier day. The app calls it at start and at each closed window, so a day end
    /// removes the forecast within one window. The view and `state(in:)` call it too.
    public static func purgeStaleForecast(today: TellsDay, defaults: UserDefaults = .standard) {
        YouVsMacStorage(defaults: defaults).purgeForecast(before: today)
    }

    /// Deletes the forecast and the scores. "Delete all data" calls it (SPEC.md 4.3).
    public static func clearStoredState(defaults: UserDefaults = .standard) {
        YouVsMacStorage(defaults: defaults).clearAll()
    }

    /// Today's prediction is not read before today's check-in is saved. This experience uses no permission and no hardware.
    public func state(in context: InsightContext) async -> ExperienceState {
        storage.purgeForecast(before: context.today)
        let base: ExperienceState = context.model.isMock ? .practice : .ready
        guard let snapshot = try? await YouVsMacSnapshot.read(in: context, extractors: extractors),
              snapshot.checkIn != nil else { return base }
        let prediction = await PredictionGate.todaysPrediction(
            in: context, features: snapshot.features.values, windowCount: snapshot.features.windowCount)
        guard prediction != nil else {
            return .notEnoughData(have: snapshot.features.windowCount, need: DataThreshold.minimumWindowsToday, unit: "windows")
        }
        return base
    }

    public func makeView(in context: InsightContext) -> AnyView {
        model?.stop()
        let model = YouVsMacModel(context: context, storage: storage, extractors: extractors)
        self.model = model
        model.start()
        return AnyView(YouVsMacView(model: model))
    }

    /// Ends all Task work. The experience has no audio and no haptics. The window frees the view.
    public func stop() {
        model?.stop()
        model = nil
    }
}
