import AppKit
import SwiftUI
import Testing
@testable import Tells

@MainActor
struct HostedWindowTests {
    /// The old code used the default `sizingOptions`. They let the hosting view resize the window
    /// on each layout pass, which caused the NSHostingView.windowDidLayout crash.
    @Test func hostingControllerDoesNotResizeTheWindow() throws {
        let window = makeFixedSizeWindow(title: "T", content: Text("hello"))
        let hosting = try #require(window.contentViewController as? NSHostingController<Text>)
        #expect(hosting.sizingOptions.isEmpty)
        #expect(NSHostingController(rootView: Text("hello")).sizingOptions.isEmpty == false)
    }

    @Test func windowHasTheFittingSize() throws {
        let window = makeFixedSizeWindow(title: "T", content: Text("hello").frame(width: 200, height: 80))
        let size = window.contentRect(forFrameRect: window.frame).size
        #expect(size.width > 0 && size.height > 0, "size \(size)")
        #expect(window.title == "T")
        #expect(window.isReleasedWhenClosed == false)
    }
}
