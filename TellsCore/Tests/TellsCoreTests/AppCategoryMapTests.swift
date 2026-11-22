import Testing
@testable import TellsCore

struct AppCategoryMapTests {
    private func category(_ suffix: String) -> AppCategory {
        AppCategoryMap.category(for: "public.app-category." + suffix)
    }

    @Test func productivityValues() {
        for value in ["business", "productivity", "finance", "reference", "education", "utilities"] {
            #expect(category(value) == .productivity, "\(value)")
        }
    }

    @Test func developerValues() {
        for value in ["developer-tools", "graphics-design"] { #expect(category(value) == .developer, "\(value)") }
    }

    @Test func socialValue() { #expect(category("social-networking") == .social) }

    @Test func entertainmentValues() {
        let values = ["entertainment", "games", "music", "video", "photography", "sports", "news", "lifestyle",
                      "travel", "weather", "action-games", "role-playing-games"]
        for value in values { #expect(category(value) == .entertainment, "\(value)") }
    }

    @Test func otherForUnknownAndNil() {
        #expect(category("medical") == .other)
        #expect(category("healthcare-fitness") == .other)
        #expect(AppCategoryMap.category(for: "something.else") == .other)
        #expect(AppCategoryMap.category(for: "-games") == .other)
        #expect(AppCategoryMap.category(for: nil) == .other)
    }
}
