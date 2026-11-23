import AppKit

/// The menu bar item. It is a plain `NSStatusItem` with an `NSMenu`, with no SwiftUI hosting view.
/// A `MenuBarExtra` keeps a SwiftUI hosting window alive all the time. That window was the
/// likely source of the idle crash in `NSHostingView.windowDidLayout` (crash 2026-11-21 22:29).
// DEFAULT: D-086
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem?
    private let menu = NSMenu()

    /// `installStatusItem` is false in tests, so they do not add an item to the real menu bar.
    init(model: AppModel, installStatusItem: Bool = true) {
        self.model = model
        statusItem = installStatusItem ? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) : nil
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem?.button?.image = NSImage(systemSymbolName: "leaf", accessibilityDescription: "Tells")
        statusItem?.menu = menu
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// The menu for the current `AppModel` state.
    func rebuild() {
        menu.removeAllItems()
        add(model.isCompanionVisible ? "Hide Companion" : "Show Companion") { $0.model.toggleCompanion() }
        if let failure = model.startupFailure {
            add(failure, enabled: false, action: nil)
            menu.addItem(.separator())
        }
        add("Check in", enabled: model.canCheckIn) { $0.model.showCheckIn() }
        let pause = NSMenuItem(title: "Pause Tells", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        pauseMenu.autoenablesItems = false
        pauseMenu.addItem(item("For 1 Hour") { $0.model.pause(for: 3600) })
        pauseMenu.addItem(item("Until Tomorrow") { $0.model.pauseUntilTomorrow() })
        pauseMenu.addItem(item("Until Resumed") { $0.model.pauseUntilResumed() })
        pause.submenu = pauseMenu
        menu.addItem(pause)
        if model.isPaused {
            add("Resume Tells") { $0.model.resume() }
        }
        add("Permissions…") { $0.model.showOnboarding() }
        add("Export CSV for Gate…", enabled: model.canExport) { $0.chooseFolderAndExport() }
        add("Delete All Data…") { $0.confirmAndDeleteAllData() }
        menu.addItem(.separator())
        let quit = item("Quit Tells") { _ in NSApplication.shared.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// The titles of the top-level items. A separator is "-". For tests.
    var itemTitles: [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    func item(titled title: String) -> NSMenuItem? { menu.items.first { $0.title == title } }

    private final class ActionItem: NSMenuItem {
        var handler: (() -> Void)?
        @objc func run() { handler?() }
    }

    private func item(_ title: String, enabled: Bool = true, action: ((MenuBarController) -> Void)?) -> NSMenuItem {
        let item = ActionItem(title: title, action: action == nil ? nil : #selector(ActionItem.run), keyEquivalent: "")
        item.target = item
        item.isEnabled = enabled
        item.handler = { [weak self] in
            guard let self else { return }
            action?(self)
        }
        return item
    }

    private func add(_ title: String, enabled: Bool = true, action: ((MenuBarController) -> Void)?) {
        menu.addItem(item(title, enabled: enabled, action: action))
    }

    /// One confirmation, then `deleteAllData()`.
    // DEFAULT: D-073
    private func confirmAndDeleteAllData() {
        let alert = NSAlert()
        alert.messageText = "Delete all data?"
        alert.informativeText = "Tells deletes all saved features, daily summaries and check-ins. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All Data")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let model = model
        Task { try? await model.deleteAllData() }
    }

    /// Folder panel, then `exportGateCSV(to:)`, then one result alert.
    // DEFAULT: D-078
    private func chooseFolderAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let model = model
        Task {
            let alert = NSAlert()
            alert.messageText = await model.exportGateCSV(to: folder)
            alert.runModal()
        }
    }
}
