import Foundation
import Observation

/// How long Tells is paused.
enum PauseState: Equatable {
    case notPaused
    case pausedUntil(Date)
    case pausedUntilResumed
}

/// The one app state object. The app makes it one time (SPEC.md 1.3).
@Observable
@MainActor
final class AppModel {
    var isCompanionVisible = true {
        didSet { onCompanionVisibilityChange?(isCompanionVisible) }
    }
    private(set) var pauseState = PauseState.notPaused

    /// The app sets this to show or hide the companion panel.
    @ObservationIgnored var onCompanionVisibilityChange: ((Bool) -> Void)?

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar

    init(now: @escaping () -> Date = { Date() }, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    var isPaused: Bool {
        switch pauseState {
        case .notPaused: false
        case .pausedUntil(let end): now() < end
        case .pausedUntilResumed: true
        }
    }

    func toggleCompanion() {
        isCompanionVisible.toggle()
    }

    func pause(for duration: TimeInterval) {
        pauseState = .pausedUntil(now().addingTimeInterval(duration))
    }

    /// Ends at the next local 04:00, the day boundary of DEC-3.
    func pauseUntilTomorrow() {
        // DEFAULT: D-056
        let boundary = DateComponents(hour: 4, minute: 0)
        guard let end = calendar.nextDate(after: now(), matching: boundary, matchingPolicy: .nextTime) else {
            pauseState = .pausedUntilResumed
            return
        }
        pauseState = .pausedUntil(end)
    }

    func pauseUntilResumed() {
        pauseState = .pausedUntilResumed
    }

    func resume() {
        pauseState = .notPaused
    }
}
