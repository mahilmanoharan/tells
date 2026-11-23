import AppKit
import SwiftUI

/// Makes a fixed-size window for a SwiftUI view.
/// The default `sizingOptions` let the hosting view resize the window on every layout pass.
/// That loop has the same risk as the 2026-11-21 22:29 crash: an `NSInternalInconsistencyException`
/// from `NSHostingView.windowDidLayout`. An empty set stops the loop:
/// the window gets its size one time, from the fitting size of the view.
// DEFAULT: D-086
@MainActor
func makeFixedSizeWindow<Content: View>(title: String, content: Content) -> NSWindow {
    let hosting = NSHostingController(rootView: content)
    let size = hosting.view.fittingSize
    hosting.sizingOptions = []
    let window = NSWindow(contentViewController: hosting)
    window.setContentSize(size)
    window.title = title
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    return window
}
