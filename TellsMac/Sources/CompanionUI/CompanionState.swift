/// The 5 companion states (SPEC.md Section 5). The caller picks the state; P4.2 connects real data.
public enum CompanionState: String, CaseIterable, Sendable {
    case normal
    case drifting
    case scattered
    case social
    case asleep
}
