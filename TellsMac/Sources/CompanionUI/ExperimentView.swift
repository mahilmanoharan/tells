import Charts
import Observation
import SwiftUI
import TellsCore

/// The state of one open "Experiment" view.
@Observable
@MainActor
final class ExperimentModel {
    enum Phase: Equatable {
        case loading
        case unreadable
        case choose(weekBeforeLabeled: Int)
        case waiting(ExperimentRecord)
        case running(ExperimentRecord, dayNumber: Int, days: [ExperimentDay])
        case notEnough(ExperimentRecord, beforeHave: Int, changeHave: Int, days: [ExperimentDay])
        case result(ExperimentRecord, ExperimentResult, days: [ExperimentDay])
    }

    private(set) var phase = Phase.loading
    private(set) var selected: ExperimentChange?
    let isPractice: Bool
    let target: String

    @ObservationIgnored private let context: InsightContext
    @ObservationIgnored private let storage: ExperimentStorage
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false
    var currentTask: Task<Void, Never>? { task }

    init(context: InsightContext, storage: ExperimentStorage, preselected: ExperimentChange? = nil) {
        self.context = context
        self.storage = storage
        selected = preselected
        isPractice = context.model.isMock
        target = context.model.target.rawValue
    }

    /// Starts one load. A new load replaces the one that runs.
    func start() {
        guard !isStopped else { return }
        task?.cancel()
        generation += 1
        let mine = generation
        task = Task { [weak self] in await self?.load(generation: mine) }
    }

    /// Ends all Task work. A late result changes nothing.
    func stop() {
        isStopped = true
        generation += 1
        task?.cancel()
        task = nil
    }

    /// The user selects a change. It works only while the list shows.
    func choose(_ change: ExperimentChange) {
        guard !isStopped, case .choose = phase else { return }
        selected = change
    }

    /// Saves the experiment. It starts the next day (design/experiences.md Section 8, step 4).
    // DEFAULT: D-100
    func startExperiment() {
        guard !isStopped, case .choose = phase, let selected else { return }
        storage.purgeExpired(today: context.today)
        storage.save(ExperimentRecord(change: selected, start: context.today.adding(days: 1)))
        start()
    }

    /// "End" at any time. A stopped experiment shows no result.
    func endExperiment() {
        guard !isStopped else { return }
        storage.clear()
        selected = nil
        start()
    }

    /// "Add one more week", one time. It extends the week of change by 7 days.
    func addWeek() {
        guard !isStopped, case .notEnough(let record, _, _, _) = phase, !record.extended else { return }
        storage.save(ExperimentRecord(change: record.change, start: record.start, extended: true))
        start()
    }

    private func isCurrent(_ mine: Int) -> Bool { !isStopped && !Task.isCancelled && mine == generation }

    private func load(generation mine: Int) async {
        storage.purgeExpired(today: context.today)
        let outcome: ExperimentOutcome
        do {
            outcome = try await ExperimentLoader.load(record: storage.record(), in: context)
        } catch {
            if isCurrent(mine) { phase = .unreadable }
            return
        }
        guard isCurrent(mine) else { return }
        switch outcome {
        case .choose(let labeled): phase = .choose(weekBeforeLabeled: labeled)
        case .waiting(let record): phase = .waiting(record)
        case .running(let record, let number, let days): phase = .running(record, dayNumber: number, days: days)
        case .notEnough(let record, let before, let change, let days):
            phase = .notEnough(record, beforeHave: before, changeHave: change, days: days)
        case .result(let record, let result, let days): phase = .result(record, result, days: days)
        }
    }
}

struct ExperimentView: View {
    let model: ExperimentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPractice {
                Text(ExperimentText.practiceBanner)
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
            Text(ExperimentText.unreadable)
        case .choose(let labeled):
            chooseView(labeled: labeled)
        case .waiting(let record):
            VStack(alignment: .leading, spacing: 10) {
                Text(record.change.title).font(.title3)
                Text(ExperimentText.startsTomorrow)
                endButton(ExperimentText.end)
            }
        case .running(let record, let number, let days):
            VStack(alignment: .leading, spacing: 10) {
                Text(record.change.title).font(.title3)
                Text(ExperimentText.dayLine(day: number, of: record.dayCount)).font(.headline)
                marks(days)
                endButton(ExperimentText.end)
            }
        case .notEnough(let record, let before, let change, _):
            VStack(alignment: .leading, spacing: 10) {
                Text(ExperimentText.notEnough(beforeHave: before, changeHave: change, need: ExperimentRules.minimumLabeledDays))
                    .font(.title3)
                HStack {
                    if !record.extended {
                        Button(ExperimentText.addWeek) { model.addWeek() }
                    }
                    endButton(ExperimentText.clearResult)
                }
            }
        case .result(let record, let result, let days):
            resultView(record: record, result: result, days: days)
        }
    }

    private func endButton(_ title: String) -> some View {
        Button(title) { model.endExperiment() }
    }

    private func chooseView(labeled: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ExperimentText.intro).font(.title3)
            Text(ExperimentText.choose).foregroundStyle(.secondary)
            ForEach(ExperimentChange.allCases) { change in
                Button { model.choose(change) } label: {
                    HStack {
                        Image(systemName: model.selected == change ? "largecircle.fill.circle" : "circle")
                        Text(change.title)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(change.title)
                .accessibilityAddTraits(model.selected == change ? .isSelected : [])
            }
            if model.selected != nil, labeled < ExperimentRules.minimumLabeledDays {
                Text(ExperimentText.weakWeekBefore(have: labeled)).foregroundStyle(.secondary)
            }
            Button(ExperimentText.start) { model.startExperiment() }
                .disabled(model.selected == nil)
        }
    }

    private func marks(_ days: [ExperimentDay]) -> some View {
        HStack(spacing: 8) {
            ForEach(days) { day in
                VStack(spacing: 2) {
                    Image(systemName: symbol(day.mark))
                    Text("\(day.number)").font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Day \(day.number): \(words(day.mark))")
            }
        }
    }

    private func symbol(_ mark: ExperimentMark) -> String {
        switch mark {
        case .done: "checkmark.circle.fill"
        case .notDone: "xmark.circle"
        case .noData: "circle.dotted"
        }
    }

    private func words(_ mark: ExperimentMark) -> String {
        switch mark {
        case .done: ExperimentText.doneMark
        case .notDone: ExperimentText.notDoneMark
        case .noData: ExperimentText.noDataMark
        }
    }

    private func resultView(record: ExperimentRecord, result: ExperimentResult, days: [ExperimentDay]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.change.title).font(.headline)
            chart(result)
            Text(ExperimentText.result(
                target: model.target, difference: result.difference, low: result.low, high: result.high, extended: record.extended))
            Text(ExperimentText.didChange(result.daysDone, of: result.dayCount))
            if result.includesZero { Text(ExperimentText.chance) }
            Text(ExperimentText.smallTest).font(.footnote).foregroundStyle(.secondary)
            endButton(ExperimentText.clearResult)
        }
    }

    /// Two weekly means. The rule is the 95% range of the difference, placed on the mean of the week before.
    private func chart(_ result: ExperimentResult) -> some View {
        let beforeLabel = "Week before"
        let changeLabel = "Change week"
        return Chart {
            BarMark(x: .value("Week", beforeLabel), y: .value(model.target, result.beforeMean))
            BarMark(x: .value("Week", changeLabel), y: .value(model.target, result.changeMean))
            RuleMark(
                x: .value("Week", changeLabel),
                yStart: .value("Low", min(max(result.beforeMean + result.low, 0), 5)),
                yEnd: .value("High", min(max(result.beforeMean + result.high, 0), 5)))
                .lineStyle(StrokeStyle(lineWidth: 3))
        }
        .chartYScale(domain: 0...5)
        .frame(height: 140)
    }
}

/// Menu item 6 (design/experiences.md Section 8).
// DEFAULT: D-100
@MainActor
public final class ExperimentExperience: InsightExperience {
    public let id = "experiment"
    public let displayName = ExperimentText.name
    public let glyph = "flask"
    public let menuOrder = 6

    private let storage: ExperimentStorage
    private var model: ExperimentModel?
    private var pendingChange: ExperimentChange?
    var currentModel: ExperimentModel? { model }
    var pending: ExperimentChange? { pendingChange }

    public init(defaults: UserDefaults = .standard) {
        storage = ExperimentStorage(defaults: defaults)
    }

    /// Deletes a record whose week before has left the store. The app calls it at start and at each closed window.
    public static func purgeStaleRecord(today: TellsDay, defaults: UserDefaults = .standard) {
        ExperimentStorage(defaults: defaults).purgeExpired(today: today)
    }

    /// Deletes the record. "Delete all data" calls it (SPEC.md 4.3).
    public static func clearStoredState(defaults: UserDefaults = .standard) {
        ExperimentStorage(defaults: defaults).clear()
    }

    /// The What-if "Test it" button gives its slider ID. The next view starts with the matching change selected (D-102).
    public func preselect(sliderID: String) {
        pendingChange = ExperimentChange(sliderID: sliderID)
    }

    /// This experience shows no model prediction, so it has no check-in gate (design/experiences.md 1.6).
    /// It needs no permission and no hardware.
    public func state(in context: InsightContext) async -> ExperienceState {
        storage.purgeExpired(today: context.today)
        let base: ExperienceState = context.model.isMock ? .practice : .ready
        guard let outcome = try? await ExperimentLoader.load(record: storage.record(), in: context) else { return base }
        if case .notEnough(_, let before, let change, _) = outcome {
            return .notEnoughData(have: min(before, change), need: ExperimentRules.minimumLabeledDays, unit: "days")
        }
        return base
    }

    public func makeView(in context: InsightContext) -> AnyView {
        model?.stop()
        let model = ExperimentModel(context: context, storage: storage, preselected: pendingChange)
        pendingChange = nil
        self.model = model
        model.start()
        return AnyView(ExperimentView(model: model))
    }

    /// Ends all Task work. The experience has no audio and no haptics. The window frees the view.
    public func stop() {
        model?.stop()
        model = nil
        pendingChange = nil
    }
}
