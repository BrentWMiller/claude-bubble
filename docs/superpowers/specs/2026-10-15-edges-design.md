# Claude Bubble — Pips that stay on screen, and a screen edge light

Date: 2026-10-15
Source: the user's screenshots (an orb half off the right edge with pips beside it; a quarter orb in a corner; "Edge light" along the bottom and right edges).

## 1. Pips rotate to stay on screen

The pip arc keeps its radius, its 11° step and its order. The whole arc rotates around the orb (`around`, degrees in view space, y-down; 90 = straight down) until every pip is on screen.

### Choosing the angle (`PipArc.around`, core)

- **Inputs:**
  - the orb's centre in screen coordinates;
  - the arc radius;
  - the number of slots;
  - the visible frame of the screen the orb is on. When the centre is off every screen, this is the screen nearest to it.
- **Candidates:** every 5° around the circle.
- **Pick:**
  - a candidate is "clear" when every slot's centre is at least 16pt inside the visible frame;
  - pick the clear candidate nearest to straight down;
  - if none is clear, pick the one with the most slots inside, nearest to down on ties;
  - once the arc has to turn, it turns 12° further (if that stays clear), so the pips sit comfortably on screen.
- **Default:** away from edges this is always 90 (unchanged behaviour).

### Applying it

- **When it's recomputed:**
  - when the orb moves;
  - when the orb changes size;
  - when the number of slots changes;
  - when displays change.
- **Easing:** the app eases the shown angle toward the target along the shortest way around (time constant about 0.12s, ticked at 20Hz). So dragging swings the arc smoothly; it never jumps.
- **What follows the angle:**
  - `PipArc.position` and `PipArc.hit` take `around`;
  - so do the arc view, the pip card anchor and the spawn pull.
- **What doesn't:** sound panning stays on the slot order, as before.

## 1b. Dragging partly off screen

- **Our own drag** (not the system's) moves the orb.
  - **Left, right and bottom:** its centre may go half an orb radius past the screen's edges, which leaves about a third of the orb showing.
  - **Top:** the whole orb stays below the menu bar.
- **Saved position:** kept on relaunch while the orb's centre is within an orb radius of a screen.

## 2. Screen edge light

When the orb is near a screen edge, a thin light runs along that edge. It is brightest where the orb meets the edge and fades out along it. In a corner, both edges light.

### Geometry (`EdgeLight`, core)

- **Proximity:**
  - per edge of the orb's screen *visible* frame (so the light sits inside the menu bar and Dock), take the distance from the orb's centre to the edge;
  - an edge that meets another display is skipped (it isn't the edge of the desktop);
  - `strength = 1 − smoothstep(R, R + D, distance)`, where R is the orb radius and D its diameter;
  - a centre past the edge counts as distance 0.
- **Shape:**
  - the light is centred on the orb's projection onto the edge;
  - its falloff along the edge is `exp(−(x / L)²)`, where L = ⅓ of that edge's length, and it is cut off at 2L each side.
- **Output:** `strips(orbCentre:orbRadius:screen:) -> [EdgeStrip]`, one per edge with strength > 0.01. Each strip has its edge, its centre along the edge and its strength.

### Look

- **Colour:** the orb's current state swatch from the theme.
- **Activity:**
  - **Working:** 1.0, with a slow shimmer travelling outward from the orb.
  - **Needs:** breathing between 0.45 and 1 over 1.4s.
  - **Error:** 0.8 with a light flicker.
  - **Idle:** 0.35.
- **Drawing:**
  - a 2pt core line on the edge;
  - a soft 14pt glow fading inward;
  - additive-looking, over everything except the orb.
- **Display corners:** the physical rounded corners mask the strip ends.

### Panels

- **Windows:** up to four thin click-through panels (one per edge), created lazily.
  - They sit at the orb's window level, just below the orb.
  - They ignore the mouse and join all Spaces.
  - Each covers its strip's length × 16pt.
- **Hidden:**
  - when its strip has no strength;
  - when the orb is hidden or popping out;
  - when Edge light is turned off.
- **Easing:** strength eases (0.25s) so the light fades in and out while dragging. A fading light stays where it was (even if the orb changed displays). When the orb hides, the light hides at once.

### Setting

- **Preference:** `edgeLight: Bool`, default on, decoded tolerantly.
- **Controls:** a Settings → Display "Edge light" toggle, and a right-click "Edge Light" item.

## Testing

- **PipArc.around:**
  - 90 in open space;
  - near the right edge it turns toward the left side;
  - near the bottom it goes up;
  - in a corner it points diagonally inward;
  - with the orb half off-screen, every slot ends up inside;
  - positions and hit tests use `around`.
- **EdgeLight:**
  - no strips in open space;
  - one strip near an edge, at full strength when touching or past it;
  - two strips in a corner;
  - the centre along the edge follows the orb;
  - the falloff cutoff.
- **Preferences:** the edgeLight default, and older saved settings.
- **By hand:** dragging the orb to each edge and corner.
