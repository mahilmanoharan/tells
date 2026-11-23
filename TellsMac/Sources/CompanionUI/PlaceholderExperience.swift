import SwiftUI

/// A stand-in for one insight experience. P4.4.x replaces each one with the real plugin.
/// The menu order, names and glyphs are from design/experiences.md Section 2.
// DEFAULT: D-093
@MainActor
public final class PlaceholderExperience: InsightExperience {
    public let id: String
    public let displayName: String
    public let glyph: String
    public let menuOrder: Int

    public init(id: String, displayName: String, glyph: String, menuOrder: Int) {
        self.id = id
        self.displayName = displayName
        self.glyph = glyph
        self.menuOrder = menuOrder
    }

    /// The 7 experiences in menu order.
    public static func all() -> [PlaceholderExperience] {
        let table: [(String, String, String)] = [
            ("youVsMac", "You vs. your Mac", "questionmark.circle"),
            ("typingSound", "Typing rhythm sound", "waveform"),
            ("ghostRacer", "Ghost racer", "keyboard"),
            ("whatIf", "What-if sliders", "slider.horizontal.3"),
            ("hapticWeek", "Haptic week", "hand.point.up.left"),
            ("experiment", "Experiment", "flask"),
            ("nudge", "In-the-moment nudge", "bell"),
        ]
        return table.enumerated().map { index, row in
            PlaceholderExperience(id: row.0, displayName: row.1, glyph: row.2, menuOrder: index + 1)
        }
    }

    public func state(in context: InsightContext) async -> ExperienceState { .ready }

    public func makeView(in context: InsightContext) -> AnyView {
        AnyView(PlaceholderExperienceView(name: displayName))
    }

    public func stop() {}
}

struct PlaceholderExperienceView: View {
    let name: String

    var body: some View {
        VStack(spacing: 8) {
            Text(name).font(.title2)
            Text("This experience is not ready yet.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
