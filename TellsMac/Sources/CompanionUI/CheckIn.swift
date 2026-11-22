import Observation
import SwiftUI
import TellsCore

/// The text of the check-in view. One place. No medical words, "predicts" and not "causes" (design/experiences.md 1.1).
public enum CheckInText {
    public static let title = "Check in"
    public static let intro = "Tells predicts these scores from how you use your Mac. Your check-in comes first. You can skip any item."
    public static let save = "Save check-in"
    public static let saved = "Your check-in is saved."
    public static let failed = "Tells could not save your check-in. Try again."

    public static func label(_ item: CheckInItem) -> String {
        switch item {
        case .energy: "Energy"
        case .mood: "Mood"
        case .social: "Social connection"
        }
    }
}

/// The state of one check-in form. Scores are 1 to 5. An absent item is skipped.
@Observable
@MainActor
public final class CheckInModel {
    public static let scale = 1...5

    public private(set) var scores: [CheckInItem: Int]
    public private(set) var isSaved = false
    public private(set) var saveFailed = false

    @ObservationIgnored private let context: InsightContext
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let onSaved: () -> Void

    public init(context: InsightContext, now: @escaping () -> Date = { Date() }, onSaved: @escaping () -> Void = {}) {
        self.context = context
        self.now = now
        self.onSaved = onSaved
        scores = [:]
    }

    /// Selects `score` for `item`. Selecting the same score again skips the item.
    // DEFAULT: D-074
    public func select(_ score: Int, for item: CheckInItem) {
        guard Self.scale.contains(score) else { return }
        isSaved = false
        scores[item] = scores[item] == score ? nil : score
    }

    /// Save needs at least one score. An empty check-in has no use.
    // DEFAULT: D-075
    public var canSave: Bool { !scores.isEmpty }

    /// Saves the check-in for today. It replaces an earlier check-in of the same day.
    public func save() async {
        guard canSave else { return }
        let checkIn = CheckIn(day: context.today, savedAt: now(), scores: scores)
        do {
            try await context.saveCheckIn(checkIn)
            isSaved = true
            saveFailed = false
            onSaved()
        } catch {
            saveFailed = true
        }
    }
}

public struct CheckInView: View {
    @State private var model: CheckInModel

    public init(model: CheckInModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(CheckInText.title).font(.title2.bold())
            Text(CheckInText.intro).foregroundStyle(.secondary)
            ForEach(CheckInItem.allCases, id: \.self) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(CheckInText.label(item))
                    HStack {
                        ForEach(Array(CheckInModel.scale), id: \.self) { score in
                            Button("\(score)") { model.select(score, for: item) }
                                .buttonStyle(.borderedProminent)
                                .tint(model.scores[item] == score ? .accentColor : .gray)
                                .accessibilityLabel("\(CheckInText.label(item)) \(score)")
                        }
                    }
                }
            }
            HStack {
                if model.isSaved { Text(CheckInText.saved).foregroundStyle(.secondary) }
                if model.saveFailed { Text(CheckInText.failed).foregroundStyle(.red) }
                Spacer()
                Button(CheckInText.save) { Task { await model.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Whether today's check-in is saved. A read error is its own state and counts as not open.
public enum CheckInGateState: Sendable, Equatable {
    case saved
    case notSaved
    case unreadable
}

/// Today's prediction shows only after today's check-in is saved (design/experiences.md 1.6, PLAN.md 4.4).
public enum PredictionGate {
    public static let unreadableText = "Tells could not read your check-in. Try again later."

    public static func state(in context: InsightContext) async -> CheckInGateState {
        do {
            let saved = try await context.store.checkIns(context.today...context.today)
            return saved.isEmpty ? .notSaved : .saved
        } catch {
            return .unreadable
        }
    }

    /// nil until today's check-in is saved (also when the read fails). Then the model prediction, or nil if the model has none.
    public static func todaysPrediction(
        in context: InsightContext, features: FeatureVector, windowCount: Int
    ) async -> Prediction? {
        guard await state(in: context) == .saved else { return nil }
        return await context.model.predict(features, day: context.today, windowCount: windowCount)
    }
}

/// Shows the check-in view until today's check-in is saved. Then it shows `content`.
/// The owner makes `model` once and passes it in. The view makes no model.
public struct CheckInGateView<Content: View>: View {
    private let context: InsightContext
    private let model: CheckInModel
    private let content: () -> Content
    @State private var state: CheckInGateState?

    public init(context: InsightContext, model: CheckInModel, @ViewBuilder content: @escaping () -> Content) {
        self.context = context
        self.model = model
        self.content = content
    }

    public var body: some View {
        Group {
            if model.isSaved || state == .saved {
                content()
            } else {
                switch state {
                case nil: ProgressView()
                case .unreadable?: Text(PredictionGate.unreadableText).padding(20)
                default: CheckInView(model: model)
                }
            }
        }
        .task { state = await PredictionGate.state(in: context) }
    }
}
