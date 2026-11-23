import AppKit
import SpriteKit

/// RGB color that can be blended between two poses.
struct RGB: Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat

    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }

    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    func blended(to other: RGB, _ t: CGFloat) -> RGB {
        var result = self
        result.r += (other.r - r) * t
        result.g += (other.g - g) * t
        result.b += (other.b - b) * t
        return result
    }
}

/// Everything that differs between states. Points use the SVG mock-up space (96 x 96, y down).
struct SproutPose {
    var stemControl: CGPoint
    var stemTop: CGPoint
    var leafBase: CGPoint
    /// Clockwise degrees on screen. 0 is the open leaf of the Normal mock-up.
    var leftLeafAngle: CGFloat
    var rightLeafAngle: CGFloat
    var leafColor: RGB
    var potColor: RGB
    var flowerScale: CGFloat
    /// Alpha of the marks: tilde, scattered ticks and arcs, sparkles, "z z".
    var markAlpha: [CGFloat]

    static func target(for state: CompanionState) -> SproutPose {
        switch state {
        case .normal:
            SproutPose(stemControl: CGPoint(x: 48, y: 51), stemTop: CGPoint(x: 48, y: 40), leafBase: CGPoint(x: 48, y: 42),
                       leftLeafAngle: 0, rightLeafAngle: 0, leafColor: RGB(0x5DBB63), potColor: RGB(0xC8724F),
                       flowerScale: 0, markAlpha: [0, 0, 0, 0])
        case .drifting:
            SproutPose(stemControl: CGPoint(x: 50, y: 50), stemTop: CGPoint(x: 58, y: 44), leafBase: CGPoint(x: 58, y: 44),
                       leftLeafAngle: -55, rightLeafAngle: 65, leafColor: RGB(0x8DAA5A), potColor: RGB(0xC8724F),
                       flowerScale: 0, markAlpha: [1, 0, 0, 0])
        case .scattered:
            SproutPose(stemControl: CGPoint(x: 46, y: 52), stemTop: CGPoint(x: 48, y: 40), leafBase: CGPoint(x: 48, y: 42),
                       leftLeafAngle: 22, rightLeafAngle: 32, leafColor: RGB(0x5DBB63), potColor: RGB(0xC8724F),
                       flowerScale: 0, markAlpha: [0, 1, 0, 0])
        case .social:
            SproutPose(stemControl: CGPoint(x: 48, y: 48), stemTop: CGPoint(x: 48, y: 34), leafBase: CGPoint(x: 48, y: 46),
                       leftLeafAngle: -24, rightLeafAngle: 24, leafColor: RGB(0x4FC768), potColor: RGB(0xC8724F),
                       flowerScale: 1, markAlpha: [0, 0, 1, 0])
        case .asleep:
            SproutPose(stemControl: CGPoint(x: 48, y: 52), stemTop: CGPoint(x: 48, y: 42), leafBase: CGPoint(x: 48, y: 44),
                       leftLeafAngle: 62, rightLeafAngle: -62, leafColor: RGB(0x5E8F62), potColor: RGB(0xA9654C),
                       flowerScale: 0, markAlpha: [0, 0, 0, 1])
        }
    }

    func blended(to other: SproutPose, _ t: CGFloat) -> SproutPose {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: mix(a.x, b.x), y: mix(a.y, b.y)) }
        return SproutPose(
            stemControl: mix(stemControl, other.stemControl),
            stemTop: mix(stemTop, other.stemTop),
            leafBase: mix(leafBase, other.leafBase),
            leftLeafAngle: mix(leftLeafAngle, other.leftLeafAngle),
            rightLeafAngle: mix(rightLeafAngle, other.rightLeafAngle),
            leafColor: leafColor.blended(to: other.leafColor, t),
            potColor: potColor.blended(to: other.potColor, t),
            flowerScale: mix(flowerScale, other.flowerScale),
            markAlpha: zip(markAlpha, other.markAlpha).map { mix($0, $1) }
        )
    }
}

/// The Sprout companion (design/companion-concepts.md, Concept C), built from SpriteKit shapes.
/// It has no text node and no number. It draws in SVG space (y down) inside a flipped root node.
final class SproutScene: SKScene {
    static let side: CGFloat = 96
    static let outline = NSColor(srgbRed: 0x2B / 255, green: 0x2F / 255, blue: 0x33 / 255, alpha: 1)
    // DEFAULT: D-085
    static let transitionSeconds: TimeInterval = 0.45

    private(set) var state: CompanionState = .normal
    /// Called when the scene pauses or resumes itself, so the view can stop its render loop (D-040).
    /// Called at each `setState`, so the view can lower its frame rate for slow states.
    var onStateChange: ((CompanionState) -> Void)?
    var onPauseChange: ((Bool) -> Void)?

    private let root = SKNode()
    private let stem = SKShapeNode()
    private let stemGroup = SKEffectNode()
    private let potGroup = SKEffectNode()
    private let potBody = SKShapeNode()
    private let potRim = SKShapeNode()
    private let leafSway = SKNode()
    private let leftLeaf = SKNode()
    private let rightLeaf = SKNode()
    private var leafShapes: [SKShapeNode] = []
    let flower = SKEffectNode()
    /// Marks in the order of `SproutPose.markAlpha`.
    private(set) var marks: [SKEffectNode] = []
    private var markMotion: [SKNode] = []

    private var pose = SproutPose.target(for: .normal)
    private var transition: (from: SproutPose, to: SproutPose, start: TimeInterval?)?

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .aspectFill
        backgroundColor = .clear
        buildNodes()
        applyPose(pose)
        startIdleMotion(for: .normal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: State

    /// Moves to `newState`. `animated: false` jumps to the final pose and settles at once.
    func setState(_ newState: CompanionState, animated: Bool = true) {
        state = newState
        onStateChange?(newState)
        stopIdleMotion()
        setScenePaused(false)
        let target = SproutPose.target(for: newState)
        if animated {
            transition = (pose, target, nil)
        } else {
            transition = nil
            pose = target
            applyPose(target)
            settle()
        }
    }

    /// A short hop for a click (D-021). It takes 0.2 s.
    // DEFAULT: D-093
    func playClickReaction() {
        let hop = SKAction.sequence([
            .moveBy(x: 0, y: 5, duration: 0.1),
            .moveBy(x: 0, y: -5, duration: 0.1),
        ])
        root.removeAction(forKey: Self.clickKey)
        root.run(hop, withKey: Self.clickKey)
    }

    private static let clickKey = "click"

    /// The transition runs in `update`, so it needs no closure and stops when the scene pauses.
    override func update(_ currentTime: TimeInterval) {
        guard var running = transition else { return }
        let start = running.start ?? currentTime
        running.start = start
        let t = min(1, (currentTime - start) / Self.transitionSeconds)
        let eased = t * t * (3 - 2 * t)
        pose = running.from.blended(to: running.to, CGFloat(eased))
        applyPose(pose)
        if t >= 1 {
            transition = nil
            settle()
        } else {
            transition = running
        }
    }

    private func settle() {
        if state == .asleep {
            setScenePaused(true) // D-040
        } else {
            startIdleMotion(for: state)
        }
    }

    private func setScenePaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        onPauseChange?(paused)
    }

    // MARK: Drawing

    private func buildNodes() {
        root.position = CGPoint(x: 0, y: Self.side)
        root.yScale = -1
        addChild(root)

        let shadow = SKShapeNode(ellipseOf: CGSize(width: 40, height: 6))
        shadow.position = CGPoint(x: 48, y: 88)
        shadow.fillColor = NSColor.black.withAlphaComponent(0.18)
        shadow.lineWidth = 0
        root.addChild(shadow)

        styleStroke(stem, width: 2.5)
        stem.fillColor = .clear
        stemGroup.shouldRasterize = true
        stemGroup.addChild(stem)
        root.addChild(stemGroup)

        root.addChild(leafSway)
        for (leaf, direction) in [(leftLeaf, CGFloat(-1)), (rightLeaf, 1)] {
            let shape = SKShapeNode(path: Self.leafPath(direction: direction))
            styleStroke(shape, width: 2)
            let vein = SKShapeNode(path: Self.veinPath(direction: direction))
            vein.strokeColor = Self.outline.withAlphaComponent(0.5)
            vein.lineWidth = 1
            leaf.addChild(shape)
            leaf.addChild(vein)
            leafShapes.append(shape)
            leafSway.addChild(leaf)
        }

        buildFlower()
        buildPot()
        buildMarks()
    }

    private func styleStroke(_ node: SKShapeNode, width: CGFloat) {
        node.strokeColor = Self.outline
        node.lineWidth = width
        node.lineCap = .round
        node.lineJoin = .round
    }

    private static func leafPath(direction: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: 28 * direction, y: -10), control: CGPoint(x: 14 * direction, y: -18))
        path.addQuadCurve(to: .zero, control: CGPoint(x: 18 * direction, y: 4))
        path.closeSubpath()
        return path
    }

    private static func veinPath(direction: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: 22 * direction, y: -9), control: CGPoint(x: 12 * direction, y: -8))
        return path
    }

    private func buildFlower() {
        flower.shouldRasterize = true
        flower.position = CGPoint(x: 48, y: 31)
        for index in 0..<5 {
            let holder = SKNode()
            holder.zRotation = CGFloat(index) * 2 * .pi / 5
            let petal = SKShapeNode(ellipseOf: CGSize(width: 7.2, height: 12))
            petal.position = CGPoint(x: 0, y: -6)
            petal.fillColor = NSColor(srgbRed: 1, green: 0xB6 / 255, blue: 0xC9 / 255, alpha: 1)
            styleStroke(petal, width: 1)
            holder.addChild(petal)
            flower.addChild(holder)
        }
        let center = SKShapeNode(circleOfRadius: 3)
        center.fillColor = NSColor(srgbRed: 1, green: 0xC8 / 255, blue: 0x3D / 255, alpha: 1)
        styleStroke(center, width: 1)
        flower.addChild(center)
        root.addChild(flower)
    }

    private func buildPot() {
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 30, y: 66))
        body.addLine(to: CGPoint(x: 66, y: 66))
        body.addLine(to: CGPoint(x: 62, y: 86))
        body.addQuadCurve(to: CGPoint(x: 34, y: 86), control: CGPoint(x: 48, y: 89))
        body.closeSubpath()
        potBody.path = body
        styleStroke(potBody, width: 2.5)
        potRim.path = CGPath(roundedRect: CGRect(x: 27, y: 60, width: 42, height: 9), cornerWidth: 3, cornerHeight: 3, transform: nil)
        styleStroke(potRim, width: 2.5)
        let shine = CGMutablePath()
        shine.move(to: CGPoint(x: 36, y: 72))
        shine.addLine(to: CGPoint(x: 37, y: 82))
        let shineNode = SKShapeNode(path: shine)
        shineNode.strokeColor = NSColor.white.withAlphaComponent(0.35)
        shineNode.lineWidth = 2
        shineNode.lineCap = .round
        potGroup.shouldRasterize = true
        potGroup.addChild(potBody)
        potGroup.addChild(potRim)
        potGroup.addChild(shineNode)
        root.addChild(potGroup)
    }

    private func buildMarks() {
        let tilde = CGMutablePath()
        tilde.move(to: CGPoint(x: 20, y: 30))
        tilde.addQuadCurve(to: CGPoint(x: 26, y: 30), control: CGPoint(x: 23, y: 27))
        tilde.addQuadCurve(to: CGPoint(x: 32, y: 30), control: CGPoint(x: 29, y: 33))

        let ticks = CGMutablePath()
        // Two arcs on each side of the pot (design/mockups/sprout-scattered.svg).
        for (x, bulge) in [(CGFloat(10), CGFloat(-4)), (5, -5), (86, 4), (91, 5)] {
            ticks.move(to: CGPoint(x: x, y: x < 48 && x > 8 ? 50 : 46))
            ticks.addQuadCurve(to: CGPoint(x: x, y: x < 48 && x > 8 ? 66 : 70), control: CGPoint(x: x + bulge, y: 58))
        }
        let sparks = CGMutablePath()
        for (cx, cy, r) in [(CGFloat(18), CGFloat(22), CGFloat(4)), (80, 22, 5), (84, 62, 3)] {
            Self.addStar(to: sparks, cx: cx, cy: cy, r: r)
        }
        let zz = CGMutablePath()
        Self.addZ(to: zz, x: 64, y: 23, size: 8)
        Self.addZ(to: zz, x: 73, y: 16, size: 6)

        marks = [
            makeMark(stroked: tilde, haloed: true, fill: nil),
            makeMark(stroked: ticks, haloed: true, fill: nil),
            makeMark(stroked: sparks, haloed: false, fill: NSColor(srgbRed: 1, green: 0xC8 / 255, blue: 0x3D / 255, alpha: 1)),
            makeMark(stroked: zz, haloed: true, fill: nil),
        ]
        marks.forEach(root.addChild)
    }

    /// A mark is a parent (alpha from the pose) and a motion child (idle animation).
    private func makeMark(stroked path: CGPath, haloed: Bool, fill: NSColor?) -> SKEffectNode {
        let mark = SKEffectNode()
        mark.shouldRasterize = true
        let motion = SKNode()
        if haloed {
            let halo = SKShapeNode(path: path)
            halo.strokeColor = NSColor.white.withAlphaComponent(0.85)
            halo.lineWidth = 4.3
            halo.lineCap = .round
            halo.lineJoin = .round
            motion.addChild(halo)
        }
        let line = SKShapeNode(path: path)
        styleStroke(line, width: haloed ? 1.8 : 0.8)
        if let fill { line.fillColor = fill }
        motion.addChild(line)
        mark.addChild(motion)
        markMotion.append(motion)
        return mark
    }

    private static func addStar(to path: CGMutablePath, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let k = r * 0.3
        let points = [(0, -r), (k, -k), (r, 0), (k, k), (0, r), (-k, k), (-r, 0), (-k, -k)]
        for (index, p) in points.enumerated() {
            let point = CGPoint(x: cx + p.0, y: cy + p.1)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
    }

    private static func addZ(to path: CGMutablePath, x: CGFloat, y: CGFloat, size: CGFloat) {
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + size, y: y))
        path.addLine(to: CGPoint(x: x, y: y + size))
        path.addLine(to: CGPoint(x: x + size, y: y + size))
    }

    // MARK: Pose

    private func applyPose(_ pose: SproutPose) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 48, y: 62))
        path.addQuadCurve(to: pose.stemTop, control: pose.stemControl)
        stem.path = path

        leafSway.position = pose.leafBase
        leftLeaf.zRotation = Self.radians(pose.leftLeafAngle)
        rightLeaf.zRotation = Self.radians(pose.rightLeafAngle)
        leafShapes.forEach { $0.fillColor = pose.leafColor.color }
        potBody.fillColor = pose.potColor.color
        potRim.fillColor = pose.potColor.color

        flower.setScale(max(pose.flowerScale, 0.001))
        flower.isHidden = pose.flowerScale < 0.01
        for (mark, alpha) in zip(marks, pose.markAlpha) {
            mark.alpha = alpha
            mark.isHidden = alpha < 0.01
        }
    }

    private static func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

    // MARK: Idle motion

    private func stopIdleMotion() {
        leafSway.removeAllActions()
        leafSway.zRotation = 0
        for motion in markMotion {
            motion.removeAllActions()
            motion.position = .zero
            motion.alpha = 1
            motion.setScale(1)
        }
    }

    /// Slow actions only. The view caps the frame rate at 30 (D-040).
    private func startIdleMotion(for state: CompanionState) {
        switch state {
        case .normal:
            sway(degrees: 3, period: 4)
        case .drifting:
            sway(degrees: 1.5, period: 6)
            let drift = SKAction.sequence([
                .group([.moveBy(x: 0, y: -6, duration: 3), .fadeAlpha(to: 0.2, duration: 3)]),
                .group([.move(to: .zero, duration: 0), .fadeAlpha(to: 1, duration: 0)]),
            ])
            markMotion[0].run(.repeatForever(drift))
        case .scattered:
            sway(degrees: 8, period: 0.6)
            let flicker = SKAction.sequence([.fadeAlpha(to: 0.4, duration: 0.25), .fadeAlpha(to: 1, duration: 0.25)])
            markMotion[1].run(.repeatForever(flicker))
        case .social:
            sway(degrees: 4, period: 2)
            let twinkle = SKAction.sequence([.scale(to: 0.7, duration: 0.5), .scale(to: 1.1, duration: 0.5)])
            markMotion[2].run(.repeatForever(twinkle))
        case .asleep:
            break
        }
    }

    private func sway(degrees: CGFloat, period: TimeInterval) {
        let angle = Self.radians(degrees)
        let half = period / 2
        let there = SKAction.rotate(toAngle: angle, duration: half / 2, shortestUnitArc: true)
        let back = SKAction.rotate(toAngle: -angle, duration: half, shortestUnitArc: true)
        let home = SKAction.rotate(toAngle: 0, duration: half / 2, shortestUnitArc: true)
        for action in [there, back, home] { action.timingMode = .easeInEaseOut }
        leafSway.run(.repeatForever(.sequence([there, back, home])))
    }
}
