import CompanionUI
import MacSensors
import SwiftUI
import TellsCore

@main
struct TellsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
