import AppKit
import SwiftUI

/// A floating panel for the companion. It never takes key focus (SPEC.md Section 5).
public final class CompanionPanel: NSPanel {
    public static let side: CGFloat = 96

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: CompanionPlaceholderView())
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}

/// Owns the panel and shows or hides it.
@MainActor
public final class CompanionPanelController {
    private let panel = CompanionPanel()
    private var hasPlacedPanel = false

    public init() {}

    public var isShown: Bool { panel.isVisible }

    public func setVisible(_ isVisible: Bool) {
        if isVisible {
            placeOnFirstShow()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func placeOnFirstShow() {
        guard !hasPlacedPanel else { return }
        hasPlacedPanel = true
        guard let area = NSScreen.main?.visibleFrame else { return }
        let margin: CGFloat = 24 // DEFAULT: D-057
        panel.setFrameOrigin(NSPoint(x: area.maxX - CompanionPanel.side - margin, y: area.minY + margin))
    }
}

/// A placeholder: a pot and a leaf. P4.1 replaces it with SpriteKit art.
struct CompanionPlaceholderView: View {
    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.green)
                .frame(width: 22, height: 44)
                .rotationEffect(.degrees(-25))
                .offset(x: -6, y: -14)
            Ellipse()
                .fill(Color.green.opacity(0.8))
                .frame(width: 22, height: 44)
                .rotationEffect(.degrees(25))
                .offset(x: 10, y: -20)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.brown)
                .frame(width: 48, height: 32)
                .offset(y: 24)
        }
        .frame(width: CompanionPanel.side, height: CompanionPanel.side)
        .accessibilityHidden(true)
    }
}
