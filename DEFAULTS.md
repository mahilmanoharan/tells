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
