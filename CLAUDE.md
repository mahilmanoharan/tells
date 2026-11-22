# Tells — rules for agents

Read `STATE.md` first. Read `PLAN.md` sections only by number, when a task card points to them.
Write all documents in ASD-STE100 (PLAN.md Section 2, "Writing rules").

## Hard rules
If a task conflicts with a rule, stop. Write the conflict in `STATE.md`.

1. Do not write raw events to disk. Keep raw events only in memory.
2. Do not record which key the user presses. Record only times.
3. Do not record audio, images, text, URLs or window titles.
4. Do not send data off the Mac.
5. Use only public APIs in the core. Put private APIs only in optional sensor plugins, behind a feature flag.
6. Do not make medical claims in the app text.
7. Do not change the model, its features or its target outside a gate.
8. Do not push to a remote repository unless `config.env` sets `ALLOW_PUSH=true`.
9. Make one commit for each completed task. Use one short line: `P1.2: <summary>`. Add no co-author trailer or tool name.
10. If a task fails 3 times, stop work on it. Write the cause in `STATE.md`. Select a different task.

## Defaults
If a detail is not specified, select a starter default (PLAN.md Section 2, GD).
Write it in `DEFAULTS.md` and leave the Answer column empty (only the operator fills it). Put `// DEFAULT: D-<id>` in the code.
If the default is one-way, do not use it. Open a GD gate in `GATES.md` and stop.

## Package map
| Path | Target | Platforms | Content |
| --- | --- | --- | --- |
| `TellsCore/` | `TellsCore` (SwiftPM) | macOS 26, iOS 26 | Pure Swift. Protocols, ring buffer, extractors, `FeatureStore`, `ModelProvider`, `DriftDetector`. No AppKit. |
| `TellsMac/` | `MacSensors` (SwiftPM) | macOS 26 | `Sensor` plugins. Private APIs only here, behind a flag. |
| `TellsMac/` | `CompanionUI` (SwiftPM) | macOS 26 | Companion, radial menu, `InsightExperience` plugins. |
| `App/` | `Tells` (app) | macOS 26 | App entry, `AppModel`, `MenuBarExtra`, onboarding. |
| `project.yml` | XcodeGen spec | — | Makes `Tells.xcodeproj`. Do not commit the `.xcodeproj`. |

Phase 1 makes these paths. Until P1.1 is done, they do not exist.

## Commands
Run from the repository root.

- Make the Xcode project: `xcodegen generate`
- Run all tests: `scripts/test.sh`. It runs 5 steps, runs all of them even after a failure, and prints `PASS` or `FAIL <n> failed step(s): <names>` last. Logs are in `.build/test-logs/`.
- Run all tests with Thread Sanitizer: `scripts/test.sh --tsan` (skips the iOS build).
- Test the app: `xcodebuild test -project Tells.xcodeproj -scheme Tells -destination 'platform=macOS'`
- Test the core only: `swift test --package-path TellsCore`
- Test Mac packages: `swift test --package-path TellsMac`
- Build the app: `xcodebuild build -project Tells.xcodeproj -scheme Tells -destination 'platform=macOS'`
- Build the core for iOS: `cd TellsCore && xcodebuild build -scheme TellsCore -destination 'generic/platform=iOS'`

## Files
- `tasks/<ID>.md`: task cards. `STATE.md`: open tasks, open gates, last 10 log lines.
- `DEFAULTS.md`, `DECISIONS.md`, `GATES.md`, `SPEC.md`, `prompt-experiment.csv`, `config.env`.
- Do not change `PLAN.md`. Do not read `log/` unless a task tells you to.
