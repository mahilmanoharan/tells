import AppKit
import CompanionUI
import SwiftUI

/// Opens the check-in window. Each opening makes a new form for today.
@MainActor
final class CheckInWindowController {
    private(set) var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?
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
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        let newWindow = makeFixedSizeWindow(title: "Tells Check-in", content: CheckInView(model: checkIn))
        window = newWindow
        // D-096: no hosting view stays after close.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: newWindow, queue: .main
        ) { [weak self, weak newWindow] _ in
            MainActor.assumeIsolated {
                guard let self, let newWindow else { return }
                releaseHostingContentAfterClose(of: newWindow) { [weak self] in
                    guard let self, self.window === newWindow else { return }
                    if let observer = self.closeObserver { NotificationCenter.default.removeObserver(observer) }
                    self.closeObserver = nil
                    self.window = nil
                }
            }
        }
        NSApplication.shared.activate()
        newWindow.makeKeyAndOrderFront(nil)
    }
}
