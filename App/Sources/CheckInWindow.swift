import AppKit
import CompanionUI
import SwiftUI

/// Opens the check-in window. Each opening makes a new form for today.
@MainActor
final class CheckInWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        guard let context = model.makeInsightContext() else { return }
        let checkIn = CheckInModel(context: context, onSaved: { [weak self] in
            // Close after a short moment so the user sees that the check-in is saved.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.window?.close()
            }
        })
        let hosting = NSHostingController(rootView: CheckInView(model: checkIn))
        let newWindow = window ?? NSWindow(contentViewController: hosting)
        newWindow.contentViewController = hosting
        newWindow.title = "Tells Check-in"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        if window == nil { newWindow.center() }
        window = newWindow
        NSApplication.shared.activate()
        newWindow.makeKeyAndOrderFront(nil)
    }
}
