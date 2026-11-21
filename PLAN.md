# Tells — Autonomous Build Plan (ASD-STE100)

Nov 21, 2026 · @Mahil

## 1. Purpose and scope

This plan tells Claude Code agents how to design and build Tells without the operator. The operator works only at the three model gates (G1, G2, G3).

**Product summary.** Tells is a macOS app. It shows a small animated character (the companion) on the desktop and an icon in the menu bar. The app measures how the user types, works and lives near the Mac. It does not record content. A personal model learns the user. When the user clicks the companion, the companion shows insights in creative ways.

**Terms.**

| Term | Meaning |
| --- | --- |
| Operator | The person who owns the project (you). |
| Orchestrator | The main agent. It reads the state, selects the next task and sends it to a subagent. |
| Subagent | An agent with one role and one task. It does not see other tasks. |
| Gate | A stop point. The loop must stop and wait for the operator. |
| Raw event | One input from a sensor, for example one key press time. |
| Feature | A number that a sensor extractor calculates from raw events in one window. |
| Window | A period of 5 minutes. |

**In scope.**

- A macOS app for Apple Silicon MacBooks, in Swift 6 and SwiftUI.
- Sensors that use the Mac hardware in unusual ways.
- One personal model that trains on the Mac.
- The companion and its insight experiences.
- An architecture that can move to iPhone later.

**Out of scope.**

- The iPhone app. (Phase 6 only makes the core ready for it.)
- An App Store release.
- Servers, cloud training and other users.
- Medical claims. Tells is a wellness and research tool.

## 2. Rules for the loop

The agents do all work alone, except at the three model gates. At a gate, the loop must stop.

**Gates.**

| Gate | When | The loop prepares | The operator does |
| --- | --- | --- | --- |
| G0 (optional) | End of Phase 0 | `SPEC.md` and the companion concept | Reads and approves. If `AUTO_APPROVE_DESIGN = true`, the loop does not stop. |
| G1 Model design | After 14 days of data | A data report and a notebook with baselines | Selects the target, the features and the model family. |
| G2 Model test | After the first training | An evaluation notebook | Tests, changes and tunes the model. Accepts or rejects it. |
| G3 Model ship | After G2 passes | A Create ML version of the model and a parity report | Approves the model for the app. |

**Inferred defaults (GD).** This plan does not specify every detail. When a task needs a detail that is not specified, the agent selects a starter default and continues.

1. Select the simplest default that you can change later.
2. Write it in `DEFAULTS.md`: ID, the detail, the default, one alternative, the reason, and `two-way` or `one-way`.
3. Put the comment `// DEFAULT: D-<id>` in the code at that location.
4. If the default is one-way (difficult to change later, for example a data schema or a privacy behavior), do not use it. Open a GD gate and stop.

At the end of each phase, the orchestrator sends the operator one short list of open defaults. Write each default as one line with one question. The operator answers `keep`, `change to <value>` or `remove`. The loop makes the changes in the next cycle.

**Hard rules.** Each agent must obey these rules. If a task conflicts with a rule, stop and write the conflict in `STATE.md`.

1. Do not write raw events to disk. Keep raw events only in memory.
2. Do not record which key the user presses. Record only times.
3. Do not record audio, images, text, URLs or window titles.
4. Do not send data off the Mac.
5. Use only public APIs in the core. Put private APIs only in optional sensor plugins, behind a feature flag.
6. Do not make medical claims in the app text.
7. Do not change the model, its features or its target outside a gate.
8. Do not push to a remote repository unless the operator set `ALLOW_PUSH = true`.
9. Make one commit for each completed task. Write the task ID in the commit message.
10. If a task fails 3 times, stop work on it. Write the cause in `STATE.md` and select a different task.

**Writing rules (ASD-STE100).** All agents write plans, specifications, logs and gate reports in Simplified Technical English.

- Write one instruction in each sentence. Use the imperative.
- Keep procedural sentences to 20 words or fewer. Keep descriptive sentences to 25 words or fewer.
- Use the active voice.
- Use one word for one meaning. Do not use synonyms for a technical name.
- Write warnings before the step that they apply to.
- Code, identifiers and API names are technical names. Use them as they are.

## 3. Agent roles and loop procedure

One orchestrator runs the loop. It sends each task to one subagent and sends the result to a reviewer that did not do the work.

**Roles.** Put each subagent definition in `.claude/agents/<role>.md`.

| Role | Does | Does not |
| --- | --- | --- |
| Orchestrator | Reads `STATE.md`, selects the next task, sends it, records the result, stops at gates. | Write app code. |
| Researcher | Reads Apple documentation, WWDC sessions and papers. Writes short notes with links. | Make design decisions. |
| Designer | Designs the companion, its states and the insight experiences. Writes specs and mock-ups. | Write sensor code. |
| Architect | Owns the package layout, the protocols and `DECISIONS.md`. | Add features outside a task. |
| Builder | Writes Swift code and unit tests for one task. | Change protocols without an Architect task. |
| Tester | Runs tests, Instruments traces and long runs. Records numbers. | Change app code. |
| Reviewer | Checks each result against the acceptance criteria and Section 7. Has no memory of the work. | Approve its own work. |
| ML assistant | Prepares data reports and notebooks for the gates. Explains each choice. | Select the final model. The operator does that. |

**Loop procedure.** Do these steps in each loop cycle.

1. Read `STATE.md`. Do not read other files unless the task card points to them.
2. If a gate is open and the operator has not closed it, stop.
3. Select the first task card in `tasks/` that has status `ready` and no open dependency.
4. Send only the task card to the subagent of its role.
5. Send the result and the card's "Done when" list to the Reviewer.
6. If the Reviewer rejects the result, send back only the failed checks. Do steps 4 to 6 again, 3 times maximum.
7. If the result passes, commit it. Set the card status to `done`.
8. Write one log line in `STATE.md`: task ID, prompt style, result, retries, tokens.
9. If the phase is complete, send the open defaults list (GD). If the next task is a gate, write the gate report in `GATES.md`. Then stop.
10. Go to step 1.

**Parallel work.** The orchestrator can send tasks from different phases at the same time when they do not touch the same files. For example, do Phase 4 tasks while Phase 2 collects data.

## 4. Architecture

Tells has three targets. Only `MacSensors` and `CompanionUI` use macOS APIs. `TellsCore` is pure Swift, so the iPhone version can use it later.

&#91;embedded content: Tells architecture · 3 targets, raw data in memory only\]

Sensors send raw events into memory. Extractors change them into features every 5 minutes. Only features and check-in labels go to disk.

### 4.1 Components

| Component | Target | Job |
| --- | --- | --- |
| `Sensor` plugins | `MacSensors` | Read one hardware source. Send `SensorSample` values through an `AsyncStream`. |
| Ring buffer | `TellsCore` | Keep raw events in memory. Write over old events. |
| `FeatureExtractor` | `TellsCore` | Change one window of samples into named numbers. |
| `FeatureStore` | `TellsCore` | Keep feature rows and labels in SwiftData for 30 days. |
| `ModelProvider` | `TellsCore` | Give predictions. `MockModelProvider` until G3, then the Create ML model. |
| `DriftDetector` | `TellsCore` | Compare today with the personal baseline. Needs no labels. |
| `InsightExperience` plugins | `CompanionUI` | One creative way to show insights (Section 4.4). |
| Companion | `CompanionUI` | The character on the desktop. It shows state and opens the experiences. |

### 4.2 Sensor checklist

Each new sensor must pass these steps before it is merged.

1. Conform to `Sensor`. Declare its permission and its availability check.
2. Write a `FeatureExtractor` for it. Name each feature `<sensor>.<feature>`.
3. Write unit tests with synthetic samples and known answers.
4. Make sure that it stops on sleep, lid close and pause.
5. Write which hardware it uses, and if the API is public or private.
6. If the API is private, put the sensor behind a feature flag. It must not break the app on a Mac without that hardware.

### 4.3 Data and retention

| Data | Where | How long |
| --- | --- | --- |
| Raw events | Memory ring buffer | Seconds to minutes |
| Feature rows | `FeatureStore` | 30 days |
| Labels (check-ins) | `FeatureStore` | 30 days |
| Daily summaries | `FeatureStore` | Kept, for trend views |
| Model | Application Support folder | Until the next training |
| CSV export | A folder the operator selects | Only for gates. The operator deletes it after the gate. |

### 4.4 Companion and insight experiences

The companion is a small original character in a transparent, floating window. It is the face of the model. Its look shows drift, not numbers. When the user clicks it, a radial menu opens the insight experiences.

**Companion states.** Phase 0 selects the final art. These states are the minimum.

| State | Trigger | Look |
| --- | --- | --- |
| Normal | Today is in the personal baseline | Calm idle animation |
| Drifting | Typing rhythm moves out of the baseline during a session | Slow, sleepy animation |
| Scattered | App switch rate is high | Looks around quickly |
| Social | Sound scene detects voices or laughter (Phase 5) | Bright animation |
| Asleep | Tells is paused or the Mac sleeps | Sleeps |

**Insight experiences.** Each one is an `InsightExperience` plugin.

| Experience | What the user does | Data | Frameworks |
| --- | --- | --- | --- |
| You vs. your Mac | Guesses the day's energy. Then the model shows its guess. A score shows who knows the user better. | Model, check-in | SwiftUI |
| Typing rhythm sound | Listens to today's typing rhythm as a beat, next to a rested day. | Typing features | AVAudioEngine |
| Ghost racer | Types a sentence next to a ghost cursor at the rhythm of the best-rested week. | Typing features | SwiftUI, Canvas |
| What-if sliders | Moves bedtime or late scrolling and sees the predicted energy change. | Model | SwiftUI, Swift Charts |
| Haptic week | Moves a finger across the trackpad and feels a bump on each low day. | Daily summaries | `NSHapticFeedbackManager` |
| Experiment | Selects a one-week change. Tells compares the week before and the week after. | Features, labels | SwiftUI |
| In-the-moment nudge | Sees the companion change when drift starts, during work. | Drift detector | SpriteKit |

You vs. your Mac also protects the data: the user enters the label before the model shows its guess.

## 5. Phases, tasks and acceptance criteria

The work has 7 phases. The operator works only at G1, G2 and G3 in Phase 3. All other phases are autonomous.

Each task must also pass the checks in Section 7 that apply to it.

### Phase 0 — Design loop (autonomous)

This phase finishes the brainstorm and writes the final specification.

- [ ] P0.1 Researcher: make a list of Mac hardware and Apple frameworks that Tells can use. Give each item a public or private label and a link.
- [ ] P0.2 Designer: write 3 companion concepts. Each concept has a look, 5 states and a click interaction. Use only original art.
- [ ] P0.3 Designer: write a spec for each insight experience in Section 4.4.
- [ ] P0.4 Architect: write `SPEC.md` and the first entries in `DECISIONS.md`.
- [ ] P0.5 Reviewer: compare `SPEC.md` with this plan. Make sure that no hard rule is broken.

Exit criteria: `SPEC.md` is complete. One companion concept is selected and the reason is in `DECISIONS.md`.

### Phase 1 — Skeleton (autonomous)

- [ ] P1.1 Make the Xcode project, the `TellsCore` package and the `MacSensors` and `CompanionUI` targets.
- [ ] P1.2 Write the `Sensor`, `FeatureExtractor`, `FeatureStore`, `ModelProvider` and `InsightExperience` protocols.
- [ ] P1.3 Add the menu bar icon with `MenuBarExtra`. Add a placeholder companion window.
- [ ] P1.4 Add the permission onboarding screen. It explains each permission in one sentence.
- [ ] P1.5 Add a test command that the loop can run (`xcodebuild test`).

Exit criteria: the app builds, starts and quits. All tests pass. `TellsCore` builds for macOS and iOS.

### Phase 2 — First sensors and data collection (autonomous)

- [ ] P2.1 `KeyboardTimingSensor`: a listen-only event tap. It records key down and key up times. It does not record key codes.
- [ ] P2.2 `ActivitySensor`: first and last input of the day, idle gaps and the sleep window estimate.
- [ ] P2.3 `AppSwitchSensor`: app activation times and app category. It does not record window titles.
- [ ] P2.4 Raw event ring buffer in memory. Feature extractors run on each 5-minute window.
- [ ] P2.5 `FeatureStore` with SwiftData. Each feature row has a schema version.
- [ ] P2.6 Daily check-in: energy, mood and social connection, each 1 to 5. Show it before any prediction.
- [ ] P2.7 Export of feature rows and labels to CSV, for the gates only.

Exit criteria: the app runs 72 hours without a crash. The checks in Section 7 pass. Then the operator uses the Mac normally for 14 days.

### Phase 3 — Model (operator in the loop)

- [ ] P3.1 ML assistant: write the data report and the G1 notebook (Section 6). Open G1. Stop.
- [ ] P3.2 After G1: train the selected models with forward-chaining validation. Write the G2 notebook. Open G2. Stop.
- [ ] P3.3 After G2: build the model with the Create ML framework in Swift. Write a parity test against the notebook. Open G3. Stop.
- [ ] P3.4 After G3: add nightly training with `NSBackgroundActivityScheduler` and the 30-day data deletion.

Exit criteria: the operator closed G1, G2 and G3. The parity test passes.

### Phase 4 — Companion and insights (autonomous)

This phase can run while Phase 2 collects data. Use a `MockModelProvider` until G3 closes.

- [ ] P4.1 Build the companion: a transparent, floating `NSPanel` with a SpriteKit scene. The user can drag it and hide it.
- [ ] P4.2 Connect the companion states to drift detection (Section 4.4). Drift detection does not need labels.
- [ ] P4.3 Click menu: a radial menu around the companion that opens each insight experience.
- [ ] P4.4 Build each insight experience as one `InsightExperience` plugin.

Exit criteria: each experience works with mock data and with real data. The companion uses less than 2% CPU when it is idle.

### Phase 5 — More sensors (autonomous, then model gates again)

- [ ] P5.1 `SoundSceneSensor`: the built-in SoundAnalysis classifier labels speech, laughter and noise level. Delete each audio buffer at once.
- [ ] P5.2 `LightSensor`: ambient light level by time of day.
- [ ] P5.3 `TrackpadForceSensor` (private API, flag): press force and micro-tremor.
- [ ] P5.4 `MotionSensor` (private API, flag): laptop accelerometer for restlessness.
- [ ] P5.5 `NearbyCrowdSensor`: the number of nearby Bluetooth devices, with no identifiers stored.

Exit criteria: each new sensor follows the sensor checklist in Section 4.2. New features go into the model only through G1 to G3 again.

### Phase 6 — iPhone readiness (autonomous)

- [ ] P6.1 Make sure that `TellsCore` has no AppKit import and builds for iOS.
- [ ] P6.2 Add an empty `IOSSensors` target with a stub sensor. Do not build the iPhone app.

## 6. ML protocol for the gates

The model predicts one daily check-in score from one day of features. It is a supervised regression for one person, with approximately 1 labeled row each day. The small number of rows is the main risk.

**What the ML assistant prepares for G1.**

1. A data report: number of days, missing days, feature distributions and label distributions.
2. A list of candidate features. Give each feature a reason and a source study, if one exists.
3. Two baselines: "your average score" and "yesterday's score".
4. A recommendation for the target (energy, mood or social connection) and the model family. Ridge regression is the default.

**What the operator decides at G1.** Select the target. Select no more than 8 features. Select the model families to test. Write the reasons in `DECISIONS.md`.

**Model levels.**

| Level | Model | Needs labels | Use |
| --- | --- | --- | --- |
| 1 | Personal baseline and drift detection (rolling mean, z-score, change-point detection) | No | Companion states from day 1 |
| 2 | Ridge or lasso regression | Yes | Daily prediction and "what-if" |
| 3 | Gradient-boosted trees | Yes, 90 days or more | Only if it beats Level 2 at G2 |

**Evaluation rules for G2.** The ML assistant must obey these rules. The Reviewer must check them.

1. Use forward-chaining validation. Train on days 1 to n. Test on day n+1. Do not use a random split.
2. Compare each model with the two baselines. If a model does not beat both baselines, reject it.
3. Report mean absolute error and Spearman correlation, each with a bootstrap 95% confidence interval.
4. Do a permutation test. Report the p-value.
5. Normalize each feature against the personal baseline for its hour and app category.
6. Keep low-activity days. Add a "low activity" feature. Do not delete these days.
7. Correct for multiple comparisons when you report which features predict the target.
8. Write "predicts", not "causes", in all insight text. Use the experiment experience for causal claims.

**What the operator does at G2.** Run the notebook. Change features, regularization and window sizes. Record each test in the notebook. Accept one model or send it back with notes.

**What the operator does at G3.** Read the parity report. The Swift model must give the same predictions as the notebook within 0.01 on the test days. Approve or reject.

**Privacy trade-off.** The app deletes feature rows after 30 days. Thus, the app cannot calculate old features again with a new extractor. Each feature row has a schema version. A new schema starts a new training window.

**Interview notes.** At each gate, the ML assistant writes 5 to 10 lines that explain the decision in plain words. Keep these notes in `GATES.md`.

## 7. Quality checks

The Reviewer uses these 8 checks on each task that they apply to. A task fails if one check fails. Each check needs evidence, not a statement.

| # | Risk | Check | Evidence |
| --- | --- | --- | --- |
| 1 | Memory leaks | Closures that keep `self` use `[weak self]`. Long-lived objects print a message in `deinit` during tests. | Memory graph after an 8-hour run. Memory growth is less than 20 MB. |
| 2 | Wrong thread | Sensor callbacks send events to an `actor`. Only finished values go to `@MainActor` code. | Thread Sanitizer run with no warnings. |
| 3 | State in the wrong place | One `@Observable` `AppModel`, made once in the app. Views read from it. No view makes its own model. | Code review note with file names. |
| 4 | Happy path only | Each feature handles: permission denied, sensor not on this Mac, too little data. The UI shows "not enough data", never a guessed number. No force unwrap. No empty `catch`. | One unit test for each failure case. |
| 5 | Slow work in the input path | The event tap callback only stamps a time and puts it in a buffer. Feature work runs on a background task. | Instruments trace: callback p99 time less than 1 ms. Companion idle CPU less than 2%. |
| 6 | Tests that test nothing | Extractor tests use synthetic events with a known answer. Each test fails if you break the calculation. | Mutation check: change one formula, and make sure that a test fails. |
| 7 | Privacy | No raw events on disk. No key codes, audio, text or titles. No network calls. No sensitive data in logs. | Disk scan of the app container. Network monitor shows no traffic. Log review. |
| 8 | Work that does not stop | Each sensor and each `Task` stops when the Mac sleeps, the lid closes, the user pauses Tells or a view closes. | Unit tests for stop. A trace that shows zero sensor work during sleep. |

## 8. Start the loop

Put this plan in the repository as `PLAN.md`. Then give the loop prompt below to Claude Code for each loop cycle.

**Files in the repository.**

| File | Owner | Content |
| --- | --- | --- |
| `CLAUDE.md` | Architect | Hard rules (Section 2), build and test commands, package map. Less than 60 lines. |
| `PLAN.md` | Operator | This plan. Agents read sections by number. Agents do not change it. |
| `SPEC.md` | Architect | The detailed specification from Phase 0. |
| `tasks/<ID>.md` | Orchestrator | One task card for each task (Section 9). |
| `STATE.md` | Orchestrator | Open tasks, open gates and the last 10 log lines. |
| `log/` | Orchestrator | Old log lines. Agents do not read it unless a task tells them to. |
| `DEFAULTS.md` | All agents | Inferred defaults and the operator answers. |
| `DECISIONS.md` | Architect | Each decision, its date, the options and the reason. |
| `GATES.md` | ML assistant | Gate reports, operator decisions and interview notes. |
| `prompt-experiment.csv` | Orchestrator | One row for each task (Section 9). |
| `.claude/agents/*.md` | Architect | One definition for each role in Section 3, with its model. |
| `config.env` | Operator | `AUTO_APPROVE_DESIGN`, `ALLOW_PUSH`, `MAX_TASKS_PER_RUN`. |

**Loop prompt.**

```markdown
Role: Tells orchestrator.
Outcome: The next ready task in tasks/ is done and passes review, or the loop stopped at a gate.
Rules: CLAUDE.md. Procedure: PLAN.md Section 3. Unclear details: PLAN.md Section 2 (GD).
Done when: STATE.md has one log line for each task, and the run did MAX_TASKS_PER_RUN tasks or fewer.
```

**Stop conditions.** The loop must stop when:

- A gate is open.
- A hard rule conflicts with a task.
- The same task failed 3 times and no other task is ready.
- The run did `MAX_TASKS_PER_RUN` tasks.

**How to close a gate.** Do the gate work in Section 6. Write your decision under the gate in `GATES.md`. Change the gate status to `closed`. Start the loop again.

## 9. Short prompts and outcome-based tasks

Each agent receives a short task card. The card states the outcome and the checks, not the steps. This keeps each context small and lets the agent select the method.

**Context rules.**

- Keep `CLAUDE.md` less than 60 lines.
- Give each subagent only its task card. The card points to files. It does not copy them.
- Keep each task card less than 25 lines.
- Keep `STATE.md` short: open tasks, open gates and the last 10 log lines.
- Do not paste this plan into a prompt. Point to a section number.
- Use Opus 5.5 for the orchestrator, Reviewer, Architect and ML assistant. Use Sonnet 5.5 for the Builder, Tester and Researcher.

**Task card format.**

```markdown
ID: P2.1
Role: builder
Outcome: Tells knows when each key goes down and up, and nothing else about the key.
Done when:
- Unit test: synthetic events give the correct hold times.
- Instruments: event tap callback p99 is less than 1 ms.
- Disk scan: no raw events on disk.
Constraints: Hard rules 1, 2, 5. Checks 2, 5, 7.
Context: TellsCore/Sensor.swift, SPEC.md "Keyboard"
Unclear details: select a default (PLAN.md Section 2, GD).
```

**Outcome rules.**

1. Write the outcome as a state of the product or the user. Do not write steps.
2. Write each "Done when" item as a check that the Reviewer can run.
3. If you cannot write a check for the outcome, the outcome is not clear. Split the task.

**Prompt experiment.** The loop also tests this method. Before each Phase 1 and Phase 2 task, the orchestrator flips a coin. Heads: an outcome card. Tails: a step-by-step card with full context. Record one row for each task in `prompt-experiment.csv`.

| Metric | How to measure |
| --- | --- |
| First-pass rate | The Reviewer accepts the result with no retry. |
| Retries | Number of returns from the Reviewer. |
| Tokens | Tokens that the task used, from the run summary. |
| Time | Minutes from send to `done`. |
| Defaults changed | Number of that task's defaults that the operator changed at GD. |

At the end of Phase 2, the ML assistant writes a prompt report in `GATES.md`. It compares the two styles with 95% confidence intervals. The sample is small, so write the result as a trend, not a proof. The operator then selects one style for Phases 3 to 6.

**Sources.**

- [neuroQWERTY: key hold times during natural typing](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5891671/)
- [Typing changes during sleep inertia (Scientific Reports)](https://link.springer.com/10.1038/srep09678)
- [BiAffect: keyboard metadata and mood on iOS](https://escholarship.org/content/qt0nc3d91k/qt0nc3d91k.pdf?t=s0aulb)
- [TrackWeight: Force Touch trackpad as a scale](https://github.com/KrishKrosh/TrackWeight)
- [apple-silicon-accelerometer: MacBook IMU through IOKit](https://pypi.org/project/macimu/)
- [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor)
