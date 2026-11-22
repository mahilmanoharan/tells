import SwiftUI
import TellsCore

public enum ExperienceState: Sendable, Equatable {
    case ready
    case practice                                   // MockModelProvider is active
    case notEnoughData(have: Int, need: Int, unit: String)
    case permissionDenied(PermissionKind)
    case notOnThisMac(hardware: String)
}

/// Read access, and one write: today's check-in (SPEC.md Section 2.7, DEC-16).
public struct InsightContext: Sendable {
    public let store: any FeatureReader                 // no save, no delete
    public let model: any ModelProvider
    public let today: TellsDay
    public let saveCheckIn: @Sendable (CheckIn) async throws -> Void

    public init(store: any FeatureReader, model: any ModelProvider, today: TellsDay,
                saveCheckIn: @escaping @Sendable (CheckIn) async throws -> Void) {
        self.store = store
        self.model = model
        self.today = today
        self.saveCheckIn = saveCheckIn
    }

    /// Gives `store` as a `FeatureReader` and sends `saveCheckIn` to `store.save(_:)`.
    public init(store: any FeatureStore, model: any ModelProvider, today: TellsDay) {
        self.init(store: store as any FeatureReader, model: model, today: today) { checkIn in
            try await store.save(checkIn)
        }
    }
}

@MainActor
public protocol InsightExperience: AnyObject, Identifiable where ID == String {
    var id: String { get }
    var displayName: String { get }
    var glyph: String { get }        // SF Symbol name
    var menuOrder: Int { get }       // 1...7
    func state(in context: InsightContext) async -> ExperienceState
    func makeView(in context: InsightContext) -> AnyView
    func stop()                      // stops Task work, audio and haptics (check 8)
}
