# SPEC.md review (P0.5)

Task: P0.5. Role: Reviewer. The Reviewer did not write SPEC.md.
Inputs: `SPEC.md` (commit f0f6929), `CLAUDE.md` "Hard rules", `PLAN.md` Sections 2, 4 and 5, `DECISIONS.md`, `DEFAULTS.md`, `design/hardware.md`, `design/experiences.md`.
Result: 9 of 10 hard rules pass. Hard rule 5 fails. 3 conflicts with PLAN.md.

## 1. Hard rules

Rules 8 to 10 are loop process rules. For these rules, the Reviewer checks that SPEC.md does not conflict with them.

| # | Rule | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Raw events only in memory | pass | SPEC.md 1.2 (line 35): only `FeatureRow`, `DailyRow`, `DailySummary` and `CheckIn` go to disk. 4.1: raw samples in `RawEventBuffer`, memory only. 8 (line 461): no `SensorSample` to disk, log or CSV. |
| 2 | No key identity, only times | pass | SPEC.md 2.1 (line 85): `SensorSample` has no key code field. 3.1 "Keyboard rules": the tap reads only type, time and autorepeat flag (DEC-12). 9: `Mirror` test for no `String` property. |
| 3 | No audio, images, text, URLs or window titles | pass | SPEC.md 2.1: no `String` field; new `SampleKind` cases hold no text, audio, images or identifiers. 3.1 "App rules": no bundle ID, app name or title in a sample (DEC-7). 4.1: experience state has no text. 4.4: export has no bundle IDs, key data or text. design/experiences.md line 232: ghost racer does not save typed text. |
| 4 | No data off the Mac | pass | SPEC.md 8 (line 464): App Sandbox on, no network client or server entitlement (DEC-9). 3.6: GD-1 decides sandbox for private sensors before P5.2. |
| 5 | Only public APIs in the core; private APIs only in optional sensor plugins, behind a flag | fail | SPEC.md 1.1, 2.2 and 3.6 pass for `TellsCore` and Phase 5 sensors. Failure: SPEC.md 1.4 (line 50) uses `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` in `SensorHub`. Apple does not document these names. No header in MacOSX27.2.sdk `Frameworks/` contains them (`grep -rl screenIsLocked` gives no result). design/hardware.md line 8 defines an undocumented item as private, and design/hardware.md does not list this item. `SensorHub` is not an optional sensor plugin and has no flag. |
| 6 | No medical claims in app text | pass | SPEC.md 8 (line 466): app text follows design/experiences.md 1.1 (banned words, "predicts" not "causes"). SPEC.md 5: the companion shows no text. SPEC.md 7: the onboarding sentences make no medical claim. |
| 7 | No change to model, features or target outside a gate | pass | SPEC.md 2.5 (line 221): only gate tasks change the model. `MockModelProvider` has `isMock == true` until G3. 3.3: "This list is the data, not the model"; G1 selects model features. 2.6: `DriftDetector` is Level 1, which needs no gate (PLAN.md Section 6). |
| 8 | No push unless `ALLOW_PUSH=true` | pass | `grep -n -i -E 'push|remote|git|commit' SPEC.md` gives no result. SPEC.md has no push step. `config.env`: `ALLOW_PUSH=false`. `git remote -v` gives no remote. |
| 9 | One commit for each task, with the task ID | pass | SPEC.md line 3: "Task: P0.4". SPEC.md has no commit rule that conflicts. `git log --oneline`: `f0f6929 P0.4: SPEC.md, first decisions, Sprout companion selected`. |
| 10 | Stop a task after 3 failures | pass | SPEC.md has no retry rule (`grep -i -E 'retr|fail|STATE.md' SPEC.md` gives no result). It does not conflict with PLAN.md Section 3, step 6. |

## 2. Conflicts between SPEC.md and PLAN.md

| ID | PLAN.md | SPEC.md | Effect | Proposed action |
| --- | --- | --- | --- | --- |
| C-1 | Section 4.4: Haptic week data is "Daily summaries". | Section 6 (lines 436, 440): Haptic week uses `CheckIn` values for the last 30 days, not `DailySummary` (DEC-6). | Haptic week shows 30 days at most. PLAN.md 4.3 keeps labels 30 days, so labels cannot go in summaries. SPEC.md has a reason. | No code change. The operator confirms DEC-6 at G0, or selects summary features for low days. |
| C-2 | Section 5, P3.4: add the 30-day data deletion after G3. | Section 4.3 (lines 396 to 397): `deleteExpired` runs at app start and at each day close from Phase 2 (DEC-13). | SPEC.md agrees with PLAN.md 4.3 and Section 6 (30 days). If G1 to G3 take more than approx. 16 days after the 14 data days, the first rows are deleted before training. | No code change. The orchestrator tells the operator at G0. P3.4 then adds only nightly training. |
| C-3 | Section 4.4: Typing rhythm sound uses "a rested day". Ghost racer uses "the best-rested week". | Section 6 and design/experiences.md: the reference is the day or week with the highest `<target>` check-in (D-025). | The reference is not "rested" when the G1 target is mood or social. The change prevents a claim about rest (hard rule 6). | No code change. The operator answers D-025 in the Phase 0 defaults list. |

Items that the Reviewer checked and that do not conflict:
- PLAN.md 4.1 components and targets agree with SPEC.md 1.1, 2 and DEC-11.
- PLAN.md 4.2 sensor checklist agrees with SPEC.md 1.4, 2.2, 3 and 9. The lid close source is public: `kAppleClamshellStateKey` and `kIOPMMessageClamshellStateChange` are in SDK `IOKit/pwr_mgt/IOPM.h` (lines 207 and 439).
- PLAN.md 4.3 retention agrees with SPEC.md 4.1. SPEC.md adds `DailyRow` at 30 days.
- PLAN.md 4.4 companion states agree with SPEC.md 5. SPEC.md adds screen lock to Asleep (D-038).
- PLAN.md 5, P1.5 names `xcodebuild test`. SPEC.md 9 names `scripts/test.sh` (D-005). P1.5 must make `scripts/test.sh` run `xcodebuild test`.
- PLAN.md 2, GD: all SPEC.md defaults (D-026 to D-045) are in `DEFAULTS.md` as `two-way`. The one-way items are design decisions in `DECISIONS.md` (DEC-1 to DEC-13). G0 auto-approves them (`AUTO_APPROVE_DESIGN=true`).
- PLAN.md 4.3 lets the CSV export go to a folder that the operator selects. If the operator selects an iCloud Drive folder, the system sends the file off the Mac. Select a local folder.

## 3. Proposed fix tasks

| Fail | Fix task | Role | Done when |
| --- | --- | --- | --- |
| Hard rule 5 | P0.6 Architect: replace the screen lock source in SPEC.md 1.4. Use a documented API (for example `NSWorkspace.screensDidSleepNotification`, `screensDidWakeNotification` and `sessionDidResignActiveNotification`). Or move `com.apple.screenIsLocked` into an optional plugin behind a flag. | Architect | SPEC.md 1.4 and D-038 name only documented sources for the always-on stop events. design/hardware.md lists each stop source with a public or private label. |
