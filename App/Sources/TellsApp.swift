import CompanionUI
import MacSensors
import SwiftUI
import TellsCore

@main
struct TellsApp: App {
    @State private var model: AppModel
    private let companionPanel: CompanionPanelController
    private let onboarding: OnboardingWindowController
    private let checkIn: CheckInWindowController

    init() {
        let model = AppModel.live()
        let panel = CompanionPanelController()
        model.onCompanionVisibilityChange = { [weak panel] isVisible in
            panel?.setVisible(isVisible)
        }
        panel.setVisible(model.isCompanionVisible)
        let onboarding = OnboardingWindowController(model: model)
        model.onShowOnboarding = { [weak onboarding] in onboarding?.show() }
        model.showOnboardingIfFirstStart()
        self.onboarding = onboarding
        let checkIn = CheckInWindowController(model: model)
        model.onShowCheckIn = { [weak checkIn] in checkIn?.show() }
        self.checkIn = checkIn
        model.startCollection()
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
        if let failure = model.startupFailure {
            Text(failure)
            Divider()
        }
        Button("Check in") { model.showCheckIn() }
            .disabled(!model.canCheckIn)
        Menu("Pause Tells") {
            Button("For 1 Hour") { model.pause(for: 3600) }
            Button("Until Tomorrow") { model.pauseUntilTomorrow() }
            Button("Until Resumed") { model.pauseUntilResumed() }
        }
        if model.isPaused {
            Button("Resume Tells") { model.resume() }
        }
        Button("Permissions…") { model.showOnboarding() }
        Button("Export CSV for Gate…") { chooseFolderAndExport() }
            .disabled(!model.canExport)
        Button("Delete All Data…") { confirmAndDeleteAllData() }
        Divider()
        Button("Quit Tells") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension MenuBarContent {
    /// One confirmation, then `deleteAllData()`.
    // DEFAULT: D-073
    @MainActor
    private func confirmAndDeleteAllData() {
        let alert = NSAlert()
        alert.messageText = "Delete all data?"
        alert.informativeText = "Tells deletes all saved features, daily summaries and check-ins. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All Data")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { try? await model.deleteAllData() }
    }

    /// Folder panel, then `exportGateCSV(to:)`, then one result alert.
    // DEFAULT: D-078
    @MainActor
    private func chooseFolderAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            let alert = NSAlert()
            alert.messageText = await model.exportGateCSV(to: folder)
            alert.runModal()
        }
    }
}
