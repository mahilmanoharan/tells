# Tells

A little plant named Sprout lives on your Mac's desktop. Tells watches *how* you use your Mac (typing rhythm, idle gaps, app switching) and never *what* you do. Over time a personal model learns your patterns, and Sprout shows you what it noticed.

Everything stays on your Mac. No keys, no text, no URLs, no window titles, no network.

## Where it's at

| Stage | What it is | Status |
| --- | --- | --- |
| 0. Design | Spec, privacy rules, companion design | done |
| 1. Skeleton | App, packages, tests, menu bar | done |
| 2. Sensors | Typing timing, activity, app switches → 5‑min feature rows, daily check-in, export | done |
| 3. Model | Train the personal model (needs ~14 days of your data) | waiting on data |
| 4. Companion | Sprout's moods, radial menu, insight screens | Sprout, moods and click menu done, insight screens next |
| 5. More sensors | Extra Mac hardware signals | later |
| 6. iPhone-ready | Make the core run on iOS | later |

**Latest:** click Sprout and a ring of 7 buttons pops out, one per insight screen. The screens are placeholders for now; the first real one ("You vs. your Mac") is next. Works with arrow keys and VoiceOver too.

**Your to-dos:** grant Input Monitoring, let it run for 72 hours, check in daily for 14 days.

## Run it

```sh
brew install xcodegen
xcodegen generate
open Tells.xcodeproj      # run the Tells scheme
```

Tests: `scripts/test.sh` (it prints PASS or FAIL at the end).

## Layout

- `TellsCore/`: pure Swift: feature math, storage, model plumbing (macOS + iOS)
- `TellsMac/`: Mac sensors and the Sprout companion
- `App/`: the menu-bar app itself
- `tasks/`, `STATE.md`, `DEFAULTS.md`, `DECISIONS.md`: how the agents plan and track the build
