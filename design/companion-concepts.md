# Companion concepts (P0.2)

This file gives 3 original companion concepts. The Architect selects one in P0.4 (D-018).
Each concept has a look, the 5 states in PLAN.md Section 4.4, a click interaction and a 96 pt note.

## Common rules for all concepts

- The art is original. It does not use an existing character, brand, mascot or game asset.
- The window is a transparent, floating `NSPanel`. The art has no background rectangle.
- The canvas is 96 x 96 pt. The art stays inside an 88 x 88 pt safe area. Motion marks can use the full 96 pt.
- Each mock-up is one static key frame of the state (D-020). The text below gives the motion.
- Outlines are dark ink (`#2B2F33`), 2 to 2.5 pt. Loose marks (motion arcs, "z", tilde) have a light halo. Thus, the art shows on light and dark desktops.
- A soft shadow ellipse under the art shows that it floats.
- The companion shows no text and no numbers. It shows drift only through its look (Section 4.4).
- The companion does not show a medical label (hard rule 6). The state names are internal names. Do not show them to the user as a diagnosis.
- Idle motion is slow and small. This helps to keep idle CPU less than 2% (PLAN.md Section 7, check 5).
- Asleep: stop all animation after the transition. Show one static frame.

### Common click interaction (D-021)

- Single click: the companion plays a short reaction (less than 0.3 s). Then the radial menu opens around it.
- Each menu item is one insight experience. The items sit on a circle around the companion.
- Click an item to open that experience. Click the companion again or push Esc to close the menu.
- Drag: move the companion. A drag does not open the menu.
- In the Asleep state, a click wakes the companion first. Then the menu opens.

Each concept below gives its own reaction and its own menu item shape.

---

## Concept A: Moss

**Look.** A smooth, grey-blue river stone with a cap of green moss. It has two small dot eyes. It has no mouth in the Normal state.
The stone is wide and low. It is a stable shape, so it looks calm on the desktop.

| State | Mock-up | Look and motion |
| --- | --- | --- |
| Normal | `mockups/moss-normal.svg` | Dot eyes. The stone breathes: it scales up and down by 2% in a 4 s cycle. It blinks one time in each 6 to 10 s. |
| Drifting | `mockups/moss-drifting.svg` | Half-closed eyes. The stone tilts 8 degrees. The moss droops to one side. A slow tilde mark floats up. The breath cycle becomes 6 s. |
| Scattered | `mockups/moss-scattered.svg` | Wide eyes. The pupils move quickly left, right and up. Motion arcs show on the 2 sides. The stone turns a small amount each 0.5 s. |
| Social | `mockups/moss-social.svg` | Happy, curved eyes and pink cheeks. A small white flower opens in the moss. The stone hops 4 pt. Small sparkles show around it. |
| Asleep | `mockups/moss-asleep.svg` | Closed eyes. The stone becomes lower and flatter. The colors become darker. A "z z" mark shows. |

**Click.** The stone squashes down and springs back. The moss lifts. The menu items are small round pebbles. They roll out from under the stone to their positions on the circle.

**At 96 pt.** The stone fills approximately 64 x 50 pt. The wide shape has a strong silhouette on all desktops. The grey-blue fill shows on light and dark backgrounds. The dark outline separates it from grey windows. The eyes are 7 pt wide. They are the smallest detail that must show. At 48 pt, the eyes and the moss stay clear (tested on the contact sheet).

---

## Concept B: Wick

**Look.** A small lantern with a wood frame, a cap, a handle ring and paper panes. A flame burns inside.
The flame has no face. The flame size, color and glow show the state. The lantern itself tilts and swings.

| State | Mock-up | Look and motion |
| --- | --- | --- |
| Normal | `mockups/wick-normal.svg` | A medium, steady flame. A soft, warm glow around the lantern. The flame moves up and down by 1 pt in a 3 s cycle. |
| Drifting | `mockups/wick-drifting.svg` | A small, low flame. The panes and the glow become dim. The lantern leans 6 degrees. A slow tilde mark floats up. |
| Scattered | `mockups/wick-scattered.svg` | The lantern swings on its handle. The flame flickers from side to side. A faint second flame shows the last position. Motion arcs show above. |
| Social | `mockups/wick-social.svg` | A tall, bright flame. A large glow. Small sparks rise and fade above the lantern. |
| Asleep | `mockups/wick-asleep.svg` | No flame. One small ember and a thin line of smoke. The panes are dark grey. A "z z" mark shows. |

**Click.** The flame jumps up one time and the glow becomes bright for a moment. The menu items are small round lights. They float out from the lantern like sparks and stop on the circle.

**At 96 pt.** The lantern fills approximately 38 x 70 pt. It is tall and narrow, so it takes less desktop width than the other concepts. The glow is a radial gradient with no hard edge. Thus, it blends on all desktops. On a light desktop, the glow is faint. The dark frame outline then gives the silhouette. On a dark desktop, the glow is the most visible part. The flame is the smallest detail that must show. At 48 pt, the flame size is still easy to compare between states.

---

## Concept C: Sprout

**Look.** A small clay pot with one stem and two leaves. It has no face. The leaf position shows the state, like a plant that opens in the day and folds at night.

| State | Mock-up | Look and motion |
| --- | --- | --- |
| Normal | `mockups/sprout-normal.svg` | The 2 leaves are open and up. They sway 3 degrees in a 4 s cycle. |
| Drifting | `mockups/sprout-drifting.svg` | The stem bends to one side. The leaves droop down. The leaf color becomes less bright. A slow tilde mark floats up. |
| Scattered | `mockups/sprout-scattered.svg` | The leaves point in different directions. They turn quickly. Small tick marks and motion arcs show around the pot. |
| Social | `mockups/sprout-social.svg` | The leaves open wide. A pink 5-petal flower opens at the top of the stem. Small sparkles show. |
| Asleep | `mockups/sprout-asleep.svg` | The 2 leaves fold up together around the stem. The pot becomes darker. A "z z" mark shows. |

**Click.** The leaves open wide and the pot bounces 2 pt. The menu items are small round leaves. They grow out on short vines to their positions on the circle.

**At 96 pt.** The art fills approximately 64 x 60 pt. The terracotta pot is a fixed, heavy base. Only the leaves change, so the user learns the states from one area. Green leaves on a green desktop picture can be less clear. The dark outline prevents this problem. The leaf angle is the smallest detail that must show. At 48 pt, open, drooped and folded leaves are still different.

---

## Comparison for the selection in P0.4

| Item | Moss | Wick | Sprout |
| --- | --- | --- | --- |
| Has a face | Yes, eyes | No | No |
| Main state signal | Eyes and posture | Flame size and glow | Leaf position |
| Desktop width at 96 pt | Wide | Narrow | Medium |
| Risk | Eyes can feel like the companion watches the user. | The glow is faint on light desktops. | The states are less clear at very small sizes. |
| SpriteKit work | Body scale, eye sprites, moss sprite | Flame particles, glow node, swing | Leaf rotation, flower sprite |

## Originality check

- Moss is a generic stone with moss. It is not a slime, a blob mascot or a rock character from a game.
- Wick is a generic lantern. The flame has no face, so it is not a fire character from a film or a game.
- Sprout is a generic pot plant with no face. The flower is a simple 5-petal shape.
- No concept uses a logo, a brand color set or a name from a known product.
