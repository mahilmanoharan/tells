# Defaults

Each agent adds a row when it selects a starter default (PLAN.md Section 2, GD).
The operator answers `keep`, `change to <value>` or `remove` in the "Answer" column.
Type: `two-way` (easy to change later) or `one-way` (difficult to change later). Do not use a one-way default. Open a GD gate.

| ID | Detail | Default | Alternative | Reason | Type | Answer |
| --- | --- | --- | --- | --- | --- | --- |
| D-001 | Repository layout | `TellsCore/` package; `TellsMac/` package with `MacSensors` and `CompanionUI`; `App/` app target | One package with all three targets | iOS can use `TellsCore` alone. `swift test` runs without Xcode. | two-way | keep |
| D-002 | Xcode project | XcodeGen makes it from `project.yml`. Git ignores the `.xcodeproj`. | Commit a hand-made `.xcodeproj` | Agents can edit YAML. XcodeGen is installed. | two-way | keep |
| D-003 | Minimum OS | macOS 26.0 and iOS 26.0 | macOS 15 and iOS 18 | The build Mac has macOS 26. SwiftData and `@Observable` work. | two-way | keep |
| D-004 | Test framework | Swift Testing | XCTest | It is the current Apple default for new code. | two-way | keep |
| D-005 | Test command | `scripts/test.sh`, with `--tsan` | Separate commands in `CLAUDE.md` | The loop runs one command and gets one result. | two-way | keep |
| D-006 | Agent model names | Full IDs: `claude-opus-5-5`, `claude-sonnet-5-5` | Aliases `opus` and `sonnet` | PLAN.md Section 9 names exact versions. | two-way | keep |
| D-007 | Designer model | Opus 5.5 | Sonnet 5.5 | PLAN.md Section 9 does not name it. Design needs judgment. | two-way | keep |
| D-008 | Task card fields | Add `Status:` and `Depends on:` to the Section 9 format. The orchestrator selects the lowest ready ID. | Keep dependencies in `STATE.md` | Loop step 3 needs status and dependencies on the card. | two-way | keep |
| D-009 | Phase 1 roles | P1.1 and P1.2: architect. P1.3, P1.4 and P1.5: builder. | All Phase 1 tasks: builder | The Architect owns layout and protocols (Section 3). | two-way | keep |
| D-010 | Prompt experiment cards | Cards on disk are outcome cards. On tails, the orchestrator writes the step version when it sends the task. It does not save it. | Two card files for each task | One card file for each task stays simple. | two-way | keep |
| D-011 | Log formats | `STATE.md`: table of date, task, style, result, retries, tokens. CSV columns: `task_id,style,first_pass,retries,tokens,minutes,defaults_changed`. | Add phase and date columns to the CSV | They match PLAN.md Sections 3 and 9. | two-way | keep |
| D-012 | Orchestrator | The main Claude Code session is the orchestrator, on Opus 5.5. Its agent file is for reference. | Run it as a subagent | Subagents cannot start other subagents. | two-way | keep |
| D-013 | Agent tools | Reviewer: read and Bash only. Researcher: read, write and web. Other roles: all tools. | All roles have all tools | The Reviewer must not change work. | two-way | keep |
| D-014 | Phase order | P1.1 waits for P0.5. | Start P1.1 during Phase 0 | Phase 1 needs `SPEC.md`. | two-way | keep |
| D-015 | Phase 0 output folder | `design/` for research notes, concepts, mock-ups and the spec review | `docs/` | One folder for all design work. | two-way | keep |
| D-016 | Bundle ID | `dev.tells.Tells` | Your own reverse-domain ID | Local builds only. Change it before Phase 2 stores data. | two-way | keep |
| D-017 | App Sandbox | App Sandbox on. Hardened Runtime on. | Sandbox off | Safer by default. Change it before Phase 2, because the data folder moves. | two-way | keep |
| D-018 | Companion selection | The Architect selects the concept in P0.4. | The Designer selects | `AUTO_APPROVE_DESIGN=true`, and the Architect owns `DECISIONS.md`. | two-way | keep |
| D-019 | Commit message | `<task ID>: <short summary>` on branch `main` | Conventional Commits | Hard rule 9 needs the task ID. | two-way | keep |
| D-020 | Companion mock-up format | One static 96 x 96 pt SVG key frame for each state. The text gives the motion. | Animated SVG or SpriteKit test scenes | Static SVG is simple to review. The Builder makes the motion in P4.1. | two-way | |
| D-021 | Companion click interaction | Click: short reaction, then a radial menu. Drag moves the companion. Click again or Esc closes the menu. A click in Asleep wakes it first. | Right-click opens the menu; left-click does nothing | PLAN.md Section 4.4 says that a click opens a radial menu. Drag must not open it. | two-way | |
| D-022 | Radial menu layout | 7 items of 28 pt on a 76 pt radius, clockwise from 12 o'clock in PLAN.md Section 4.4 order. SF Symbols glyphs. 180 degree arc at screen edges. | Items in a vertical list next to the companion | It follows the table order and fits a 96 pt companion. | two-way | |
| D-023 | Experience window | One shared SwiftUI `Window` (`insights`), 520 x 440 pt, one experience at a time | One window for each experience | One window is simple to stop and close (check 8). | two-way | |
| D-024 | You vs. your Mac flow | Optional 1-5 forecast before the check-in. The check-in label is saved, then the Mac guess shows. Closer guess wins; tie within 0.25. Forecast and score in `UserDefaults`. | The check-in is the guess; score the Mac against the "yesterday's score" baseline | The user and the Mac both guess before the label is known. | two-way | |
| D-025 | Reference day and week | The labeled day, or 7-day period, with the highest `<target>` check-in in the last 30 days | The day with the lowest typing variation | It uses only labels and makes no claim about rest. | two-way | |
| D-026 | Ghost racer key events | The keyboard timing sensor ignores key events while the `insights` window is the key window. | Let the race keys go into the typing features | It collects less data. A later change can only add data to future windows, so it is easy to change. Race typing is not normal work. | two-way | |
| D-027 | Not-enough-data thresholds | Typing window: 20+ key presses. Usable typing day: 12+ typing windows. Prediction needs 12+ feature windows today. | 6 windows (30 minutes) | One hour of typing gives a stable rhythm value. | two-way | |
| D-028 | Experiment changes and result | 4 Mac-use changes. 7 days before vs. 7 days of change. Mean difference with bootstrap 95% interval (2000 resamples). Needs 5 labeled days each week. Record in `UserDefaults`. | 14-day weeks | Tells can measure Mac-use changes. One week keeps the test short. | two-way | |
| D-029 | Nudge rule | Start: abs z >= 2 for 3 typing windows. End: abs z < 1 for 2 windows. One notice motion in 60 minutes at most. 3 sensitivity values. Baseline needs 3 usable typing days. | Start after 1 window | 15 minutes prevents nudges from short changes. | two-way | |
| D-030 | Haptic low day | Labeled day 1 point or more below the 30-day mean. One `.levelChange` bump; two bumps for the lowest day. Visual marks as fallback. | Bottom 25% of 30-day labels | A 1-point drop on a 1-5 scale is easy to explain. | two-way | |
| D-031 | What-if slider set | Bedtime and late scrolling, only if the model uses the feature. Range: the user's 30-day minimum to maximum. | Fixed ranges (21:00 to 02:00) | The model has no data outside the user's range. | two-way | |
| D-032 | Typing sound mapping | 30 s for one day. One bar for each typing window. 2 to 8 ticks from mean key interval; swing from variation; volume from key count. Synthesized 5 ms 1 kHz click. | One beat for each hour | It is short and needs no audio files. | two-way | |
| D-033 | Raw buffer size | 20,000 samples for each sensor, oldest written over | Size from window length | Two windows of fast typing fit. | two-way | |
| D-034 | Activity probe rate | `secondsSinceLastEventType` each 1 s | Each 5 s | 1 s gives exact idle gaps at low cost. | two-way | |
| D-035 | IKI and hold limits | Pause: IKI over 2000 ms. Hold over 2000 ms dropped. Statistics need 10 or more values. | 1500 ms | Common pause cut-off in typing studies. | two-way | |
| D-036 | Partial windows | Do not save a row with less than 60 s of coverage | Save all partial windows | Very short windows give noisy values. | two-way | |
| D-037 | Scattered trigger | `appswitch.switch_count` 10 or more and over the 14-day 90th percentile, in the last window | Fixed 15 switches | It adapts to the user and has a floor. | two-way | |
| D-038 | State priority and stop events | Asleep, Social, Scattered, Drifting, Normal. Screen lock also stops sensors and shows Asleep. | Drifting before Scattered | Asleep must win. Locked time is not Mac use. | two-way | |
| D-039 | Drift input | `keyboard.iki_median_ms`, log value, same hour plus or minus 1, last 14 usable days | `keyboard.iki_sd_ms` | Median is stable with few key presses. | two-way | |
| D-040 | Companion frame rate | 30 fps maximum. Scene paused in Asleep. | 60 fps | Helps to keep idle CPU under 2%. | two-way | |
| D-041 | Pause options | Menu bar "Pause Tells": 1 hour, until tomorrow, until resumed | One on/off switch | Short pauses are common. | two-way | |
| D-042 | Private sensor flags | `UserDefaults` key `flag.<sensor>`, off by default | Build-time compiler flag | The operator can test without a new build. | two-way | |
| D-043 | CSV export layout | 3 files: `windows.csv`, `days.csv`, `checkins.csv`. One column for each feature. | One long file | Wide files open directly in pandas. | two-way | |
| D-044 | No-permission sensor text | One onboarding sentence for `activity` and `appswitch` together | No text | The user knows all data that Tells records. | two-way | |
| D-045 | Lid close signal | `IOPMrootDomain` interest notification `kIOPMMessageClamshellStateChange`, then read `AppleClamshellState`. Sensors stop when it is true, also in clamshell mode. | Poll `AppleClamshellState` each 5 s | One notification, no polling. Confirm on the build Mac in P2.2. | two-way | |
| D-046 | Reviewer as task worker | When the Reviewer role does a task (for example P0.5), it writes drafts to the scratchpad. The orchestrator copies them into the repository. A second reviewer checks the result. | Give the Reviewer Write access | D-013 keeps the Reviewer read-only. | two-way | |
