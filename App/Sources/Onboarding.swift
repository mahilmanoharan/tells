import Foundation
import TellsCore

/// The onboarding text and Settings links. One place (SPEC.md 7).
enum PermissionInfo {
    static let sharedSentence = "Tells also records when you use your Mac and which type of app is in front, never the app name." // D-044

    static func sentence(for kind: PermissionKind) -> String {
        switch kind {
        case .inputMonitoring:
            "Tells records only the times of your key presses, never which keys you press, to learn your typing rhythm."
        case .microphone:
            "Tells listens for voices and laughter near you, and it deletes each sound sample at once without a recording."
        case .bluetooth:
            "Tells counts the Bluetooth devices near your Mac, and it does not keep their names or IDs."
        }
    }

    static func settingsURL(for kind: PermissionKind) -> URL {
        let pane = switch kind {
        case .inputMonitoring: "Privacy_ListenEvent"
        case .microphone: "Privacy_Microphone"
        case .bluetooth: "Privacy_Bluetooth"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") ?? URL(fileURLWithPath: "/")
    }
}

/// One row of the onboarding screen.
struct PermissionRow: Equatable, Identifiable {
    let kind: PermissionKind
    let sentence: String
    let status: PermissionStatus
    let settingsURL: URL

    var id: PermissionKind { kind }

    var statusText: String {
        switch status {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notAsked: "Not asked"
        }
    }

    var buttonTitle: String? {
        switch status {
        case .granted: nil
        case .denied: "Open System Settings"
        case .notAsked: "Allow…"
        }
    }
}

/// Remembers that the onboarding screen was shown.
protocol FirstStartStore: AnyObject {
    var onboardingShown: Bool { get set }
}

// DEFAULT: D-059
final class UserDefaultsFirstStartStore: FirstStartStore {
    private let defaults: UserDefaults
    private let key = "onboardingShown"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var onboardingShown: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
