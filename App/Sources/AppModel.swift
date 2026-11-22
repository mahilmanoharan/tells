import AppKit
import CompanionUI
import Foundation
import MacSensors
import Observation
import TellsCore

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

    @ObservationIgnored private let permissions: PermissionChecking
    @ObservationIgnored private let firstStartStore: FirstStartStore
    @ObservationIgnored private let registeredPermissions: [PermissionKind]
    private(set) var permissionStatuses: [PermissionKind: PermissionStatus] = [:]

    /// The store for all saved features. P2.8 sets it. Until then it is nil.
    @ObservationIgnored var store: (any FeatureStore)?

    /// The app sets this to open the onboarding window.
    @ObservationIgnored var onShowOnboarding: (() -> Void)?

    /// The app sets this to open the check-in window.
    @ObservationIgnored var onShowCheckIn: (() -> Void)?

    /// `registeredPermissions` lists the permissions that the registered sensors need.
    init(
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current,
        permissions: PermissionChecking = SystemPermissions(),
        firstStartStore: FirstStartStore = UserDefaultsFirstStartStore(),
        registeredPermissions: [PermissionKind] = [.inputMonitoring] // Phase 1/2: only `keyboard`
    ) {
        self.now = now
        self.calendar = calendar
        self.permissions = permissions
        self.firstStartStore = firstStartStore
        self.registeredPermissions = registeredPermissions
        refreshPermissions()
    }

    var permissionRows: [PermissionRow] {
        registeredPermissions.map { kind in
            PermissionRow(
                kind: kind,
                sentence: PermissionInfo.sentence(for: kind),
                status: permissionStatuses[kind] ?? .notAsked,
                settingsURL: PermissionInfo.settingsURL(for: kind)
            )
        }
    }

    var keyboardAvailability: SensorAvailability {
        switch permissionStatuses[.inputMonitoring] ?? .notAsked {
        case .granted: .available
        case .denied: .permissionDenied(.inputMonitoring)
        case .notAsked: .permissionNotAsked(.inputMonitoring)
        }
    }

    func refreshPermissions() {
        for kind in PermissionKind.allCases {
            permissionStatuses[kind] = permissions.status(of: kind)
        }
    }

    /// Opens the onboarding window on the first start only.
    func showOnboardingIfFirstStart() {
        guard !firstStartStore.onboardingShown else { return }
        firstStartStore.onboardingShown = true
        onShowOnboarding?()
    }

    /// The check-in needs the store. Until P2.8 sets it, the menu item is off.
    var canCheckIn: Bool { store != nil }

    func showCheckIn() {
        onShowCheckIn?()
    }

    /// The Tells day starts at 04:00 (DEC-3). Before 04:00 it is still the day before.
    // DEFAULT: D-076
    var today: TellsDay {
        TellsDay(now().addingTimeInterval(-4 * 3600), calendar: calendar)
    }

    /// The context for the check-in view. nil until P2.8 sets `store`.
    func makeInsightContext() -> InsightContext? {
        guard let store else { return nil }
        return InsightContext(store: store, model: MockModelProvider(), today: today)
    }

    func showOnboarding() {
        onShowOnboarding?()
    }

    /// The only place where a permission request starts. The user clicks the button.
    func requestPermission(_ kind: PermissionKind) {
        permissions.request(kind)
        refreshPermissions()
    }

    var openSettings: (URL) -> Void = { NSWorkspace.shared.open($0) }

    func performAction(for kind: PermissionKind) {
        switch permissionStatuses[kind] ?? .notAsked {
        case .notAsked: requestPermission(kind)
        case .denied: openSettings(PermissionInfo.settingsURL(for: kind))
        case .granted: break
        }
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

    /// Deletes all saved data, including the daily summaries (SPEC.md 4.3). The caller asks the user first.
    func deleteAllData() async throws {
        try await store?.deleteAll()
    }

    func pauseUntilResumed() {
        pauseState = .pausedUntilResumed
    }

    func resume() {
        pauseState = .notPaused
    }
}
