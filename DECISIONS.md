# Decisions

The Architect owns this file. Add one entry for each decision. Do not delete entries. If a decision changes, add a new entry that points to the old one.

Entry format:

```markdown
## DEC-<n>: <title>
Date: YYYY-MM-DD
Options: <option A>; <option B>
Decision: <the selected option>
Reason: <one or two sentences>
```

## DEC-1: Companion concept
Date: 2026-11-21
Options: A Moss; B Wick; C Sprout (design/companion-concepts.md)
Decision: C Sprout.
Reason: Sprout has no face, so it does not look like it watches the user of an app that measures input. Leaf rotation costs less CPU than flame particles and glow, and the open, drooped and folded leaves show the states with no medical meaning.

## DEC-2: Feature row storage format
Date: 2026-11-21
Options: one row for each sensor for each window, with a name-to-value dictionary; one SwiftData model with one column for each feature
Decision: One `FeatureRow` for each sensor for each window. Values are a JSON `[String: Double]`. Each row has `schemaVersion`, UTC `windowStart`, `utcOffsetMinutes`, local `day` and `coverageSeconds` (SPEC.md Section 2.4).
Reason: New sensors and new schema versions need no SwiftData migration. Rows are deleted after 30 days, so the format must be correct before Phase 2 collects data.

## DEC-3: Tells day and night attribution
Date: 2026-11-21
Options: local calendar day, with the night before attributed to the day; a day that starts at 04:00
Decision: Day D is the local calendar date. Day features close at 04:00 on D+1. Night features (`activity.late_input_min`, `activity.sleep_*`) use 18:00 on D-1 to 14:00 on D.
Reason: The check-in of day D comes after the night before. Calendar dates are simple to compare with check-ins and to export.

## DEC-4: Phase 2 feature set, schema version 1
Date: 2026-11-21
Options: the names and formulas in SPEC.md Sections 3.2 and 3.3; a smaller set with only key count and median IKI
Decision: SPEC.md Sections 3.2 and 3.3 are schema version 1 of `keyboard`, `activity` and `appswitch`.
Reason: Old rows cannot be calculated again after 30 days (PLAN.md Section 6). A wide first set gives G1 more candidates. G1 still selects no more than 8 model features.

## DEC-5: Check-in label schema
Date: 2026-11-21
Options: one check-in for each day with energy, mood and social, each an optional integer 1 to 5; more than one check-in each day
Decision: One `CheckIn` for each day. A new save on the same day replaces it. An item can be skipped. Kept 30 days.
Reason: The model predicts one daily score (PLAN.md Section 6). Optional items keep a partial check-in useful.

## DEC-6: Daily summary content
Date: 2026-11-21
Options: summaries with 6 day features and no labels; summaries with labels
Decision: `DailySummary` keeps only the 6 names in SPEC.md Section 3.5. It has no check-in scores. It is kept until "Delete all data".
Reason: PLAN.md Section 4.3 keeps labels 30 days and summaries longer. Labels in summaries would keep labels longer than 30 days. Haptic week needs only 30 days of check-ins.

## DEC-7: App identity on disk
Date: 2026-11-21
Options: category only; bundle ID
Decision: Only the `AppCategory` (5 values, SPEC.md Section 3.4) goes into a sample. Bundle IDs and app names stay in memory. Activations of Tells are dropped.
Reason: A bundle ID can show private use. PLAN.md Section 6 needs only the category for normalization.

## DEC-8: Missing values
Date: 2026-11-21
Options: an absent key; NaN; 0
Decision: An absent key is a missing value. 0 is a measured zero. No row means the sensor did not run.
Reason: The model and the "not enough data" states must not read a missing value as zero (check 4).

## DEC-9: App Sandbox and network entitlements, Phases 1 to 4
Date: 2026-11-21
Options: App Sandbox on with no network entitlement; App Sandbox off
Decision: App Sandbox on. No network client or server entitlement. The store is in the app container. This confirms D-017 for Phases 1 to 4. GD-1 in `GATES.md` decides private sensors before P5.2.
Reason: The system then blocks network calls (hard rule 4). The listen-only event tap, idle time and `NSWorkspace` work in the sandbox. Confirm the event tap in P2.1.

## DEC-10: Hardware out of scope
Date: 2026-11-21
Options: add the lid angle sensor and headphone motion; leave them out
Decision: Leave them out. Answers to "Open points for the Architect" in design/hardware.md: the lid angle IDs and the shared hub question are not necessary; the sandbox point goes to GD-1.
Reason: PLAN.md does not list them. Adding a sensor changes the feature set, and that needs the gates (hard rule 7).

## DEC-11: Protocol location
Date: 2026-11-21
Options: `Sensor`, `SensorSample`, `FeatureExtractor`, `FeatureStore`, `ModelProvider` in `TellsCore` and `InsightExperience` in `CompanionUI`; `Sensor` in `MacSensors`
Decision: The first option (SPEC.md Section 2).
Reason: A future `IOSSensors` target can conform to `Sensor` with only `TellsCore`. `InsightExperience` returns a SwiftUI view, so it cannot be in pure `TellsCore`.

## DEC-12: Key event data
Date: 2026-11-21
Options: read no key code, pair key up to key down first-in first-out; read the key code in memory to pair holds
Decision: The tap callback reads only the event type, the time and the autorepeat flag. `SensorSample` has no key code field. Holds pair first-in, first-out.
Reason: Hard rule 2. A small hold error during key roll-over is acceptable.

## DEC-13: Retention rule
Date: 2026-11-21
Options: delete rows with a day before today minus 30 days, at start and at day close; delete by row age in hours
Decision: The first option (SPEC.md Section 4.3).
Reason: Whole days are simple to test and match the day features.
