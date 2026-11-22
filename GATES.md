# Gates

The loop stops when a gate is `open`. To close a gate, do the gate work in PLAN.md Section 6. Write your decision under the gate. Change the status to `closed`. Start the loop again.

| Gate | Status | Opens |
| --- | --- | --- |
| G0 Design | auto (`AUTO_APPROVE_DESIGN=true`) | End of Phase 0 |
| G1 Model design | not open | After 14 days of data |
| G2 Model test | not open | After the first training |
| G3 Model ship | not open | After G2 passes |

## G0 Design
No report yet.

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
