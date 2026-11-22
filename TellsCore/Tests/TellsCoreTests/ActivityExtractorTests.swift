import Foundation
import Testing
@testable import TellsCore

struct ActivityExtractorTests {
    private let extractor = ActivityExtractor()
    private let dayD = TellsDay(yyyymmdd: 20261121)
    private let start = Date(timeIntervalSince1970: 1_795_000_000)
    private var window: DateInterval { DateInterval(start: start, duration: 300) }

    private var midnight: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 21))!
    }

    private func probe(atS seconds: Double, since: Double) -> SensorSample {
        SensorSample(sensor: .activity, time: start.addingTimeInterval(seconds), kind: .inputProbe, value: since)
    }

    private func value(_ vector: FeatureVector, _ text: String) throws -> Double? { vector[try name(text)] }

    // MARK: window

    @Test func windowKnownAnswers() throws {
        // Input at 20 s (probes 20.5, 21.5) and at 100 s (probe 100.4). No other input.
        let samples = [probe(atS: 20.5, since: 0.5), probe(atS: 21.5, since: 1.5),
                       probe(atS: 100.4, since: 0.4), probe(atS: 101.4, since: 1.4)]
        let result = extractor.extractWindow(samples, window: window)
        #expect(try value(result, "activity.input_s") == 2)
        #expect(abs(try #require(try value(result, "activity.leading_idle_s")) - 20) < 1e-6)
        #expect(abs(try #require(try value(result, "activity.trailing_idle_s")) - 200) < 1e-6)
        #expect(abs(try #require(try value(result, "activity.longest_idle_s")) - 200) < 1e-6)
    }

    @Test func windowWithNoInputIsFullyIdle() throws {
        let result = extractor.extractWindow([probe(atS: 10, since: 4000)], window: window)
        #expect(try value(result, "activity.input_s") == 0)
        #expect(try value(result, "activity.leading_idle_s") == 300)
        #expect(try value(result, "activity.trailing_idle_s") == 300)
        #expect(try value(result, "activity.longest_idle_s") == 300)
    }

    @Test func partialWindowKnownAnswers() throws {
        // 120 s window. Input at 20 s and at 100 s. Leading 20, trailing 120 - 100 = 20, longest gap 80 s.
        let partial = DateInterval(start: start, duration: 120)
        let samples = [probe(atS: 20.5, since: 0.5), probe(atS: 100.4, since: 0.4)]
        let result = extractor.extractWindow(samples, window: partial)
        #expect(try value(result, "activity.input_s") == 2)
        #expect(abs(try #require(try value(result, "activity.leading_idle_s")) - 20) < 1e-6)
        #expect(abs(try #require(try value(result, "activity.trailing_idle_s")) - 20) < 1e-6)
        #expect(abs(try #require(try value(result, "activity.longest_idle_s")) - 80) < 1e-6)
    }

    @Test func partialWindowWithNoInputIsIdleForItsLength() throws {
        let partial = DateInterval(start: start, duration: 120)
        let result = extractor.extractWindow([probe(atS: 10, since: 4000)], window: partial)
        #expect(try value(result, "activity.input_s") == 0)
        #expect(try value(result, "activity.leading_idle_s") == 120)
        #expect(try value(result, "activity.trailing_idle_s") == 120)
        #expect(try value(result, "activity.longest_idle_s") == 120)
    }

    @Test func longestIdleCanBeInTheMiddle() throws {
        let samples = [probe(atS: 10.5, since: 0.5), probe(atS: 250.5, since: 0.5)]
        let result = extractor.extractWindow(samples, window: window)
        #expect(try value(result, "activity.longest_idle_s") == 240)
    }

    // MARK: day

    /// A window row at `minute` after 00:00 of day D (negative = day D-1). `input` is the first and last input
    /// in seconds from the window start; nil = a full idle window.
    private func activityRow(_ minute: Double, first: Double? = nil, last: Double? = nil,
                             inputS: Double? = nil, offset: Int = 0) -> FeatureRow {
        let startDate = midnight.addingTimeInterval(minute * 60 - Double(offset) * 60)   // `minute` is local time
        let values: FeatureVector
        if let first, let last {
            values = [try! name("activity.input_s"): inputS ?? 10,
                      try! name("activity.leading_idle_s"): first,
                      try! name("activity.trailing_idle_s"): 300 - last,
                      try! name("activity.longest_idle_s"): 100]
        } else {
            values = [try! name("activity.input_s"): 0, try! name("activity.leading_idle_s"): 300,
                      try! name("activity.trailing_idle_s"): 300, try! name("activity.longest_idle_s"): 300]
        }
        return FeatureRow(sensor: .activity, schemaVersion: 1, windowStart: startDate, utcOffsetMinutes: offset,
                          day: TellsDay(startDate.addingTimeInterval(Double(offset) * 60), calendar: utcCalendar), coverageSeconds: 300, values: values)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func nightAcrossMidnightGivesTheSleepGap() throws {
        let rows = [
            activityRow(-30, first: 10, last: 290),     // last input 23:55 on D-1 = -5 min + ... see below
            activityRow(435, first: 60, last: 120),     // 07:15 on D, first input 07:16
            activityRow(450, first: 0, last: 300),
        ]
        let result = extractor.extractDay(rows, day: dayD)
        // Window -30: last input at -30 + 290/60 = -25.1667 min. Next input at 435 + 1 = 436 min.
        let start = try #require(try value(result, "activity.sleep_start_min"))
        let end = try #require(try value(result, "activity.sleep_end_min"))
        let gap = try #require(try value(result, "activity.sleep_gap_min"))
        #expect(abs(start - (-30 + 290.0 / 60)) < 1e-6)
        #expect(abs(end - 436) < 1e-6)
        #expect(abs(gap - (end - start)) < 1e-6)
        #expect(start < 0)
    }

    @Test func gapAcrossWindowBoundaryIsJoined() throws {
        // 05:50 window: last input at 250 s (trailing 50). 05:55 window: full idle.
        // 06:00 window: first input at 200 s (leading 200). Gap = 50 + 300 + 200 = 550 s.
        // Then 30 s of trailing + 30 s of leading across 06:05 / 06:10 = no break.
        let rows = [
            activityRow(600, first: 0, last: 250),
            activityRow(605),
            activityRow(610, first: 200, last: 270),
            activityRow(615, first: 30, last: 100),
        ]
        let result = extractor.extractDay(rows, day: dayD)
        // Gap 600+250/60 .. 610+200/60 = 550 s: a break. 270 -> 330 s (next window leading 30): 60 s, no break.
        #expect(try value(result, "activity.break_count") == 1)
        // Stretch 1: 0..250 s (250/60 min). Stretch 2: 610 + 200/60 .. 615 + 100/60 = 5 min - 100/60 + ... 
        let stretch = try #require(try value(result, "activity.longest_stretch_min"))
        let second = (615.0 + 100.0 / 60) - (610.0 + 200.0 / 60)
        #expect(abs(stretch - max(second, 250.0 / 60)) < 1e-6)
        #expect(try value(result, "activity.first_input_min") == 600)
        #expect(abs(try #require(try value(result, "activity.last_input_min")) - (615 + 100.0 / 60)) < 1e-6)
    }

    @Test func noSleepGapLeavesSleepKeysAbsent() throws {
        // Gaps of about 2.4 hours only: below 180 min.
        let rows = [activityRow(-60, first: 0, last: 300), activityRow(90, first: 0, last: 300),
                    activityRow(240, first: 0, last: 300), activityRow(390, first: 0, last: 300)]
        let result = extractor.extractDay(rows, day: dayD)
        #expect(try value(result, "activity.sleep_start_min") == nil)
        #expect(try value(result, "activity.sleep_end_min") == nil)
        #expect(try value(result, "activity.sleep_gap_min") == nil)
        #expect(try value(result, "activity.input_min") != nil)
    }

    @Test func sleepGapMustStartInTheNightRangeAndIsOpenEnded() throws {
        // A 4 h gap that starts at 12:00 is not a sleep gap. An open gap with no later input is not one either.
        let rows = [activityRow(720, first: 0, last: 300), activityRow(960, first: 0, last: 300),
                    activityRow(1300, first: 0, last: 300)]
        let result = extractor.extractDay(rows, day: dayD)
        #expect(try value(result, "activity.sleep_gap_min") == nil)
    }

    @Test func lowActivityDay() throws {
        // 5 windows with 60 input seconds each = 5 min of input.
        let rows = (0..<5).map { activityRow(600 + Double($0) * 5, first: 0, last: 300, inputS: 60) }
        let result = extractor.extractDay(rows, day: dayD)
        #expect(abs(try #require(try value(result, "activity.input_min")) - 5) < 1e-9)
        #expect(try value(result, "activity.low_activity") == 1)
        #expect(abs(try #require(try value(result, "activity.coverage_min")) - 25) < 1e-9)
        let busy = (0..<13).map { activityRow(600 + Double($0) * 5, first: 0, last: 300, inputS: 300) }
        let busyResult = extractor.extractDay(busy, day: dayD)
        #expect(abs(try #require(try value(busyResult, "activity.input_min")) - 65) < 1e-9)
        #expect(try value(busyResult, "activity.low_activity") == 0)
    }

    @Test func lateInputCountsFrom22OnPreviousDayTo04() throws {
        let rows = [activityRow(-150, first: 0, last: 300, inputS: 60),   // 21:30, outside
                    activityRow(-120, first: 0, last: 300, inputS: 120),  // 22:00, inside
                    activityRow(60, first: 0, last: 300, inputS: 180),    // 01:00, inside
                    activityRow(240, first: 0, last: 300, inputS: 600),   // 04:00, outside
                    activityRow(600, first: 0, last: 300, inputS: 60)]
        let result = extractor.extractDay(rows, day: dayD)
        #expect(abs(try #require(try value(result, "activity.late_input_min")) - 5) < 1e-9)
    }

    @Test func breaksCountGapsFiveToSixtyMinutes() throws {
        // Gaps: 10 min (break), 90 min (no break, but splits the stretch), 2 min (no break).
        let rows = [activityRow(600, first: 0, last: 300),   // input to 605
                    activityRow(615, first: 0, last: 300),   // gap 10 min; input to 620
                    activityRow(710, first: 0, last: 300),   // gap 90 min; input to 715
                    activityRow(717, first: 0, last: 300)]   // gap 2 min; input to 722
        let result = extractor.extractDay(rows, day: dayD)
        #expect(try value(result, "activity.break_count") == 1)
        #expect(abs(try #require(try value(result, "activity.longest_stretch_min")) - 12) < 1e-9)  // 710 to 722
    }

    @Test func noRowOnTheDayGivesAnEmptyVector() {
        #expect(extractor.extractDay([], day: dayD).isEmpty)
        #expect(extractor.extractDay([activityRow(-100, first: 0, last: 300)], day: dayD).isEmpty)
    }

    @Test func declaresOnlyActivityNames() {
        #expect(extractor.windowFeatures.count == 4)
        #expect(extractor.dayFeatures.count == 11)
        #expect((extractor.windowFeatures + extractor.dayFeatures).allSatisfy { $0.rawValue.hasPrefix("activity.") })
    }

    // MARK: edges (each one fails under a one-line change of a formula)

    @Test func lowActivityEdgeIsExactly60Minutes() throws {
        for (minutes, expected) in [(59.0, 1.0), (60.0, 0.0), (61.0, 0.0)] {
            let result = extractor.extractDay([activityRow(600, first: 0, last: 300, inputS: minutes * 60)], day: dayD)
            #expect(try value(result, "activity.low_activity") == expected)
        }
    }

    @Test func inputSecondsCountOnlyProbesUnderOneSecond() throws {
        let samples = [probe(atS: 10, since: 1.0), probe(atS: 11, since: 0.99)]
        #expect(try value(extractor.extractWindow(samples, window: window), "activity.input_s") == 1)
    }

    @Test func duplicateProbesOfOneInputChangeNothing() throws {
        let one = extractor.extractWindow([probe(atS: 20.5, since: 0.5)], window: window)
        let many = extractor.extractWindow((0..<5).map { probe(atS: 20.5 + Double($0), since: 0.5 + Double($0)) }, window: window)
        #expect(abs(try #require(try value(one, "activity.longest_idle_s")) - 280) < 1e-6)
        #expect(abs(try #require(try value(many, "activity.longest_idle_s")) - 280) < 1e-6)
    }

    @Test func sleepGapOf200MinutesCounts() throws {
        // Input ends at 05:00 (300 min), the next input is at 08:20 (500 min): 200 min.
        let result = extractor.extractDay([activityRow(295, first: 0, last: 300), activityRow(500, first: 0, last: 300)], day: dayD)
        #expect(try value(result, "activity.sleep_gap_min") == 200)
    }

    @Test func sleepGapStartsBetweenMidnightAndSixCounts() throws {
        // Starts at 01:05 (65 min), ends 04:20 (260 min): 195 min.
        let result = extractor.extractDay([activityRow(60, first: 0, last: 300), activityRow(260, first: 0, last: 300)], day: dayD)
        #expect(try value(result, "activity.sleep_start_min") == 65)
        #expect(try value(result, "activity.sleep_gap_min") == 195)
    }

    @Test func sleepGapStartingBefore18OnPreviousDayIsIgnored() throws {
        // A 395 min gap starts at -495 (15:45 on D-1): ignored. The next gap starts at -95 and lasts 195 min.
        let rows = [activityRow(-500, first: 0, last: 300), activityRow(-100, first: 0, last: 300),
                    activityRow(100, first: 0, last: 300)]
        let result = extractor.extractDay(rows, day: dayD)
        #expect(try value(result, "activity.sleep_start_min") == -95)
        #expect(try value(result, "activity.sleep_gap_min") == 195)
    }

    @Test func longestOfTwoSleepGapsWinsInEitherOrder() throws {
        // shortFirst: gaps of 195 and 295 min. longFirst: gaps of 245 and 195 min.
        let shortFirst = [activityRow(-300, first: 0, last: 300), activityRow(-100, first: 0, last: 300),
                          activityRow(200, first: 0, last: 300)]   // -295 to -100 = 195, -95 to 200 = 295
        let longFirst = [activityRow(-350, first: 0, last: 300), activityRow(-100, first: 0, last: 300),
                         activityRow(100, first: 0, last: 300)]
        #expect(try value(extractor.extractDay(shortFirst, day: dayD), "activity.sleep_gap_min") == 295)
        #expect(try value(extractor.extractDay(longFirst, day: dayD), "activity.sleep_gap_min") == 245)
    }

    @Test func lastInputAfterMidnightBefore04Counts() throws {
        let rows = [activityRow(600, first: 0, last: 300), activityRow(1500, first: 0, last: 300)]   // 01:00 on D+1
        let result = extractor.extractDay(rows, day: dayD)
        #expect(try value(result, "activity.last_input_min") == 1505)
    }

    @Test func inputMinuteSumsOnlyRowsOfDayD() throws {
        let rows = [activityRow(-60, first: 0, last: 300, inputS: 600), activityRow(600, first: 0, last: 300, inputS: 120),
                    activityRow(1500, first: 0, last: 300, inputS: 300)]   // day D+1
        let result = extractor.extractDay(rows, day: dayD)
        #expect(try value(result, "activity.input_min") == 2)
        #expect(try value(result, "activity.coverage_min") == 5)
    }

    @Test func nonZeroUtcOffsetMovesTheLocalTime() throws {
        // Local 10:00 with a +120 min offset: the instant is 08:00 UTC. The minute is still 600.
        let result = extractor.extractDay([activityRow(600, first: 60, last: 120, offset: 120)], day: dayD)
        #expect(abs(try #require(try value(result, "activity.first_input_min")) - 601) < 1e-9)
        #expect(abs(try #require(try value(result, "activity.last_input_min")) - 602) < 1e-9)
    }

    @Test func gapOfExactlyOneHourIsABreak() throws {
        let rows = [activityRow(600, first: 0, last: 300), activityRow(665, first: 0, last: 300)]   // 605 to 665
        #expect(try value(extractor.extractDay(rows, day: dayD), "activity.break_count") == 1)
    }

    @Test func partialWindowBeforeAStopJoinsTheGapAtItsRealEnd() throws {
        // Full window at 10:00 (600 min), input at 0 s and 300 s: last input 605.
        // Partial 120 s window at 10:05 (605 min), input at 30 s only: first = last = 605.5, trailing 90 s.
        // Stop at 10:07. No rows for 30 min. Full window at 10:37 (637 min), first input at 0 s: 637.
        // Gap 1: 605 to 605.5 = 0.5 min (no break). Gap 2: 605.5 to 637 = 31.5 min (break).
        // break_count = 1. longest_stretch_min = max(605.5 - 600, 647 - 637) with last input at 642 (300 s window,
        // last input at 5 min): stretch 1 = 605.5 - 600 = 5.5, stretch 2 = 642 - 637 = 5. So 5.5. last_input_min = 642.
        let n = { (text: String) in try! name(text) }
        let full = activityRow(600, first: 0, last: 300)
        let partial = FeatureRow(sensor: .activity, schemaVersion: 1,
                                 windowStart: midnight.addingTimeInterval(605 * 60), utcOffsetMinutes: 0, day: dayD,
                                 coverageSeconds: 120,
                                 values: [n("activity.input_s"): 1, n("activity.leading_idle_s"): 30,
                                          n("activity.trailing_idle_s"): 90, n("activity.longest_idle_s"): 90])
        let later = activityRow(637, first: 0, last: 300)
        let result = extractor.extractDay([full, partial, later], day: dayD)
        #expect(try value(result, "activity.break_count") == 1)
        #expect(abs(try #require(try value(result, "activity.longest_stretch_min")) - 5.5) < 1e-9)
        #expect(abs(try #require(try value(result, "activity.last_input_min")) - 642) < 1e-9)
    }
}
