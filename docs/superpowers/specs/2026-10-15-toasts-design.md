# Claude Bubble — Toasts

Date: 2026-10-15
Source design: `~/Downloads/Claude session status indicator (6)/Pip Sounds.dc.html` (toast stack + `outcome="success"`)

## Goal

Small decoded "toasts" under the orb that announce what just happened: a session started, needs you, hit an error, finished, went back to work, or everything finished. Each is readable at a glance, and the stack fans open on hover.

## Toasts

| Kind | Text | Colour | Lifetime | From |
|---|---|---|---|---|
| started | "started" | working swatch | 4s | pip spawned |
| needs | "needs you" | needs swatch | 8s | → needs |
| error | "hit an error" | error swatch | 8s | → error |
| finished | "finished" | pearl `#f1effa` | 6s | → done (idle) |
| resumed | "back to work" | working swatch | 3.5s | → working *from needs or error only* |
| allDone | "All sessions complete" (name "All sessions") | success mint | 6s | all-done merge, shown 0.45s later |

- **Content:** each toast shows the session's display name and the text.
- **Cap:** at most 5 are shown. A sixth hides the oldest.
- **Hover:** lifetimes pause while the pointer is over the stack.

## Layout (`ToastQueue.layout`)

Showing toasts are ordered newest first (k = 0, 1, …).

- **Collapsed:**
  - top = 6 + 7k
  - scale = 1 − 0.055k
  - opacity = 1 − 0.3k (0 for k > 2)
  - blur = 1.2 · min(k, 3)
- **Expanded (stack hovered):** top = 6 + 40k, scale 1, opacity 1, blur 0.
- **Leaving:** keeps its k, then rises 8pt, scales to 0.94 and fades out over about 0.45s. It is removed after 0.7s.
- **Stack height:** 0 when empty. Collapsed: 40 + 7 · min(n − 1, 2). Expanded: 6 + 40n.

## Decode entrance (`ToastDecode`)

The decode runs from p = 0 to p = 1 over 0.48s.

- **Letter reveal:** each non-space character i of a string of length L resolves once p ≥ 0.1 + 0.55 · i/L + 0.1 · rnd. Until then it shows a glyph from `▓▒░█<>/\_=+*#01:;`, re-rolled every 45ms.
- **Visual layers** (app):
  - red/cyan text fringes ±(3.2(1−p)²)pt fading with (1−p);
  - scanlines and a sweep fading with (1−p);
  - a flash in the toast's colour at opacity 0.35(1−p)⁴;
  - occasional sideways jitter while p < 0.55;
  - the dot flickers while p < 0.4;
  - a reveal mask growing from the top centre over 0.8s.

## Placement and panel

- **Panel:** a click-through floating panel attached to the orb (a child window, like the hover list), centred under the orb with its top 1.49 orb radii below the orb's centre, which is below the pips.
- **Flip:** when there's no room below on the orb's screen, it goes above the orb (bottom edge 1.49 orb radii above the centre). It then mirrors: the newest toast sits nearest the orb and the stack grows upward.
- **Hover:** expanding is computed from the pointer being inside the stack's area; the panel never takes clicks.
- **Hover list open:** the toasts hide while the list is open and return when it closes, with timers still running.

## Orb

- **Pull:** every toast except "started" gives the orb a small downward taffy pull: `OrbAnimator.pull(towards:amplitude: 0.32)`. When the toasts are above the orb, it pulls upward.
- **Success colour:** the all-done green becomes the design's mint success palette: c1 [.74, 1, .84], c2 [.5, .88, .7], c3 [.9, 1, .92], halo [.1, .3, .18]. The timing is unchanged.

## Settings

- **Preference:** `toasts: Bool`, default on, tolerant of decoding older saved settings.
- **Controls:** a Settings → Display "Show toasts" toggle, and a right-click "Toasts" item.

## Testing

- **ToastQueue:** event → toast mapping (resumed only from needs/error), lifetimes, hover pause, cap, collapsed and expanded layout, leaving, stack height.
- **ToastDecode:** p = 0 is fully scrambled, p = 1 is the original, spaces are kept, and letters reveal left to right.
- **Animator:** pull amplitude.
- **Preferences:** the toasts default and older saved settings.
- **By hand:** the look, through the Session Simulator.
