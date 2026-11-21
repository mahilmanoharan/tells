# Insight experiences (P0.3)

This file gives one spec for each insight experience in PLAN.md Section 4.4.
A Builder uses one section to build one `InsightExperience` plugin in P4.4.
The radial menu details apply to P4.3. Each default has a `D-<id>` in `DEFAULTS.md`.

## 1. Common rules for all experiences

### 1.1 Words and claims

- Do not make a medical claim in the app text (hard rule 6).
- Do not use these words in the app text: diagnose, disorder, symptom, illness, disease, treatment, therapy, health, burnout, depression, anxiety, fatigue, sleep quality.
- Write "predicts", not "causes", in all insight text (PLAN.md Section 6, rule 8).
- Write "your check-in score" for the label. Do not write "your energy is low". Write "your energy check-in was 2".
- Only the Experiment (Section 8) can say that a change "came with" a difference. It must also say that one week is a small test.
- Write all app text in plain, short sentences.

### 1.2 Privacy

- Experiences read only feature rows, labels, daily summaries and model outputs.
- Experiences do not read raw events from the ring buffer. Exception: Ghost racer measures its own key times in memory (Section 4).
- Do not record audio, images, text, URLs or window titles (hard rule 3).
- Do not save typed characters. Do not write typed characters to a log.
- Experiences do not train the model. They do not change the model, its features or its target (hard rule 7). They call only the prediction methods of `ModelProvider`.

### 1.3 The target name

- The target is the check-in item that the model predicts. The operator selects it at G1.
- Read the target name from `ModelProvider`. Do not write "energy" as a fixed word in the code.
- Until G3 closes, `MockModelProvider` gives the target "energy".
- In this file, `<target>` is the target name. Example: "Your energy check-in was 4."

### 1.4 Shared states

Each experience shows exactly one of these states. It never shows a guessed number (PLAN.md Section 7, check 4).

| State | When | What the user sees |
| --- | --- | --- |
| Ready | The data inputs pass the thresholds in the section. | The experience. |
| Not enough data | A data threshold fails. | One sentence that names the missing data. A progress line, for example "3 of 7 days with a check-in". No chart, no number for the missing value. |
| Permission denied | A sensor that the inputs need has no permission. | "Tells needs <permission> for this." A button that opens the permission onboarding screen (P1.4). |
| Not on this Mac | The hardware is not on this Mac. | "This Mac does not have <hardware>." The experience gives its fallback, if the section has one. |
| Practice | `MockModelProvider` is active (before G3). | The experience works with mock data. A banner on top says: "Practice mode. The Mac guess comes from a test model." |

- Each state has a unit test (check 4).
- Do not use a force unwrap. Do not use an empty `catch`.

### 1.5 Data thresholds (D-027)

These numbers apply to all sections. A "typing window" is one 5-minute feature row with 20 or more key presses.

| Name | Value |
| --- | --- |
| Usable typing day | 12 or more typing windows on that day (1 hour of typing). |
| Labeled day | A day with a saved check-in for `<target>`. |
| Model prediction for today | `ModelProvider` returns a value. It needs 12 or more feature windows today. |

### 1.6 Check-in before prediction

PLAN.md Section 4.4 requires the label before the model guess.

- Do not show today's prediction in an experience until today's check-in is saved.
- If today has no check-in, show the daily check-in (P2.6) in place of the prediction.
- After the user saves the check-in, show the prediction.
- Predictions for past days can show at all times.

### 1.7 Where an experience opens (D-023)

- All experiences open in one shared SwiftUI `Window` with the ID `insights`.
- The window size is 520 x 440 pt. The title is the experience name.
- The window shows one experience at a time. A new menu choice replaces the current experience.
- When the window closes, stop all `Task` work, audio and haptics of the experience (check 8).

---

## 2. Radial menu (D-021, D-022)

The radial menu is the same for all 3 companion concepts. Only the item shape changes (pebble, light or leaf, see `design/companion-concepts.md`).

**How the user opens it.**

1. Click the companion once. Do not drag.
2. The companion plays its click reaction (less than 0.3 s).
3. The 7 items move out to their positions on a circle around the companion.
4. Click an item. The menu closes and the `insights` window opens that experience.
5. To close the menu with no choice, click the companion again or push Esc.

If the companion is in the Asleep state, the first click wakes it. Then the menu opens.

**Layout.**

- The item centers are on a circle with a radius of 76 pt from the companion center.
- Each item is a 28 pt circle with one glyph from SF Symbols.
- Item 1 is at the 12 o'clock position. The other items follow clockwise, with 360/7 degrees between them.
- If an item is off the screen, put all items on a 180 degree arc that points to the screen center.
- When the pointer is on an item, show the experience name in a small label next to it.
- An item in the "Not enough data" state shows at 50% opacity. It still opens. The experience then shows its "Not enough data" state.

**Order and glyphs.**

| Item | Experience | SF Symbol |
| --- | --- | --- |
| 1 | You vs. your Mac | `questionmark.circle` |
| 2 | Typing rhythm sound | `waveform` |
| 3 | Ghost racer | `keyboard` |
| 4 | What-if sliders | `slider.horizontal.3` |
| 5 | Haptic week | `hand.point.up.left` |
| 6 | Experiment | `flask` |
| 7 | In-the-moment nudge | `bell` |

**Keyboard and VoiceOver.**

- When the menu opens, item 1 has the focus.
- Push the Right arrow or Tab to move the focus clockwise. Push the Left arrow or Shift-Tab to move it counterclockwise.
- Push Return or Space to open the item with the focus.
- Each item has an accessibility label with the experience name and its state, for example "Haptic week, not enough data".

**Needs from the `InsightExperience` protocol (for P1.2).** The radial menu needs these values from each plugin: an ID, a display name, a glyph name, a menu order, a function that gives the current shared state (Section 1.4), and a SwiftUI view.

---

## 3. You vs. your Mac

**Purpose.** The user and the model each guess today's `<target>` check-in. A score shows who is closer more often.

**Rule.** The user saves today's check-in label before the model guess shows. The model guess must not change the label.

**User steps (D-024).**

1. Open the experience from radial menu item 1.
2. If today has no forecast and no check-in, the experience asks: "What will your `<target>` check-in be today?" The user selects 1 to 5. This is the forecast.
3. If today has no check-in, the experience shows the daily check-in (P2.6): energy, mood and social connection, each 1 to 5. The user saves it. This is the label.

   Warning: do not show the Mac guess before the check-in is saved. Do not show the Mac guess in the check-in view.

4. The experience then shows 3 values next to each other: your forecast, the Mac guess and your check-in.
5. The closer guess wins the day. If the two errors are within 0.25 of each other, the day is a tie.
6. The score line shows the total, for example "You 6, Mac 4, Tie 2".
7. If the user opens the experience after the check-in and gave no forecast, step 2 is not possible. Show the Mac guess next to the check-in. Do not add the day to the score.

**Data inputs.**

- The user forecast: one integer, 1 to 5. Keep it in `UserDefaults` with today's date. Delete it after the reveal or at the end of the day.
- Today's check-in label from `FeatureStore`.
- Today's prediction from `ModelProvider`, rounded to one decimal place.
- The score: 3 integers (you, Mac, tie) in `UserDefaults`. Each day adds to the score one time only.

**Frameworks.** SwiftUI.

**Text.**

- "The Mac predicted 3.6. Your check-in was 4. Your forecast was 3."
- "The Mac guess was closer today."
- Do not write that the Mac "knows" why.

**Not enough data.**

- No model prediction for today: save the check-in. Then show "Not enough data today for a Mac guess. Your check-in is saved." Show your forecast and check-in only. Do not add the day to the score.
- Before G3: the Practice state (Section 1.4). Practice days do not go into the real score. Keep a separate practice score, and reset it when G3 closes.

---

## 4. Typing rhythm sound

**Purpose.** The user listens to today's typing rhythm as a beat. A second beat plays the rhythm of a reference day.

**Reference day (D-025).** The labeled, usable typing day with the highest `<target>` check-in in the last 30 days. If two days have the same score, use the newer day. Do not include today.

**User steps.**

1. Open the experience from radial menu item 2.
2. Push "Play today". The beat plays for 30 s.
3. Push "Play reference day". The beat of the reference day plays for 30 s.
4. Push "Play both" to hear today on the left channel and the reference day on the right channel.
5. A thin timeline shows the hours of the day. A marker moves along it while the sound plays.
6. Push Stop or close the window to stop the sound.

**Data inputs.** The typing feature rows of today and of the reference day. Each typing window needs:

- the mean time between key presses,
- the variation of the time between key presses,
- the number of key presses.

Use the names that the P2.1 extractor gives. Do not read raw key events.

**Sound mapping (D-032).**

- Put the typing windows of one day in time order. Each window becomes one bar of the beat.
- Divide 30 s by the number of windows to get the bar length.
- Mean time between key presses sets the number of ticks in the bar. A shorter time gives more ticks, from 2 to 8.
- Variation sets the timing swing of the ticks. More variation gives more swing.
- The number of key presses sets the volume, from 30% to 100%.
- Windows without typing are silent bars.
- Make each tick with a short synthesized click (sine, 5 ms, 1 kHz). Do not use audio files of other works.

**Frameworks.** `AVAudioEngine` with an `AVAudioSourceNode` that synthesizes the ticks. Do not use the microphone input node. Do not record audio.

**Text.** "Today's rhythm, next to your highest `<target>` day of the last 30 days." Do not write that the rhythm causes the score.

**Not enough data.**

- Today is not a usable typing day: "Not enough typing today. 5 of 12 windows." Disable "Play today" and "Play both".
- No reference day: "No reference day yet. Tells needs one day with a check-in and 1 hour of typing." Disable "Play reference day" and "Play both".
- No audio output device: show the timeline only, with the text "No sound output is available."

---

## 5. Ghost racer

**Purpose.** The user types a short sentence. A ghost cursor moves at the typing rhythm of the reference week.

**Reference week (D-025).** The 7-day period in the last 30 days with the highest mean `<target>` check-in. It needs 5 or more labeled days and 3 or more usable typing days. Do not include today.

**User steps.**

1. Open the experience from radial menu item 3.
2. The experience shows one sentence from a built-in list of 20 original sentences. Each sentence has 40 to 60 characters.
3. Push "Start". A 3-second count-down starts.
4. Type the sentence in the field. The ghost cursor moves along the same sentence above the field.
5. When the user types the last character, show the result: your time and the ghost time, in seconds.
6. Push "Again" to get a new sentence.

**Data inputs.**

- The ghost: the median time between key presses and its variation, from the typing windows of the reference week.
- The ghost moves one character for each step. Each step is the median time plus a random value from the variation. Use a fixed random seed for each sentence, so the ghost is the same each time.
- The user: key times from the text field, in memory only. The view compares each typed character with the sentence to color it correct or wrong.

**Privacy.** Hard rules 1 and 3 require these steps. They are not defaults.

- Keep the typed characters only in the view state. Clear them when the round ends or the window closes.
- Do not save the typed text. Do not write it to a log.
- Do not save the race result. It shows only during the round.

**Sensor rule (D-026).**

- The keyboard timing sensor must ignore key events while the `insights` window is the key window. Thus, typing in Ghost racer does not go into the typing features.

**Frameworks.** SwiftUI for the field and the result. `Canvas` with `TimelineView` to draw the sentence and the ghost cursor.

**Text.** "The ghost types at the rhythm of your highest `<target>` week." Do not write "your best week". Do not write that a faster rhythm gives a better score.

**Not enough data.** No week passes the reference week rule: "Not enough data for a ghost yet. 3 of 5 days with a check-in in one week." The user can still type the sentence. Show the user's time only, with no ghost.

---

## 6. What-if sliders

**Purpose.** The user moves a slider for one daily habit. A chart shows how the model prediction changes.

**Slider set (D-031).** Show a slider only if the accepted model uses that feature.

| Slider | Feature source | Range |
| --- | --- | --- |
| Bedtime | Sleep window start estimate (P2.2) | The user's minimum to maximum in the last 30 days |
| Late scrolling | Minutes of input after 22:00 (P2.2) | The user's minimum to maximum in the last 30 days |

- Do not let a slider go outside the user's own range. The model has no data there.
- Start each slider at today's value. If today has no value, start it at the 30-day median.

**User steps.**

1. Open the experience from radial menu item 4.
2. If today has no check-in, the experience shows the daily check-in first (Section 1.6). The user saves it. Do not show the chart before this.
3. Move one slider.
4. The chart shows the predicted `<target>` for each slider value, as a line. A point shows the current slider value.
5. The text below the chart gives the prediction at today's value and at the slider value. It also gives today's saved check-in.
6. Push "Reset" to move the sliders back to today's values.
7. Push "Test it" to open the Experiment (Section 8) with the matching change selected.

**Data inputs.**

- Today's feature vector.
- The 30-day range of each slider feature, from `FeatureStore`.
- `ModelProvider` predictions for changed feature vectors. Change only the slider feature. Keep all other features at today's values.

**Frameworks.** SwiftUI for the sliders. Swift Charts (`LineMark` and `PointMark`) for the chart.

**Text.**

- "The model predicts a `<target>` check-in of 3.8 with a 23:00 bedtime. With today's 00:30 bedtime, it predicts 3.4. Your check-in today was 3."
- Show this text only after today's check-in is saved (Section 1.6).
- Below each chart: "This is a prediction from your past days. It does not show a cause. To test a change, use Experiment."

**Not enough data.**

- No model prediction for today: "Not enough data today for a prediction."
- The model uses none of the slider features: "The current model does not use bedtime or late scrolling." Show no chart.
- Fewer than 7 days of the slider feature: "Not enough days to make a range. 4 of 7 days." Hide that slider.
- Before G3: the Practice state. `MockModelProvider` must declare both slider features.

---

## 7. Haptic week

**Purpose.** The user moves a finger across a strip on the trackpad. The trackpad gives a bump on each low day of the last 7 days.

**Low day (D-030).** A labeled day with a `<target>` check-in 1 point or more below the user's 30-day mean.

**User steps.**

1. Open the experience from radial menu item 5.
2. The window shows a strip with 7 columns, one for each day. The oldest day is on the left. Each column shows the weekday name.
3. Move the pointer slowly across the strip with one finger.
4. When the pointer goes into a low-day column, the trackpad gives one bump.
5. When the pointer goes into the lowest day of the week, the trackpad gives two bumps, 80 ms apart.
6. Click a column to show that day's check-in score below the strip.

**Data inputs.** The daily summaries of the last 7 days, with the `<target>` check-in. The 30-day mean of the `<target>` check-in.

**Frameworks.** `NSHapticFeedbackManager.defaultPerformer`, with the `.levelChange` pattern and `.now` performance time. SwiftUI with an `onContinuousHover` modifier on the strip.

**Visual fallback.** Each low-day column also has a small raised mark. Thus, the experience works with VoiceOver and with no haptics. VoiceOver reads each column, for example "Tuesday, energy check-in 2, low day".

**Text.** "Bumps show days with a check-in 1 point or more below your 30-day average." Do not write "bad day".

**Not enough data.**

- Fewer than 4 labeled days in the last 7 days: "Not enough check-ins this week. 3 of 4 days." Show the columns with no marks.
- Fewer than 7 labeled days in the last 30 days: "Not enough check-ins to make an average. 5 of 7 days."
- Not on this Mac: if no Force Touch trackpad is connected, the bumps do not play. Show "This Mac has no Force Touch trackpad. The marks show the low days." Use the visual fallback.

---

## 8. Experiment

**Purpose.** The user selects one change for one week. Tells compares the check-ins of the week before and the week of the change.

**Change list (D-028).** All changes are about Mac use, because Tells can measure Mac use.

| Change | How Tells measures if the user did it |
| --- | --- |
| Stop Mac use by 23:00 | Last input time of the day (P2.2) |
| No Mac input after 22:00 | Minutes of input after 22:00 (P2.2) |
| Take a 5-minute break each 90 minutes | Idle gaps of 5 minutes or more (P2.2) |
| Fewer app switches | App switch rate (P2.3) |

**User steps.**

1. Open the experience from radial menu item 6.
2. Select one change from the list.
3. Read the text: "Do this change for 7 days. Do your check-in each day."
4. Push "Start". The experiment starts at the next midnight.
5. During the week, the experience shows the day number and a mark for each day that the user did the change.
6. After 7 days, the experience shows the result.
7. Push "End" at any time to stop the experiment. A stopped experiment shows no result.

Only one experiment can run at a time.

**Data inputs.**

- The experiment record: change ID, start date and end date. Keep it in `UserDefaults`. Do not save text.
- Week before: the 7 days just before the start date. Week of change: the 7 days from the start date.
- The `<target>` check-in labels of both weeks.
- The feature that measures the change, for each day of the week of change.

**Result method.**

- The result is the mean `<target>` check-in of the week of change minus the mean of the week before.
- Give a bootstrap 95% confidence interval with 2000 resamples.
- Give the number of days that the user did the change.

**Frameworks.** SwiftUI. Swift Charts (`BarMark`) for the two weekly means, with the interval as a `RuleMark`.

**Text.**

- "During the change week, your `<target>` check-ins were 0.6 higher on average (95% range: -0.1 to 1.3). You did the change on 6 of 7 days."
- "One week is a small test. Other things in your week can also change your check-ins."
- If the interval includes 0: "This result can be chance."
- Do not write that the change "improves" or "treats" anything.

**Not enough data.**

- Fewer than 5 labeled days in the week before or in the week of change: "Not enough check-ins for a result. Week before: 4 of 5 days." Offer "Add one more week" one time. This extends the week of change by 7 days.
- At the start, if the week before has fewer than 5 labeled days, show a warning before "Start": "Your last 7 days have 3 check-ins. The result can be not enough data."

---

## 9. In-the-moment nudge

**Purpose.** During work, the companion changes to the Drifting state when typing rhythm moves out of the personal baseline. The nudge has no text, no sound and no notification.

**Nudge rule (D-029).** `DriftDetector` gives a z-score for each typing window against the personal baseline for that hour (PLAN.md Section 6, Level 1).

- Drift starts when the absolute z-score is 2 or more for 3 typing windows in a row (15 minutes).
- At drift start, the companion plays one 1.5 s notice motion. Then it stays in the Drifting state.
- Drift ends when the absolute z-score is less than 1 for 2 typing windows in a row. The companion goes back to Normal.
- Play the notice motion a maximum of one time in 60 minutes.
- Do not play it while a full-screen app is active or during the quiet hours.

**User steps.**

1. Work as usual. The companion shows drift with its look.
2. Click the companion and open radial menu item 7.
3. The view shows: an on/off switch for the nudge, a sensitivity control and the quiet hours.
4. The view also shows the start and end times of today's drift periods, as a timeline.
5. Change a setting. It applies at once.

**Sensitivity values.**

| Sensitivity | z-score to start | Windows in a row |
| --- | --- | --- |
| Low | 2.5 | 4 |
| Medium (default) | 2.0 | 3 |
| High | 1.5 | 3 |

**Data inputs.**

- `DriftDetector` output for each typing window. It needs no labels.
- The settings: on/off, sensitivity and quiet hours in `UserDefaults`. Default quiet hours: none.
- Today's drift periods: start and end times only, in memory. Clear them at midnight.

**Frameworks.** SpriteKit for the notice motion and the Drifting state in the companion scene. SwiftUI for the settings view.

**Text.**

- Timeline label: "Your typing rhythm was outside your usual range."
- Do not write "you are tired" or a word from the list in Section 1.1.

**Not enough data.** The baseline needs 3 usable typing days.

- Until then, the companion stays in the Normal state. It does not show drift.
- The view shows: "Tells is learning your usual rhythm. 2 of 3 days."
- If Input Monitoring permission is denied, the view shows the Permission denied state (Section 1.4).
