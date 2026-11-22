import CompanionUI
import MacSensors
import SwiftUI
import TellsCore

@main
struct TellsApp: App {
    @State private var model: AppModel
    private let companionPanel: CompanionPanelController
    private let onboarding: OnboardingWindowController

    init() {
        let model = AppModel()
        let panel = CompanionPanelController()
        model.onCompanionVisibilityChange = { [weak panel] isVisible in
            panel?.setVisible(isVisible)
        }
        panel.setVisible(model.isCompanionVisible)
        let onboarding = OnboardingWindowController(model: model)
        model.onShowOnboarding = { [weak onboarding] in onboarding?.show() }
        model.showOnboardingIfFirstStart()
        self.onboarding = onboarding
        _model = State(initialValue: model)
        companionPanel = panel
    }

    var body: some Scene {
        MenuBarExtra("Tells", systemImage: "leaf") {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.menu)
        Settings {
            EmptyView()
        }
    }
}

private struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        Button(model.isCompanionVisible ? "Hide Companion" : "Show Companion") {
            model.toggleCompanion()
        }
        Menu("Pause Tells") {
            Button("For 1 Hour") { model.pause(for: 3600) }
            Button("Until Tomorrow") { model.pauseUntilTomorrow() }
            Button("Until Resumed") { model.pauseUntilResumed() }
        }
        if model.isPaused {
            Button("Resume Tells") { model.resume() }
        }
        Button("Permissions…") { model.showOnboarding() }
        Divider()
        Button("Quit Tells") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
