import AppKit
import SpriteKit
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

@MainActor
struct SproutSceneTests {
    private func makeScene() -> SproutScene {
        SproutScene(size: CGSize(width: 96, height: 96))
    }

    private func allNodes(_ node: SKNode) -> [SKNode] {
        [node] + node.children.flatMap(allNodes)
    }

    @Test func startsInNormal() {
        let scene = makeScene()
        #expect(scene.state == .normal)
        #expect(scene.flower.isHidden)
        #expect(scene.marks.allSatisfy { $0.isHidden })
        #expect(!scene.isPaused)
    }

    @Test func eachStateShowsItsLook() {
        let scene = makeScene()
        // Order of marks: tilde, scattered ticks, sparkles, "z z".
        let expectedMark: [CompanionState: Int?] = [.normal: nil, .drifting: 0, .scattered: 1, .social: 2, .asleep: 3]
        for state in CompanionState.allCases {
            scene.setState(state, animated: false)
            #expect(scene.state == state)
            #expect(scene.flower.isHidden == (state != .social))
            for (index, mark) in scene.marks.enumerated() {
                #expect(mark.isHidden == (expectedMark[state]! != index))
            }
            #expect(scene.isPaused == (state == .asleep))
        }
    }

    @Test func asleepPausesAfterTheTransition() {
        let scene = makeScene()
        scene.setState(.asleep, animated: true)
        #expect(!scene.isPaused)
        scene.update(10)
        #expect(!scene.isPaused)
        scene.update(10 + SproutScene.transitionSeconds + 0.1)
        #expect(scene.isPaused)
        scene.setState(.normal, animated: false)
        #expect(!scene.isPaused)
    }

    @Test func viewRunsAtMost30FpsAndStopsInAsleep() {
        let panel = CompanionPanel()
        let view = panel.sceneView
        #expect(view.preferredFramesPerSecond <= 30)
        #expect(!view.isPaused)
        view.sprout.setState(.asleep, animated: false)
        #expect(view.isPaused)
        view.sprout.setState(.social, animated: false)
        #expect(!view.isPaused)
        view.setSuspendedByHost(true)
        #expect(view.isPaused)
    }

    @Test func sceneHasNoTextNode() {
        let scene = makeScene()
        #expect(!allNodes(scene).contains { $0 is SKLabelNode })
    }

    @Test func panelHoldsOneSKViewAndCanBeDragged() {
        let panel = CompanionPanel()
        #expect(panel.contentView is SKView)
        #expect(!panel.sceneView.mouseDownCanMoveWindow) // the view drags the panel itself (D-021)
    }

    @Test func positionSurvivesRestart() throws {
        guard let area = NSScreen.main?.visibleFrame else { return }
        let suite = "tells.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let place = NSPoint(x: area.minX + 120, y: area.minY + 140)
        let first = CompanionPanelController(defaults: defaults)
        first.setVisible(true)
        first.panel.setFrameOrigin(place)
        first.setVisible(false)
        #expect(!first.isShown)
        let second = CompanionPanelController(defaults: defaults)
        second.setVisible(true)
        #expect(second.panel.frame.origin == place)
        second.setVisible(false)
    }
}
