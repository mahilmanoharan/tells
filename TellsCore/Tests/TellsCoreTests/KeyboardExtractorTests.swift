import Foundation
import Testing
@testable import TellsCore

struct KeyboardExtractorTests {
    private let extractor = KeyboardExtractor()
    private let start = Date(timeIntervalSince1970: 1_795_000_000)
    private var window: DateInterval { DateInterval(start: start, duration: 300) }

    private func sample(_ kind: SampleKind, atMs ms: Double) -> SensorSample {
        SensorSample(sensor: .keyboard, time: start.addingTimeInterval(ms / 1000), kind: kind)
    }

    /// Key downs at the given ms. Each key is held `hold` ms.
    private func keys(downs: [Double], hold: Double = 100) -> [SensorSample] {
        downs.flatMap { [sample(.keyDown, atMs: $0), sample(.keyUp, atMs: $0 + hold)] }
            .sorted { $0.time < $1.time }
    }

    private func value(_ vector: FeatureVector, _ text: String) throws -> Double? {
        vector[try name(text)]
    }

    private func close(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 1e-3
    }

    @Test func knownAnswersForTwelveKeys() throws {
        // IKIs: 100, 200, 300, ... 1100 ms (11 values).
        var times: [Double] = [0]
        for step in 1...11 { times.append(times.last! + Double(step) * 100) }
        let result = extractor.extractWindow(keys(downs: times), window: window)
        #expect(try value(result, "keyboard.key_count") == 12)
        #expect(close(try value(result, "keyboard.iki_mean_ms"), 600))
        #expect(close(try value(result, "keyboard.iki_median_ms"), 600))
        let sd = try #require(try value(result, "keyboard.iki_sd_ms"))
        #expect(abs(sd - 331.6625) < 0.001)       // sqrt(110000)
        #expect(close(try value(result, "keyboard.iki_iqr_ms"), 500))   // Q3 850, Q1 350
        #expect(try value(result, "keyboard.pause_count") == 0)
        #expect(close(try value(result, "keyboard.typing_s"), 6.6))
    }

    @Test func holdsPairFirstInFirstOutAndDropLongOnes() throws {
        // 11 keys, each down at i*500 ms, hold 50 ms; hold values 11 of 50.
        let result = extractor.extractWindow(keys(downs: (0..<11).map { Double($0) * 500 }, hold: 50), window: window)
        #expect(close(try value(result, "keyboard.hold_median_ms"), 50))
        #expect(close(try value(result, "keyboard.hold_sd_ms"), 0))
        // Holds over 2000 ms are dropped: 11 keys, one held 3000 ms leaves 10 holds and the key stays.
        var samples = keys(downs: (0..<10).map { Double($0) * 500 }, hold: 50)
        samples.append(sample(.keyDown, atMs: 5000))
        samples.append(sample(.keyUp, atMs: 8000))
        let dropped = extractor.extractWindow(samples.sorted { $0.time < $1.time }, window: window)
        #expect(close(try value(dropped, "keyboard.hold_median_ms"), 50))
        let tooFew = extractor.extractWindow(keys(downs: [0, 500], hold: 50) + [sample(.keyUp, atMs: 9000)], window: window)
        #expect(try value(tooFew, "keyboard.hold_median_ms") == nil)
    }

    @Test func pausesAreCountedAndLeftOutOfIkiStatistics() throws {
        // 12 keys: 10 IKIs of 100 ms, then 2500 ms, then 100 ms.
        var times: [Double] = [0]
        for _ in 0..<10 { times.append(times.last! + 100) }
        times.append(times.last! + 2500)
        times.append(times.last! + 100)
        let result = extractor.extractWindow(keys(downs: times), window: window)
        #expect(try value(result, "keyboard.pause_count") == 1)
        #expect(close(try value(result, "keyboard.iki_mean_ms"), 100))
        #expect(close(try value(result, "keyboard.typing_s"), 1.1))
    }

    @Test func fewerThanTenIkisLeavesStatisticsAbsent() throws {
        let result = extractor.extractWindow(keys(downs: (0..<10).map { Double($0) * 200 }), window: window) // 9 IKIs
        #expect(try value(result, "keyboard.key_count") == 10)
        #expect(try value(result, "keyboard.iki_mean_ms") == nil)
        #expect(try value(result, "keyboard.iki_median_ms") == nil)
        #expect(try value(result, "keyboard.iki_sd_ms") == nil)
        #expect(try value(result, "keyboard.iki_iqr_ms") == nil)
        #expect(try value(result, "keyboard.typing_s") != nil)
    }

    @Test func noKeysGivesKeyCountZero() throws {
        let result = extractor.extractWindow([], window: window)
        #expect(try value(result, "keyboard.key_count") == 0)
        #expect(try value(result, "keyboard.pause_count") == 0)
        #expect(try value(result, "keyboard.iki_median_ms") == nil)
        #expect(try value(result, "keyboard.hold_median_ms") == nil)
    }

    @Test func everyDeclaredWindowFeatureCanAppear() throws {
        let times = (0..<20).map { Double($0) * 150 + (Double($0 % 3) * 10) }
        let result = extractor.extractWindow(keys(downs: times, hold: 80), window: window)
        for feature in extractor.windowFeatures { #expect(result[feature] != nil, "\(feature)") }
    }

    // MARK: day features

    private func keyRow(minute: Int, keys: Double, ikiMedian: Double? = nil, ikiSD: Double? = nil,
                        holdMedian: Double? = nil, day: TellsDay = TellsDay(yyyymmdd: 20261121)) throws -> FeatureRow {
        var values: FeatureVector = [try name("keyboard.key_count"): keys]
        if let ikiMedian { values[try name("keyboard.iki_median_ms")] = ikiMedian }
        if let ikiSD { values[try name("keyboard.iki_sd_ms")] = ikiSD }
        if let holdMedian { values[try name("keyboard.hold_median_ms")] = holdMedian }
        return row(.keyboard, minute: minute, day: day, values: values)
    }

    @Test func dayFeaturesWithTwelveTypingWindows() throws {
        let day = TellsDay(yyyymmdd: 20261121)
        var rows = try (0..<12).map { try keyRow(minute: $0 * 5, keys: 30, ikiMedian: Double(100 + $0 * 10),
                                                 ikiSD: Double($0), holdMedian: 80) }
        rows.append(try keyRow(minute: 100, keys: 5, ikiMedian: 9999))             // not a typing window
        rows.append(try keyRow(minute: 200, keys: 7, day: TellsDay(yyyymmdd: 20261120))) // other day
        let result = extractor.extractDay(rows, day: day)
        #expect(try value(result, "keyboard.day_key_count") == 12 * 30 + 5)
        #expect(try value(result, "keyboard.day_typing_windows") == 12)
        #expect(try value(result, "keyboard.day_iki_median_ms") == 155)   // median of 100...210
        #expect(try value(result, "keyboard.day_iki_sd_ms") == 5.5)
        #expect(try value(result, "keyboard.day_hold_median_ms") == 80)
    }

    @Test func dayMediansAbsentWithElevenTypingWindows() throws {
        let rows = try (0..<11).map { try keyRow(minute: $0 * 5, keys: 20, ikiMedian: 100, ikiSD: 10, holdMedian: 80) }
        let result = extractor.extractDay(rows, day: TellsDay(yyyymmdd: 20261121))
        #expect(try value(result, "keyboard.day_typing_windows") == 11)
        #expect(try value(result, "keyboard.day_iki_median_ms") == nil)
        #expect(try value(result, "keyboard.day_iki_sd_ms") == nil)
        #expect(try value(result, "keyboard.day_hold_median_ms") == nil)
    }

    @Test func dayWithNoRowsIsEmpty() {
        #expect(extractor.extractDay([], day: TellsDay(yyyymmdd: 20261121)).isEmpty)
    }
}
