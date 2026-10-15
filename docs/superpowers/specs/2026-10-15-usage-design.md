# Claude Bubble — Usage and time till reset

Date: 2026-10-15
Source design: the "Usage" mock (color temperature, hover card footer, threshold toasts, low-usage mode). The mock's own hover card is not used; our existing card gains the footer.

## Goal

Show how much of the 5-hour usage window is left, and how long until it resets, without adding an alarm. The orb slowly warms as usage runs down, the hover card's footer says the numbers, a toast marks each threshold, and under 10% the orb quiets down.

## Data

### Status line wrapper

Claude Code passes the status line JSON on stdin, including `rate_limits.five_hour.used_percentage` (0–100) and `resets_at` (epoch seconds).

- **Install Claude Code Hooks…** also installs the wrapper:
  - copies the bundled `claude-bubble-statusline.sh` to `~/.claude-bubble/statusline.sh` (refreshed on launch like the hook);
  - if `statusLine.command` is set and isn't already the wrapper, saves it to `~/.claude-bubble/statusline-inner` (a one-line file holding the original command);
  - sets `statusLine` to `{"type": "command", "command": "\"~/.claude-bubble/statusline.sh\""}` (absolute path), keeping any other keys such as `padding`.
  - Re-running never wraps the wrapper: when the command already points at `.claude-bubble/statusline.sh` (in any form), `statusline-inner` is left alone. A `statusLine` that isn't an object is left untouched.
- **The wrapper** is plain shell (no python3: it runs on every status line update) and reads stdin once.
  - It exits at once if it is already running inside itself (`CLAUDE_BUBBLE_STATUSLINE`), so a command that points back at the wrapper can't loop.
  - When the input mentions `five_hour`, it saves the input as is to `~/.claude-bubble/usage.json` (temp file + rename); the app reads `rate_limits.five_hour` from it, and takes the capture time from the file's modification time.
  - Then it runs the inner command (via `bash -c`) with the same stdin and passes through its output and exit code. No inner command → prints nothing.
  - `CLAUDE_BUBBLE_DIR` overrides `~/.claude-bubble` (for tests), like the hook.

### Reading (`UsageReading`, core)

- `UsageReading { usedPercent: Double, resetsAt: Date, capturedAt: Date }`, decoded from `usage.json`; a missing or broken file is `nil`.
- `left(at:)` = `100 − usedPercent`, clamped 0…100, or **100** once `now ≥ resetsAt`.
- Percent is shown rounded **up**, so it always agrees with the level (25.4 → 26%, ok).
- `level(at:)`: **ok** when left > 25, **low** when 10 < left ≤ 25, **critical** when left ≤ 10.
- `timeLeft(at:)` = `resetsAt − now`, at least 0; formatted with the existing `DurationFormat` ("3h 4m", "38m").
- The app re-reads the file every **5s** (same rhythm as the job files).

## Orb

### Color temperature (`UsageTint`, core)

- **Blend:**
  - from 50% left down to 25%, `warm = 0 → 1` toward the palette's **needs** colors;
  - from 25% down to 0, `critical = 0 → 1` toward the palette's **error** colors (applied after the warm blend).
- **What changes:** only c1, c3 and halo (the rim and glow). c2 (the body) keeps the state's colour.
- **Which states:** working and idle only; needs and error already wear those colours.
- **No reading:** no tint.
- **Easing:** the animator eases the tint amount over about 2s (time constant 0.6s), so it never jumps.
- **During the all-done green wash:** the wash still wins.

### Low-usage mode

- **Below 10% left** (critical), the animator eases over about 1.5s to:
  - scale × **0.88**;
  - phase speed × **0.4**;
  - glow × **0.6**.
- **Leaving critical** (reset, or a new reading) eases back the same way.

## Hover card footer

- **Layout:** the card is 300pt wide. `Today · 3h 56m · 5 sessions` on the left (the word "working" is dropped while usage shows, so it fits the card), `23% · 3h 4m` on the right.
- **Percent color:**
  - ok: white at 0.4 (the footer's text colour);
  - low: the palette's needs swatch;
  - critical: the palette's error swatch.
- **Reset time:** the footer's grey.
- **No reading:** the right side is hidden.
- **Usage turned off in settings:** the right side is hidden.
- **When the footer shows:**
  - shown when there is a today summary **or** a usage reading;
  - with no today summary, the left side is empty and only the usage shows.

## Threshold toasts (`UsageAlerts`, core)

Toasts get an optional text override, so a toast can show text that changes (the usage numbers). They also get three kinds, each with the name **"Usage"**:

| Kind | When | Text | Colour | Lifetime |
|---|---|---|---|---|
| usageLow | left crosses to ≤ 25 | "25% left · resets 1h 12m" (actual numbers) | needs swatch | 6s |
| usageCritical | left crosses to ≤ 10 | "8% left · resets 38m" | error swatch | 8s |
| usageRefreshed | the window resets after a threshold toast fired in it | "refreshed · 100% left" | idle swatch | 6s |

- **Once per window:** a window is identified by its `resetsAt` (a later one by more than a minute is a new window), and each threshold fires once in it.
- **A jump** across both thresholds (say 40 → 8) fires only the critical toast.
- **The first reading** after launch never fires: it only sets the baseline. If launched at 8% left, no toast.
- **Refresh:** fires when the current window's `resetsAt` passes (or a reading arrives with a later `resetsAt`) and that window fired a threshold toast.
- **The orb's pull:** every usage toast gives the same small taffy pull as the other toasts.
- **Toasts setting:** respects the existing Toasts on/off setting too.

## Settings

- **Preference:** `usage: Bool`, default **on**, decoded tolerantly (older saved settings).
- **Controls:** Settings → Display "Show usage", and a right-click/menu-bar "Usage" toggle.
- **When it's off,** all four pieces stop:
  - no tint;
  - no low-usage mode;
  - no footer numbers;
  - no usage toasts.
- **Turning it back on** doesn't fire toasts for thresholds already crossed: the baseline resets.

## Session Simulator

- **Controls:** a **Usage** section with:
  - a "Simulate usage" toggle;
  - a slider for % left (0–100);
  - a **Reset window** button.
- **While simulating:**
  - the reading is `used = 100 − slider`, resetting 1h 12m from when simulation began;
  - **Reset window** moves `resetsAt` to now, which triggers the refresh path, then starts a fresh window at 100% left.
- **Closing the simulator** returns to the real reading and resets the toast baseline.

## Testing

- **UsageReading:**
  - decoding from JSON;
  - left (including after the reset);
  - level boundaries (25, 10);
  - time left.
- **UsageTint:**
  - none at ≥ 50%;
  - fully needs at 25%;
  - fully error at 0;
  - c2 untouched;
  - needs and error states untouched.
- **UsageAlerts:**
  - baseline on the first reading;
  - the low then critical crossings;
  - the 40 → 8 jump fires only critical;
  - once per window;
  - refresh only after a threshold;
  - a new window resets the thresholds;
  - turning it off and on resets the baseline.
- **Animator:** the low-usage pose eases to 0.88 scale, 0.4 speed and 0.6 glow, and back; the tint eases.
- **Installer:** wraps an existing command and saves the inner command; is idempotent; with no prior statusLine it installs the wrapper with no inner command; keeps other statusLine keys.
- **Wrapper (shell):**
  - writes usage.json and passes the output through;
  - with no rate limits, writes nothing and still passes through;
  - on bad JSON, still passes through;
  - with no inner command, prints nothing;
  - keeps the inner command's exit code.
- **Toasts:** a text override shows in the placement.
- **Preferences:** the usage default, and older saved settings.
- **By hand:** through the simulator's Usage section.
