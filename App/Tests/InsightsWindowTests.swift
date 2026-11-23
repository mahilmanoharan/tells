import AppKit
import CompanionUI
import Foundation
import SwiftUI
import Synchronization
import Testing
import TellsCore
@testable import Tells

@MainActor
private final class StoppableExperience: InsightExperience {
    let id: String
    let displayName: String
    let glyph = "circle"
    let menuOrder = 1
    private(set) var madeViews = 0
    private(set) var stops = 0

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    func state(in context: InsightContext) async -> ExperienceState { .ready }
    func makeView(in context: InsightContext) -> AnyView {
        madeViews += 1
        return AnyView(EmptyView())
    }
    func stop() { stops += 1 }
}

@MainActor
struct InsightsWindowTests {
    private func context() -> InsightContext {
        InsightContext(store: InMemoryFeatureStore(), model: MockModelProvider(), today: TellsDay(yyyymmdd: 20261123))
    }

    @Test func windowHasTheSpecifiedSizeAndTitle() throws {
        let one = StoppableExperience(id: "one", displayName: "One")
        let controller = InsightsWindowController(experiences: [one], contextProvider: { nil }, onKeyChange: { _ in })
        controller.show(experienceID: "one")
        let window = try #require(controller.window)
        #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 520, height: 440))
        #expect(window.title == "One")
        window.close()
    }

    @Test func newChoiceReplacesAndStopsTheOldExperience() throws {
        let one = StoppableExperience(id: "one", displayName: "One")
        let two = StoppableExperience(id: "two", displayName: "Two")
        let ctx = context()
        let controller = InsightsWindowController(experiences: [one, two], contextProvider: { ctx }, onKeyChange: { _ in })
        controller.show(experienceID: "one")
        #expect(one.madeViews == 1 && one.stops == 0)
        controller.show(experienceID: "two")
        #expect(one.stops == 1)
        #expect(controller.window?.title == "Two")
        controller.window?.close()
        #expect(two.stops == 1)
        #expect(controller.currentID == nil)
    }

    /// D-026: while the insights window is the key window, the hub suppresses keyboard events.
    @Test func keyWindowSuppressesTheKeyboardSensor() throws {
        let hub = FakeSuppressHub()
        let model = AppModel(hub: hub)
        let one = StoppableExperience(id: "one", displayName: "One")
        let controller = InsightsWindowController(
            experiences: [one], contextProvider: { nil }, onKeyChange: { model.setInsightsWindowIsKey($0) })
        controller.show(experienceID: "one")
        let window = try #require(controller.window)
        hub.reset()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(hub.calls == [true])
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(hub.calls == [true, false])
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        window.close()
        #expect(hub.calls.last == false)
    }

    /// The wake is visual only: a click in Asleep does not end the user pause.
    @Test func clickInAsleepKeepsTheUserPause() {
        let model = AppModel()
        model.pauseUntilResumed()
        let companion = CompanionPanelController(defaults: UserDefaults(suiteName: "tells.test.\(UUID().uuidString)") ?? .standard)
        companion.setVisible(true)
        companion.setState(.asleep, animated: false)
        let menu = RadialMenuController(companion: companion, experiences: PlaceholderExperience.all(), contextProvider: { nil })
        menu.onWake = { companion.setState(.normal, animated: false) }
        menu.onClose = { companion.setState(model.companionState, animated: false) }
        menu.companionClicked()
        #expect(companion.state == .normal)
        #expect(model.isPaused)
        menu.close()
        #expect(model.isPaused)
        companion.setVisible(false)
    }
}

private final class FakeSuppressHub: CollectionControlling {
    private let log = Mutex<[Bool]>([])
    var calls: [Bool] { log.withLock { $0 } }
    func reset() { log.withLock { $0 = [] } }
    func run() async {}
    func setPaused(_ paused: Bool) async {}
    func retryUnstarted() async {}
    func hasUnstartedSensors() async -> Bool { false }
    func setKeyboardSuppressed(_ value: Bool) { log.withLock { $0.append(value) } }
}
