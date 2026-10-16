# Claude Bubble — Island mode

Date: 2026-10-15
Source design: `~/Downloads/Claude session status indicator (8)/Top Island.dc.html`

## Goal

A second presentation style: instead of the floating orb, a black pill docked to a screen edge. It shows a miniature orb, the current activity and the session pips. It widens on its own when something needs you, fails or finishes, and opens into the session panel on hover.

## Settings

| Preference | Values | Default |
|---|---|---|
| `style` | orb, island | orb |
| `islandDock` | top, bottom, left, right | top |
| `islandRest` | live, compact | live |
| `islandGlow` | waves, none | waves |

- **Saved settings:** all four decode tolerantly from older saves.
- **Settings → Display:** a Style picker. The island options show while Style is Island.
- **Menus:** a right-click / menu-bar "Style" submenu (Orb, Island), and an "Island Dock" submenu while in island mode.
- **When Style is Island:** the floating orb panel, its pips, the edge light, the orb hover card and the pip card are hidden. These carry on through the island's orb:
  - toasts;
  - sounds;
  - usage (tint, low-usage mode, footer);
  - work motions and layers;
  - the completion moment.

## Placement (`IslandLayout`, core)

- **Window:** one click-through window, 380 × 440pt, on the island's display.
  - The display is the one under the pointer when Follow the Pointer is on, otherwise the main display.
  - The window never moves or resizes while you use it. The pill inside it animates.
- **Window position per dock**, against the display's visible frame (so the top dock sits just under the menu bar, not over the notch):
  - **top:** centred, flush with the top;
  - **bottom:** centred, flush with the bottom (above the Dock);
  - **left:** flush with the left edge, vertically centred;
  - **right:** flush with the right edge, vertically centred.
- **Pill position:** inside the window, the pill is anchored to the docked edge, centred along it. Its corners are rounded (22pt) on the open side only.
- **Mouse:** only the pill takes the mouse. The rest of the window passes clicks through.

## Modes (`IslandMode`, core)

The highest-priority mode that applies wins: **hover → needs → error → done → rest**.

| Mode | When | Size (w × h) |
|---|---|---|
| hover | the pointer has been over the pill for 0.6s (the existing hover delay; it closes 0.35s after leaving) | 350 × (46 + 49 × rows + 34), at least 1 row |
| needs | any session needs you (most urgent first) | 360 × 98 |
| error | a session entered error within the last 3.5s | 360 × 98 |
| done | within 4.5s of the all-done moment | 300 × 44 |
| rest, live | otherwise | 290 × 44 |
| rest, compact | otherwise, compact | 130 × 44 |
| rest, side dock | otherwise, docked left or right | 44 × (8 + 28 + (n > 0 ? 10 + 5n + 4(n − 1) : 0) + 12), where n = pips (up to 5) |

- **Side docks** use the horizontal sizes whenever the mode isn't rest.
- **Size changes** use a slightly springy animation (response 0.5, damping 0.72).

### Content

- **Bar** (every mode except side rest):
  - a 28pt orb (the shared animator, rendered by its own Metal view);
  - text;
  - pips (5pt, up to 5, the theme's status colours; needs and error glow). Live rest shows the pips on the right.
- **Bar text:**
  - **rest:** the focus session's status line (its `detail`), "Idle", or "No sessions";
  - **needs:** "‹name› needs you", in the needs colour;
  - **error:** "‹name› hit an error", in the error colour;
  - **done:** "All sessions complete", in the success green;
  - **hover:** "Sessions".
  - **Compact rest:** no text.
- **needs / error:** under the bar, the session's detail (the question, or the error) and its project.
- **hover:** the session rows and the Today footer (with usage), the same views as the hover card.
- **Side rest:** the orb, with a column of pips under it.

### Glow ("waves")

- **Dot-wave:** a rolling dot-wave inside the pill, radiating from the orb. It is a 4pt dot grid; each dot is pushed and lit by two travelling sine waves warped by angle (ported from the design's canvas).
  - **Colour:** the state colour (working: the theme's working colour; needs, error, idle: theirs; done: the success green).
  - **Speed:** 0.5 at idle, 1.6 for needs or error, 1.1 otherwise.
  - **Brightness:** it brightens briefly on tool ticks.
- **Inner glow:** a soft radial glow behind the orb, breathing.
- **Rim:** a 1pt inset rim in the state colour, at 6–10% opacity.
- **"none":** a plain black pill with a soft drop shadow.

## Toasts (`ToastLayout.placeIsland`, core)

- **top:** under the pill (12pt gap), centred.
- **bottom:** above the pill, flipped.
- **left / right:** under the pill, aligned to the docked edge.

The frame is always pulled fully on screen. Toasts hide while the island is in hover mode.

## Interaction

- **Click:** clicking the pill focuses the terminal, as the orb does. The island can't be dragged.
- **Right-click:** opens the usual orb menu.
- **Hidden:** Hide Bubble hides the island too.

## Testing

- **Preferences:** the defaults, and older saved settings.
- **IslandMode:**
  - the priority order;
  - the error window (3.5s);
  - the done window (4.5s);
  - hover overriding everything;
  - needs choosing the most urgent session.
- **IslandLayout:**
  - the size for each mode, rest style and dock;
  - side rest with 0, 1 and 5 pips;
  - the window frame for each dock;
  - the pill rect for each dock.
- **ToastLayout.placeIsland:** each dock, and always on screen.
- **By hand:** offscreen renders of each mode, then live through the Simulator.
