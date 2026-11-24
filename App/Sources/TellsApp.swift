import AppKit
import CompanionUI
import MacSensors
import TellsCore

/// The app has no SwiftUI scene. The menu bar item is an `NSStatusItem` (see `MenuBarController`).
@main
enum TellsMain {
    @MainActor private static var app: TellsApp?

    static func main() {
        MainActor.assumeIsolated {
            let tells = TellsApp()
            app = tells
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.run()
        }
    }
}

@MainActor
final class TellsApp {
    private let model: AppModel
    private let companionPanel: CompanionPanelController
    private let onboarding: OnboardingWindowController
    private let checkIn: CheckInWindowController
    private let insights: InsightsWindowController
    private let radialMenu: RadialMenuController
    private let menuBar: MenuBarController

    init() {
        let model = AppModel.live()
        let panel = CompanionPanelController()
        // P4.4.x replaces the placeholders one by one.
        let typingSound = TypingSoundExperience(
            keyboardAvailability: { [weak model] in model?.keyboardAvailability ?? .available },
            openPermissions: { [weak model] in model?.showOnboarding() })
        let whatIf = WhatIfExperience()
        let experiences: [any InsightExperience] = [YouVsMacExperience(), typingSound, GhostRacerExperience(), whatIf,
                                                    HapticWeekExperience()]
            + PlaceholderExperience.all().filter { $0.menuOrder > 5 }
        let insights = InsightsWindowController(
            experiences: experiences, contextProvider: { [weak model] in model?.makeInsightContext() },
            onKeyChange: { [weak model] isKey in model?.setInsightsWindowIsKey(isKey) })
        // "Test it" opens the Experiment. P4.4.6 selects the matching change.
        whatIf.openExperiment = { [weak insights] _ in insights?.show(experienceID: "experiment") }
        let menu = RadialMenuController(companion: panel, experiences: experiences,
                                        contextProvider: { [weak model] in model?.makeInsightContext() })
        menu.onChoose = { [weak insights] id in insights?.show(experienceID: id) }
        // The wake is visual only. Collection stays paused (D-093).
        menu.onWake = { [weak panel] in panel?.setState(.normal) }
        menu.onClose = { [weak panel, weak model] in
            if let model { panel?.setState(model.companionState) }
        }
        panel.onClick = { [weak menu] in menu?.companionClicked() }
        self.insights = insights
        radialMenu = menu
        model.onCompanionVisibilityChange = { [weak panel, weak menu] isVisible in
            if !isVisible { menu?.close() }
            panel?.setVisible(isVisible)
        }
        model.onCompanionStateChange = { [weak panel] state in panel?.setState(state) }
        panel.setVisible(model.isCompanionVisible)
        let onboarding = OnboardingWindowController(model: model)
        model.onShowOnboarding = { [weak onboarding] in onboarding?.show() }
        model.showOnboardingIfFirstStart()
        self.onboarding = onboarding
        let checkIn = CheckInWindowController(model: model)
        model.onShowCheckIn = { [weak checkIn] in checkIn?.show() }
        self.checkIn = checkIn
        YouVsMacExperience.purgeStaleForecast(today: model.today)
        model.startCollection()
        self.model = model
        menuBar = MenuBarController(model: model)
        companionPanel = panel
    }
}
