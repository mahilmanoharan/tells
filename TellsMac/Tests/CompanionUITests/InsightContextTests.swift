import Foundation
import SwiftUI
import Testing
@testable import CompanionUI
import TellsCore

/// A fake experience. It shows the shared states and keeps one Task that `stop()` cancels.
@MainActor
final class FakeExperience: InsightExperience {
    let id = "fake"
    let displayName = "Fake"
    let glyph = "circle"
    let menuOrder = 1
    let need: PermissionKind?
    let permissionStatus: PermissionStatus
    private(set) var work: Task<Void, Never>?

    init(need: PermissionKind? = nil, permissionStatus: PermissionStatus = .granted) {
        self.need = need
        self.permissionStatus = permissionStatus
    }

    func state(in context: InsightContext) async -> ExperienceState {
        if let need, permissionStatus == .denied { return .permissionDenied(need) }
        let today = DateInterval(start: .distantPast, end: .distantFuture)
        let rows = (try? await context.store.featureRows(nil, in: today)) ?? []
        let windows = TodayFeatures.build(day: context.today, rows: rows, extractors: []).windowCount
        let prediction = await context.model.predict([:], day: context.today, windowCount: windows)
        guard prediction != nil || windows >= DataThreshold.minimumWindowsToday else {
            return .notEnoughData(have: windows, need: DataThreshold.minimumWindowsToday, unit: "windows")
        }
        return context.model.isMock ? .practice : .ready
    }

    func makeView(in context: InsightContext) -> AnyView {
        work = Task { while !Task.isCancelled { await Task.yield() } }
        return AnyView(EmptyView())
    }

    func stop() {
        work?.cancel()
        work = nil
    }
}

@Suite("InsightContext")
@MainActor
struct InsightContextTests {
    let today = TellsDay(yyyymmdd: 20261121)

    @Test func savesACheckInThroughTheStore() async throws {
        let store = InMemoryFeatureStore()
        let context = InsightContext(store: store, model: MockModelProvider(), today: today)
        let checkIn = CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 5), scores: [.energy: 4])

        try await context.saveCheckIn(checkIn)

        #expect(try await store.checkIns(today...today) == [checkIn])
        #expect(try await context.store.checkIns(today...today) == [checkIn])
    }

    @Test func savesWithAnInjectedWriter() async throws {
        let saved = SavedCheckIns()
        let context = InsightContext(store: InMemoryFeatureStore(), model: MockModelProvider(), today: today) {
            await saved.add($0)
        }
        try await context.saveCheckIn(CheckIn(day: today, savedAt: Date(timeIntervalSince1970: 0), scores: [.mood: 2]))
        #expect(await saved.items.map(\.scores) == [[.mood: 2]])
    }

    @Test func tooLittleDataShowsNotEnoughData() async throws {
        let store = InMemoryFeatureStore()
        let context = InsightContext(store: store, model: MockModelProvider(), today: today)
        #expect(await FakeExperience().state(in: context) == .notEnoughData(have: 0, need: 12, unit: "windows"))
    }

    @Test func permissionDeniedShowsItsState() async {
        let context = InsightContext(store: InMemoryFeatureStore(), model: MockModelProvider(), today: today)
        let experience = FakeExperience(need: .inputMonitoring, permissionStatus: .denied)
        #expect(await experience.state(in: context) == .permissionDenied(.inputMonitoring))
    }

    @Test func mockModelWithEnoughWindowsShowsPractice() async throws {
        let store = InMemoryFeatureStore()
        for index in 0..<12 {
            try await store.save(FeatureRow(
                sensor: .activity, schemaVersion: 1,
                windowStart: Date(timeIntervalSince1970: Double(index * 300)), utcOffsetMinutes: 0,
                day: today, coverageSeconds: 300, values: [:]))
        }
        let context = InsightContext(store: store, model: MockModelProvider(), today: today)
        #expect(await FakeExperience().state(in: context) == .practice)
    }

    @Test func stopCancelsTheViewTask() throws {
        let experience = FakeExperience()
        _ = experience.makeView(in: InsightContext(store: InMemoryFeatureStore(), model: MockModelProvider(), today: today))
        let work = try #require(experience.work)
        experience.stop()
        experience.stop()
        #expect(work.isCancelled)
        #expect(experience.work == nil)
    }
}

actor SavedCheckIns {
    private(set) var items: [CheckIn] = []
    func add(_ checkIn: CheckIn) { items.append(checkIn) }
}
