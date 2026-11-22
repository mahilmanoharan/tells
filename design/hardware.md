# Mac hardware sources and frameworks

Task: P0.1. Scope: PLAN.md Phase 2, Phase 5 and the lid angle sensor.
This file gives facts only. It does not make design decisions.

## Notes on the evidence
- The fetch tool could not show the text of Apple documentation pages. The Apple links name the API page. Check them again in Xcode before you use the API.
- Private items come from community projects. Apple does not document them. Test each one on the build Mac.
- Hard rule 5: private APIs go only in optional sensor plugins, behind a feature flag.

## Table

| Name | Hardware | Framework or API | Public or private | Link |
| --- | --- | --- | --- | --- |
| Key timing (P2.1) | Built-in and external keyboard | `CGEvent.tapCreate` with `.listenOnly`, in CoreGraphics. Needs Input Monitoring permission. | Public | [CGEvent.tapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)) |
| Input Monitoring check (P2.1) | None (permission state) | `CGPreflightListenEventAccess` and `CGRequestListenEventAccess` | Public | [CGPreflightListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()) |
| Idle time (P2.2) | Keyboard, mouse and trackpad | `CGEventSource.secondsSinceLastEventType` | Public | [secondsSinceLastEventType](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:)) |
| Sleep and wake times (P2.2, checklist step 4, stop source SPEC.md 1.4) | Whole Mac (power state) | `NSWorkspace.willSleepNotification` and `didWakeNotification` | Public | [willSleepNotification](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification) |
| Display sleep and wake (stop source, SPEC.md 1.4) | Displays | `NSWorkspace.screensDidSleepNotification` and `screensDidWakeNotification` (`NSWorkspaceScreensDidSleepNotification` in `AppKit/NSWorkspace.h`) | Public | [screensDidSleepNotification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification) |
| User session active or not active (stop source, SPEC.md 1.4) | None (login session) | `NSWorkspace.sessionDidResignActiveNotification` and `sessionDidBecomeActiveNotification` (`AppKit/NSWorkspace.h`) | Public | [sessionDidResignActiveNotification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification) |
| Lid close (stop source, SPEC.md 1.4, D-045) | Lid switch | IOKit `IOPMrootDomain` property `AppleClamshellState`, interest message `kIOPMMessageClamshellStateChange` (`IOKit/pwr_mgt/IOPM.h`) | Public | [IOKit](https://developer.apple.com/documentation/iokit) |
| App quit (stop source, SPEC.md 1.4) | None (app event) | `NSApplication.willTerminateNotification` | Public | [willTerminateNotification](https://developer.apple.com/documentation/appkit/nsapplication/willterminatenotification) |
| Screen lock and unlock (not used, DEC-14) | None (login session) | Distributed notifications `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked`. No SDK header contains these names. | Private | [DistributedNotificationCenter (Apple documents the class, not these names)](https://developer.apple.com/documentation/foundation/distributednotificationcenter) |
| App activation times (P2.3) | None (software event) | `NSWorkspace.didActivateApplicationNotification` | Public | [didActivateApplicationNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification) |
| App category (P2.3) | None (app bundle data) | `LSApplicationCategoryType` key in the app Info.plist, read through `Bundle` | Public | [LSApplicationCategoryType](https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype) |
| Sound scene (P5.1) | Built-in microphone | `AVAudioEngine` input node with SoundAnalysis `SNAudioStreamAnalyzer` and `SNClassifySoundRequest` (built-in classifier `version1`). Needs Microphone permission. | Public | [SNClassifySoundRequest](https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest), [SoundAnalysis](https://developer.apple.com/documentation/soundanalysis) |
| Ambient light (P5.2) | Ambient light sensor next to the display or camera | No public API. Community code reads IOKit service `AppleLMUController`, or the IORegistry `CurrentLux` property. | Private | [Apple Developer Forums: no supported API](https://developer.apple.com/forums/thread/81806), [Lumen (reads the sensor)](https://github.com/knightfolk/Lumen), [Chromium `ambient_light_mac.cc`](https://chromium.googlesource.com/chromium/src/+/c31119bc5/content/browser/device_sensors/ambient_light_mac.cc) |
| Trackpad press stage (P5.3, public part) | Force Touch trackpad | `NSEvent.pressure` and `stage` on mouse events. It gives the force only while the app gets a click event. | Public | [NSEvent.pressure](https://developer.apple.com/documentation/appkit/nsevent/pressure) |
| Trackpad raw force and touch data (P5.3) | Force Touch trackpad | `MultitouchSupport.framework`, through the wrapper OpenMultitouchSupport. App Sandbox must be off. | Private | [TrackWeight](https://github.com/KrishKrosh/TrackWeight), [OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport) |
| Laptop accelerometer (P5.4) | Apple silicon MacBook inertial sensor (`AppleSPUHIDDevice`) | IOKit HID, vendor usage page `0xFF00`, usage 3 (accelerometer) and 9 (gyroscope) | Private | [macimu on PyPI](https://pypi.org/project/macimu/) |
| Headphone motion (not in PLAN.md) | AirPods and Beats with motion sensors | `CMHeadphoneMotionManager` in CoreMotion | Public | [CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager) |
| Nearby Bluetooth devices (P5.5) | Bluetooth radio | CoreBluetooth `CBCentralManager.scanForPeripherals`. Needs Bluetooth permission. | Public | [scanForPeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/scanforperipherals(withservices:options:)) |
| Lid angle | Lid angle sensor (2019 16-inch MacBook Pro and newer) | IOKit HID device: vendor `0x05AC`, product `0x8104`, usage page `0x0020`, usage `0x008A` | Private | [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor), [hinge-angle crate (IDs)](https://docs.rs/crate/hinge-angle/0.1.0/source/src/macos.rs), [heise report](https://heise.de/-10650581) |

## Risk of each private item
- Ambient light: Apple says there is no supported API, so a macOS update can remove the service, and App Sandbox blocks the IOKit access ([forum](https://developer.apple.com/forums/thread/81806), [Lumen](https://github.com/knightfolk/Lumen)).
- Trackpad raw force: the framework is private, so a macOS update can change or block it. It also needs App Sandbox off, which conflicts with D-017 ([OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport), [Medium note on Apple blocking it in a 10.13.2 beta, not verified](https://medium.com/ryan-hanson/touching-apples-private-multitouch-framework-64f87611cfc9)).
- Laptop accelerometer: Apple does not expose the sensor, it works only on some Apple silicon Macs (M2 to M5, tested on one M3 Pro), and the source says it needs root ([macimu](https://pypi.org/project/macimu/)).
- Lid angle: it is an undocumented HID device, and reports say it fails on some M1 and M2 Macs ([LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor), [heise](https://heise.de/-10650581)).

## Open points for the Architect
- The lid angle sensor is not in PLAN.md Phase 5. This file lists it only because the task card asks for it.
- The README of LidAngleSensor does not say how it reads the sensor. The IDs above come from a different project, the hinge-angle crate. Confirm them on the build Mac.
- The accelerometer and the lid angle sensor may use the same hub, but no source confirms this.
- Sandbox: the trackpad wrapper needs App Sandbox off. The IOKit paths for light and accelerometer may need it off too. D-017 sets it on. This is for the Architect to decide.
