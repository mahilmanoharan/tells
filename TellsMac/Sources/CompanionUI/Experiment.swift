import Foundation
import TellsCore

/// The text of "Experiment" (design/experiences.md Section 8).
/// No medical words. "Predicts", not "causes". Only this experience can say that a change "came with" a difference (1.1).
public enum ExperimentText {
    public static let name = "Experiment"
    public static let practiceBanner = "Practice mode. The Mac guess comes from a test model."
    public static let unreadable = "Tells could not read your data. Try again later."
    public static let intro = "Do this change for 7 days. Do your check-in each day."
    public static let choose = "Select one change."
    public static let start = "Start"
    public static let end = "End"
    public static let clearResult = "Clear result"
    public static let addWeek = "Add one more week"
    public static let startsTomorrow = "Your experiment starts tomorrow."
    public static let smallTest = "One week is a small test. Other things in your week can also change your check-ins."
    public static let chance = "This result can be chance."
    public static let doneMark = "Done"
    public static let notDoneMark = "Not done"
    public static let noDataMark = "No data yet"

    public static func dayLine(day: Int, of total: Int) -> String { "Day \(day) of \(total)" }

    public static func weakWeekBefore(have: Int) -> String {
        "Your last 7 days have \(have) \(have == 1 ? "check-in" : "check-ins"). The result can be not enough data."
    }

    /// Names only the period that fails.
    public static func notEnough(beforeHave: Int, changeHave: Int, need: Int) -> String {
        var parts = ["Not enough check-ins for a result."]
        if beforeHave < need { parts.append("Week before: \(beforeHave) of \(need) days.") }
        if changeHave < need { parts.append("Week of change: \(changeHave) of \(need) days.") }
        return parts.joined(separator: " ")
    }

    public static func didChange(_ days: Int, of total: Int) -> String { "You did the change on \(days) of \(total) days." }

    public static func result(target: String, difference: Double, low: Double, high: Double, extended: Bool) -> String {
        let period = extended ? "change period" : "change week"
        return "During the \(period), your \(target) check-ins were \(direction(difference)) on average "
            + "(95% range: \(signed(low)) to \(signed(high)))."
    }

    static func direction(_ difference: Double) -> String {
        let text = format(abs(difference))
        if text == "0.0" { return "the same" }
        return difference > 0 ? "\(text) higher" : "\(text) lower"
    }

    static func signed(_ value: Double) -> String {
        let text = format(abs(value))
        return value < 0 && text != "0.0" ? "-\(text)" : text
    }

    static func format(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// The 4 changes (design/experiences.md Section 8, D-028). All are about Mac use.
public enum ExperimentChange: String, CaseIterable, Sendable, Identifiable {
    case stopByTwentyThree
    case noInputAfterTwentyTwo
    case breakEveryNinety
    case fewerSwitches

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stopByTwentyThree: "Stop Mac use by 23:00"
        case .noInputAfterTwentyTwo: "No Mac input after 22:00"
        case .breakEveryNinety: "Take a 5-minute break each 90 minutes"
        case .fewerSwitches: "Fewer app switches"
        }
    }

    /// The change that matches a What-if slider (design/experiences.md Section 6, step 7).
    // DEFAULT: D-102
    public init?(sliderID: String) {
        switch sliderID {
        case WhatIfSliderKind.bedtime.rawValue: self = .stopByTwentyThree
        case WhatIfSliderKind.lateScrolling.rawValue: self = .noInputAfterTwentyTwo
        default: return nil
        }
    }

    var feature: FeatureName? {
        switch self {
        case .stopByTwentyThree: FeatureName("activity.last_input_min")
        case .noInputAfterTwentyTwo: FeatureName("activity.late_input_min")
        case .breakEveryNinety: FeatureName("activity.longest_stretch_min")
        case .fewerSwitches: FeatureName("appswitch.day_switch_rate_h")
        }
    }
}

/// The saved experiment: a change ID and dates. It has no text and no scores (design/experiences.md Section 8).
public struct ExperimentRecord: Sendable, Equatable {
    public let change: ExperimentChange
    public let start: TellsDay
    public let extended: Bool

    // DEFAULT: D-100
    static let weekLength = 7

    public init(change: ExperimentChange, start: TellsDay, extended: Bool = false) {
        self.change = change
        self.start = start
        self.extended = extended
    }

    public var dayCount: Int { extended ? 2 * Self.weekLength : Self.weekLength }
    public var lastDay: TellsDay { start.adding(days: dayCount - 1) }
    public var weekBefore: ClosedRange<TellsDay> { start.adding(days: -Self.weekLength)...start.adding(days: -1) }
    public var weekOfChange: ClosedRange<TellsDay> { start...lastDay }
    /// The check-ins of the week before leave the store after this day (DEC-5), so the record leaves too.
    func isExpired(today: TellsDay) -> Bool { Retention.isExpired(weekBefore.lowerBound, today: today) }

    func days() -> [TellsDay] { (0..<dayCount).map { start.adding(days: $0) } }
}

/// The record in `UserDefaults`. One experiment at a time.
// DEFAULT: D-100
struct ExperimentStorage {
    let defaults: UserDefaults

    private enum Key {
        static let change = "tells.experiment.change"
        static let start = "tells.experiment.start"
        static let extended = "tells.experiment.extended"
    }

    func record() -> ExperimentRecord? {
        guard let raw = defaults.string(forKey: Key.change), let change = ExperimentChange(rawValue: raw),
              defaults.object(forKey: Key.start) != nil else { return nil }
        let start = defaults.integer(forKey: Key.start)
        guard (19_000_101...99_991_231).contains(start), start / 100 % 100 >= 1, start / 100 % 100 <= 12,
              start % 100 >= 1, start % 100 <= 31 else { return nil }
        return ExperimentRecord(change: change, start: TellsDay(yyyymmdd: start), extended: defaults.bool(forKey: Key.extended))
    }

    func save(_ record: ExperimentRecord) {
        defaults.set(record.change.rawValue, forKey: Key.change)
        defaults.set(record.start.yyyymmdd, forKey: Key.start)
        defaults.set(record.extended, forKey: Key.extended)
    }

    func clear() {
        for key in [Key.change, Key.start, Key.extended] { defaults.removeObject(forKey: key) }
    }

    /// Deletes a record whose week before has left the store, and a record that does not parse.
    func purgeExpired(today: TellsDay) {
        let hasKeys = defaults.object(forKey: Key.change) != nil || defaults.object(forKey: Key.start) != nil
        guard hasKeys else { return }
        if let record = record(), !record.isExpired(today: today) { return }
        clear()
    }
}

/// Mean difference and a bootstrap 95% range (design/experiences.md Section 8, "Result method").
struct ExperimentResult: Sendable, Equatable {
    let beforeMean: Double
    let changeMean: Double
    let difference: Double
    let low: Double
    let high: Double
    let daysDone: Int
    let dayCount: Int
    var includesZero: Bool { low <= 0 && high >= 0 }
}

enum ExperimentRules {
    // DEFAULT: D-028
    static let minimumLabeledDays = 5
    static let resamples = 2000
    // DEFAULT: D-101
    static let stopByMinute = 23 * 60
    static let longestStretchMinutes = 90.0
    static let minimumBaselineDays = 3

    static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

    /// The 2.5th and 97.5th percentile of the difference of 2000 resampled means. A fixed seed, so a reopen gives the same range.
    /// nil if a group is empty or the task is cancelled.
    static func bootstrap(before: [Double], change: [Double], seed: UInt64) -> (low: Double, high: Double)? {
        guard !before.isEmpty, !change.isEmpty else { return nil }
        var random = SeededRandom(seed: seed)
        var differences: [Double] = []
        differences.reserveCapacity(resamples)
        for _ in 0..<resamples {
            if Task.isCancelled { return nil }
            differences.append(resampledMean(change, &random) - resampledMean(before, &random))
        }
        differences.sort()
        let lowIndex = Int((0.025 * Double(resamples)).rounded(.down))
        let highIndex = Int((0.975 * Double(resamples)).rounded(.up)) - 1
        return (differences[lowIndex], differences[min(highIndex, differences.count - 1)])
    }

    private static func resampledMean(_ values: [Double], _ random: inout SeededRandom) -> Double {
        var total = 0.0
        for _ in values { total += values[Int(random.nextUInt64() % UInt64(values.count))] }
        return total / Double(values.count)
    }

    /// nil if the day has no data for the change. Day D uses the row of day D, except "No Mac input after 22:00":
    /// it uses `activity.late_input_min` of day D+1 for the evening of day D (SPEC.md Section 6).
    static func didChange(
        _ change: ExperimentChange, day: TellsDay, rows: [TellsDay: DailyRow], baselineSwitchRate: Double?
    ) -> Bool? {
        guard let name = change.feature else { return nil }
        switch change {
        case .stopByTwentyThree:
            return rows[day]?.values[name].map { $0 <= Double(stopByMinute) }
        case .noInputAfterTwentyTwo:
            return rows[day.adding(days: 1)]?.values[name].map { $0 < 0.5 }
        case .breakEveryNinety:
            return rows[day]?.values[name].map { $0 <= longestStretchMinutes }
        case .fewerSwitches:
            guard let baselineSwitchRate, let rate = rows[day]?.values[name] else { return nil }
            return rate < baselineSwitchRate
        }
    }

    /// The mean rate of the week before. nil with fewer than 3 days of data.
    static func baselineSwitchRate(rows: [TellsDay: DailyRow], weekBefore: ClosedRange<TellsDay>) -> Double? {
        guard let name = ExperimentChange.fewerSwitches.feature else { return nil }
        var values: [Double] = []
        var day = weekBefore.lowerBound
        while day <= weekBefore.upperBound {
            if let value = rows[day]?.values[name] { values.append(value) }
            day = day.adding(days: 1)
        }
        return values.count >= minimumBaselineDays ? mean(values) : nil
    }
}

enum ExperimentMark: Sendable, Equatable {
    case done
    case notDone
    case noData      // no daily row yet, or a day that is not over
}

struct ExperimentDay: Sendable, Equatable, Identifiable {
    let day: TellsDay
    let number: Int
    let mark: ExperimentMark
    var id: Int { day.yyyymmdd }
}

enum ExperimentOutcome: Sendable, Equatable {
    case choose(weekBeforeLabeled: Int)
    case waiting(ExperimentRecord)
    case running(ExperimentRecord, dayNumber: Int, days: [ExperimentDay])
    case notEnough(ExperimentRecord, beforeHave: Int, changeHave: Int, days: [ExperimentDay])
    case result(ExperimentRecord, ExperimentResult, days: [ExperimentDay])
}

/// Reads only check-ins and daily rows (design/experiences.md 1.2). It reads no prediction and changes nothing in the model (hard rule 7).
enum ExperimentLoader {
    static func load(record: ExperimentRecord?, in context: InsightContext) async throws -> ExperimentOutcome {
        let target = context.model.target
        guard let record else {
            // The experiment starts the next Tells day. The week before is the 7 days that end today.
            let next = context.today.adding(days: 1)
            let before = next.adding(days: -ExperimentRecord.weekLength)...next.adding(days: -1)
            let checkIns = try await context.store.checkIns(before)
            return .choose(weekBeforeLabeled: labeled(checkIns, target: target).count)
        }
        if context.today < record.start { return .waiting(record) }
        let rowDays = record.weekBefore.lowerBound...record.lastDay.adding(days: 1)
        let daily = try await context.store.dailyRows(rowDays)
        let rows = Dictionary(daily.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let baseline = ExperimentRules.baselineSwitchRate(rows: rows, weekBefore: record.weekBefore)
        let days = record.days().enumerated().map { index, day in
            let didChange = day < context.today
                ? ExperimentRules.didChange(record.change, day: day, rows: rows, baselineSwitchRate: baseline) : nil
            let mark: ExperimentMark = didChange.map { $0 ? .done : .notDone } ?? .noData
            return ExperimentDay(day: day, number: index + 1, mark: mark)
        }
        if context.today <= record.lastDay {
            return .running(record, dayNumber: record.start.dayDistance(to: context.today) + 1, days: days)
        }
        let checkIns = try await context.store.checkIns(record.weekBefore.lowerBound...record.lastDay)
        let before = scores(checkIns, in: record.weekBefore, target: target)
        let during = scores(checkIns, in: record.weekOfChange, target: target)
        guard before.count >= ExperimentRules.minimumLabeledDays, during.count >= ExperimentRules.minimumLabeledDays else {
            return .notEnough(record, beforeHave: before.count, changeHave: during.count, days: days)
        }
        let seed = UInt64(record.start.yyyymmdd) &+ (record.extended ? 1 : 0)
        guard let range = ExperimentRules.bootstrap(before: before, change: during, seed: seed) else { throw CancellationError() }
        let beforeMean = ExperimentRules.mean(before)
        let changeMean = ExperimentRules.mean(during)
        let result = ExperimentResult(
            beforeMean: beforeMean, changeMean: changeMean, difference: changeMean - beforeMean,
            low: range.low, high: range.high, daysDone: days.filter { $0.mark == .done }.count, dayCount: record.dayCount)
        return .result(record, result, days: days)
    }

    static func labeled(_ checkIns: [CheckIn], target: CheckInItem) -> [CheckIn] {
        checkIns.filter { $0.scores[target] != nil }
    }

    static func scores(_ checkIns: [CheckIn], in days: ClosedRange<TellsDay>, target: CheckInItem) -> [Double] {
        checkIns.filter { days.contains($0.day) }.compactMap { $0.scores[target].map(Double.init) }
    }
}

extension TellsDay {
    /// The number of calendar days from this day to `other`. A later `other` gives a positive number.
    func dayDistance(to other: TellsDay) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        func date(_ day: TellsDay) -> Date? {
            calendar.date(from: DateComponents(year: day.yyyymmdd / 10_000, month: day.yyyymmdd / 100 % 100, day: day.yyyymmdd % 100))
        }
        guard let from = date(self), let to = date(other) else { return 0 }
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }
}
