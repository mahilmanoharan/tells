import Foundation
import MacSensors
import Testing
import TellsCore
@testable import Tells

@MainActor
struct OnboardingTests {
    private final class FakePermissions: PermissionChecking, @unchecked Sendable {
        var statuses: [PermissionKind: PermissionStatus] = [:]
        var requested: [PermissionKind] = []
        func status(of kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .notAsked }
        func request(_ kind: PermissionKind) { requested.append(kind) }
    }

    private final class FakeStore: FirstStartStore {
        var onboardingShown = false
    }

    private func makeModel(
        _ permissions: FakePermissions = FakePermissions(),
        store: FakeStore = FakeStore(),
        registered: [PermissionKind] = [.inputMonitoring]
    ) -> AppModel {
        AppModel(permissions: permissions, firstStartStore: store, registeredPermissions: registered)
    }

    @Test func onboardingShowsOnFirstStartOnly() {
        let store = FakeStore()
        var shown = 0
        let first = makeModel(store: store)
        first.onShowOnboarding = { shown += 1 }
        first.showOnboardingIfFirstStart()
        #expect(shown == 1)
        let second = makeModel(store: store)
        second.onShowOnboarding = { shown += 1 }
        second.showOnboardingIfFirstStart()
        #expect(shown == 1)
    }

    @Test func menuItemShowsOnboardingAgain() {
        let store = FakeStore()
        store.onboardingShown = true
        var shown = 0
        let model = makeModel(store: store)
        model.onShowOnboarding = { shown += 1 }
        model.showOnboarding()
        #expect(shown == 1)
    }

    @Test func noRequestBeforeTheButtonAction() {
        let permissions = FakePermissions()
        let model = makeModel(permissions)
        model.showOnboardingIfFirstStart()
        model.refreshPermissions()
        #expect(permissions.requested.isEmpty)
        model.performAction(for: .inputMonitoring)
        #expect(permissions.requested == [.inputMonitoring])
    }

    @Test func requestRefreshesStatus() {
        let permissions = FakePermissions()
        let model = makeModel(permissions)
        #expect(model.keyboardAvailability == .permissionNotAsked(.inputMonitoring))
        permissions.statuses[.inputMonitoring] = .granted
        model.requestPermission(.inputMonitoring)
        #expect(model.keyboardAvailability == .available)
    }

    @Test func deniedGivesPermissionDeniedAndAppStaysUsable() {
        let permissions = FakePermissions()
        permissions.statuses[.inputMonitoring] = .denied
        let model = makeModel(permissions)
        #expect(model.keyboardAvailability == .permissionDenied(.inputMonitoring))
        model.toggleCompanion()
        #expect(!model.isCompanionVisible)
        model.pauseUntilResumed()
        #expect(model.isPaused)
    }

    @Test func deniedButtonOpensSettingsAndDoesNotRequest() {
        let permissions = FakePermissions()
        permissions.statuses[.inputMonitoring] = .denied
        let model = makeModel(permissions)
        var opened: [URL] = []
        model.openSettings = { opened.append($0) }
        model.performAction(for: .inputMonitoring)
        #expect(opened == [PermissionInfo.settingsURL(for: .inputMonitoring)])
        #expect(permissions.requested.isEmpty)
    }

    @Test func rowsShowOnlyRegisteredPermissions() {
        #expect(makeModel().permissionRows.map(\.kind) == [.inputMonitoring])
        let all = makeModel(registered: PermissionKind.allCases)
        #expect(all.permissionRows.map(\.kind) == [.inputMonitoring, .microphone, .bluetooth])
    }

    @Test func rowButtonsAndStatusText() {
        let permissions = FakePermissions()
        let model = makeModel(permissions)
        #expect(model.permissionRows[0].statusText == "Not asked")
        #expect(model.permissionRows[0].buttonTitle == "Allow…")
        permissions.statuses[.inputMonitoring] = .denied
        model.refreshPermissions()
        #expect(model.permissionRows[0].statusText == "Denied")
        #expect(model.permissionRows[0].buttonTitle == "Open System Settings")
        permissions.statuses[.inputMonitoring] = .granted
        model.refreshPermissions()
        #expect(model.permissionRows[0].statusText == "Granted")
        #expect(model.permissionRows[0].buttonTitle == nil)
    }

    @Test func sentencesAndURLsMatchSpec() {
        let expected: [PermissionKind: (String, String)] = [
            .inputMonitoring: ("Tells records only the times of your key presses, never which keys you press, to learn your typing rhythm.", "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
            .microphone: ("Tells listens for voices and laughter near you, and it deletes each sound sample at once without a recording.", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
            .bluetooth: ("Tells counts the Bluetooth devices near your Mac, and it does not keep their names or IDs.", "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"),
        ]
        for row in makeModel(registered: PermissionKind.allCases).permissionRows {
            #expect(row.sentence == expected[row.kind]?.0)
            #expect(row.settingsURL.absoluteString == expected[row.kind]?.1)
        }
        #expect(PermissionInfo.sharedSentence == "Tells also records when you use your Mac and which type of app is in front, never the app name.")
    }

    @Test func sentencesAreShortAndHaveNoMedicalWords() {
        let medical = ["health", "medical", "diagnos", "depress", "anxiety", "disorder", "therapy", "treat", "cure", "illness", "disease", "symptom", "clinical"]
        let sentences = PermissionKind.allCases.map(PermissionInfo.sentence(for:)) + [PermissionInfo.sharedSentence]
        for sentence in sentences {
            #expect(sentence.split(separator: " ").count <= 25)
            for word in medical {
                #expect(!sentence.lowercased().contains(word))
            }
        }
    }
}
