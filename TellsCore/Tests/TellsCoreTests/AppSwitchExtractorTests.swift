import Foundation
import Testing
@testable import TellsCore

struct AppSwitchExtractorTests {
    private let extractor = AppSwitchExtractor()
    private let day = TellsDay(yyyymmdd: 20261121)
    private let start = Date(timeIntervalSince1970: 1_795_000_000)
    private var window: DateInterval { DateInterval(start: start, duration: 300) }

    private func activation(atS seconds: Double, _ category: AppCategory) -> SensorSample {
        SensorSample(sensor: .appswitch, time: start.addingTimeInterval(seconds), kind: .appActivated,
                     value: Double(category.rawValue))
    }

    private func value(_ vector: FeatureVector, _ text: String) throws -> Double? { vector[try name(text)] }

    @Test func windowKnownAnswers() throws {
        // developer 10..100 (90 s), social 100..130 (30 s), developer 130..200 (70 s), other 200..300 (100 s).
        let samples = [activation(atS: 10, .developer), activation(atS: 100, .social),
                       activation(atS: 130, .developer), activation(atS: 200, .other)]
        let result = extractor.extractWindow(samples, window: window)
        #expect(try value(result, "appswitch.switch_count") == 4)
        #expect(try value(result, "appswitch.category_count") == 3)
        #expect(try value(result, "appswitch.developer_s") == 160)
        #expect(try value(result, "appswitch.social_s") == 30)
        #expect(try value(result, "appswitch.other_s") == 100)
        #expect(try value(result, "appswitch.productivity_s") == 0)
        #expect(try value(result, "appswitch.entertainment_s") == 0)
    }

    private func frontmost(atS seconds: Double, _ category: AppCategory) -> SensorSample {
        SensorSample(sensor: .appswitch, time: start.addingTimeInterval(seconds), kind: .appFrontmost,
                     value: Double(category.rawValue))
    }

    @Test func frontmostAloneFillsTheWindowAndIsNoSwitch() throws {
        let result = extractor.extractWindow([frontmost(atS: 0, .developer)], window: window)
        #expect(try value(result, "appswitch.developer_s") == 300)
        #expect(try value(result, "appswitch.switch_count") == 0)
        #expect(try value(result, "appswitch.category_count") == 1)
    }

    @Test func frontmostThenActivationSplitsTheSeconds() throws {
        let samples = [frontmost(atS: 0, .developer), activation(atS: 100, .social)]
        let result = extractor.extractWindow(samples, window: window)
        #expect(try value(result, "appswitch.developer_s") == 100)
        #expect(try value(result, "appswitch.social_s") == 200)
        #expect(try value(result, "appswitch.switch_count") == 1)
        #expect(try value(result, "appswitch.category_count") == 2)
    }

    @Test func windowWithNoActivationHasZeros() throws {
        let result = extractor.extractWindow([], window: window)
        #expect(try value(result, "appswitch.switch_count") == 0)
        #expect(try value(result, "appswitch.category_count") == 0)
        #expect(try value(result, "appswitch.other_s") == 0)
    }

    @Test func timeBeforeTheFirstActivationCountsForNoCategory() throws {
        let result = extractor.extractWindow([activation(atS: 250, .productivity)], window: window)
        #expect(try value(result, "appswitch.productivity_s") == 50)
        let total = extractor.windowFeatures.dropFirst(2).compactMap { result[$0] }.reduce(0, +)
        #expect(total == 50)
    }

    @Test func otherSensorsSamplesAreIgnored() throws {
        let foreign = SensorSample(sensor: .activity, time: start, kind: .inputProbe, value: 1)
        let result = extractor.extractWindow([foreign], window: window)
        #expect(try value(result, "appswitch.switch_count") == 0)
    }

    // MARK: day

    private func row(_ sensor: SensorID, _ values: [String: Double], day rowDay: TellsDay? = nil,
                     minute: Double = 600) throws -> FeatureRow {
        let startDate = start.addingTimeInterval(minute * 60)
        return FeatureRow(sensor: sensor, schemaVersion: 1, windowStart: startDate, utcOffsetMinutes: 0,
                          day: rowDay ?? day, coverageSeconds: 300,
                          values: Dictionary(uniqueKeysWithValues: try values.map { (try name($0.key), $0.value) }))
    }

    private func switchRows() throws -> [FeatureRow] {
        [try row(.appswitch, ["appswitch.switch_count": 6, "appswitch.developer_s": 120, "appswitch.social_s": 60,
                              "appswitch.other_s": 30]),
         try row(.appswitch, ["appswitch.switch_count": 4, "appswitch.developer_s": 60, "appswitch.productivity_s": 180,
                              "appswitch.entertainment_s": 30]),
         try row(.appswitch, ["appswitch.switch_count": 99, "appswitch.developer_s": 6000], day: day.adding(days: -1))]
    }

    @Test func daySumsKnownAnswers() throws {
        let result = extractor.extractDay(try switchRows(), day: day)
        #expect(try value(result, "appswitch.day_switch_count") == 10)
        #expect(try value(result, "appswitch.day_developer_min") == 3)
        #expect(try value(result, "appswitch.day_social_min") == 1)
        #expect(try value(result, "appswitch.day_productivity_min") == 3)
        #expect(try value(result, "appswitch.day_entertainment_min") == 0.5)
        #expect(try value(result, "appswitch.day_other_min") == 0.5)
    }

    @Test func rateIsPresentAtThirtyInputMinutes() throws {
        // 1800 s = 30 min of input: 10 switches / 0.5 h = 20 per hour.
        let rows = try switchRows() + [try row(.activity, ["activity.input_s": 1800])]
        let result = extractor.extractDay(rows, day: day)
        #expect(abs(try #require(try value(result, "appswitch.day_switch_rate_h")) - 20) < 1e-9)
    }

    @Test func rateIsAbsentUnderThirtyInputMinutes() throws {
        let rows = try switchRows() + [try row(.activity, ["activity.input_s": 1799])]
        #expect(try value(extractor.extractDay(rows, day: day), "appswitch.day_switch_rate_h") == nil)
        #expect(try value(extractor.extractDay(try switchRows(), day: day), "appswitch.day_switch_rate_h") == nil)
    }

    @Test func noAppSwitchRowGivesAnEmptyDay() throws {
        #expect(extractor.extractDay([try row(.activity, ["activity.input_s": 3600])], day: day).isEmpty)
    }
}
