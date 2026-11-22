import AppKit
import Foundation
import Synchronization

/// One app activation as the sensor sees it. It holds the category text, the process number and a Tells flag.
/// It holds no bundle ID, no app name and no window title (hard rule 3).
struct AppActivation: Sendable, Equatable {
    let categoryType: String?
    let processID: Int32
    let isTells: Bool
}

protocol AppActivationSource: Sendable {
    func start(handler: @escaping @Sendable (AppActivation) -> Void)
    func stop()
    /// The app in front now, or nil if there is none.
    func frontmost() -> AppActivation?
}

/// Public API: `NSWorkspace.didActivateApplicationNotification`. It needs no permission.
/// The bundle of the app is read here only to get `LSApplicationCategoryType`. Nothing else is read from it.
final class SystemAppActivationSource: AppActivationSource {
    private struct Observer: @unchecked Sendable { let token: any NSObjectProtocol }

    private let observer = Mutex<Observer?>(nil)

    func start(handler: @escaping @Sendable (AppActivation) -> Void) {
        stop()
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            handler(Self.activation(of: app))
        }
        observer.withLock { $0 = Observer(token: token) }
    }

    func stop() {
        let old = observer.withLock { current -> Observer? in
            defer { current = nil }
            return current
        }
        if let old { NSWorkspace.shared.notificationCenter.removeObserver(old.token) }
    }

    func frontmost() -> AppActivation? {
        NSWorkspace.shared.frontmostApplication.map(Self.activation)
    }

    private static func activation(of app: NSRunningApplication) -> AppActivation {
        AppActivation(categoryType: categoryType(of: app),
                      processID: app.processIdentifier,
                      isTells: app.processIdentifier == ProcessInfo.processInfo.processIdentifier)
    }

    private static func categoryType(of app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
    }
}
