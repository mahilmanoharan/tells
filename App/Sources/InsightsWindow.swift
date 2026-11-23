import AppKit
import CompanionUI
import Observation
import SwiftUI

/// The one view that the insights window shows. A new choice replaces it.
@MainActor
@Observable
final class InsightsContent {
    var view = AnyView(EmptyView())
}

// DEFAULT: D-093 (an AppKit window, not a SwiftUI scene)
/// The shared window for all insight experiences (D-023). 520 x 440 pt, one experience at a time.
/// While it is the key window, the keyboard sensor drops key events (D-026).
@MainActor
final class InsightsWindowController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 520, height: 440)

    private let experiences: [String: any InsightExperience]
    private let contextProvider: () -> InsightContext?
    private let onKeyChange: (Bool) -> Void
    private let content = InsightsContent()
    private(set) var window: NSWindow?
    private(set) var currentID: String?
    private var observers: [any NSObjectProtocol] = []

    init(experiences: [any InsightExperience], contextProvider: @escaping () -> InsightContext?,
         onKeyChange: @escaping (Bool) -> Void) {
        self.experiences = Dictionary(experiences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.contextProvider = contextProvider
        self.onKeyChange = onKeyChange
        super.init()
    }

    /// Shows the experience. It stops the one that was open before.
    func show(experienceID: String) {
        guard let experience = experiences[experienceID] else { return }
        stopCurrent()
        currentID = experienceID
        if let context = contextProvider() {
            content.view = experience.makeView(in: context)
        } else {
            content.view = AnyView(Text("Tells has no data yet.").foregroundStyle(.secondary))
        }
        let window = window ?? makeWindow()
        window.title = experience.displayName
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: InsightsRootView(content: content))
        hosting.sizingOptions = []   // D-086
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(Self.size)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onKeyChange(true) }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onKeyChange(false) }
            },
        ]
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        stopCurrent()
        content.view = AnyView(EmptyView())
        onKeyChange(false)
        // D-096: no hosting view stays after close. The next show() builds a new window.
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        releaseHostingContentAfterClose(of: closing) { [weak self] in
            guard let self else { return }
            closing.delegate = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            window = nil
        }
    }

    /// Stops the Task work, audio and haptics of the open experience (check 8).
    private func stopCurrent() {
        if let currentID { experiences[currentID]?.stop() }
        currentID = nil
    }
}

struct InsightsRootView: View {
    let content: InsightsContent

    var body: some View {
        content.view
            .frame(width: InsightsWindowController.size.width, height: InsightsWindowController.size.height)
    }
}
