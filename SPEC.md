# Tells specification

Task: P0.4. Owner: Architect.
This file gives the technical specification for Phases 1 to 4. It points to `design/` for art, flows and research. Do not copy text from `design/` into this file.

Related files:
- `PLAN.md` Sections 4 and 6: architecture and ML protocol.
- `design/hardware.md`: hardware sources and API labels (public or private).
- `design/companion-concepts.md`: companion art. Concept C (Sprout) is selected (DEC-1).
- `design/experiences.md`: the 7 insight experiences and the radial menu.
- `DECISIONS.md`: one-way decisions (DEC-<n>). `DEFAULTS.md`: two-way defaults (D-<id>).

## 1. Architecture

### 1.1 Targets
The package map in `CLAUDE.md` gives the targets. These rules apply:

- `TellsCore` is pure Swift. It imports only `Foundation`, `SwiftData` and `Observation`. It does not import `AppKit`, `SwiftUI`, `CoreGraphics` or `IOKit`. It builds for macOS 26 and iOS 26.
- `MacSensors` contains the `Sensor` conformers. It can import `AppKit`, `CoreGraphics` and `IOKit`.
- `CompanionUI` contains the companion, the radial menu and the `InsightExperience` plugins. It can import `AppKit`, `SwiftUI`, `SpriteKit`, `AVFoundation` and `Charts`.
- `Tells` (app) contains `AppModel`, `MenuBarExtra`, onboarding and the wiring between the targets.
- Use Swift 6 language mode with strict concurrency in all targets.

### 1.2 Data flow
1. A `Sensor` sends `SensorSample` values through an `AsyncStream`.
2. `SensorHub` (`MacSensors`) reads each stream and puts each sample in `RawEventBuffer` (`TellsCore`, an `actor`).
3. `WindowClock` (`TellsCore`) fires at each 5-minute boundary of local clock time (:00, :05, :10 and so on).
4. For each sensor, `WindowClock` takes the samples of the closed window from `RawEventBuffer`. It sends them to the `FeatureExtractor` of that sensor.
5. The extractor returns a `FeatureVector`. `FeatureStore` saves it as one `FeatureRow`.
6. `RawEventBuffer` deletes the samples of the closed window.
7. At day close (04:00 local time, DEC-3), `DailyFeatureExtractor` values make one `DailyRow` and one `DailySummary` for the closed day.
8. `DriftDetector` reads each new keyboard `FeatureRow`. It gives the drift state to `AppModel`.
9. `ModelProvider` gives predictions to the insight experiences. For a closed day, the input is its `DailyRow`. For today, the input is `TodayFeatures` (Section 2.5, DEC-16).

Only `FeatureRow`, `DailyRow`, `DailySummary` and `CheckIn` values go to disk (hard rule 1).

### 1.3 Threads
- The event tap callback and other system callbacks only stamp the time and yield one `SensorSample` (check 5).
- `RawEventBuffer`, `WindowClock`, `FeatureStore` and `DriftDetector` are actors or run on a background `Task`.
- Only finished values (state, predictions, status) go to `@MainActor` code (check 2).
- `AppModel` is one `@Observable` `@MainActor` class. The app makes it one time. Views read from it (check 3).

### 1.4 Stop and start
`SensorHub` stops all sensors and `WindowClock` on these events. It starts them again after the event ends.

| Event | Source |
| --- | --- |
| Mac sleep | `NSWorkspace.willSleepNotification`, `didWakeNotification` |
| Lid close (D-045) | Mac sleep, or the IOKit `IOPMrootDomain` property `AppleClamshellState` changes to true (interest message `kIOPMMessageClamshellStateChange`, public `IOKit/pwr_mgt` headers). The sensors also stop in clamshell mode with an external display. |
| Display sleep (D-038, D-047) | `NSWorkspace.screensDidSleepNotification`, `screensDidWakeNotification`. Screen lock puts the displays to sleep after the display sleep time. |
| User session not active (D-038, D-047) | `NSWorkspace.sessionDidResignActiveNotification`, `sessionDidBecomeActiveNotification` (fast user switching, login window) |
| User pause | Menu bar "Pause Tells" (D-041) |
| App quit | `NSApplication.willTerminateNotification` |

- When a sensor stops, it finishes its stream. `WindowClock` closes the current window as a partial window.
- Each partial window records its coverage (Section 4.2). A window with less than 60 s of coverage is not saved (D-036).
- Each `Task` that a view starts stops when the view closes (check 8).
- All stop sources are public and documented (design/hardware.md). Tells does not use the undocumented screen lock distributed notifications (D-047, DEC-14).

## 2. Protocols

`TellsCore` defines all protocols except `InsightExperience`. `CompanionUI` defines `InsightExperience` (DEC-11).
The signatures below are the contract for P1.2. The Builder can add helper types. Do not change these signatures without an Architect task.

### 2.1 Shared types (`TellsCore`)

```swift
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
}

public enum SampleKind: UInt8, Sendable {
    case keyDown, keyUp                 // keyboard: value 0
    case inputProbe                     // activity: value = seconds since last input
    case appActivated                   // appswitch: value = AppCategory.rawValue
    case appFrontmost                   // appswitch: app already in front, not a switch (D-066)
    case systemSleep, systemWake        // activity: value 0
}

public enum AppCategory: Int, Sendable, CaseIterable {
    case other = 0, productivity, developer, social, entertainment
}

/// A feature name in the form <sensor>.<feature>, lower snake case.
public struct FeatureName: Hashable, Sendable, Codable {
    public let rawValue: String
    public init?(_ rawValue: String)   // nil if the form is wrong
}

public typealias FeatureVector = [FeatureName: Double]   // an absent key = a missing value (DEC-8)

/// The local calendar day, for example 20261121.
public struct TellsDay: Hashable, Comparable, Sendable, Codable { public let yyyymmdd: Int }
```

Phase 5 tasks add `SampleKind` cases. A new case must not hold text, audio, images or identifiers.

### 2.2 Sensor (`TellsCore`; conformers in `MacSensors`)

```swift
public protocol Sensor: AnyObject, Sendable {
    var id: SensorID { get }
    var permission: PermissionKind? { get }      // nil if no permission is necessary
    var usesPrivateAPI: Bool { get }             // true: needs a feature flag (hard rule 5)
    func availability() async -> SensorAvailability
    func start() throws -> AsyncStream<SensorSample>  // throws if not available
    func stop() async                                  // finishes the stream; safe to call 2 times
}
```

- `start()` does not request a permission. Only the onboarding screen requests permissions, after a user click.
- A sensor with `usesPrivateAPI == true` returns `.disabledByFlag` if its flag is off. Flags are in `UserDefaults` with the key `flag.<sensor>`. All flags are off by default (D-042).

### 2.3 FeatureExtractor (`TellsCore`)

```swift
public protocol FeatureExtractor: Sendable {
    var sensor: SensorID { get }
    var schemaVersion: Int { get }
    var windowFeatures: [FeatureName] { get }
    var dayFeatures: [FeatureName] { get }
    /// Pure function. Samples are in time order and inside `window`.
    func extractWindow(_ samples: [SensorSample], window: DateInterval) -> FeatureVector
    /// Pure function. Rows of this sensor from 18:00 on day-1 to 04:00 on day+1 (DEC-3).
    func extractDay(_ rows: [FeatureRow], day: TellsDay) -> FeatureVector
}
```

- Extractors do not read the clock, the disk or the network. Tests give them synthetic samples (check 6).
- If an extractor changes a formula or a feature name, it increments `schemaVersion` (PLAN.md Section 6).

### 2.4 FeatureStore (`TellsCore`)

```swift
public struct FeatureRow: Sendable, Equatable {
    public let sensor: SensorID
    public let schemaVersion: Int
    public let windowStart: Date          // UTC instant
    public let utcOffsetMinutes: Int      // local offset at windowStart
    public let day: TellsDay              // local calendar day of windowStart
    public let coverageSeconds: Double    // 60...300
    public let values: FeatureVector
}

public struct DailyRow: Sendable, Equatable {        // day features, 30 days
    public let day: TellsDay
    public let schemaVersions: [SensorID: Int]
    public let values: FeatureVector
}

public struct DailySummary: Sendable, Equatable {    // kept until the user deletes it (DEC-6)
    public let day: TellsDay
    public let values: FeatureVector                 // only the names in Section 3.5
}

public enum CheckInItem: String, Sendable, CaseIterable, Codable { case energy, mood, social }

public struct CheckIn: Sendable, Equatable {         // 30 days (DEC-5)
    public let day: TellsDay
    public let savedAt: Date
    public let scores: [CheckInItem: Int]            // each 1...5; an absent item = skipped
}

/// Read-only access. Insight experiences get only this part (Section 2.7, DEC-16).
public protocol FeatureReader: Sendable {
    func featureRows(_ sensor: SensorID?, in interval: DateInterval) async throws -> [FeatureRow]
    func dailyRows(_ days: ClosedRange<TellsDay>) async throws -> [DailyRow]
    func dailySummaries(_ days: ClosedRange<TellsDay>) async throws -> [DailySummary]
    func checkIns(_ days: ClosedRange<TellsDay>) async throws -> [CheckIn]
}

public protocol FeatureStore: FeatureReader {
    func save(_ row: FeatureRow) async throws
    func save(_ row: DailyRow) async throws
    func save(_ summary: DailySummary) async throws
    func save(_ checkIn: CheckIn) async throws       // replaces the check-in of the same day
    func deleteExpired(today: TellsDay) async throws  // Section 4.3
    func deleteAll() async throws
}
```

- `SwiftDataFeatureStore` is the app conformer. `InMemoryFeatureStore` is the test conformer.
- The SwiftData models keep `values` as a JSON-encoded `[String: Double]` attribute (DEC-2).

### 2.5 ModelProvider (`TellsCore`)

```swift
public struct Prediction: Sendable, Equatable {
    public let day: TellsDay
    public let target: CheckInItem
    public let value: Double              // clamped to 1...5
}

public protocol ModelProvider: Sendable {
    var target: CheckInItem { get }
    var featureNames: [FeatureName] { get }   // the features the model uses
    var isMock: Bool { get }                  // true until G3 closes
    var modelVersion: String { get }
    /// nil if `windowCount` is less than 12 (D-027), or if a name in `featureNames` is absent (DEC-8).
    func predict(_ features: FeatureVector, day: TellsDay, windowCount: Int) async -> Prediction?
}

/// The day features of one day, built from the saved `FeatureRow` values of that day (DEC-16).
public struct TodayFeatures: Sendable, Equatable {
    public let day: TellsDay
    public let values: FeatureVector
    public let windowCount: Int           // distinct `windowStart` values of rows with `row.day == day` (D-050)
    /// Pure function. For each extractor, it gives the rows of its sensor to `extractDay`, then merges the vectors.
    public static func build(day: TellsDay, rows: [FeatureRow], extractors: [any FeatureExtractor]) -> TodayFeatures
}
```

- Today's input is `TodayFeatures.build`. The caller reads the rows from 18:00 on day-1 to now with `featureRows(nil, in:)`. Then it calls `predict(t.values, day: t.day, windowCount: t.windowCount)`.
- For a closed day, the caller uses `DailyRow.values` and the count of that day's `FeatureRow` windows. After 30 days, the rows are deleted, so the count is 0 and `predict` returns nil.
- `build` does not read the clock or the disk. Day features that need data after "now" (for example `activity.last_input_min`) show the value so far.

- `MockModelProvider` has `target == .energy` and `isMock == true`. It declares `activity.sleep_start_min` and `activity.late_input_min` (design/experiences.md Section 6). Its prediction is a fixed linear function, so tests know the answer (D-051).
- Experiences only call `predict`. No code outside a gate task changes the model, its features or its target (hard rule 7).

### 2.6 DriftDetector (`TellsCore`)
`DriftDetector` is an `actor`. It is PLAN.md Section 6, Level 1. It needs no labels.

- Input: keyboard `FeatureRow` values. Feature: `keyboard.iki_median_ms` (D-039).
- Baseline: the mean and standard deviation of the log value, for the same local hour plus or minus 1 hour, from the last 14 usable typing days.
- Output for each typing window: a z-score, or nil if the baseline has fewer than 3 usable typing days.
- `DriftState` (`normal` or `drifting`) follows the nudge rule and sensitivity in design/experiences.md Section 9 (D-029).

### 2.7 InsightExperience (`CompanionUI`)

```swift
public enum ExperienceState: Sendable, Equatable {
    case ready
    case practice                                   // MockModelProvider is active
    case notEnoughData(have: Int, need: Int, unit: String)
    case permissionDenied(PermissionKind)
    case notOnThisMac(hardware: String)
}

public struct InsightContext: Sendable {             // read access, and one write: today's check-in
    public let store: any FeatureReader                 // no save, no delete
    public let model: any ModelProvider
    public let today: TellsDay
    public let saveCheckIn: @Sendable (CheckIn) async throws -> Void
    public init(store: any FeatureReader, model: any ModelProvider, today: TellsDay,
                saveCheckIn: @escaping @Sendable (CheckIn) async throws -> Void)
    /// Gives `store` as a `FeatureReader` and sends `saveCheckIn` to `store.save(_:)`.
    public init(store: any FeatureStore, model: any ModelProvider, today: TellsDay)
}

@MainActor
public protocol InsightExperience: AnyObject, Identifiable where ID == String {
    var id: String { get }
    var displayName: String { get }
    var glyph: String { get }        // SF Symbol name
    var menuOrder: Int { get }       // 1...7
    func state(in context: InsightContext) async -> ExperienceState
    func makeView(in context: InsightContext) -> AnyView
    func stop()                      // stops Task work, audio and haptics (check 8)
}
```

- The radial menu reads `id`, `displayName`, `glyph`, `menuOrder` and `state` (design/experiences.md Section 2).
- `InsightContext` gives no write access to the model. It gives no access to `RawEventBuffer`.
- The only write is `saveCheckIn`. "You vs. your Mac" and "What-if sliders" use it to save today's check-in (design/experiences.md Sections 3 and 6). Experiences cannot save rows or delete data (DEC-16).

## 3. Sensors

Each sensor follows the checklist in PLAN.md Section 4.2. `design/hardware.md` gives each API and its label.

### 3.1 Phase 2 sensors

| Sensor | `SensorID` | API (public) | Permission | Sample kinds |
| --- | --- | --- | --- | --- |
| `KeyboardTimingSensor` (P2.1) | `keyboard` | `CGEvent.tapCreate`, `.listenOnly`, key down and key up | Input Monitoring | `keyDown`, `keyUp` |
| `ActivitySensor` (P2.2) | `activity` | `CGEventSource.secondsSinceLastEventType`, polled each 1 s (D-034); `NSWorkspace` sleep and wake | None | `inputProbe`, `systemSleep`, `systemWake` |
| `AppSwitchSensor` (P2.3) | `appswitch` | `NSWorkspace.didActivateApplicationNotification`; `LSApplicationCategoryType` | None | `appActivated` |

Keyboard rules (DEC-12):
- The tap callback reads only the event type, the time and the autorepeat flag. It does not read the key code, the characters or the modifier flags.
- Autorepeat key downs are dropped. `flagsChanged` events are not in the tap mask.
- While the `insights` window is the key window, the sensor drops all key events (D-026).

App rules (DEC-7):
- The sensor reads the bundle of the activated app only in memory, to get its category. It does not put the bundle ID, the app name or a window title in a sample.
- Activations of Tells itself are dropped.
- The category map is in Section 3.4.

### 3.2 Phase 2 window features (each 5-minute window)

Definitions: an IKI (inter-key interval) is the time between two key downs in the window. An IKI over 2000 ms is a pause (D-035). A hold is the time from a key down to its key up. Key ups pair with key downs in first-in, first-out order, because the sensor has no key code (DEC-12). A hold over 2000 ms is dropped.

| Feature | Unit | Definition |
| --- | --- | --- |
| `keyboard.key_count` | count | Key downs (no autorepeat). |
| `keyboard.iki_mean_ms` | ms | Mean of IKIs of 2000 ms or less. |
| `keyboard.iki_median_ms` | ms | Median of the same IKIs. |
| `keyboard.iki_sd_ms` | ms | Sample standard deviation of the same IKIs. |
| `keyboard.iki_iqr_ms` | ms | Interquartile range of the same IKIs. |
| `keyboard.hold_median_ms` | ms | Median hold. |
| `keyboard.hold_sd_ms` | ms | Sample standard deviation of holds. |
| `keyboard.pause_count` | count | IKIs over 2000 ms. |
| `keyboard.typing_s` | s | Sum of IKIs of 2000 ms or less. |
| `activity.input_s` | s | Probe seconds with input in the last 1 s. |
| `activity.leading_idle_s` | s | Seconds from window start to the first input. 300 if no input. |
| `activity.trailing_idle_s` | s | Seconds from the last input to window end. 300 if no input. |
| `activity.longest_idle_s` | s | Longest period with no input in the window. |
| `appswitch.switch_count` | count | Activations of an app that is different from the previous app. |
| `appswitch.category_count` | count | Number of different categories that were frontmost. |
| `appswitch.productivity_s` | s | Seconds with a `productivity` app frontmost. |
| `appswitch.developer_s` | s | Seconds with a `developer` app frontmost. |
| `appswitch.social_s` | s | Seconds with a `social` app frontmost. |
| `appswitch.entertainment_s` | s | Seconds with an `entertainment` app frontmost. |
| `appswitch.other_s` | s | Seconds with an `other` app frontmost. |

- The IKI and hold statistics need 10 or more values in the window. If there are fewer, the key is absent (DEC-8).
- `keyboard.key_count` is 0, not absent, when the sensor ran and no key was pressed.
- A "typing window" has `keyboard.key_count` of 20 or more (D-027).

### 3.3 Phase 2 day features
Day features use the windows of the Tells day and the night before (DEC-3). Times are minutes after 00:00 of day D. A negative value is a time on day D-1.

| Feature | Unit | Definition |
| --- | --- | --- |
| `keyboard.day_key_count` | count | Sum of `keyboard.key_count` on day D. |
| `keyboard.day_typing_windows` | count | Typing windows on day D. |
| `keyboard.day_iki_median_ms` | ms | Median of `keyboard.iki_median_ms` over typing windows. Absent if fewer than 12 typing windows. |
| `keyboard.day_iki_sd_ms` | ms | Median of `keyboard.iki_sd_ms` over typing windows. Same rule. |
| `keyboard.day_hold_median_ms` | ms | Median of `keyboard.hold_median_ms` over typing windows. Same rule. |
| `activity.first_input_min` | min | First input on day D after 04:00. |
| `activity.last_input_min` | min | Last input before 04:00 on day D+1 (up to 1680). |
| `activity.input_min` | min | Sum of `activity.input_s` on day D, divided by 60. |
| `activity.low_activity` | 0 or 1 | 1 if `activity.input_min` is less than 60 (PLAN.md Section 6, rule 6). |
| `activity.break_count` | count | Idle gaps of 5 to 60 minutes between first and last input. |
| `activity.longest_stretch_min` | min | Longest period with no idle gap of 5 minutes or more. |
| `activity.late_input_min` | min | Input minutes from 22:00 on D-1 to 04:00 on D. |
| `activity.sleep_start_min` | min | Start of the longest no-input gap that starts between 18:00 on D-1 and 06:00 on D and is 180 minutes or more. Absent if none. |
| `activity.sleep_end_min` | min | End of that gap. |
| `activity.sleep_gap_min` | min | Length of that gap. |
| `activity.coverage_min` | min | Minutes with a saved `activity` row on day D. |
| `appswitch.day_switch_count` | count | Sum of `appswitch.switch_count` on day D. |
| `appswitch.day_switch_rate_h` | per hour | `appswitch.day_switch_count` divided by `activity.input_min` / 60. Absent if `activity.input_min` is less than 30. |
| `appswitch.day_productivity_min` | min | Sum of `appswitch.productivity_s` / 60. The other 4 categories have the same form: `appswitch.day_<category>_min`. |

- Gaps join across windows with `activity.trailing_idle_s` of one window, full idle windows and `activity.leading_idle_s` of the next window. A period with no saved row counts as no input.
- G1 selects the model features from these names (PLAN.md Section 6). This list is the data, not the model.

### 3.4 App category map (DEC-7)
The map uses the `LSApplicationCategoryType` value. A missing or unknown value is `other`.

| `AppCategory` | `public.app-category.` values |
| --- | --- |
| `productivity` | `business`, `productivity`, `finance`, `reference`, `education`, `utilities` |
| `developer` | `developer-tools`, `graphics-design` |
| `social` | `social-networking` |
| `entertainment` | `entertainment`, `games` and each `*-games` value, `music`, `video`, `photography`, `sports`, `news`, `lifestyle`, `travel`, `weather` |
| `other` | All other values, and no value |

### 3.5 Daily summary names (DEC-6)
`DailySummary` keeps only: `keyboard.day_key_count`, `keyboard.day_iki_median_ms`, `activity.input_min`, `activity.first_input_min`, `activity.last_input_min`, `appswitch.day_switch_count`.

### 3.6 Phase 5 sensors
Phase 5 tasks give the feature names. This table gives only the plan.

| Sensor | `SensorID` | API label | Permission | Flag |
| --- | --- | --- | --- | --- |
| `SoundSceneSensor` | `sound` | Public | Microphone | No |
| `LightSensor` | `light` | Private | None | Yes |
| `TrackpadForceSensor` | `trackpad` | Private | None | Yes |
| `MotionSensor` | `motion` | Private | None | Yes |
| `NearbyCrowdSensor` | `crowd` | Public | Bluetooth | No |

- The lid angle sensor and headphone motion are not in scope (DEC-10).
- Private sensors can need App Sandbox off. Gate GD-1 in `GATES.md` decides this before P5.2.

## 4. Data and retention

### 4.1 What goes to disk

| Data | Store | Kept | Content |
| --- | --- | --- | --- |
| Raw samples | `RawEventBuffer`, memory only | Until their window closes (max. approx. 10 min) | `SensorSample` |
| Feature rows | `FeatureStore` | 30 days | `FeatureRow` |
| Day rows | `FeatureStore` | 30 days | `DailyRow` |
| Check-ins | `FeatureStore` | 30 days | `CheckIn` |
| Daily summaries | `FeatureStore` | Until "Delete all data" | `DailySummary`, no labels |
| Model | `Application Support/Tells/Model/` | Until the next training | Create ML model (after G3) |
| Experience state | `UserDefaults` | See design/experiences.md | Forecast, scores, experiment record, nudge settings. No text. |
| CSV export | A folder that the operator selects | The operator deletes it after the gate | Feature rows, day rows, check-ins |

- The SwiftData store is `Application Support/Tells/Tells.store` in the app container (DEC-9).
- `RawEventBuffer` keeps a maximum of 20,000 samples for each sensor (D-033). It writes over the oldest samples.

### 4.2 Schema (DEC-2)
- One `FeatureRow` for each sensor for each window. Its values are a dictionary of feature names.
- Each extractor has its own `schemaVersion`, starting at 1. A new version starts a new training window (PLAN.md Section 6).
- `coverageSeconds` is the time in the window that the sensor ran. Rows under 60 s are not saved (D-036).

### 4.3 Deletion
- `deleteExpired(today:)` deletes each `FeatureRow`, `DailyRow` and `CheckIn` with a `day` before `today` minus 30 days (DEC-13).
- It runs at app start and at each day close.
- Menu bar "Delete all data" calls `deleteAll()` after one confirmation. It also deletes the model, the experience state and the daily summaries.

### 4.4 CSV export (P2.7)
- The operator starts it from the menu bar. It writes 3 files to a folder that the operator selects with `NSOpenPanel`: `windows.csv`, `days.csv`, `checkins.csv` (D-043).
- Columns: `day`, `window_start` (ISO 8601 with offset), `sensor`, `schema_version`, `coverage_s`, then one column for each feature name. A missing value is an empty cell.
- The export has no bundle IDs, no key data and no text.

## 5. Companion

The selected concept is Sprout (design/companion-concepts.md, Concept C; DEC-1).

- Window: a borderless, transparent, floating `NSPanel` of 96 x 96 pt. It does not take the key focus. It shows on all Spaces.
- Scene: one `SKView` with one SpriteKit scene. Nodes: pot, stem, 2 leaves, flower, marks.
- Click, drag and radial menu: design/companion-concepts.md "Common click interaction" and design/experiences.md Section 2.
- The user can hide the companion from the menu bar. The menu bar icon stays.

| State | Trigger | Priority |
| --- | --- | --- |
| Asleep | Tells is paused, or the Mac sleeps, or the displays sleep, or the user session is not active | 1 (highest) |
| Social | `sound` sensor detects speech or laughter (Phase 5) | 2 |
| Scattered | `appswitch.switch_count` of the last window is 10 or more and over the 90th percentile of the last 14 days (D-037) | 3 |
| Drifting | `DriftDetector` gives `drifting` | 4 |
| Normal | All other times | 5 |

- If two triggers are true, the state with the highest priority shows (D-038).
- Idle animation runs at 30 frames each second at most. In Asleep, the scene is paused (`isPaused = true`) after the transition (D-040). Idle CPU must be less than 2%.
- The companion shows no text and no numbers.

## 6. Insight experiences

design/experiences.md gives the full spec of each experience. This table gives the plugin data for the radial menu.

| `menuOrder` | `id` | `displayName` | Main inputs |
| --- | --- | --- | --- |
| 1 | `youVsMac` | You vs. your Mac | `ModelProvider`, `CheckIn` |
| 2 | `typingSound` | Typing rhythm sound | `keyboard.iki_mean_ms`, `keyboard.iki_sd_ms`, `keyboard.key_count` |
| 3 | `ghostRacer` | Ghost racer | `keyboard.iki_median_ms`, `keyboard.iki_sd_ms` |
| 4 | `whatIf` | What-if sliders | `ModelProvider`, `activity.sleep_start_min`, `activity.late_input_min` |
| 5 | `hapticWeek` | Haptic week | `CheckIn` (last 30 days) |
| 6 | `experiment` | Experiment | `CheckIn`, `activity.last_input_min`, `activity.late_input_min`, `activity.longest_stretch_min`, `appswitch.day_switch_rate_h` |
| 7 | `nudge` | In-the-moment nudge | `DriftDetector` |

- Haptic week uses `CheckIn` values, not `DailySummary` values, because summaries have no labels (DEC-6).
- Experiment "No Mac input after 22:00" uses `activity.late_input_min` of day D+1 for the evening of day D.

## 7. Permissions

The onboarding screen (P1.4) shows one row for each permission that a registered sensor needs. Each row shows the sentence below, the status and a button.

| Permission | Sensor | Onboarding sentence | System Settings URL |
| --- | --- | --- | --- |
| Input Monitoring | `keyboard` | Tells records only the times of your key presses, never which keys you press, to learn your typing rhythm. | `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent` |
| Microphone (Phase 5) | `sound` | Tells listens for voices and laughter near you, and it deletes each sound sample at once without a recording. | `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` |
| Bluetooth (Phase 5) | `crowd` | Tells counts the Bluetooth devices near your Mac, and it does not keep their names or IDs. | `x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth` |

- `activity` and `appswitch` need no permission. The onboarding screen says (D-044): "Tells also records when you use your Mac and which type of app is in front, never the app name."
- No permission request starts before the user clicks the button.
- If the user denies a permission, the app continues. The related experiences show the "Permission denied" state.

## 8. Privacy

The hard rules in `CLAUDE.md` apply. These items make them exact.

- Raw samples stay in `RawEventBuffer` (hard rule 1). No code writes a `SensorSample` to disk, to a log or to the CSV export.
- `SensorSample` has no `String` field and no key code field (hard rules 2 and 3; DEC-12).
- Bundle IDs, app names and window titles stay in memory only (DEC-7).
- The app has App Sandbox on and no `com.apple.security.network.client` or `network.server` entitlement. Thus, the system blocks network calls (hard rule 4; DEC-9).
- `TellsCore` uses only public APIs. Private APIs are only in `MacSensors` sensors with `usesPrivateAPI == true` and a flag (hard rule 5).
- App text follows design/experiences.md Section 1.1 (hard rule 6).
- Logs use `os.Logger` with `privacy: .private` for each value. Logs do not contain feature values or check-in scores.
- Daily summaries have no check-in scores (DEC-6).

## 9. Testing

- Framework: Swift Testing (D-004). Command: `scripts/test.sh`, with `--tsan` for Thread Sanitizer (D-005).
- `TellsCore` tests run with `swift test --package-path TellsCore`. They use no hardware and no permission.
- Each extractor has tests with synthetic samples and a known answer for each feature (check 6). Example: 11 key downs 100 ms apart give `keyboard.iki_median_ms == 100`.
- Each day feature has a test with synthetic `FeatureRow` values, including a gap across a window boundary and a night across midnight.
- Fake conformers (`FakeSensor`, `InMemoryFeatureStore`, `MockModelProvider`) cover: permission denied, not on this Mac, too little data, and stop (check 4, check 8).
- A test makes sure that `SensorSample` has no `String` property (reflection with `Mirror`).
- A test makes sure that `deleteExpired` deletes the day 31 rows and keeps the day 30 rows.
- Each `InsightExperience` has one test for each `ExperienceState`.
- The iOS build of `TellsCore` runs in `scripts/test.sh` (Phase 1 exit criteria).
- Long runs (Tester): 8-hour memory run (check 1), Instruments trace of the tap callback (check 5), 72-hour run (Phase 2 exit), disk scan of the app container and a network monitor (check 7).
