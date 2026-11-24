import Charts
import Foundation
import Observation
import SwiftUI
import TellsCore

/// The text of "What-if sliders" (design/experiences.md Section 6).
/// No medical words. "Predicts", not "causes" (design/experiences.md 1.1).
public enum WhatIfText {
    public static let name = "What-if sliders"
    public static let practiceBanner = "Practice mode. The Mac guess comes from a test model."
    public static let unreadable = "Tells could not read your data. Try again later."
    public static let notEnoughToday = "Not enough data today for a prediction."
    public static let unusedModel = "The current model does not use bedtime or late scrolling."
    public static let noRange = "Your values did not change enough to make a range."
    public static let reset = "Reset"
    public static let testIt = "Test it"
    public static let disclaimer =
        "This is a prediction from your past days. It does not show a cause. To test a change, use Experiment."

    public static func windowsProgress(have: Int, need: Int) -> String { "\(have) of \(need) windows today" }

    public static func notEnoughDays(have: Int, need: Int) -> String {
        "Not enough days to make a range. \(have) of \(need) days."
    }

    /// "The model predicts an energy check-in of 3.8 with a 23:00 bedtime. With today's 00:30 bedtime, it predicts 3.4.
    /// Your check-in today was 3." The last sentence is absent if the check-in has no score for the target.
    public static func summary(
        target: String, kind: WhatIfSliderKind, sliderValue: Double?, atSlider: Double?,
        startValue: Double, atStart: Double, usesToday: Bool, checkInScore: Int?
    ) -> String {
        var parts: [String] = []
        if let sliderValue, let atSlider {
            parts.append("The model predicts \(article(target)) \(target) check-in of \(format(atSlider)) with \(kind.phrase(sliderValue, article: true)).")
            let owner = usesToday ? "today's" : "your usual"
            parts.append("With \(owner) \(kind.phrase(startValue, article: false)), it predicts \(format(atStart)).")
        } else {
            let owner = usesToday ? "today's" : "your usual"
            parts.append("With \(owner) \(kind.phrase(startValue, article: false)), the model predicts \(article(target)) \(target) check-in of \(format(atStart)).")
        }
        if let checkInScore { parts.append("Your \(target) check-in today was \(checkInScore).") }
        return parts.joined(separator: " ")
    }

    static func article(_ word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }

    public static func format(_ value: Double) -> String { YouVsMacText.format(YouVsMacRules.rounded(value)) }
}

/// The 2 sliders (design/experiences.md Section 6, D-031).
public enum WhatIfSliderKind: String, CaseIterable, Sendable, Identifiable {
    case bedtime
    case lateScrolling

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bedtime: "Bedtime"
        case .lateScrolling: "Late scrolling"
        }
    }

    /// `activity.sleep_start_min` and `activity.late_input_min` (SPEC.md Section 6).
    var featureName: FeatureName? {
        switch self {
        case .bedtime: FeatureName("activity.sleep_start_min")
        case .lateScrolling: FeatureName("activity.late_input_min")
        }
    }

    /// Minutes after 00:00 of the day (DEC-3). A value under 0 is the evening before.
    public static func clock(_ minutes: Double) -> String {
        let whole = Int(minutes.rounded())
        let inDay = ((whole % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", inDay / 60, inDay % 60)
    }

    public func label(_ value: Double) -> String {
        switch self {
        case .bedtime: Self.clock(value)
        case .lateScrolling: "\(Int(value.rounded())) min"
        }
    }

    func phrase(_ value: Double, article: Bool) -> String {
        switch self {
        case .bedtime: (article ? "a " : "") + "\(Self.clock(value)) bedtime"
        case .lateScrolling: "\(Int(value.rounded())) min of late scrolling"
        }
    }
}

/// One slider that has a range.
struct WhatIfSlider: Equatable, Sendable {
    let kind: WhatIfSliderKind
    let minimum: Double
    let maximum: Double
    let start: Double
    let usesToday: Bool     // false: the start is the 30-day median
}

/// What the experience needs to show the sliders. It holds only numbers.
struct WhatIfInputs: Equatable, Sendable {
    let sliders: [WhatIfSlider]
    let vector: FeatureVector       // today's features. A missing slider feature has its start value.
    let windowCount: Int
    let baseline: Double            // the prediction at the start values
    let checkInScore: Int?
}

enum WhatIfOutcome: Equatable, Sendable {
    case unusedModel
    case needsCheckIn
    case notEnoughDays(have: Int)
    case noRange
    case noPrediction(windows: Int)
    case ready(WhatIfInputs)
}

/// Reads only feature rows, daily rows and check-ins (design/experiences.md 1.2). It changes nothing in the model (hard rule 7).
// DEFAULT: D-098
enum WhatIfLoader {
    static let rangeDays = 30
    static let minimumDays = 7
    static let curveSteps = 21

    static func load(in context: InsightContext, extractors: [any FeatureExtractor]) async throws -> WhatIfOutcome {
        let used = WhatIfSliderKind.allCases.compactMap { kind -> (WhatIfSliderKind, FeatureName)? in
            guard let name = kind.featureName, context.model.featureNames.contains(name) else { return nil }
            return (kind, name)
        }
        guard !used.isEmpty else { return .unusedModel }
        let snapshot = try await YouVsMacSnapshot.read(in: context, extractors: extractors)
        // The check-in comes before any prediction (design/experiences.md 1.6).
        guard let checkIn = snapshot.checkIn else { return .needsCheckIn }
        let past = try await context.store.dailyRows(
            context.today.adding(days: -rangeDays)...context.today.adding(days: -1))
        var sliders: [WhatIfSlider] = []
        var mostDays = 0
        var hasFlatRange = false
        for (kind, name) in used {
            let values = past.compactMap { $0.values[name] }
            mostDays = max(mostDays, values.count)
            guard values.count >= minimumDays else { continue }
            let todayValue = snapshot.features.values[name]
            let all = values + (todayValue.map { [$0] } ?? [])
            guard let low = all.min(), let high = all.max(), high > low else {
                hasFlatRange = true
                continue
            }
            sliders.append(WhatIfSlider(kind: kind, minimum: low, maximum: high,
                                        start: todayValue ?? median(values), usesToday: todayValue != nil))
        }
        guard !sliders.isEmpty else { return hasFlatRange ? .noRange : .notEnoughDays(have: mostDays) }
        var vector = snapshot.features.values
        for slider in sliders {
            if let name = slider.kind.featureName { vector[name] = slider.start }
        }
        let windowCount = snapshot.features.windowCount
        guard let prediction = await PredictionGate.todaysPrediction(in: context, features: vector, windowCount: windowCount)
        else { return .noPrediction(windows: windowCount) }
        return .ready(WhatIfInputs(sliders: sliders, vector: vector, windowCount: windowCount,
                                   baseline: prediction.value, checkInScore: checkIn.scores[context.model.target]))
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

public struct WhatIfPoint: Equatable, Sendable, Identifiable {
    public let x: Double
    public let y: Double
    public var id: Double { x }
}

/// The state of one open "What-if sliders" view.
@Observable
@MainActor
public final class WhatIfModel {
    public enum Phase: Equatable {
        case loading
        case unreadable
        case checkIn
        case unusedModel
        case notEnoughDays(have: Int)
        case noRange
        case noPrediction(windows: Int)
        case ready
    }

    public private(set) var phase = Phase.loading
    public private(set) var selected: WhatIfSliderKind?
    public private(set) var value = 0.0
    public private(set) var curve: [WhatIfPoint] = []
    public private(set) var predictionAtValue: Double?
    public private(set) var checkInModel: CheckInModel?
    public let isPractice: Bool
    public let target: String
    var onTestIt: ((String) -> Void)?

    @ObservationIgnored private let context: InsightContext
    @ObservationIgnored private let extractors: [any FeatureExtractor]
    @ObservationIgnored private var inputs: WhatIfInputs?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var curveGeneration = 0
    @ObservationIgnored private var pointGeneration = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var curveTask: Task<Void, Never>?
    @ObservationIgnored private var pointTask: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false
    var currentTask: Task<Void, Never>? { task }
    var currentCurveTask: Task<Void, Never>? { curveTask }
    var currentPointTask: Task<Void, Never>? { pointTask }

    init(context: InsightContext, extractors: [any FeatureExtractor]) {
        self.context = context
        self.extractors = extractors
        isPractice = context.model.isMock
        target = context.model.target.rawValue
    }

    public var sliders: [WhatIfSliderKind] { inputs?.sliders.map(\.kind) ?? [] }
    var selectedSlider: WhatIfSlider? { inputs?.sliders.first { $0.kind == selected } }
    public var range: ClosedRange<Double>? { selectedSlider.map { $0.minimum...$0.maximum } }
    public var startValue: Double? { selectedSlider?.start }
    public var baseline: Double? { inputs?.baseline }

    /// The text below the chart (design/experiences.md Section 6, "Text"). nil before the data is ready.
    public var summaryText: String? {
        guard phase == .ready, let slider = selectedSlider, let inputs else { return nil }
        let moved = abs(value - slider.start) > 1e-9
        return WhatIfText.summary(
            target: target, kind: slider.kind, sliderValue: moved ? value : nil, atSlider: moved ? predictionAtValue : nil,
            startValue: slider.start, atStart: inputs.baseline, usesToday: slider.usesToday,
            checkInScore: inputs.checkInScore)
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
        curveGeneration += 1
        pointGeneration += 1
        task?.cancel()
        curveTask?.cancel()
        pointTask?.cancel()
        task = nil
        curveTask = nil
        pointTask = nil
        checkInModel = nil
        onTestIt = nil
    }

    /// Shows one slider. The slider starts at its start value.
    public func select(_ kind: WhatIfSliderKind) {
        guard phase == .ready, !isStopped, let slider = inputs?.sliders.first(where: { $0.kind == kind }) else { return }
        selected = kind
        value = slider.start
        predictionAtValue = inputs?.baseline
        beginCurve(for: slider)
    }

    /// The user moves the slider. The value stays inside the user's own range.
    public func setValue(_ newValue: Double) {
        guard phase == .ready, !isStopped, let slider = selectedSlider, newValue.isFinite else { return }
        value = min(max(newValue, slider.minimum), slider.maximum)
        pointTask?.cancel()
        pointGeneration += 1
        let mine = pointGeneration
        let wanted = value
        guard let inputs, let name = slider.kind.featureName else { return }
        var vector = inputs.vector
        vector[name] = wanted
        let windows = inputs.windowCount
        pointTask = Task { [weak self] in
            guard let self else { return }
            let prediction = await self.context.model.predict(vector, day: self.context.today, windowCount: windows)
            guard self.isCurrentPoint(mine) else { return }
            self.predictionAtValue = prediction?.value
        }
    }

    /// Moves the slider back to today's value.
    public func reset() {
        guard let slider = selectedSlider else { return }
        setValue(slider.start)
    }

    /// Opens the Experiment with the matching change (design/experiences.md Section 6, step 7).
    public func testIt() {
        guard !isStopped, let selected else { return }
        onTestIt?(selected.rawValue)
    }

    private func isCurrent(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == generation }
    private func isCurrentCurve(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == curveGeneration }
    private func isCurrentPoint(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == pointGeneration }

    private func load(generation mine: Int) async {
        let outcome: WhatIfOutcome
        do {
            outcome = try await WhatIfLoader.load(in: context, extractors: extractors)
        } catch {
            if isCurrent(mine) { phase = .unreadable }
            return
        }
        guard isCurrent(mine) else { return }
        checkInModel = nil
        switch outcome {
        case .unusedModel: phase = .unusedModel
        case .noRange: phase = .noRange
        case .notEnoughDays(let have): phase = .notEnoughDays(have: have)
        case .noPrediction(let windows): phase = .noPrediction(windows: windows)
        case .needsCheckIn:
            checkInModel = CheckInModel(context: context, onSaved: { [weak self] in self?.start() })
            phase = .checkIn
        case .ready(let ready):
            inputs = ready
            phase = .ready
            if let first = ready.sliders.first { select(first.kind) }
        }
    }

    /// The prediction for each slider value. Only the slider feature changes (design/experiences.md Section 6).
    private func beginCurve(for slider: WhatIfSlider) {
        curveTask?.cancel()
        pointTask?.cancel()
        pointGeneration += 1
        curveGeneration += 1
        let mine = curveGeneration
        curve = []
        guard let inputs, let name = slider.kind.featureName else { return }
        let model = context.model
        let day = context.today
        curveTask = Task { [weak self] in
            var points: [WhatIfPoint] = []
            for step in 0..<WhatIfLoader.curveSteps {
                let fraction = Double(step) / Double(WhatIfLoader.curveSteps - 1)
                let x = slider.minimum + (slider.maximum - slider.minimum) * fraction
                var vector = inputs.vector
                vector[name] = x
                let prediction = await model.predict(vector, day: day, windowCount: inputs.windowCount)
                guard let self, self.isCurrentCurve(mine) else { return }
                if let prediction { points.append(WhatIfPoint(x: x, y: prediction.value)) }
            }
            guard let self, self.isCurrentCurve(mine) else { return }
            self.curve = points
        }
    }
}

struct WhatIfView: View {
    let model: WhatIfModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPractice {
                Text(WhatIfText.practiceBanner)
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
            Text(WhatIfText.unreadable)
        case .checkIn:
            if let checkInModel = model.checkInModel { CheckInView(model: checkInModel) }
        case .unusedModel:
            Text(WhatIfText.unusedModel).font(.title3)
        case .noRange:
            Text(WhatIfText.noRange).font(.title3)
        case .notEnoughDays(let have):
            Text(WhatIfText.notEnoughDays(have: have, need: WhatIfLoader.minimumDays)).font(.title3)
        case .noPrediction(let windows):
            VStack(alignment: .leading, spacing: 8) {
                Text(WhatIfText.notEnoughToday).font(.title3)
                Text(WhatIfText.windowsProgress(have: windows, need: DataThreshold.minimumWindowsToday))
                    .foregroundStyle(.secondary)
            }
        case .ready:
            readyView
        }
    }

    @ViewBuilder private var readyView: some View {
        if let kind = model.selected, let range = model.range {
            VStack(alignment: .leading, spacing: 10) {
                if model.sliders.count > 1 {
                    Picker("Slider", selection: Binding(get: { kind }, set: { model.select($0) })) {
                        ForEach(model.sliders) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack {
                    Text(kind.title).font(.headline)
                    Spacer()
                    Text(kind.label(model.value)).monospacedDigit()
                }
                Slider(value: Binding(get: { model.value }, set: { model.setValue($0) }), in: range)
                    .accessibilityLabel(kind.title)
                chart(kind: kind)
                if let text = model.summaryText { Text(text) }
                HStack {
                    Button(WhatIfText.reset) { model.reset() }
                    Button(WhatIfText.testIt) { model.testIt() }
                }
                Text(WhatIfText.disclaimer).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func chart(kind: WhatIfSliderKind) -> some View {
        Chart {
            ForEach(model.curve) { point in
                LineMark(x: .value(kind.title, point.x), y: .value(model.target, point.y))
            }
            if let predicted = model.predictionAtValue {
                PointMark(x: .value(kind.title, model.value), y: .value(model.target, predicted))
                    .symbolSize(80)
            }
        }
        .chartYScale(domain: 1...5)
        .chartXAxis {
            AxisMarks { mark in
                AxisGridLine()
                AxisValueLabel {
                    if let number = mark.as(Double.self) { Text(kind.label(number)) }
                }
            }
        }
        .frame(height: 160)
    }
}

/// Menu item 4 (design/experiences.md Section 6).
// DEFAULT: D-098
@MainActor
public final class WhatIfExperience: InsightExperience {
    public let id = "whatIf"
    public let displayName = WhatIfText.name
    public let glyph = "slider.horizontal.3"
    public let menuOrder = 4

    /// Called with the slider id when the user pushes "Test it". The app opens the Experiment.
    public var openExperiment: ((String) -> Void)?

    private let extractors: [any FeatureExtractor]
    private var model: WhatIfModel?
    var currentModel: WhatIfModel? { model }

    public convenience init() {
        self.init(extractors: [KeyboardExtractor(), ActivityExtractor(), AppSwitchExtractor()])
    }

    init(extractors: [any FeatureExtractor]) {
        self.extractors = extractors
    }

    /// Today's prediction is not read before today's check-in is saved. This experience uses no permission and no hardware.
    public func state(in context: InsightContext) async -> ExperienceState {
        let base: ExperienceState = context.model.isMock ? .practice : .ready
        guard let outcome = try? await WhatIfLoader.load(in: context, extractors: extractors) else { return base }
        switch outcome {
        case .unusedModel: return .notEnoughData(have: 0, need: 1, unit: "slider features")
        case .noRange: return .notEnoughData(have: 1, need: 2, unit: "different values")
        case .notEnoughDays(let have): return .notEnoughData(have: have, need: WhatIfLoader.minimumDays, unit: "days")
        case .noPrediction(let windows):
            return .notEnoughData(have: windows, need: DataThreshold.minimumWindowsToday, unit: "windows")
        case .needsCheckIn, .ready: return base
        }
    }

    public func makeView(in context: InsightContext) -> AnyView {
        model?.stop()
        let model = WhatIfModel(context: context, extractors: extractors)
        model.onTestIt = { [weak self] change in self?.openExperiment?(change) }
        self.model = model
        model.start()
        return AnyView(WhatIfView(model: model))
    }

    /// Ends all Task work. The experience has no audio and no haptics. The window frees the view.
    public func stop() {
        model?.stop()
        model = nil
    }
}
