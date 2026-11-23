import AppKit
import Testing
import TellsCore
@testable import Tells

@MainActor
struct MenuBarControllerTests {
    private func controller(_ model: AppModel = AppModel()) -> (MenuBarController, AppModel) {
        (MenuBarController(model: model, installStatusItem: false), model)
    }

    @Test func defaultMenuHasAllItems() {
        let (menu, _) = controller()
        #expect(menu.itemTitles == [
            "Hide Companion", "Check in", "Pause Tells", "Permissions…",
            "Export CSV for Gate…", "Delete All Data…", "-", "Quit Tells",
        ])
        #expect(menu.item(titled: "Pause Tells")?.submenu?.items.map(\.title) == ["For 1 Hour", "Until Tomorrow", "Until Resumed"])
    }

    @Test func companionTitleFollowsVisibility() {
        let (menu, model) = controller()
        model.isCompanionVisible = false
        menu.rebuild()
        #expect(menu.itemTitles.first == "Show Companion")
    }

    @Test func storeNilDisablesCheckInAndExport() {
        let (menu, _) = controller()
        #expect(menu.item(titled: "Check in")?.isEnabled == false)
        #expect(menu.item(titled: "Export CSV for Gate…")?.isEnabled == false)
        #expect(menu.item(titled: "Delete All Data…")?.isEnabled == true)
    }

    @Test func storeSetEnablesCheckInAndExport() {
        let model = AppModel()
        model.store = InMemoryFeatureStore()
        let (menu, _) = controller(model)
        #expect(menu.item(titled: "Check in")?.isEnabled == true)
        #expect(menu.item(titled: "Export CSV for Gate…")?.isEnabled == true)
    }

    @Test func pausedMenuShowsResume() {
        let (menu, model) = controller()
        model.pauseUntilResumed()
        menu.rebuild()
        #expect(menu.itemTitles.contains("Resume Tells"))
        model.resume()
        menu.rebuild()
        #expect(!menu.itemTitles.contains("Resume Tells"))
    }

    @Test func startupFailureShowsDisabledLineAndSeparator() {
        let model = AppModel()
        model.startupFailure = "Tells could not open its store: x"
        let (menu, _) = controller(model)
        let line = menu.item(titled: "Tells could not open its store: x")
        #expect(line?.isEnabled == false)
        #expect(menu.itemTitles[1] == "Tells could not open its store: x")
        #expect(menu.itemTitles[2] == "-")
    }

    @Test func itemActionCallsModel() {
        let (menu, model) = controller()
        let item = menu.item(titled: "Hide Companion")
        _ = item?.target?.perform(item?.action)
        #expect(model.isCompanionVisible == false)
    }
}
