import Foundation
import Testing
@testable import TellsCore

@Suite("FeatureName")
struct FeatureNameTests {
    @Test(arguments: ["keyboard.iki_median_ms", "appswitch.day_switch_rate_h", "activity.input_s", "keyboard.key_count2"])
    func acceptsTheCorrectForm(_ text: String) {
        #expect(FeatureName(text)?.rawValue == text)
    }

    @Test(arguments: [
        "", "keyboard", "keyboard.", ".key_count", "Keyboard.key_count", "keyboard.Key_count",
        "keyboard.keyCount", "keyboard.key__count", "keyboard._key", "keyboard.key_", "keyboard.2key",
        "keyboard.key count", "keyboard.key-count", "keyboard.key_count.extra", "mouse.key_count",
    ])
    func rejectsAWrongForm(_ text: String) {
        #expect(FeatureName(text) == nil)
    }

    @Test func decodingRejectsAWrongForm() throws {
        let good = try JSONDecoder().decode([FeatureName].self, from: Data(#"["keyboard.key_count"]"#.utf8))
        #expect(good.map(\.rawValue) == ["keyboard.key_count"])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([FeatureName].self, from: Data(#"["Keyboard.KeyCount"]"#.utf8))
        }
    }

    @Test func encodesAsAPlainString() throws {
        let data = try JSONEncoder().encode([try name("activity.input_min")])
        #expect(String(decoding: data, as: UTF8.self) == #"["activity.input_min"]"#)
    }
}

@Suite("TellsDay")
struct TellsDayTests {
    @Test func addsCalendarDays() {
        #expect(TellsDay(yyyymmdd: 20261121).adding(days: -30) == TellsDay(yyyymmdd: 20261022))
        #expect(TellsDay(yyyymmdd: 20260101).adding(days: -1) == TellsDay(yyyymmdd: 20251231))
        #expect(TellsDay(yyyymmdd: 20280228).adding(days: 1) == TellsDay(yyyymmdd: 20280229))
    }

    @Test func ordersByDate() {
        #expect(TellsDay(yyyymmdd: 20251231) < TellsDay(yyyymmdd: 20260101))
    }
}
