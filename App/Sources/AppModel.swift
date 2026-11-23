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

/// What `AppModel` needs from the sensor hub. A fake replaces it in tests.
protocol CollectionControlling: Sendable {
    func run() async
    func setPaused(_ paused: Bool) async
    func retryUnstarted() async
    /// True while a sensor is not started, for example for a missing permission.
    func hasUnstartedSensors() async -> Bool
}

extension SensorHub: CollectionControlling {}

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

    /// The store for all saved features. nil in tests, and when the store file cannot open.
    @ObservationIgnored var store: (any FeatureStore)?

    /// A short sentence when collection could not start. nil when it runs or when nothing was asked to run.
    var startupFailure: String?

    @ObservationIgnored private let hub: (any CollectionControlling)?
    @ObservationIgnored private let dayCloser: DayCloser?
    @ObservationIgnored private var pauseSignals: AsyncStream<Bool>.Continuation?
    @ObservationIgnored private var pauseTimer: Task<Void, Never>?
    @ObservationIgnored private(set) var collectionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var terminateObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var permissionPoll: Task<Void, Never>?
    @ObservationIgnored private var pollObservers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    @ObservationIgnored private let permissionPollInterval: Duration
    @ObservationIgnored private let pauseSleep: @Sendable (TimeInterval) async throws -> Void

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
        registeredPermissions: [PermissionKind] = [.inputMonitoring], // Phase 1/2: only `keyboard`
        hub: (any CollectionControlling)? = nil,
        dayCloser: DayCloser? = nil,
        pauseSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        permissionPollInterval: Duration = .seconds(30)   // DEFAULT: D-088
    ) {
        self.permissionPollInterval = permissionPollInterval
        self.pauseSleep = pauseSleep
        self.hub = hub
        self.dayCloser = dayCloser
        self.now = now
        self.calendar = calendar
        self.permissions = permissions
        self.firstStartStore = firstStartStore
        self.registeredPermissions = registeredPermissions
        refreshPermissions()
    }

    /// The one set of Phase 2 collection objects: one store, one buffer, one clock, one hub, one day closer.
    /// The app calls this once. Tests and the test host get a model without collection.
    // DEFAULT: D-081
    static func live(
        isTestProcess: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil,
        openStore: () throws -> SwiftDataFeatureStore = { try SwiftDataFeatureStore.open() }
    ) -> AppModel {
        guard !isTestProcess else { return AppModel() }
        do {
            let store = try openStore()
            let extractors: [any FeatureExtractor] = [KeyboardExtractor(), ActivityExtractor(), AppSwitchExtractor()]
            let buffer = RawEventBuffer()
            let clock = WindowClock(buffer: buffer, extractors: extractors, store: store)
            let hub = SensorHub(sensors: [KeyboardTimingSensor(), ActivitySensor(), AppSwitchSensor()],
                                buffer: buffer, clock: clock)
            let model = AppModel(hub: hub, dayCloser: DayCloser(extractors: extractors, store: store))
            model.store = store
            return model
        } catch {
            let model = AppModel()
            model.startupFailure = "Tells could not open its store: \(error.localizedDescription)"
            return model
        }
    }

    /// Starts the sensors, the day closer and the permission watch. Call it once.
    func startCollection() {
        guard collectionTasks.isEmpty, let hub else { return }
        let (signals, continuation) = AsyncStream<Bool>.makeStream()
        pauseSignals = continuation
        collectionTasks = [
            // One task sends the pause changes in order.
            Task { for await paused in signals { await hub.setPaused(paused) } },
            Task { await hub.run() },
            Task { [dayCloser] in await dayCloser?.start() },
        ]
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopCollection() }
        }
        observePermissionTriggers()
        sendPause()   // also starts the permission poll
    }

    /// A sensor with a missing permission starts after the grant, without a restart (D-080).
    /// The app checks when it becomes active and when the Mac wakes. While a sensor waits, it checks each 30 s.
    /// No check runs while the app is paused, while the Mac sleeps, or when no sensor waits (check 8).
    // DEFAULT: D-088
    private func observePermissionTriggers() {
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        pollObservers = [
            (app, app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePermissionPoll() }
            }),
            (workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPermissionPoll() }
            }),
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePermissionPoll(firstCheckAfterInterval: true) }
            }),
        ]
    }

    /// Starts the check loop again. It ends by itself when no sensor waits, and it never runs while paused.
    func updatePermissionPoll(firstCheckAfterInterval: Bool = false) {
        permissionPoll?.cancel()
        permissionPoll = nil
        guard let hub, !collectionTasks.isEmpty, pauseState == .notPaused else { return }
        let interval = permissionPollInterval
        permissionPoll = Task { [weak self] in
            var delay = firstCheckAfterInterval
            while !Task.isCancelled {
                if delay {
                    do { try await Task.sleep(for: interval, tolerance: interval / 3) } catch { return }
                }
                delay = true
                guard let self, !Task.isCancelled, self.pauseState == .notPaused else { return }
                self.refreshPermissions()
                await hub.retryUnstarted()
                guard await hub.hasUnstartedSensors() else { return }
            }
        }
    }

    private func cancelPermissionPoll() {
        permissionPoll?.cancel()
        permissionPoll = nil
    }

    /// Cancels the poll and the pause timer, and ends the pause signals. The hub stops itself on quit.
    func stopCollection() {
        collectionTasks.forEach { $0.cancel() }
        cancelPermissionPoll()
        for (center, token) in pollObservers { center.removeObserver(token) }
        pollObservers = []
        pauseTimer?.cancel()
        pauseTimer = nil
        pauseSignals?.finish()
        pauseSignals = nil
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        Task { [dayCloser] in await dayCloser?.stop() }
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
            let status = permissions.status(of: kind)
            if permissionStatuses[kind] != status { permissionStatuses[kind] = status }
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

    /// The CSV export needs the store. Until P2.8 sets it, the menu item is off.
    var canExport: Bool { store != nil }

    /// Writes the 3 gate CSV files for the last 30 days into `folder`. Returns one short result line.
    // DEFAULT: D-078
    func exportGateCSV(to folder: URL) async -> String {
        guard let store else { return "Export failed: no store." }
        do {
            let urls = try await CSVExport.exportAll(from: store, days: today.adding(days: -29)...today, to: folder)
            return "Exported \(urls.count) files."
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
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
        setPauseState(.pausedUntil(now().addingTimeInterval(duration)))
    }

    /// Sets the state and tells the hub. A timed pause resumes by itself at its end.
    private func setPauseState(_ state: PauseState) {
        pauseState = state
        pauseTimer?.cancel()
        pauseTimer = nil
        if case .pausedUntil(let end) = state {
            let sleep = pauseSleep
            pauseTimer = Task { [weak self, now] in
                do { try await sleep(max(0, end.timeIntervalSince(now()))) } catch { return }
                self?.pauseEnded(at: end)
            }
        }
        sendPause()
    }

    private func pauseEnded(at end: Date) {
        guard pauseState == .pausedUntil(end) else { return }
        setPauseState(.notPaused)
    }

    private func sendPause() {
        pauseSignals?.yield(pauseState != .notPaused)
        updatePermissionPoll()
    }

    /// Ends at the next local 04:00, the day boundary of DEC-3.
    func pauseUntilTomorrow() {
        // DEFAULT: D-056
        let boundary = DateComponents(hour: 4, minute: 0)
        guard let end = calendar.nextDate(after: now(), matching: boundary, matchingPolicy: .nextTime) else {
            setPauseState(.pausedUntilResumed)
            return
        }
        setPauseState(.pausedUntil(end))
    }

    /// Deletes all saved data, including the daily summaries (SPEC.md 4.3). The caller asks the user first.
    func deleteAllData() async throws {
        try await store?.deleteAll()
    }

    func pauseUntilResumed() {
        setPauseState(.pausedUntilResumed)
    }

    func resume() {
        setPauseState(.notPaused)
    }
}
