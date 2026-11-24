import AppKit
import Foundation
import IOKit
import Observation
import SwiftUI
import TellsCore

/// The text of "Haptic week" (design/experiences.md Section 7).
/// No medical words. "Predicts", not "causes" (design/experiences.md 1.1).
public enum HapticWeekText {
    public static let name = "Haptic week"
    public static let practiceBanner = "Practice mode. The Mac guess comes from a test model."
    public static let unreadable = "Tells could not read your data. Try again later."
    public static let explanation = "Bumps show days with a check-in 1 point or more below your 30-day average."
    public static let noTrackpad = "This Mac has no Force Touch trackpad. The marks show the low days."
    public static let lowDayWord = "low day"

    public static func notEnoughWeek(have: Int, need: Int) -> String {
        "Not enough check-ins this week. \(have) of \(need) days."
    }

    public static func notEnoughMonth(have: Int, need: Int) -> String {
        "Not enough check-ins to make an average. \(have) of \(need) days."
    }

    public static func average(_ value: Double) -> String { "Your 30-day average: " + String(format: "%.1f", value) }

    /// The text below the strip after a click on a column.
    public static func dayLine(target: String, weekday: String, score: Int?) -> String {
        guard let score else { return "\(weekday): no check-in." }
        return "\(weekday): your \(target) check-in was \(score)."
    }

    /// The VoiceOver text of one column, for example "Tuesday, energy check-in 2, low day".
    public static func columnLabel(target: String, weekday: String, score: Int?, isLow: Bool) -> String {
        guard let score else { return "\(weekday), no check-in" }
        return "\(weekday), \(target) check-in \(score)" + (isLow ? ", \(lowDayWord)" : "")
    }

    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// The weekday of a calendar day. It does not depend on the time zone.
    public static func weekday(_ day: TellsDay) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = DateComponents(year: day.yyyymmdd / 10_000, month: day.yyyymmdd / 100 % 100, day: day.yyyymmdd % 100)
        guard let date = calendar.date(from: parts) else { return "" }
        let index = calendar.component(.weekday, from: date) - 1
        return weekdays.indices.contains(index) ? weekdays[index] : ""
    }
}

/// One column of the strip.
struct HapticDay: Equatable, Sendable, Identifiable {
    let day: TellsDay
    let score: Int?
    let isLow: Bool
    let isLowest: Bool
    var id: Int { day.yyyymmdd }
    var weekday: String { HapticWeekText.weekday(day) }
    /// One bump for a low day, two for the lowest day of the week (design/experiences.md Section 7, steps 4 and 5).
    var bumps: Int { isLowest ? 2 : (isLow ? 1 : 0) }
}

enum HapticWeekStatus: Equatable, Sendable {
    case ready
    case notEnoughWeek(have: Int)
    case notEnoughMonth(have: Int)
}

struct HapticWeekContent: Equatable, Sendable {
    let days: [HapticDay]       // 7 days, oldest first
    let weekLabeled: Int
    let monthLabeled: Int
    let mean: Double?
    let status: HapticWeekStatus
}

/// The rules of the strip. All day logic uses `TellsDay` values from the app (04:00 boundary, DEC-3).
// DEFAULT: D-099
enum HapticWeekRules {
    static let weekDays = 7
    static let averageDays = 30
    static let minimumWeekDays = 4
    static let minimumAverageDays = 7
    /// A low day is 1 point or more below the 30-day mean (D-030).
    static let lowMargin = 1.0

    /// The week is the 6 days before today and today. The average is the 30 days that end with today.
    static func build(checkIns: [CheckIn], target: CheckInItem, today: TellsDay) -> HapticWeekContent {
        var scores: [TellsDay: Int] = [:]
        for checkIn in checkIns {
            if let score = checkIn.scores[target] { scores[checkIn.day] = score }
        }
        let monthScores = (0..<averageDays).compactMap { scores[today.adding(days: -$0)] }
        let weekDays = (0..<Self.weekDays).reversed().map { today.adding(days: -$0) }
        let weekLabeled = weekDays.filter { scores[$0] != nil }.count
        let mean = monthScores.isEmpty ? nil : Double(monthScores.reduce(0, +)) / Double(monthScores.count)
        let status: HapticWeekStatus
        if weekLabeled < minimumWeekDays {
            status = .notEnoughWeek(have: weekLabeled)
        } else if monthScores.count < minimumAverageDays {
            status = .notEnoughMonth(have: monthScores.count)
        } else {
            status = .ready
        }
        // No marks and no bumps without enough data.
        let limit = status == .ready ? mean.map { $0 - lowMargin + 1e-9 } : nil
        func isLow(_ score: Int?) -> Bool {
            guard let score, let limit else { return false }
            return Double(score) <= limit
        }
        let lowScores = weekDays.compactMap { day in scores[day].flatMap { isLow($0) ? $0 : nil } }
        let lowest = lowScores.min()
        let days = weekDays.map { day -> HapticDay in
            let score = scores[day]
            let low = isLow(score)
            return HapticDay(day: day, score: score, isLow: low, isLowest: low && score == lowest)
        }
        return HapticWeekContent(days: days, weekLabeled: weekLabeled, monthLabeled: monthScores.count,
                                 mean: mean, status: status)
    }
}

/// Reads only check-ins (SPEC.md Section 6). It reads no prediction, so it has no check-in gate (design/experiences.md 1.6).
// DEFAULT: D-099
enum HapticWeekLoader {
    static func load(in context: InsightContext) async throws -> HapticWeekContent {
        let checkIns = try await context.store.checkIns(
            context.today.adding(days: -(HapticWeekRules.averageDays - 1))...context.today)
        return HapticWeekRules.build(checkIns: checkIns, target: context.model.target, today: context.today)
    }
}

/// The trackpad bump. One bump is one short pulse.
@MainActor
protocol HapticPlaying: AnyObject {
    /// false if this Mac has no Force Touch trackpad.
    var isAvailable: Bool { get }
    func bump()
    /// Ends all haptics.
    func stop()
}

/// Uses `NSHapticFeedbackManager` with the `.levelChange` pattern (design/experiences.md Section 7).
@MainActor
final class TrackpadHaptics: HapticPlaying {
    var isAvailable: Bool { Self.hasForceTouchTrackpad() }

    func bump() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// A bump is one short pulse and it cannot be recalled. The model stops the second bump of a pair.
    func stop() {}

    /// Looks for a multitouch device that gives haptic output. It reads the IOKit registry, a public framework.
    // DEFAULT: D-099
    nonisolated static func hasForceTouchTrackpad() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let value = IORegistryEntryCreateCFProperty(service, "ActuationSupported" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
            IOObjectRelease(service)
            if (value as? Bool) == true { return true }
            service = IOIteratorNext(iterator)
        }
        return false
    }
}

/// The state of one open "Haptic week" view.
@Observable
@MainActor
final class HapticWeekModel {
    enum Phase: Equatable {
        case loading
        case unreadable
        case loaded(HapticWeekContent)
    }

    static let secondBumpDelay = Duration.milliseconds(80)

    private(set) var phase = Phase.loading
    private(set) var hovered: Int?
    private(set) var selected: Int?
    private(set) var hasTrackpad: Bool
    let isPractice: Bool
    let target: String

    @ObservationIgnored private let context: InsightContext
    @ObservationIgnored private let player: any HapticPlaying
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var bumpGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var bumpTask: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false
    var currentLoadTask: Task<Void, Never>? { loadTask }
    var currentBumpTask: Task<Void, Never>? { bumpTask }

    init(context: InsightContext, player: any HapticPlaying) {
        self.context = context
        self.player = player
        hasTrackpad = player.isAvailable
        isPractice = context.model.isMock
        target = context.model.target.rawValue
    }

    var content: HapticWeekContent? {
        if case .loaded(let content) = phase { return content }
        return nil
    }

    /// The text below the strip after a click.
    var selectedLine: String? {
        guard let selected, let day = content?.days[safe: selected] else { return nil }
        return HapticWeekText.dayLine(target: target, weekday: day.weekday, score: day.score)
    }

    func start() {
        guard !isStopped else { return }
        loadTask?.cancel()
        generation += 1
        let mine = generation
        loadTask = Task { [weak self] in await self?.load(generation: mine) }
    }

    /// Ends all Task work and all haptics. A late result changes nothing.
    func stop() {
        isStopped = true
        generation += 1
        bumpGeneration += 1
        loadTask?.cancel()
        bumpTask?.cancel()
        loadTask = nil
        bumpTask = nil
        player.stop()
        hovered = nil
        selected = nil
    }

    /// The pointer is in column `column`, or outside the strip (nil). A bump plays when the pointer goes into a low-day column.
    func hover(column: Int?) {
        guard !isStopped else { return }
        guard column != hovered else { return }
        hovered = column
        guard let column, let content, content.status == .ready, let day = content.days[safe: column], day.bumps > 0 else { return }
        playBumps(day.bumps)
    }

    /// A click on a column shows the score of that day.
    func select(column: Int) {
        guard !isStopped, let content, content.days.indices.contains(column) else { return }
        selected = column
    }

    private func isCurrent(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == generation }
    private func isCurrentBump(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == bumpGeneration }

    /// One bump, or two bumps 80 ms apart. A new play replaces a pending second bump.
    private func playBumps(_ count: Int) {
        bumpTask?.cancel()
        bumpTask = nil
        bumpGeneration += 1
        hasTrackpad = player.isAvailable
        guard hasTrackpad else { return }
        player.bump()
        guard count > 1 else { return }
        let mine = bumpGeneration
        bumpTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.secondBumpDelay)
            } catch {
                return
            }
            guard let self, self.isCurrentBump(mine) else { return }
            self.player.bump()
            self.bumpTask = nil
        }
    }

    private func load(generation mine: Int) async {
        let loaded: HapticWeekContent
        do {
            loaded = try await HapticWeekLoader.load(in: context)
        } catch {
            if isCurrent(mine) { phase = .unreadable }
            return
        }
        guard isCurrent(mine) else { return }
        hasTrackpad = player.isAvailable
        phase = .loaded(loaded)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct HapticWeekView: View {
    let model: HapticWeekModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPractice {
                Text(HapticWeekText.practiceBanner)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            content
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .unreadable:
            Text(HapticWeekText.unreadable)
        case .loaded(let content):
            loadedView(content)
        }
    }

    @ViewBuilder private func loadedView(_ content: HapticWeekContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(HapticWeekText.explanation).font(.title3)
            switch content.status {
            case .ready:
                if let mean = content.mean { Text(HapticWeekText.average(mean)).foregroundStyle(.secondary) }
            case .notEnoughWeek(let have):
                Text(HapticWeekText.notEnoughWeek(have: have, need: HapticWeekRules.minimumWeekDays))
            case .notEnoughMonth(let have):
                Text(HapticWeekText.notEnoughMonth(have: have, need: HapticWeekRules.minimumAverageDays))
            }
            if !model.hasTrackpad {
                Text(HapticWeekText.noTrackpad).foregroundStyle(.secondary)
            }
            strip(content)
            if let line = model.selectedLine { Text(line) }
        }
    }

    private func strip(_ content: HapticWeekContent) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 6) {
                ForEach(Array(content.days.enumerated()), id: \.element.id) { index, day in
                    column(day, index: index)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let width = max(proxy.size.width, 1)
                    model.hover(column: min(max(Int(point.x / width * Double(content.days.count)), 0), content.days.count - 1))
                case .ended:
                    model.hover(column: nil)
                }
            }
        }
        .frame(height: 130)
    }

    private func column(_ day: HapticDay, index: Int) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(index == model.selected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15))
                if day.isLow {
                    // The raised mark for a low day (the visual fallback).
                    Capsule().fill(Color.primary).frame(width: 24, height: day.isLowest ? 12 : 6).padding(.top, 8)
                }
            }
            Text(String(day.weekday.prefix(3))).font(.caption)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.select(column: index) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HapticWeekText.columnLabel(target: model.target, weekday: day.weekday,
                                                       score: day.score, isLow: day.isLow))
        .accessibilityAddTraits(.isButton)
    }
}

/// Menu item 5 (design/experiences.md Section 7).
// DEFAULT: D-099
@MainActor
public final class HapticWeekExperience: InsightExperience {
    public let id = "hapticWeek"
    public let displayName = HapticWeekText.name
    public let glyph = "hand.point.up.left"
    public let menuOrder = 5

    private let player: any HapticPlaying
    private var model: HapticWeekModel?
    var currentModel: HapticWeekModel? { model }

    public convenience init() {
        self.init(player: TrackpadHaptics())
    }

    init(player: any HapticPlaying) {
        self.player = player
    }

    /// This experience shows no prediction, so it has no check-in gate (design/experiences.md 1.6).
    /// Not enough data comes first, then a missing trackpad, then practice or ready.
    public func state(in context: InsightContext) async -> ExperienceState {
        let base: ExperienceState = context.model.isMock ? .practice : .ready
        guard let content = try? await HapticWeekLoader.load(in: context) else { return base }
        switch content.status {
        case .notEnoughWeek(let have):
            return .notEnoughData(have: have, need: HapticWeekRules.minimumWeekDays, unit: "days")
        case .notEnoughMonth(let have):
            return .notEnoughData(have: have, need: HapticWeekRules.minimumAverageDays, unit: "days")
        case .ready:
            return player.isAvailable ? base : .notOnThisMac(hardware: "Force Touch trackpad")
        }
    }

    public func makeView(in context: InsightContext) -> AnyView {
        model?.stop()
        let model = HapticWeekModel(context: context, player: player)
        self.model = model
        model.start()
        return AnyView(HapticWeekView(model: model))
    }

    /// Ends all Task work and all haptics. The experience has no audio.
    public func stop() {
        model?.stop()
        model = nil
        player.stop()
    }
}
