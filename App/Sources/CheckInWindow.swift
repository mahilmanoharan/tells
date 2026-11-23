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
        // The form is always 380 pt wide. A new form for each opening needs a new window.
        window?.close()
        let newWindow = makeFixedSizeWindow(title: "Tells Check-in", content: CheckInView(model: checkIn))
        window = newWindow
        NSApplication.shared.activate()
        newWindow.makeKeyAndOrderFront(nil)
    }
}
