import Foundation
import Testing
@testable import TellsCore

@Suite("MockModelProvider")
struct MockModelProviderTests {
    let day = TellsDay(yyyymmdd: 20261121)

    func features(sleepStart: Double, lateInput: Double) throws -> FeatureVector {
        [try name("activity.sleep_start_min"): sleepStart, try name("activity.late_input_min"): lateInput]
    }

    @Test func declaresItsContract() throws {
        let model = MockModelProvider()
        #expect(model.target == .energy)
        #expect(model.isMock)
        #expect(model.featureNames == [try name("activity.sleep_start_min"), try name("activity.late_input_min")])
    }

    @Test func givesTheKnownAnswer() async throws {
        let prediction = try #require(
            await MockModelProvider().predict(try features(sleepStart: 500, lateInput: 30), day: day, windowCount: 12)
        )
        #expect(prediction.day == day)
        #expect(prediction.target == .energy)
        #expect(abs(prediction.value - 2.7) < 1e-9)
    }

    @Test func clampsTo1Through5() async throws {
        let high = await MockModelProvider().predict(try features(sleepStart: -1000, lateInput: 0), day: day, windowCount: 20)
        let low = await MockModelProvider().predict(try features(sleepStart: 2000, lateInput: 300), day: day, windowCount: 20)
        #expect(high?.value == 5)
        #expect(low?.value == 1)
    }

    @Test func returnsNilBelow12Windows() async throws {
        let input = try features(sleepStart: 500, lateInput: 30)
        #expect(await MockModelProvider().predict(input, day: day, windowCount: 11) == nil)
        #expect(await MockModelProvider().predict(input, day: day, windowCount: 0) == nil)
        #expect(await MockModelProvider().predict(input, day: day, windowCount: 12) != nil)
    }

    @Test func returnsNilIfAFeatureIsMissing() async throws {
        let input: FeatureVector = [try name("activity.sleep_start_min"): 500]
        #expect(await MockModelProvider().predict(input, day: day, windowCount: 40) == nil)
    }
}

@Suite("TodayFeatures")
struct TodayFeaturesTests {
    let today = TellsDay(yyyymmdd: 20261121)

    @Test func runsEachExtractorOnItsOwnRows() throws {
        let input = try name("activity.input_s")
        let rows = [
            row(.activity, minute: 0, values: [input: 120]),
            row(.activity, minute: 5, values: [input: 60]),
            row(.keyboard, minute: 5, values: [input: 9999]),
        ]
        let result = TodayFeatures.build(day: today, rows: rows, extractors: [SumExtractor()])
        #expect(result.values == [try name("activity.input_min"): 3])
        #expect(result.day == today)
    }

    @Test func countsDistinctWindowsOfToday() {
        let yesterday = TellsDay(yyyymmdd: 20261120)
        let rows = [
            row(.activity, minute: 0), row(.keyboard, minute: 0),
            row(.activity, minute: 5),
            row(.activity, minute: -400, day: yesterday),
        ]
        #expect(TodayFeatures.build(day: today, rows: rows, extractors: []).windowCount == 2)
    }

    @Test func tooLittleDataTodayGivesNoPrediction() async throws {
        let sleep = try name("activity.sleep_start_min")
        let late = try name("activity.late_input_min")
        let values: FeatureVector = [sleep: 500, late: 30]
        let elevenWindows = (0..<11).map { row(.activity, minute: $0 * 5, values: values) }
        let few = TodayFeatures.build(day: today, rows: elevenWindows, extractors: [])
        #expect(few.windowCount == 11)
        #expect(await MockModelProvider().predict(values, day: today, windowCount: few.windowCount) == nil)

        let enough = TodayFeatures.build(day: today, rows: elevenWindows + [row(.activity, minute: 55)], extractors: [])
        #expect(await MockModelProvider().predict(values, day: today, windowCount: enough.windowCount) != nil)
    }
}
