# Gates

The loop stops when a gate is `open`. To close a gate, do the gate work in PLAN.md Section 6. Write your decision under the gate. Change the status to `closed`. Start the loop again.

| Gate | Status | Opens |
| --- | --- | --- |
| G0 Design | auto (`AUTO_APPROVE_DESIGN=true`) | End of Phase 0 |
| G1 Model design | not open | After 14 days of data |
| G2 Model test | not open | After the first training |
| G3 Model ship | not open | After G2 passes |

## G0 Design
Status: auto (`AUTO_APPROVE_DESIGN=true`). Reviewer: P0.5. Full report: `design/spec-review.md`.
- Hard rules: 9 of 10 pass. Rule 5 fails: SPEC.md 1.4 uses the undocumented `com.apple.screenIsLocked` notification in `SensorHub`, with no flag.
- Proposed fix: P0.6 (Architect) replaces it with a documented source, or puts it behind a flag. Do P0.6 before P2.2.
- Conflicts with PLAN.md: 3, each with a reason in SPEC.md.
  - C-1: Haptic week uses 30 days of check-ins, not daily summaries (DEC-6).
  - C-2: 30-day deletion starts in Phase 2, not P3.4 (DEC-13). Close G1 to G3 fast, or old rows are deleted.
  - C-3: "Rested" day and week are the highest `<target>` check-in (D-025).
- One-way decisions DEC-1 to DEC-13 pass under auto-approval. The operator can read them in `DECISIONS.md`.

## G1 Model design
No report yet.

## G2 Model test
No report yet.

## G3 Model ship
No report yet.

## GD gates (one-way defaults)

| Gate | Status | Opens |
| --- | --- | --- |
| GD-1 App Sandbox for private sensors | not open | Before P5.2 starts |

### GD-1 App Sandbox for private sensors
Opened by: P0.4 (Architect). Not open yet. It does not block Phases 1 to 4.
Question: Can the app turn App Sandbox off for the private sensors in P5.2 to P5.4?
Facts: design/hardware.md says the trackpad wrapper needs App Sandbox off, and the IOKit paths for light and motion can need it off. DEC-9 keeps App Sandbox on with no network entitlement in Phases 1 to 4.
Why one-way: Sandbox off moves the store out of the app container, and the system no longer blocks network calls (hard rule 4).
Options: (a) keep App Sandbox on and drop sensors that need it off; (b) a separate helper without sandbox for the private sensors only; (c) App Sandbox off for the app.
Recommendation: (a) first. Test each private sensor in the sandbox. Use (b) only if the operator wants that sensor.
Decision: none yet.
