import AppKit
import SwiftUI
import TellsCore

struct OnboardingView: View {
    let model: AppModel
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions").font(.title2.bold())
            ForEach(model.permissionRows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.sentence)
                    HStack {
                        Text(row.statusText).foregroundStyle(.secondary)
                        Spacer()
                        if let title = row.buttonTitle {
                            Button(title) { model.performAction(for: row.kind) }
                        }
                    }
                }
            }
            Text(PermissionInfo.sharedSentence).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Continue", action: onContinue).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Opens the onboarding window and refreshes the status when the app becomes active.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [model] _ in
            MainActor.assumeIsolated { model.refreshPermissions() }
        }
    }

    func show() {
        model.refreshPermissions()
        if window == nil {
            window = makeFixedSizeWindow(
                title: "Tells Permissions",
                content: OnboardingView(model: model) { [weak self] in self?.window?.close() }
            )
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
