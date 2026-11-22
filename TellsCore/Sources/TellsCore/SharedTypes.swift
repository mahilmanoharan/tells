import Foundation

public enum SensorID: String, Sendable, CaseIterable, Codable {
    case keyboard, activity, appswitch          // Phase 2
    case sound, light, trackpad, motion, crowd  // Phase 5
}

public enum PermissionKind: String, Sendable, CaseIterable {
    case inputMonitoring, microphone, bluetooth
}

public enum PermissionStatus: Sendable, Equatable { case granted, denied, notAsked }

public enum SensorAvailability: Sendable, Equatable {
    case available
    case permissionDenied(PermissionKind)
    case permissionNotAsked(PermissionKind)
    case notOnThisMac
    case disabledByFlag
}

/// One raw event. It has no String field and no key code field (hard rules 2 and 3).
public struct SensorSample: Sendable, Equatable {
    public let sensor: SensorID
    public let time: Date
    public let kind: SampleKind
    public let value: Double      // meaning depends on kind; 0 if not used

    public init(sensor: SensorID, time: Date, kind: SampleKind, value: Double = 0) {
        self.sensor = sensor
        self.time = time
        self.kind = kind
        self.value = value
    }
}

public enum SampleKind: UInt8, Sendable {
    case keyDown, keyUp                 // keyboard: value 0
    case inputProbe                     // activity: value = seconds since last input
    case appActivated                   // appswitch: value = AppCategory.rawValue
    case appFrontmost                   // appswitch: the app already in front, not a switch; value = AppCategory.rawValue
    case systemSleep, systemWake        // activity: value 0
}

public enum AppCategory: Int, Sendable, CaseIterable {
    case other = 0, productivity, developer, social, entertainment
}

/// A feature name in the form <sensor>.<feature>, lower snake case.
public struct FeatureName: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// nil if the form is wrong.
    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard Self.isValid(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Feature name has the wrong form")
            )
        }
        rawValue = text
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    // DEFAULT: D-052
    private static func isValid(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, SensorID(rawValue: String(parts[0])) != nil else { return false }
        return isLowerSnakeCase(parts[1])
    }

    private static func isLowerSnakeCase(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLowercase else { return false }
        guard text.last != "_", !text.contains("__") else { return false }
        return text.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLowercase || $0.isNumber)) }
    }
}

public typealias FeatureVector = [FeatureName: Double]   // an absent key = a missing value (DEC-8)

/// The local calendar day, for example 20261121.
public struct TellsDay: Hashable, Comparable, Sendable, Codable {
    public let yyyymmdd: Int

    public init(yyyymmdd: Int) {
        self.yyyymmdd = yyyymmdd
    }

    /// The calendar day of `date` in the time zone of `calendar`.
    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        yyyymmdd = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// The day that is `count` calendar days after this day. A negative `count` goes back.
    public func adding(days count: Int) -> TellsDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = DateComponents(year: yyyymmdd / 10_000, month: yyyymmdd / 100 % 100, day: yyyymmdd % 100)
        guard let start = calendar.date(from: parts),
              let moved = calendar.date(byAdding: .day, value: count, to: start) else { return self }
        return TellsDay(moved, calendar: calendar)
    }

    public static func < (lhs: TellsDay, rhs: TellsDay) -> Bool { lhs.yyyymmdd < rhs.yyyymmdd }
}
