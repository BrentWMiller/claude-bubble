# Claude Bubble — Settings: colors, size, opacity, follow the pointer

Date: 2026-10-15
Builds on: `2026-10-15-claude-bubble-design.md`, `2026-10-15-multi-session-design.md`

## Goal

Let the user make the orb look and sit how they like: per-state colors with presets, orb size and opacity, and an option for the orb to follow the pointer between displays. Every change applies live and persists across restarts and rebuilds.

## Scope

- **In:**
  - Settings window
  - three palette presets plus per-state custom colors
  - size and opacity sliders
  - follow-the-pointer toggle
  - persistence
- **Out:**
  - export/import of themes
  - per-display positions (the user chose one shared relative spot)
  - changing motion (wave, speed)
  - list panel styling

## Settings window

- **Opening it:** the menu-bar menu gets **Settings…** (⌘,). The window is a standard titled macOS window hosting a SwiftUI form in grouped style, 420pt wide. Opening it activates the app; there is still no Dock icon.
- **Colors section:**
  - a **Preset** picker: "Agents view" (the default), "Original design", "Blue";
  - one color well each for **Idle**, **Working**, **Needs you** and **Error**, showing that state's swatch (pip) color;
  - a **Reset to preset** button.
  - Picking a color marks the palette customized; the picker then shows the preset name followed by " (customized)". Choosing a preset, or Reset, replaces all four states with that preset.
- **Orb section:**
  - a **Size** slider, 40–160pt orb diameter, step 1, default 72, with the value shown;
  - an **Opacity** slider, 30–100%, default 100%, with the value shown.
- **Display section:** a toggle, **Follow the pointer to other displays**, default off.
- Every control applies immediately and saves immediately.

## Palettes

- `StateColors`: `c1`, `c2`, `c3`, `halo` (the shader colors) and `swatch` (the flat color for pips, row text fallback and color wells).
- `OrbPalette`: one `StateColors` per `BubbleState`, Codable.
- **Presets** (exact values):
  - **Agents view:** the current values. Idle green `c1 [0.42,0.88,0.56] c2 [0.22,0.62,0.4] c3 [0.72,0.96,0.78] halo [0.06,0.3,0.14]`. Working, error and needs as they are in `OrbParams` today. Swatches: idle c1, working c2, needs c1, error c1.
  - **Original design:** `PAL.claude` from the design's `orbParticles.js`.
    - Idle: `[.62,.66,.82] [.4,.44,.62] [.8,.82,.95] [.16,.18,.34]`
    - Needs: `[1,.72,.22] [1,.38,.24] [1,.86,.55] [.6,.24,.08]`
    - Working and error as today.
    - Swatches: working c2, the others c1.
  - **Blue:** `PAL.blue` from `orbParticles.js`.
    - Idle: `[.55,.6,1] [.35,.38,.85] [.7,.8,1] [.08,.1,.45]`
    - Working: `[1,.3,.9] [.3,.78,1] [1,.72,.6] [.12,.1,.95]`
    - Needs and error the same as Original design.
    - Swatches: c1.
- **Deriving a custom color from base `B` (sRGB, 0–1):**
  - `c1 = B`
  - `c2` = B with hue −25°, the same saturation, and value × 0.75
  - `c3 = mix(B, white, 0.45)`
  - `halo` = B × 0.45
  - `swatch = B`
- Motion values (energy, wave, glow, and so on) are unchanged and stay per state in `OrbParams`.

## Size and opacity

- **Panel geometry:** panel side = diameter ÷ 0.6 (72 → 120). Everything already measured from the panel frame keeps working: the click hit test (`width × 0.3`), list anchoring (`orbRect`) and the renderer's point size.
- **Pips:** the row sits at `y = side × 0.033`, with a height of `min(14, side × 0.17)`.
- **Resizing** keeps the orb's center fixed, then clamps onto the screen.
- **Opacity** sets the bubble panel's `alphaValue`. The hover list stays fully opaque.

## Follow the pointer

- **Turning it on** records the orb's current relative spot: the panel center's fraction across and up the visible frame of the display it is on.
- **Each 50ms hover tick:** if follow is on and the display containing the pointer differs from the one containing the orb's center, move the orb to the shared relative spot on the pointer's display. The orb stays fully inside that display's visible frame.
- **Dragging** while follow is on updates the shared relative spot.
- **With follow off,** placement behaves exactly as before: a saved absolute origin, with fallback when that display is gone.

## Persistence

- `BubblePreferences` (Codable) is stored as a single JSON blob under the UserDefaults key `preferences`:
  - `palette`
  - `presetName`
  - `customized`
  - `diameter`
  - `opacity`
  - `followPointer`
  - `relativeSpot` (`[x, y]` or nil)
- **Loading:**
  - a missing or corrupt blob gives the defaults;
  - `diameter` is clamped to 40–160 and `opacity` to 0.3–1;
  - an unknown `presetName` falls back to "Agents view".

## Error handling

- A corrupt preferences blob falls back to the defaults and is not overwritten until the user changes something.
- A color that can't be converted to sRGB is ignored.

## Testing

- **Unit tests:**
  - the Agents view preset equals today's `OrbParams` colors;
  - the other two presets match the JS values;
  - derivation: `c1 == base`, c3 lighter, the halo darker, c2's hue shifted;
  - palette and preferences round-trip through JSON;
  - preference defaults and clamping, and a corrupt blob giving the defaults;
  - `RelativePlacement`: the relative-spot round trip, clamping on a smaller display, and the origin for a given spot;
  - `OrbSize.panelSide` and clamping;
  - the animator easing toward a changed palette.
- **By hand:** live sliders, color wells, presets and Reset; moving the pointer between displays with follow on; the settings surviving a Restart.
