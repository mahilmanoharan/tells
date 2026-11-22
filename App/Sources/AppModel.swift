import Observation

/// The one app state object. The app makes it one time (SPEC.md 1.3).
@Observable
@MainActor
final class AppModel {}
