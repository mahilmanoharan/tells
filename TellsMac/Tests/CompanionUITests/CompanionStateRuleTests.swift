import Testing
@testable import CompanionUI

struct CompanionStateRuleTests {
    private func state(_ signals: CompanionSignals) -> CompanionState { CompanionStateRule.state(for: signals) }

    @Test func noTriggerGivesNormal() {
        #expect(state(CompanionSignals()) == .normal)
    }

    @Test func eachTriggerGivesItsState() {
        #expect(state(CompanionSignals(asleep: true)) == .asleep)
        #expect(state(CompanionSignals(social: true)) == .social)
        #expect(state(CompanionSignals(scattered: true)) == .scattered)
        #expect(state(CompanionSignals(drifting: true)) == .drifting)
    }

    @Test func asleepWinsOverAll() {
        #expect(state(CompanionSignals(asleep: true, social: true, scattered: true, drifting: true)) == .asleep)
    }

    @Test func socialWinsOverScatteredAndDrifting() {
        #expect(state(CompanionSignals(social: true, scattered: true, drifting: true)) == .social)
    }

    @Test func scatteredWinsOverDrifting() {
        #expect(state(CompanionSignals(scattered: true, drifting: true)) == .scattered)
    }

    @Test func everyTwoTriggerTieFollowsThePriority() {
        #expect(state(CompanionSignals(asleep: true, social: true)) == .asleep)
        #expect(state(CompanionSignals(asleep: true, scattered: true)) == .asleep)
        #expect(state(CompanionSignals(asleep: true, drifting: true)) == .asleep)
        #expect(state(CompanionSignals(social: true, scattered: true)) == .social)
        #expect(state(CompanionSignals(social: true, drifting: true)) == .social)
    }
}
