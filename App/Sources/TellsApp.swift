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
    private let menuBar: MenuBarController

    init() {
        let model = AppModel.live()
        let panel = CompanionPanelController()
        model.onCompanionVisibilityChange = { [weak panel] isVisible in
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
        model.startCollection()
        self.model = model
        menuBar = MenuBarController(model: model)
        companionPanel = panel
    }
}
