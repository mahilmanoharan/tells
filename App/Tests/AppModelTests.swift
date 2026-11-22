import Testing
@testable import Tells

@MainActor
struct AppModelTests {
    @Test func appModelCanBeMadeOnTheMainActor() {
        let model = AppModel()
        #expect(model === model)
    }
}
