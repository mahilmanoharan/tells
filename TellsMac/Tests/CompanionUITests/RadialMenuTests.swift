import AppKit
import SwiftUI
import Testing
import TellsCore
@testable import CompanionUI

private func nearlyEqual(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

@MainActor
struct RadialMenuLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let middle = CGPoint(x: 800, y: 500)

    @Test func sevenItemsOnA76PointCircleClockwiseFromTwelve() {
        let offsets = RadialMenuLayout.offsets(count: 7, companionCenter: middle, bounds: screen)
        #expect(offsets.count == 7)
        #expect(offsets.allSatisfy { nearlyEqual(hypot($0.x, $0.y), 76) })
        #expect(nearlyEqual(offsets[0].x, 0) && nearlyEqual(offsets[0].y, 76))   // 12 o'clock
        #expect(offsets[1].x > 0 && offsets[6].x < 0)                              // clockwise
        let step = 2 * Double.pi / 7
        for index in 1..<7 {
            let a = atan2(Double(offsets[index - 1].y), Double(offsets[index - 1].x))
            let b = atan2(Double(offsets[index].y), Double(offsets[index].x))
            var delta = a - b                                                       // clockwise is a falling angle
            if delta < 0 { delta += 2 * .pi }
            #expect(abs(delta - step) < 0.001)
        }
    }

    @Test func itemsAndGlyphsFollowTheDesignTable() {
        #expect(RadialMenuLayout.itemDiameter == 28 && RadialMenuLayout.radius == 76)
        let all = PlaceholderExperienceTable.rows
        #expect(all.map(\.name) == ["You vs. your Mac", "Typing rhythm sound", "Ghost racer", "What-if sliders",
                                    "Haptic week", "Experiment", "In-the-moment nudge"])
        #expect(all.map(\.glyph) == ["questionmark.circle", "waveform", "keyboard", "slider.horizontal.3",
                                     "hand.point.up.left", "flask", "bell"])
        #expect(all.map(\.order) == Array(1...7))
    }

    @Test func atTheLeftEdgeTheItemsUseA180DegreeArcToTheScreenCenter() {
        let edge = CGPoint(x: 30, y: 500)
        let offsets = RadialMenuLayout.offsets(count: 7, companionCenter: edge, bounds: screen)
        #expect(offsets.allSatisfy { nearlyEqual(hypot($0.x, $0.y), 76) })
        #expect(offsets.allSatisfy { edge.x + $0.x - 14 >= screen.minX - 0.001 })   // all on screen
        #expect(offsets.allSatisfy { $0.x >= -0.001 })                               // the arc points right
        #expect(nearlyEqual(offsets[0].x, 0) && nearlyEqual(offsets[0].y, 76))      // arc starts at 12
        #expect(nearlyEqual(offsets[6].x, 0) && nearlyEqual(offsets[6].y, -76))      // and ends at 6
        #expect(nearlyEqual(offsets[3].x, 76) && nearlyEqual(offsets[3].y, 0))
    }

    @Test func atTheBottomEdgeTheArcPointsUp() {
        let edge = CGPoint(x: 800, y: 30)
        let offsets = RadialMenuLayout.offsets(count: 7, companionCenter: edge, bounds: screen)
        #expect(offsets.allSatisfy { $0.y >= -0.001 })
        #expect(nearlyEqual(offsets[0].x, -76) && nearlyEqual(offsets[6].x, 76))
    }

    @Test func noBoundsKeepsTheFullCircle() {
        let offsets = RadialMenuLayout.offsets(count: 7, companionCenter: .zero, bounds: nil)
        #expect(offsets.contains { $0.y < 0 })
    }
}

/// The table, read from the placeholders.
@MainActor
private enum PlaceholderExperienceTable {
    struct Row { let name: String; let glyph: String; let order: Int }
    static var rows: [Row] { PlaceholderExperience.all().map { Row(name: $0.displayName, glyph: $0.glyph, order: $0.menuOrder) } }
}

@MainActor
struct RadialMenuModelTests {
    private func makeModel() -> RadialMenuModel {
        let items = PlaceholderExperience.all().map { RadialMenuItem(id: $0.id, name: $0.displayName, glyph: $0.glyph) }
        return RadialMenuModel(items: items, offsets: RadialMenuLayout.offsets(count: 7, companionCenter: .zero, bounds: nil))
    }

    @Test func itemOneHasTheFocusAtFirst() {
        #expect(makeModel().focusIndex == 0)
    }

    @Test func arrowKeysAndTabMoveTheFocus() {
        let model = makeModel()
        #expect(RadialMenuKey(keyCode: 124, shift: false) == .next)
        #expect(RadialMenuKey(keyCode: 123, shift: false) == .previous)
        #expect(RadialMenuKey(keyCode: 48, shift: false) == .next)
        #expect(RadialMenuKey(keyCode: 48, shift: true) == .previous)
        model.handle(.next)
        model.handle(.next)
        #expect(model.focusIndex == 2)
        model.handle(.previous)
        #expect(model.focusIndex == 1)
        model.handle(.previous)
        model.handle(.previous)
        #expect(model.focusIndex == 6)    // wraps counterclockwise
        model.handle(.next)
        #expect(model.focusIndex == 0)    // wraps clockwise
    }

    @Test func returnAndSpaceChooseTheFocusedItem() {
        let model = makeModel()
        var chosen: [String] = []
        model.onChoose = { chosen.append($0) }
        model.handle(.next)
        #expect(RadialMenuKey(keyCode: 36, shift: false) == .choose)
        #expect(RadialMenuKey(keyCode: 49, shift: false) == .choose)
        model.handle(.choose)
        #expect(chosen == ["typingSound"])
    }

    @Test func accessibilityLabelHasNameAndState() {
        var item = RadialMenuItem(id: "hapticWeek", name: "Haptic week", glyph: "hand.point.up.left")
        #expect(item.accessibilityLabel == "Haptic week, ready")
        item.state = .notEnoughData(have: 3, need: 7, unit: "days")
        #expect(item.accessibilityLabel == "Haptic week, not enough data")
        #expect(item.isDimmed)
        item.state = .permissionDenied(.inputMonitoring)
        #expect(!item.isDimmed)
    }

    @Test func stateUpdateDimsOneItem() {
        let model = makeModel()
        model.setStates(["experiment": .notEnoughData(have: 1, need: 7, unit: "days")])
        #expect(model.items.filter(\.isDimmed).map(\.id) == ["experiment"])
    }
}

@MainActor
struct RadialMenuControllerTests {
    private func makeRig() -> (RadialMenuController, CompanionPanelController) {
        let companion = CompanionPanelController(defaults: UserDefaults(suiteName: "tells.test.\(UUID().uuidString)") ?? .standard)
        let menu = RadialMenuController(companion: companion, experiences: PlaceholderExperience.all(), contextProvider: { nil })
        return (menu, companion)
    }

    private func keyEvent(_ code: UInt16, shift: Bool = false) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)
    }

    @Test func clickOpensAndSecondClickCloses() {
        let (menu, companion) = makeRig()
        companion.setVisible(true)
        menu.companionClicked()
        #expect(menu.isOpen)
        #expect(menu.model?.items.count == 7)
        menu.companionClicked()
        #expect(!menu.isOpen)
        companion.setVisible(false)
    }

    @Test func closeFreesTheHostingView() async throws {
        let (menu, companion) = makeRig()
        companion.setVisible(true)
        menu.open()
        #expect(menu.menuPanel.contentView != nil)
        menu.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(menu.menuPanel.contentView == nil)
        menu.open()                      // a new open builds new content
        #expect(menu.menuPanel.contentView != nil)
        menu.close()
        companion.setVisible(false)
    }

    @Test func escapeClosesTheMenu() throws {
        let (menu, companion) = makeRig()
        companion.setVisible(true)
        menu.open()
        menu.menuPanel.keyDown(with: try #require(keyEvent(53)))
        #expect(!menu.isOpen)
        companion.setVisible(false)
    }

    @Test func arrowKeysMoveTheFocusThroughThePanel() throws {
        let (menu, companion) = makeRig()
        companion.setVisible(true)
        menu.open()
        #expect(menu.model?.focusIndex == 0)
        menu.menuPanel.keyDown(with: try #require(keyEvent(124)))
        menu.menuPanel.keyDown(with: try #require(keyEvent(124)))
        #expect(menu.model?.focusIndex == 2)
        menu.menuPanel.keyDown(with: try #require(keyEvent(123)))
        #expect(menu.model?.focusIndex == 1)
        menu.menuPanel.keyDown(with: try #require(keyEvent(48, shift: true)))
        #expect(menu.model?.focusIndex == 0)
        menu.close()
        companion.setVisible(false)
    }

    @Test func returnChoosesTheFocusedItemAndClosesTheMenu() throws {
        let (menu, companion) = makeRig()
        companion.setVisible(true)
        var chosen: [String] = []
        menu.onChoose = { chosen.append($0) }
        menu.open()
        menu.menuPanel.keyDown(with: try #require(keyEvent(124)))
        menu.menuPanel.keyDown(with: try #require(keyEvent(36)))
        #expect(chosen == ["typingSound"])
        #expect(!menu.isOpen)
        companion.setVisible(false)
    }

    @Test func clickInAsleepWakesBeforeTheMenuOpens() {
        let (menu, companion) = makeRig()
        companion.setVisible(true)
        companion.setState(.asleep, animated: false)
        var openWhenWoken: Bool?
        menu.onWake = { openWhenWoken = menu.isOpen }
        menu.companionClicked()
        #expect(openWhenWoken == false)    // the wake came first
        #expect(menu.isOpen)
        menu.close()
        companion.setState(.normal, animated: false)
        menu.companionClicked()
        #expect(openWhenWoken == false && menu.isOpen)   // no wake outside Asleep: the callback did not run again
        menu.close()
        companion.setVisible(false)
    }
}

@MainActor
struct CompanionClickTests {
    @Test func aPressWithNoMovementIsAClick() {
        let panel = CompanionPanel()
        var clicks = 0
        panel.sceneView.onClick = { clicks += 1 }
        let start = panel.frame.origin
        panel.sceneView.beginPress(atScreenPoint: NSPoint(x: 100, y: 100))
        panel.sceneView.continuePress(toScreenPoint: NSPoint(x: 102, y: 101))
        panel.sceneView.endPress()
        #expect(clicks == 1)
        #expect(panel.frame.origin == start)
    }

    @Test func aDragMovesThePanelAndIsNotAClick() {
        let panel = CompanionPanel()
        var clicks = 0
        panel.sceneView.onClick = { clicks += 1 }
        let start = panel.frame.origin
        panel.sceneView.beginPress(atScreenPoint: NSPoint(x: 100, y: 100))
        panel.sceneView.continuePress(toScreenPoint: NSPoint(x: 140, y: 90))
        panel.sceneView.endPress()
        #expect(clicks == 0)
        #expect(panel.frame.origin == NSPoint(x: start.x + 40, y: start.y - 10))
    }
}
