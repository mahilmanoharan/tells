/// The 5 companion states (SPEC.md Section 5). `CompanionStateRule` picks the state from today's data.
public enum CompanionState: String, CaseIterable, Sendable {
    case normal
    case drifting
    case scattered
    case social
    case asleep
}

/// What the rule reads. Each flag is true while its trigger is true.
public struct CompanionSignals: Sendable, Equatable {
    public var asleep: Bool
    public var social: Bool
    public var scattered: Bool
    public var drifting: Bool

    public init(asleep: Bool = false, social: Bool = false, scattered: Bool = false, drifting: Bool = false) {
        self.asleep = asleep
        self.social = social
        self.scattered = scattered
        self.drifting = drifting
    }
}

/// The state priority of SPEC.md Section 5 (D-038): Asleep, Social, Scattered, Drifting, Normal.
public enum CompanionStateRule {
    public static func state(for signals: CompanionSignals) -> CompanionState {
        if signals.asleep { return .asleep }
        if signals.social { return .social }
        if signals.scattered { return .scattered }
        if signals.drifting { return .drifting }
        return .normal
    }
}
