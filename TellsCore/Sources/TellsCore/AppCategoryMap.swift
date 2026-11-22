import Foundation

/// The map from an `LSApplicationCategoryType` value to an `AppCategory` (SPEC.md 3.4).
/// It reads only the category text. No app name and no bundle ID go through it (hard rule 3).
public enum AppCategoryMap {
    private static let prefix = "public.app-category."

    private static let productivity: Set<String> = [
        "business", "productivity", "finance", "reference", "education", "utilities",
    ]
    private static let developer: Set<String> = ["developer-tools", "graphics-design"]
    private static let social: Set<String> = ["social-networking"]
    private static let entertainment: Set<String> = [
        "entertainment", "games", "music", "video", "photography", "sports", "news", "lifestyle", "travel", "weather",
    ]

    /// `other` for a value that is not in the table and for no value.
    public static func category(for value: String?) -> AppCategory {
        guard let value, value.hasPrefix(prefix) else { return .other }
        let name = String(value.dropFirst(prefix.count))
        if productivity.contains(name) { return .productivity }
        if developer.contains(name) { return .developer }
        if social.contains(name) { return .social }
        if entertainment.contains(name) || name.hasSuffix("-games") { return .entertainment }
        return .other
    }
}
