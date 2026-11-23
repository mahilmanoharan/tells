import AppKit
import Observation
import SwiftUI
import TellsCore

/// Where the 7 items sit (design/experiences.md Section 2, D-022).
public enum RadialMenuLayout {
    public static let itemDiameter: CGFloat = 28
    public static let radius: CGFloat = 76

    /// Item centers relative to the companion center. y points up (AppKit). Item 1 is at 12 o'clock,
    /// and the items follow clockwise. If an item would leave `bounds`, all items share a 180 degree arc
    /// that points to the middle of `bounds`.
    public static func offsets(count: Int, companionCenter: CGPoint, bounds: CGRect?) -> [CGPoint] {
        guard count > 0 else { return [] }
        let full = (0..<count).map { point(angle: Double($0) * 2 * .pi / Double(count)) }
        guard let bounds, full.contains(where: { !isInside(companionCenter, $0, bounds) }) else { return full }
        let toCenter = atan2(Double(bounds.midX - companionCenter.x), Double(bounds.midY - companionCenter.y))
        guard count > 1 else { return [point(angle: toCenter)] }
        let step = Double.pi / Double(count - 1)
        return (0..<count).map { point(angle: toCenter - .pi / 2 + Double($0) * step) }
    }

    /// `angle` is clockwise from 12 o'clock.
    private static func point(angle: Double) -> CGPoint {
        CGPoint(x: radius * CGFloat(sin(angle)), y: radius * CGFloat(cos(angle)))
    }

    private static func isInside(_ center: CGPoint, _ offset: CGPoint, _ bounds: CGRect) -> Bool {
        let half = itemDiameter / 2
        let rect = CGRect(x: center.x + offset.x - half, y: center.y + offset.y - half, width: itemDiameter, height: itemDiameter)
        return bounds.contains(rect)
    }
}

/// One menu item: an experience with its current state.
public struct RadialMenuItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let glyph: String
    public var state: ExperienceState

    public init(id: String, name: String, glyph: String, state: ExperienceState = .ready) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.state = state
    }

    /// Not enough data shows at 50% opacity. The item still opens.
    public var isDimmed: Bool {
        if case .notEnoughData = state { return true }
        return false
    }

    public var accessibilityLabel: String { "\(name), \(Self.words(for: state))" }

    static func words(for state: ExperienceState) -> String {
        switch state {
        case .ready: "ready"
        case .practice: "practice mode"
        case .notEnoughData: "not enough data"
        case .permissionDenied: "needs permission"
        case .notOnThisMac: "not on this Mac"
        }
    }
}

public enum RadialMenuKey: Sendable, Equatable {
    case next, previous, choose, close

    public init?(keyCode: UInt16, shift: Bool) {
        switch keyCode {
        case 124: self = .next            // Right arrow
        case 123: self = .previous        // Left arrow
        case 48: self = shift ? .previous : .next   // Tab, Shift-Tab
        case 36, 76, 49: self = .choose   // Return, Enter, Space
        case 53: self = .close            // Esc
        default: return nil
        }
    }
}

/// The items, the focus and the hover. The view reads it.
@MainActor
@Observable
public final class RadialMenuModel {
    public private(set) var items: [RadialMenuItem]
    public private(set) var focusIndex = 0     // item 1 has the focus when the menu opens
    public private(set) var usedKeyboard = false
    public var hoveredID: String?
    public let offsets: [CGPoint]

    @ObservationIgnored public var onChoose: ((String) -> Void)?
    @ObservationIgnored public var onClose: (() -> Void)?

    public init(items: [RadialMenuItem], offsets: [CGPoint]) {
        self.items = items
        self.offsets = offsets
    }

    public var focusedItem: RadialMenuItem? { items.indices.contains(focusIndex) ? items[focusIndex] : nil }

    /// Right arrow or Tab is +1 (clockwise). Left arrow or Shift-Tab is -1. The focus wraps.
    public func moveFocus(by step: Int) {
        guard !items.isEmpty else { return }
        usedKeyboard = true
        focusIndex = ((focusIndex + step) % items.count + items.count) % items.count
    }

    public func setStates(_ states: [String: ExperienceState]) {
        for index in items.indices {
            if let state = states[items[index].id] { items[index].state = state }
        }
    }

    public func choose(_ id: String) { onChoose?(id) }

    /// Returns true if the key was used.
    @discardableResult
    public func handle(_ key: RadialMenuKey) -> Bool {
        switch key {
        case .next: moveFocus(by: 1)
        case .previous: moveFocus(by: -1)
        case .choose: if let id = focusedItem?.id { choose(id) }
        case .close: onClose?()
        }
        return true
    }
}

struct RadialMenuView: View {
    static let side = CGSize(width: 360, height: 260)
    let model: RadialMenuModel
    @State private var spread = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var center: CGPoint { CGPoint(x: Self.side.width / 2, y: Self.side.height / 2) }

    var body: some View {
        ZStack {
            // A click anywhere else closes the menu. This includes the companion.
            Color.clear.contentShape(Rectangle()).onTapGesture { model.onClose?() }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                itemView(item, index: index)
            }
            if let label = labelledItem, let index = model.items.firstIndex(of: label) {
                Text(label.name)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .position(position(of: index, extra: 34))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Self.side.width, height: Self.side.height)
        .onAppear {
            if reduceMotion { spread = true } else { withAnimation(.easeOut(duration: 0.2)) { spread = true } }
        }
    }

    private var labelledItem: RadialMenuItem? {
        if let id = model.hoveredID { return model.items.first { $0.id == id } }
        return model.usedKeyboard ? model.focusedItem : nil
    }

    private func position(of index: Int, extra: CGFloat = 0) -> CGPoint {
        guard spread, model.offsets.indices.contains(index) else { return center }
        let offset = model.offsets[index]
        let scale = (RadialMenuLayout.radius + extra) / RadialMenuLayout.radius
        return CGPoint(x: center.x + offset.x * scale, y: center.y - offset.y * scale)   // SwiftUI y points down
    }

    private func itemView(_ item: RadialMenuItem, index: Int) -> some View {
        let isFocused = index == model.focusIndex
        return Button { model.choose(item.id) } label: {
            Image(systemName: item.glyph)
                .font(.system(size: 13))
                .frame(width: RadialMenuLayout.itemDiameter, height: RadialMenuLayout.itemDiameter)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(isFocused ? Color.accentColor : Color.secondary.opacity(0.5),
                                               lineWidth: isFocused ? 2 : 1))
        }
        .buttonStyle(.plain)
        .opacity(item.isDimmed ? 0.5 : 1)
        .position(position(of: index))
        .onHover { inside in
            if inside { model.hoveredID = item.id } else if model.hoveredID == item.id { model.hoveredID = nil }
        }
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}

/// The panel for the menu. It can be the key window, so it reads the keys, but it does not activate the app.
final class RadialMenuPanel: NSPanel {
    var onKey: ((RadialMenuKey) -> Void)?

    init() {
        let size = RadialMenuView.side
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if let key = RadialMenuKey(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift)) {
            onKey?(key)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onKey?(.close) }
}

/// Opens and closes the menu for the companion (D-021). It keeps no timer.
// DEFAULT: D-093
@MainActor
public final class RadialMenuController: NSObject, NSWindowDelegate {
    private let companion: CompanionPanelController
    private let experiences: [any InsightExperience]
    private let contextProvider: () -> InsightContext?
    private let panel = RadialMenuPanel()
    private var stateTask: Task<Void, Never>?
    public private(set) var model: RadialMenuModel?

    /// The user chose an experience. The menu is already closed.
    public var onChoose: ((String) -> Void)?
    /// A click in the Asleep state calls this before the menu opens (D-021).
    public var onWake: (() -> Void)?
    /// The menu closed. The app puts the companion back in its real state.
    public var onClose: (() -> Void)?

    public init(companion: CompanionPanelController, experiences: [any InsightExperience],
                contextProvider: @escaping () -> InsightContext?) {
        self.companion = companion
        self.experiences = experiences.sorted { $0.menuOrder < $1.menuOrder }
        self.contextProvider = contextProvider
        super.init()
        panel.delegate = self
        panel.onKey = { [weak self] key in self?.model?.handle(key) }
    }

    public var isOpen: Bool { model != nil }
    var menuPanel: RadialMenuPanel { panel }

    /// The companion was clicked. A second click closes the menu.
    public func companionClicked() {
        if isOpen { close(); return }
        if companion.state == .asleep { onWake?() }
        open()
    }

    public func open() {
        guard model == nil, !experiences.isEmpty else { return }
        let frame = companion.panel.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        // DEFAULT: D-093
        let bounds = (companion.panel.screen ?? NSScreen.main)?.visibleFrame
        let offsets = RadialMenuLayout.offsets(count: experiences.count, companionCenter: center, bounds: bounds)
        let items = experiences.map { RadialMenuItem(id: $0.id, name: $0.displayName, glyph: $0.glyph) }
        let model = RadialMenuModel(items: items, offsets: offsets)
        model.onChoose = { [weak self] id in self?.choose(id) }
        model.onClose = { [weak self] in self?.close() }
        self.model = model

        let size = RadialMenuView.side
        let hosting = NSHostingView(rootView: RadialMenuView(model: model))
        hosting.sizingOptions = []   // D-086: a fixed size, no layout loop
        panel.contentView = hosting
        panel.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height), display: false)
        panel.makeKeyAndOrderFront(nil)
        loadStates(into: model)
    }

    public func close() {
        guard model != nil else { return }
        stateTask?.cancel()
        stateTask = nil
        model = nil
        panel.orderOut(nil)
        onClose?()
        // No hosting view at idle (D-086). Free it one run loop turn later, so a tap handler never frees its own view.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model == nil else { return }
            self.panel.contentView = nil
        }
    }

    private func choose(_ id: String) {
        close()
        onChoose?(id)
    }

    /// Reads the state of each experience one time, then updates the dimming.
    private func loadStates(into model: RadialMenuModel) {
        guard let context = contextProvider() else { return }
        let experiences = experiences
        stateTask = Task { [weak model] in
            var states: [String: ExperienceState] = [:]
            for experience in experiences {
                if Task.isCancelled { return }
                states[experience.id] = await experience.state(in: context)
            }
            if !Task.isCancelled { model?.setStates(states) }
        }
    }

    /// The user clicked another window.
    public func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
