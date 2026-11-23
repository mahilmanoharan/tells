import Foundation
import Observation
import SwiftUI
import TellsCore

/// The text of "Ghost racer" (design/experiences.md Section 5).
/// No medical words. "Predicts", not "causes" (design/experiences.md 1.1).
public enum GhostRacerText {
    public static let name = "Ghost racer"
    public static let practiceBanner = "Practice mode. The Mac guess comes from a test model."
    public static let unreadable = "Tells could not read your data. Try again later."
    public static let start = "Start"
    public static let again = "Again"
    public static let typeHere = "Type the sentence here"

    public static func intro(target: String) -> String {
        "The ghost types at the rhythm of your highest \(target) week."
    }

    public static func notEnoughForGhost(have: Int, need: Int, unit: String) -> String {
        "Not enough data for a ghost yet. \(have) of \(need) days with \(unit) in one week."
    }

    public static func yourTime(_ seconds: Double) -> String { "Your time: \(format(seconds)) s" }
    public static func ghostTime(_ seconds: Double) -> String { "Ghost time: \(format(seconds)) s" }
    public static func format(_ seconds: Double) -> String { String(format: "%.1f", seconds) }

    /// 20 original sentences, 40 to 60 characters each.
    static let sentences = [
        "The blue kite climbed above the quiet harbor.",
        "A small boat drifted past the old stone pier.",
        "Warm bread cooled on the sill by the window.",
        "The train crossed the bridge just after sunrise.",
        "We counted twelve green doors along the lane.",
        "Rain tapped the roof while the kettle began to hum.",
        "A tall lamp lit the path through the garden.",
        "The cat watched the clouds roll over the hill.",
        "Maria packed a map, two pears and a red scarf.",
        "Every shelf in the shop smelled of cedar and ink.",
        "The market opened early and the street filled fast.",
        "A cold wind turned the pages of the open book.",
        "He wrote the note twice and then tucked it away.",
        "Seven gray birds landed on the fence at noon.",
        "The river was wide and slow under the bridge.",
        "She tuned the old guitar until the room went still.",
        "Snow settled on the bikes outside the library.",
        "Our team met at the corner and walked to the park.",
        "A plain white cup sat beside the brass clock.",
        "The path bent left past the mill and the pond.",
    ]
}

/// The typing rhythm of the reference week.
struct GhostRhythm: Equatable, Sendable {
    let medianMs: Double
    let sdMs: Double

    /// The ghost never types faster than this step.
    // DEFAULT: D-097
    static let minimumStepMs = 30.0

    /// One step in seconds for each character. Each step is the median plus a random value from the variation.
    /// The seed is fixed for each sentence, so the ghost is the same each time (design/experiences.md Section 5).
    func steps(count: Int, seed: UInt64) -> [Double] {
        var random = SeededRandom(seed: seed)
        return (0..<count).map { _ in
            max(Self.minimumStepMs, medianMs + sdMs * random.nextGaussian()) / 1_000
        }
    }

    /// The time at which each character is done, in seconds from the start.
    func finishTimes(count: Int, seed: UInt64) -> [Double] {
        var total = 0.0
        return steps(count: count, seed: seed).map { step in
            total += step
            return total
        }
    }
}

/// SplitMix64 with a Box-Muller step. It has a fixed output for a fixed seed.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A value from 0 (not included) to 1 (included).
    mutating func nextUnit() -> Double { (Double(nextUInt64() >> 11) + 1) / 9_007_199_254_740_992 }

    mutating func nextGaussian() -> Double {
        let first = nextUnit()
        let second = nextUnit()
        return (-2 * log(first)).squareRoot() * cos(2 * .pi * second)
    }
}

/// The result of the search for the reference week.
enum GhostOutcome: Equatable, Sendable {
    case ghost(GhostRhythm)
    /// `unit` is "a check-in" or "typing". The line reads "have of need days with <unit> in one week".
    case notEnough(have: Int, need: Int, unit: String)
}

enum GhostWeek {
    // DEFAULT: D-025
    static let lengthDays = 7
    static let lookbackDays = 30
    static let minimumLabeledDays = 5
    static let minimumTypingDays = 3

    private static let keyCount = FeatureName("keyboard.key_count")
    private static let median = FeatureName("keyboard.iki_median_ms")
    private static let sd = FeatureName("keyboard.iki_sd_ms")

    /// One typing window of the keyboard sensor, with the values the ghost needs.
    struct Window: Equatable {
        let median: Double
        let sd: Double
    }

    /// The typing windows of each day. A typing window has 20 or more key presses (D-027).
    /// `typingCount` counts the typing windows. `windows` keeps the ones that have a median above 0 and a variation.
    struct Day: Equatable {
        var typingCount = 0
        var windows: [Window] = []
        var isUsable: Bool { typingCount >= TypingDay.usableTypingWindows }
    }

    private static func value(_ row: FeatureRow, _ name: FeatureName?) -> Double? { name.flatMap { row.values[$0] } }

    static func group(_ rows: [FeatureRow]) -> [TellsDay: Day] {
        var days: [TellsDay: Day] = [:]
        for row in rows where row.sensor == .keyboard {
            guard let keys = value(row, keyCount), keys >= TypingDay.typingWindowKeys else { continue }
            var day = days[row.day] ?? Day()
            day.typingCount += 1
            if let ikiMedian = value(row, median), ikiMedian > 0, let ikiSD = value(row, sd) {
                day.windows.append(Window(median: ikiMedian, sd: ikiSD))
            }
            days[row.day] = day
        }
        return days
    }

    /// The 7-day period of the last 30 days with the highest mean target check-in. Today is not in it.
    /// A tie goes to the newer week (the same rule as D-025 for one day).
    static func pick(today: TellsDay, target: CheckInItem, checkIns: [CheckIn], days: [TellsDay: Day]) -> GhostOutcome {
        let scores = Dictionary(checkIns.compactMap { checkIn in checkIn.scores[target].map { (checkIn.day, $0) } },
                                uniquingKeysWith: { _, newer in newer })
        var mostLabeled = 0
        var mostTyping = 0
        var best: (mean: Double, end: TellsDay, week: [TellsDay])?
        let first = today.adding(days: -lookbackDays)
        for startOffset in 0...(lookbackDays - lengthDays) {
            let week = (0..<lengthDays).map { first.adding(days: startOffset + $0) }
            guard let end = week.last, end < today else { continue }
            let labeled = week.compactMap { scores[$0] }
            mostLabeled = max(mostLabeled, labeled.count)
            guard labeled.count >= minimumLabeledDays else { continue }
            let typing = week.filter { days[$0]?.isUsable == true }.count
            mostTyping = max(mostTyping, typing)
            guard typing >= minimumTypingDays else { continue }
            let mean = Double(labeled.reduce(0, +)) / Double(labeled.count)
            if best == nil || (mean, end) >= (best?.mean ?? 0, best?.end ?? end) { best = (mean, end, week) }
        }
        guard let best else {
            if mostLabeled < minimumLabeledDays {
                return .notEnough(have: mostLabeled, need: minimumLabeledDays, unit: "a check-in")
            }
            return .notEnough(have: mostTyping, need: minimumTypingDays, unit: "typing")
        }
        let windows = best.week.flatMap { (days[$0]?.isUsable == true ? days[$0]?.windows : nil) ?? [] }
        guard let medianOfMedians = middle(windows.map(\.median)), let medianOfSD = middle(windows.map(\.sd)) else {
            return .notEnough(have: 0, need: minimumTypingDays, unit: "typing")
        }
        return .ghost(GhostRhythm(medianMs: medianOfMedians, sdMs: medianOfSD))
    }

    static func middle(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

/// Reads the keyboard feature rows and check-ins of the last 30 days. It does not read today's prediction.
enum GhostLoader {
    static func load(in context: InsightContext) async throws -> GhostOutcome {
        let first = context.today.adding(days: -GhostWeek.lookbackDays)
        let rows = try await context.store.featureRows(
            .keyboard, in: TypingSoundLoader.interval(from: first, to: context.today))
        let checkIns = try await context.store.checkIns(first...context.today.adding(days: -1))
        return GhostWeek.pick(today: context.today, target: context.model.target,
                              checkIns: checkIns, days: GhostWeek.group(rows))
    }
}

struct GhostResult: Equatable, Sendable {
    let yourSeconds: Double
    let ghostSeconds: Double?     // nil if there is no ghost
}

/// The state of one open "Ghost racer" view.
/// The typed characters live only here. The round end, `stop()` and a new sentence clear them. Nothing is saved.
@Observable
@MainActor
final class GhostRacerModel {
    enum Phase: Equatable {
        case loading
        case unreadable
        case loaded(GhostOutcome)
    }

    enum Round: Equatable {
        case idle
        case countdown(Int)
        case racing
        case finished(GhostResult)
    }

    private(set) var phase = Phase.loading
    private(set) var round = Round.idle
    private(set) var sentenceIndex: Int
    private(set) var typed = ""
    /// True after the ghost has typed the last character, so the view can stop its frame timer.
    private(set) var ghostDone = false
    let isPractice: Bool
    let target: String

    // DEFAULT: D-097
    static let countdownSeconds = 3

    @ObservationIgnored private let context: InsightContext
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let countdownStep: Duration
    @ObservationIgnored private let ghostTimeScale: Double
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var roundGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var roundTask: Task<Void, Never>?
    @ObservationIgnored private var raceStart = 0.0
    @ObservationIgnored private var finishTimes: [Double] = []
    @ObservationIgnored private var isStopped = false
    var currentLoadTask: Task<Void, Never>? { loadTask }
    var currentRoundTask: Task<Void, Never>? { roundTask }

    init(context: InsightContext, now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         countdownStep: Duration = .seconds(1), ghostTimeScale: Double = 1) {
        self.context = context
        self.ghostTimeScale = ghostTimeScale
        self.now = now
        self.countdownStep = countdownStep
        isPractice = context.model.isMock
        target = context.model.target.rawValue
        // The first sentence depends on the day. No random value.
        sentenceIndex = context.today.yyyymmdd % GhostRacerText.sentences.count
    }

    var sentence: String { GhostRacerText.sentences[sentenceIndex] }
    var sentenceCount: Int { sentence.count }

    var rhythm: GhostRhythm? {
        if case .loaded(.ghost(let rhythm)) = phase { return rhythm }
        return nil
    }

    func start() {
        guard !isStopped else { return }
        loadTask?.cancel()
        generation += 1
        let mine = generation
        loadTask = Task { [weak self] in await self?.load(generation: mine) }
    }

    /// Ends all Task work and clears the typed characters. A late result changes nothing.
    func stop() {
        isStopped = true
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        endRound()
        round = .idle
    }

    /// Push "Start": the count-down, then the race.
    func startRound() {
        guard !isStopped, round == .idle, case .loaded = phase else { return }
        roundGeneration += 1
        let mine = roundGeneration
        ghostDone = false
        typed = ""
        round = .countdown(Self.countdownSeconds)
        roundTask = Task { [weak self] in await self?.runCountdown(roundGeneration: mine) }
    }

    /// Push "Again": a new sentence.
    func again() {
        guard !isStopped, case .finished = round else { return }
        endRound()
        sentenceIndex = (sentenceIndex + 1) % GhostRacerText.sentences.count
        round = .idle
    }

    /// The text field sends its new text. It counts only while the race runs.
    /// A change of more than one character at once (a paste) is ignored.
    func setTyped(_ text: String) {
        guard !isStopped, round == .racing else { return }
        guard text.count <= sentenceCount, abs(text.count - typed.count) <= 1 else { return }
        typed = text
        if text.count == sentenceCount { finishRound() }
    }

    /// For each character of the sentence: nil if not typed yet, else true if it is right.
    func correctness(at index: Int) -> Bool? {
        let typedCharacters = Array(typed)
        let sentenceCharacters = Array(sentence)
        guard index < typedCharacters.count, index < sentenceCharacters.count else { return nil }
        return typedCharacters[index] == sentenceCharacters[index]
    }

    /// The number of characters that the ghost has passed `elapsed` seconds after the start.
    func ghostPosition(elapsed: Double) -> Int { finishTimes.filter { $0 <= elapsed }.count }

    /// Seconds since the race start, or 0 outside a race.
    var elapsed: Double { round == .racing ? max(0, now() - raceStart) : 0 }

    private func isCurrent(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == generation }
    private func isCurrentRound(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == roundGeneration }

    private func endRound() {
        roundGeneration += 1
        roundTask?.cancel()
        roundTask = nil
        typed = ""
        ghostDone = false
        finishTimes = []
    }

    private func runCountdown(roundGeneration mine: Int) async {
        var remaining = Self.countdownSeconds
        while remaining > 0 {
            do {
                try await Task.sleep(for: countdownStep)
            } catch {
                return
            }
            guard isCurrentRound(mine) else { return }
            remaining -= 1
            if remaining > 0 { round = .countdown(remaining) }
        }
        beginRace(roundGeneration: mine)
    }

    private func beginRace(roundGeneration mine: Int) {
        guard isCurrentRound(mine) else { return }
        finishTimes = rhythm?.finishTimes(count: sentenceCount, seed: Self.seed(for: sentenceIndex)) ?? []
        raceStart = now()
        round = .racing
        guard let ghostTotal = finishTimes.last else { return }
        let wait = Duration.seconds(ghostTotal * ghostTimeScale)
        roundTask = Task { [weak self] in
            // The frame timer of the view stops after the ghost is done.
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, self.isCurrentRound(mine) else { return }
            self.ghostDone = true
        }
    }

    private func finishRound() {
        let yours = max(0, now() - raceStart)
        let ghost = finishTimes.last
        roundGeneration += 1
        roundTask?.cancel()
        roundTask = nil
        typed = ""                    // the round ended: the typed characters are cleared
        ghostDone = true
        finishTimes = []
        round = .finished(GhostResult(yourSeconds: yours, ghostSeconds: ghost))
    }

    /// A fixed seed for each sentence.
    static func seed(for index: Int) -> UInt64 { 0x7E11_5000 &+ UInt64(index) }

    private func load(generation mine: Int) async {
        do {
            let outcome = try await GhostLoader.load(in: context)
            if isCurrent(mine) { phase = .loaded(outcome) }
        } catch {
            if isCurrent(mine) { phase = .unreadable }
        }
    }
}

struct GhostRacerView: View {
    let model: GhostRacerModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPractice {
                Text(GhostRacerText.practiceBanner)
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
            Text(GhostRacerText.unreadable)
        case .loaded(let outcome):
            loadedView(outcome)
        }
    }

    @ViewBuilder private func loadedView(_ outcome: GhostOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch outcome {
            case .ghost:
                Text(GhostRacerText.intro(target: model.target)).font(.title3)
            case .notEnough(let have, let need, let unit):
                Text(GhostRacerText.notEnoughForGhost(have: have, need: need, unit: unit)).font(.title3)
            }
            raceView
        }
    }

    @ViewBuilder private var raceView: some View {
        switch model.round {
        case .idle:
            sentenceCanvas(ghostPosition: nil)
            Button(GhostRacerText.start) { model.startRound() }
        case .countdown(let remaining):
            sentenceCanvas(ghostPosition: nil)
            Text("\(remaining)").font(.largeTitle.bold()).accessibilityLabel("Starting in \(remaining)")
        case .racing:
            if model.rhythm != nil {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: model.ghostDone)) { _ in
                    sentenceCanvas(ghostPosition: model.ghostPosition(elapsed: model.elapsed))
                }
            } else {
                sentenceCanvas(ghostPosition: nil)
            }
            TextField(GhostRacerText.typeHere, text: Binding(get: { model.typed }, set: { model.setTyped($0) }))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
        case .finished(let result):
            sentenceCanvas(ghostPosition: nil)
            Text(GhostRacerText.yourTime(result.yourSeconds)).font(.headline)
            if let ghost = result.ghostSeconds { Text(GhostRacerText.ghostTime(ghost)).font(.headline) }
            Button(GhostRacerText.again) { model.again() }
        }
    }

    private static let cell = CGSize(width: 12, height: 28)
    private static let charactersPerLine = 32

    private func sentenceCanvas(ghostPosition: Int?) -> some View {
        let sentence = Array(model.sentence)
        let correctness = sentence.indices.map { model.correctness(at: $0) }
        let lines = (sentence.count + Self.charactersPerLine - 1) / Self.charactersPerLine
        return Canvas { graphics, _ in
            for (index, character) in sentence.enumerated() {
                let origin = CGPoint(x: CGFloat(index % Self.charactersPerLine) * Self.cell.width,
                                     y: CGFloat(index / Self.charactersPerLine) * Self.cell.height)
                let color: Color = switch correctness[index] {
                case .some(true): .green
                case .some(false): .red
                case .none: .primary
                }
                let text = Text(String(character)).font(.system(size: 18, design: .monospaced)).foregroundColor(color)
                graphics.draw(graphics.resolve(text), at: CGPoint(x: origin.x + Self.cell.width / 2, y: origin.y + Self.cell.height / 2))
            }
            if let ghostPosition {
                let position = min(ghostPosition, sentence.count)
                let x = CGFloat(position % Self.charactersPerLine) * Self.cell.width
                let y = CGFloat(position / Self.charactersPerLine) * Self.cell.height
                graphics.fill(Path(CGRect(x: x, y: y + Self.cell.height - 4, width: Self.cell.width, height: 3)),
                              with: .color(.accentColor))
            }
        }
        .frame(width: CGFloat(Self.charactersPerLine) * Self.cell.width, height: CGFloat(lines) * Self.cell.height)
        .accessibilityLabel(model.sentence)
    }
}

/// Menu item 3 (design/experiences.md Section 5).
// DEFAULT: D-097
@MainActor
public final class GhostRacerExperience: InsightExperience {
    public let id = "ghostRacer"
    public let displayName = GhostRacerText.name
    public let glyph = "keyboard"
    public let menuOrder = 3

    private var model: GhostRacerModel?
    var currentModel: GhostRacerModel? { model }

    public init() {}

    /// This experience shows no prediction, so it has no check-in gate (design/experiences.md 1.6).
    /// It needs no permission: the user types in its own field. Without a ghost, the user can still type.
    public func state(in context: InsightContext) async -> ExperienceState {
        let base: ExperienceState = context.model.isMock ? .practice : .ready
        guard let outcome = try? await GhostLoader.load(in: context) else { return base }
        if case .notEnough(let have, let need, _) = outcome {
            return .notEnoughData(have: have, need: need, unit: "days")
        }
        return base
    }

    public func makeView(in context: InsightContext) -> AnyView {
        model?.stop()
        let model = GhostRacerModel(context: context)
        self.model = model
        model.start()
        return AnyView(GhostRacerView(model: model))
    }

    /// Ends all Task work and clears the typed characters. The experience has no audio and no haptics.
    public func stop() {
        model?.stop()
        model = nil
    }
}
