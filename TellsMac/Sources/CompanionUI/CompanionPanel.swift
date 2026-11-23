import AppKit
import SpriteKit

/// A floating panel for the companion. It never takes key focus (SPEC.md Section 5).
public final class CompanionPanel: NSPanel {
    public static let side: CGFloat = 96
    let sceneView: CompanionSKView

    public init() {
        let sceneView = CompanionSKView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        self.sceneView = sceneView
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
        contentView = sceneView
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}

/// The one SKView of the companion. It draws at 30 fps at most (D-040) and can be dragged.
final class CompanionSKView: SKView {
    let sprout = SproutScene(size: CGSize(width: SproutScene.side, height: SproutScene.side))
    private var isSuspendedByHost = false
    private var isOccluded = false
    private var occlusionObserver: (any NSObjectProtocol)?

    /// Calm states: Normal, Drifting and Asleep. The sway is slow, so a low rate looks the same. Idle CPU cost.
    // DEFAULT: D-089
    static let calmFramesPerSecond = 8
    static let livelyFramesPerSecond = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowsTransparency = true
        preferredFramesPerSecond = Self.calmFramesPerSecond // Normal state; DEFAULT: D-040, D-085, D-089
        ignoresSiblingOrder = true
        presentScene(sprout)
        sprout.onPauseChange = { [weak self] _ in self?.refreshPause() }
        sprout.onStateChange = { [weak self] state in
            // DEFAULT: D-085, D-089
            self?.preferredFramesPerSecond = state == .scattered || state == .social
                ? Self.livelyFramesPerSecond : Self.calmFramesPerSecond
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The render loop also stops while the panel is fully covered, on another Space, or the screen is off.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.setOccluded(!window.occlusionState.contains(.visible)) }
        }
    }

    private func setOccluded(_ occluded: Bool) {
        isOccluded = occluded
        refreshPause()
    }

    /// A click starts a window drag, so the panel moves by its background.
    override var mouseDownCanMoveWindow: Bool { true }

    /// The host stops the render loop while the panel is hidden.
    func setSuspendedByHost(_ suspended: Bool) {
        isSuspendedByHost = suspended
        refreshPause()
    }

    private func refreshPause() {
        isPaused = isSuspendedByHost || isOccluded || sprout.isPaused
    }
}

/// Owns the panel, shows or hides it, and remembers where the user put it.
@MainActor
public final class CompanionPanelController: NSObject, NSWindowDelegate {
    static let positionKey = "companion.panelOrigin"

    let panel = CompanionPanel()
    private let defaults: UserDefaults
    private var hasPlacedPanel = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        panel.delegate = self
    }

    public var isShown: Bool { panel.isVisible }

    /// The state the scene shows. Default is Normal. P4.2 connects real data.
    public var state: CompanionState { panel.sceneView.sprout.state }

    public func setState(_ state: CompanionState, animated: Bool = true) {
        panel.sceneView.sprout.setState(state, animated: animated)
    }

    public func setVisible(_ isVisible: Bool) {
        if isVisible {
            placeOnFirstShow()
            panel.sceneView.setSuspendedByHost(false)
            panel.orderFrontRegardless()
        } else {
            savePosition()
            panel.orderOut(nil)
            panel.sceneView.setSuspendedByHost(true)
        }
    }

    public func windowDidMove(_ notification: Notification) {
        savePosition()
    }

    private func savePosition() {
        guard hasPlacedPanel else { return }
        defaults.set(NSStringFromPoint(panel.frame.origin), forKey: Self.positionKey)
    }

    // DEFAULT: D-084, D-085
    private func placeOnFirstShow() {
        guard !hasPlacedPanel else { return }
        if let saved = savedOrigin() {
            panel.setFrameOrigin(saved)
        } else if let area = NSScreen.main?.visibleFrame {
            let margin: CGFloat = 24 // DEFAULT: D-057
            panel.setFrameOrigin(NSPoint(x: area.maxX - CompanionPanel.side - margin, y: area.minY + margin))
        }
        hasPlacedPanel = true
    }

    /// The saved origin, only if the panel would still be on a screen.
    private func savedOrigin() -> NSPoint? {
        guard let text = defaults.string(forKey: Self.positionKey) else { return nil }
        let origin = NSPointFromString(text)
        let frame = NSRect(origin: origin, size: panel.frame.size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) } ? origin : nil
    }
}
