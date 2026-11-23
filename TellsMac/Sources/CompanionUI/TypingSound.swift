import Foundation
import Observation
import SwiftUI
import TellsCore

/// The text of "Typing rhythm sound" (design/experiences.md Section 4).
/// No medical words. "Predicts", not "causes" (design/experiences.md 1.1).
public enum TypingSoundText {
    public static let name = "Typing rhythm sound"
    public static let practiceBanner = "Practice mode. The Mac guess comes from a test model."
    public static let unreadable = "Tells could not read your data. Try again later."
    public static let noReference = "No reference day yet. Tells needs one day with a check-in and 1 hour of typing."
    public static let noSound = "No sound output is available."
    public static let playFailed = "Tells could not play the sound. Try again."
    public static let noKeyboard = "This Mac does not have a keyboard."
    public static let openPermissions = "Open permissions"
    public static let playToday = "Play today"
    public static let playReference = "Play reference day"
    public static let playBoth = "Play both"
    public static let stop = "Stop"

    public static func intro(target: String) -> String {
        "Today's rhythm, next to your highest \(target) day of the last 30 days."
    }

    public static func notEnoughToday(have: Int, need: Int) -> String {
        "Not enough typing today. \(have) of \(need) windows."
    }

    public static func needsPermission(_ kind: PermissionKind) -> String {
        "Tells needs \(permissionName(kind)) for this."
    }

    public static func referenceLine(target: String, day: TellsDay, score: Int) -> String {
        "Reference day: \(date(day)). Your \(target) check-in was \(score)."
    }

    public static func date(_ day: TellsDay) -> String {
        String(format: "%04d-%02d-%02d", day.yyyymmdd / 10_000, day.yyyymmdd / 100 % 100, day.yyyymmdd % 100)
    }

    private static func permissionName(_ kind: PermissionKind) -> String {
        switch kind {
        case .inputMonitoring: "Input Monitoring"
        case .microphone: "Microphone"
        case .bluetooth: "Bluetooth"
        }
    }
}

/// One feature row of the keyboard sensor, as one bar of the beat.
struct TypingBar: Equatable, Sendable {
    let dayFraction: Double      // 0 at 04:00 local time (DEC-3), up to 1 at 04:00 the next day
    let keyCount: Double?
    let ikiMean: Double?
    let ikiSD: Double?

    /// A typing window has 20 or more key presses (D-027).
    var isTyping: Bool { (keyCount ?? 0) >= TypingDay.typingWindowKeys }
}

/// The keyboard windows of one day, in time order. Read from feature rows only (design/experiences.md 1.2).
struct TypingDay: Equatable, Sendable {
    // DEFAULT: D-027
    static let typingWindowKeys = 20.0
    static let usableTypingWindows = 12
    /// The Tells day starts at 04:00 (DEC-3).
    static let dayStartMinutes = 240

    let day: TellsDay
    let bars: [TypingBar]

    var typingWindowCount: Int { bars.filter(\.isTyping).count }
    var isUsable: Bool { typingWindowCount >= Self.usableTypingWindows }

    private static let keyCountName = FeatureName("keyboard.key_count")
    private static let meanName = FeatureName("keyboard.iki_mean_ms")
    private static let sdName = FeatureName("keyboard.iki_sd_ms")

    /// Groups keyboard rows by their `day` (set by the window clock with the 04:00 boundary).
    static func group(_ rows: [FeatureRow]) -> [TellsDay: TypingDay] {
        let byDay = Dictionary(grouping: rows.filter { $0.sensor == .keyboard }, by: \.day)
        return Dictionary(uniqueKeysWithValues: byDay.map { day, dayRows in
            let ordered = dayRows.sorted { $0.windowStart < $1.windowStart }
            return (day, TypingDay(day: day, bars: ordered.map(bar(from:))))
        })
    }

    private static func bar(from row: FeatureRow) -> TypingBar {
        func value(_ name: FeatureName?) -> Double? { name.flatMap { row.values[$0] } }
        let minutes = Int((row.windowStart.timeIntervalSince1970 / 60).rounded(.down)) + row.utcOffsetMinutes
        let shifted = ((minutes - dayStartMinutes) % 1_440 + 1_440) % 1_440
        return TypingBar(dayFraction: Double(shifted) / 1_440, keyCount: value(keyCountName),
                         ikiMean: value(meanName), ikiSD: value(sdName))
    }
}

/// The labeled, usable typing day with the highest target score of the last 30 days. Not today (D-025).
struct ReferenceDay: Equatable, Sendable {
    let day: TypingDay
    let score: Int

    static let lookbackDays = 30

    /// A tie goes to the newer day.
    static func pick(today: TellsDay, target: CheckInItem, checkIns: [CheckIn], days: [TellsDay: TypingDay]) -> ReferenceDay? {
        let oldest = today.adding(days: -lookbackDays)
        let candidates = checkIns.compactMap { checkIn -> ReferenceDay? in
            guard checkIn.day >= oldest, checkIn.day < today, let score = checkIn.scores[target],
                  let day = days[checkIn.day], day.isUsable else { return nil }
            return ReferenceDay(day: day, score: score)
        }
        return candidates.max { ($0.score, $0.day.day) < ($1.score, $1.day.day) }
    }
}

struct TypingSoundContent: Equatable, Sendable {
    let today: TypingDay
    let reference: ReferenceDay?
}

/// Reads today and the reference day. It reads the keyboard feature rows and check-ins only.
enum TypingSoundLoader {
    static func load(in context: InsightContext) async throws -> TypingSoundContent {
        let oldest = context.today.adding(days: -ReferenceDay.lookbackDays)
        let rows = try await context.store.featureRows(.keyboard, in: interval(from: oldest, to: context.today))
        let days = TypingDay.group(rows)
        let checkIns = try await context.store.checkIns(oldest...context.today.adding(days: -1))
        let today = days[context.today] ?? TypingDay(day: context.today, bars: [])
        let reference = ReferenceDay.pick(today: context.today, target: context.model.target, checkIns: checkIns, days: days)
        return TypingSoundContent(today: today, reference: reference)
    }

    /// 1 day of margin on each side. The rows carry their own `day`, so the code filters by it.
    static func interval(from first: TellsDay, to last: TellsDay) -> DateInterval {
        let calendar = Calendar.current
        func start(_ day: TellsDay) -> Date? {
            calendar.date(from: DateComponents(year: day.yyyymmdd / 10_000, month: day.yyyymmdd / 100 % 100, day: day.yyyymmdd % 100))
        }
        guard let from = start(first).flatMap({ calendar.date(byAdding: .day, value: -1, to: $0) }),
              let to = start(last).flatMap({ calendar.date(byAdding: .day, value: 3, to: $0) }) else {
            return DateInterval(start: .distantPast, end: .distantFuture)
        }
        return DateInterval(start: from, end: to)
    }
}

enum TypingSoundMode: Sendable, Equatable { case today, reference, both }

/// The state of one open "Typing rhythm sound" view.
@Observable
@MainActor
final class TypingSoundModel {
    enum Phase: Equatable {
        case loading
        case unreadable
        case permission(PermissionKind)
        case notOnThisMac
        case loaded(TypingSoundContent)
    }

    private(set) var phase = Phase.loading
    private(set) var playing: TypingSoundMode?
    private(set) var progress = 0.0
    private(set) var audioAvailable: Bool
    private(set) var playbackFailed = false
    let isPractice: Bool
    let target: String

    @ObservationIgnored private let context: InsightContext
    @ObservationIgnored private let player: any RhythmPlaying
    @ObservationIgnored private let availability: @MainActor () -> SensorAvailability
    @ObservationIgnored let openPermissions: @MainActor () -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false
    var currentLoadTask: Task<Void, Never>? { loadTask }
    var currentProgressTask: Task<Void, Never>? { progressTask }

    init(context: InsightContext, player: any RhythmPlaying,
         availability: @escaping @MainActor () -> SensorAvailability, openPermissions: @escaping @MainActor () -> Void) {
        self.context = context
        self.player = player
        self.availability = availability
        self.openPermissions = openPermissions
        audioAvailable = player.isAvailable
        isPractice = context.model.isMock
        target = context.model.target.rawValue
    }

    func start() {
        guard !isStopped else { return }
        loadTask?.cancel()
        generation += 1
        let mine = generation
        loadTask = Task { [weak self] in await self?.load(generation: mine) }
    }

    /// Ends all Task work and the sound. A late result changes nothing.
    func stop() {
        isStopped = true
        generation += 1
        playGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        progressTask?.cancel()
        progressTask = nil
        player.stop()
        playing = nil
        progress = 0
    }

    var content: TypingSoundContent? {
        if case .loaded(let content) = phase { return content }
        return nil
    }

    func canPlay(_ mode: TypingSoundMode) -> Bool {
        guard audioAvailable, let content else { return false }
        switch mode {
        case .today: return content.today.isUsable
        case .reference: return content.reference != nil
        case .both: return content.today.isUsable && content.reference != nil
        }
    }

    /// Plays 30 s of the beat. A new play replaces the one that runs.
    func play(_ mode: TypingSoundMode) {
        guard !isStopped, let content else { return }
        audioAvailable = player.isAvailable
        guard canPlay(mode) else { return }
        endPlayback()
        let today = TypingRhythm.render(TypingRhythm.bars(for: content.today))
        let reference = content.reference.map { TypingRhythm.render(TypingRhythm.bars(for: $0.day)) }
        let (left, right): ([Float], [Float])
        switch mode {
        case .today: (left, right) = (today, today)
        case .reference: (left, right) = (reference ?? [], reference ?? [])
        case .both: (left, right) = (today, reference ?? [])
        }
        do {
            try player.play(left: left, right: right)
        } catch {
            player.stop()
            playbackFailed = true
            return
        }
        playbackFailed = false
        playing = mode
        progress = 0
        let mine = playGeneration
        progressTask = Task { [weak self] in await self?.follow(playGeneration: mine) }
    }

    /// The user pushes Stop.
    func stopPlayback() {
        guard !isStopped else { return }
        endPlayback()
    }

    /// The place of the marker on the timeline of `track` (0 to 1), or nil if that track does not play.
    func markerFraction(for track: TypingSoundMode) -> Double? {
        guard let playing, let content else { return nil }
        let day: TypingDay?
        switch track {
        case .today where playing != .reference: day = content.today
        case .reference where playing != .today: day = content.reference?.day
        default: day = nil
        }
        guard let day, !day.bars.isEmpty else { return nil }
        let index = min(day.bars.count - 1, Int(progress * Double(day.bars.count)))
        return day.bars[index].dayFraction
    }

    private func endPlayback() {
        playGeneration += 1
        progressTask?.cancel()
        progressTask = nil
        player.stop()
        playing = nil
        progress = 0
    }

    private func isCurrent(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == generation }
    private func isCurrentPlay(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == playGeneration }

    private func follow(playGeneration mine: Int) async {
        while isCurrentPlay(mine) {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard isCurrentPlay(mine) else { return }
            if player.isPlaying {
                progress = player.progress
            } else {
                endPlayback()
                return
            }
        }
    }

    private func load(generation mine: Int) async {
        audioAvailable = player.isAvailable
        switch availability() {
        case .permissionDenied(let kind), .permissionNotAsked(let kind):
            if isCurrent(mine) { phase = .permission(kind) }
            return
        case .notOnThisMac:
            if isCurrent(mine) { phase = .notOnThisMac }
            return
        case .available, .disabledByFlag:
            break
        }
        do {
            let content = try await TypingSoundLoader.load(in: context)
            if isCurrent(mine) { phase = .loaded(content) }
        } catch {
            if isCurrent(mine) { phase = .unreadable }
        }
    }
}

struct TypingSoundView: View {
    let model: TypingSoundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPractice {
                Text(TypingSoundText.practiceBanner)
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
            Text(TypingSoundText.unreadable)
        case .permission(let kind):
            VStack(alignment: .leading, spacing: 10) {
                Text(TypingSoundText.needsPermission(kind))
                Button(TypingSoundText.openPermissions) { model.openPermissions() }
            }
        case .notOnThisMac:
            Text(TypingSoundText.noKeyboard)
        case .loaded(let content):
            loadedView(content)
        }
    }

    @ViewBuilder private func loadedView(_ content: TypingSoundContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TypingSoundText.intro(target: model.target)).font(.title3)
            if !content.today.isUsable {
                Text(TypingSoundText.notEnoughToday(have: content.today.typingWindowCount,
                                                    need: TypingDay.usableTypingWindows))
                    .foregroundStyle(.secondary)
            }
            timeline("Today", day: content.today, marker: model.markerFraction(for: .today))
            if let reference = content.reference {
                Text(TypingSoundText.referenceLine(target: model.target, day: reference.day.day, score: reference.score))
                timeline("Reference day", day: reference.day, marker: model.markerFraction(for: .reference))
            } else {
                Text(TypingSoundText.noReference).foregroundStyle(.secondary)
            }
            if !model.audioAvailable {
                Text(TypingSoundText.noSound).foregroundStyle(.secondary)
            }
            if model.playbackFailed {
                Text(TypingSoundText.playFailed).foregroundStyle(.red)
            }
            HStack {
                Button(TypingSoundText.playToday) { model.play(.today) }.disabled(!model.canPlay(.today))
                Button(TypingSoundText.playReference) { model.play(.reference) }.disabled(!model.canPlay(.reference))
                Button(TypingSoundText.playBoth) { model.play(.both) }.disabled(!model.canPlay(.both))
                Button(TypingSoundText.stop) { model.stopPlayback() }.disabled(model.playing == nil)
            }
        }
    }

    private func timeline(_ title: String, day: TypingDay, marker: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Canvas { graphics, size in
                graphics.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.15)))
                for bar in day.bars where bar.isTyping {
                    let x = bar.dayFraction * size.width
                    graphics.fill(Path(CGRect(x: x, y: size.height * 0.3, width: 2, height: size.height * 0.4)),
                                  with: .color(.accentColor))
                }
                if let marker {
                    graphics.fill(Path(CGRect(x: marker * size.width - 1, y: 0, width: 3, height: size.height)),
                                  with: .color(.primary))
                }
            }
            .frame(height: 24)
            .accessibilityLabel("\(title) timeline, 4 in the morning to 4 in the morning")
            HStack {
                Text("04:00"); Spacer(); Text("16:00"); Spacer(); Text("04:00")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// Menu item 2 (design/experiences.md Section 4).
// DEFAULT: D-095
@MainActor
public final class TypingSoundExperience: InsightExperience {
    public let id = "typingSound"
    public let displayName = TypingSoundText.name
    public let glyph = "waveform"
    public let menuOrder = 2

    private let player: any RhythmPlaying
    private let availability: @MainActor () -> SensorAvailability
    private let openPermissions: @MainActor () -> Void
    private var model: TypingSoundModel?
    var currentModel: TypingSoundModel? { model }

    /// `keyboardAvailability` tells if the keyboard sensor has its permission. `openPermissions` opens the permission screen.
    public convenience init(keyboardAvailability: @escaping @MainActor () -> SensorAvailability = { .available },
                            openPermissions: @escaping @MainActor () -> Void = {}) {
        self.init(player: EngineRhythmPlayer(), availability: keyboardAvailability, openPermissions: openPermissions)
    }

    init(player: any RhythmPlaying, availability: @escaping @MainActor () -> SensorAvailability,
         openPermissions: @escaping @MainActor () -> Void) {
        self.player = player
        self.availability = availability
        self.openPermissions = openPermissions
    }

    /// This experience shows no prediction, so it has no check-in gate (design/experiences.md 1.6).
    public func state(in context: InsightContext) async -> ExperienceState {
        switch availability() {
        case .permissionDenied(let kind), .permissionNotAsked(let kind): return .permissionDenied(kind)
        case .notOnThisMac: return .notOnThisMac(hardware: "keyboard")
        case .available, .disabledByFlag: break
        }
        let base: ExperienceState = context.model.isMock ? .practice : .ready
        guard let content = try? await TypingSoundLoader.load(in: context) else { return base }
        if !content.today.isUsable {
            return .notEnoughData(have: content.today.typingWindowCount, need: TypingDay.usableTypingWindows, unit: "windows")
        }
        return base
    }

    public func makeView(in context: InsightContext) -> AnyView {
        model?.stop()
        let model = TypingSoundModel(context: context, player: player, availability: availability,
                                     openPermissions: openPermissions)
        self.model = model
        model.start()
        return AnyView(TypingSoundView(model: model))
    }

    /// Ends all Task work and the sound. The experience has no haptics.
    public func stop() {
        model?.stop()
        model = nil
        player.stop()
    }
}
