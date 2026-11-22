import AppKit
import Testing
@testable import CompanionUI

@MainActor
struct CompanionPanelTests {
    @Test func panelHasTheSpecifiedShape() {
        let panel = CompanionPanel()
        #expect(panel.frame.size == NSSize(width: 96, height: 96))
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.isOpaque)
        #expect(panel.isMovableByWindowBackground)
    }

    @Test func panelNeverTakesFocus() {
        let panel = CompanionPanel()
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }
}
