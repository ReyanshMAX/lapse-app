# UI.md — screens, states, and user flows

## Overview

Six screens. The app opens on Record if no session is open, or on the paused
session if one is. Everything else hangs off a tab bar with Record and Library.

## Non-goals

- No onboarding carousel — a single permission prime before first capture
- No settings screen beyond the four settings listed below
- No themes, no dark/light toggle (the app is dark-only)
- No iPad-specific layout, no landscape support in v1
- No animations beyond system defaults and the recording pulse

## Design tokens

Dark only, "cold ink" direction — navy-black rather than true black, with a
single desaturated icy-blue accent reserved for actionable elements only
(buttons, active states, tag chips), so it never competes with the recording
indicator as the app's one saturated color.

Background `#0A0D13`. Surface `#12161F`. Surface 2 (nested/elevated surfaces)
`#1A2029`. Primary text `#EDEFF4`. Secondary text `#7D8494`. Accent `#6FA3D9`.
Recording indicator `#FF3B30` — unchanged.
Type: SF Pro Text for UI, SF Mono for all timer and duration displays. Corner
radius 14. Spacing scale 4/8/12/16/24/32.

A tag's chip/band color is always its stored `Tag.colorHex`
(`TagCatalog.palette`, docs/DATA_MODEL.md) — the same tag reads as the same
color in the Tagging segment list, the Tagging slider, the Library grid, and
the Stats per-tag split bar, rather than each screen picking its own ad hoc
palette.

## Screens

### 1. Record — idle

Camera preview filling the screen, a framing guide overlay (rule-of-thirds grid
plus a centre-crop safe-area rectangle matching the 9:16 preset), a large Record
button, and a camera flip control. Below the button: today's study total if a
session already exists for this `dayKey`.

If a paused session exists for the current `dayKey`, this screen instead shows
Resume as the primary action with the accumulated study time above it.

First entry shows a permission prime explaining why the camera is needed, then
the system prompt.

### 2. Record — recording

The live camera preview and framing guide stay visible while recording (D-028)
— the screen reads near-black because `UIScreen.main.brightness` is dropped to
0.05 (D-018, docs/CAPTURE.md screen dimming), not because the preview is
hidden. The only clearly lit elements against that dimmed feed:

- Study timer, SF Mono, 48pt, centred, updating at 1 Hz
- A small pulsing red dot
- Pause button, large hit target, bottom centre
- Warning banners when a guard fires (battery, thermal, disk)

Tapping anywhere other than Pause does nothing.

### 3. Record — paused

Returns to the (undimmed, but still scrim-darkened for legibility) live preview
with Resume and End Session. Shows accumulated study time, clip count, and
estimated storage used. The Live Activity is live in this state and its Resume
action deep-links here and immediately resumes.

Ending prompts for confirmation only if study time is under 5 minutes.

### 4. Tagging

Reached on End Session. Two modes over the same `TagRange` data (D-010).

**Segment list (default).** One row per clip-boundary segment: start–end on the
study axis, duration, and a tag field with autocomplete from the `Tag` table.
Multi-select tags per row. Untagged rows are allowed and shown in secondary text.

**Slider (refine).** A horizontal track representing total study time, with
draggable range handles. Dragging a boundary resizes adjacent ranges live and
persists once on release — ranges must tile the axis with no gaps or overlaps.
Tapping a range selects it and opens the same tag field. Because tap is taken by
tagging, split/merge are explicit controls: **Split** halves the selected
segment, **Merge →** folds it into its right neighbour. Merging unions the two
ranges' tags.

The End-Session button on the Record screen ends the session and presents this
screen as a full-screen cover; **Continue to Export** pushes the Export screen,
and **Close** dismisses (leaving ranges as they are — untagged is valid).

`TagRangeMath` in StudyLapseCore owns split/merge/resize and must maintain the
tiling invariant. Every mutation runs through it.

### 5. Export

Preview thumbnail, then controls: speed (multiplier stepper or a "fit to" field
with 15/30/60s presets), aspect (three-way picker), overlay style and corner,
intro/outro toggles. Live estimated output duration updates as controls change,
and shows the clamped value when the minimum-speed floor binds
(docs/DATA_MODEL.md).

Render button → progress with cancel → result screen with Save to Photos, Share,
and Add Voiceover.

### 6. Voiceover

Plays the rendered export. The playhead follows playback (a full drag scrubber
is Phase 8; use the `VideoPlayer` transport for now). Record button captures a
take starting at the current output position; recording stops on tap or at end
of video. Takes render as blocks on a timeline strip under the player, each
with Mute and Delete actions (re-record = delete + record again). Overlapping
takes are prevented at creation — the record button is disabled while the
playhead sits inside an existing take.

A banner appears if any take is stale against the current export profile
revision (`ExportProfile.reconcileRevision`), offering to delete the affected
takes. Reverting the profile settings is not offered — no per-revision settings
history is stored (OPEN_QUESTIONS.md Q-008).

Re-export bakes takes in; the pre-voiceover export is retained until the new one
succeeds.

### 7. Library

Grid of sessions, newest first: thumbnail, date, total study time, tag chips. Tap
opens a detail sheet with the clip list, exports, re-export, and delete. Delete
removes the database rows and the session directory together.

### 8. Stats

Total hours, current streak, per-tag time split as a horizontal bar, and a
calendar heatmap by `dayKey`. Untagged time appears explicitly as its own band.

## Empty states

Both Library and Stats can be reached with zero finished sessions (a fresh
install, or every session still in progress). Neither is a blank screen:

- **Library, no sessions.** Centered: a film-stack glyph in a surface-2 circle,
  "No sessions yet", and "Finished study sessions show up here."
- **Stats, no data.** Same layout: a bar-chart glyph, "No data yet", and
  "Finish a study session to see your totals, streaks, and heatmap here."

Both use the same layout (icon in a tinted circle, title, secondary-text
message, centered) built from the token palette, not the system default
`ContentUnavailableView` styling.

## Settings

Four only: capture interval (1/2/3/5/10s, default 2), day cutoff hour (default
4), default camera (front/rear), and default export profile.

## Live Activity

Shown while a session is paused. Compact leading: app glyph. Compact trailing:
accumulated study time. Expanded: study time, clip count, and a Resume button
backed by an App Intent that deep-links to Record — paused and ready.

While recording, the app is foregrounded by definition, so no Live Activity is
presented.

## Notes

- Every duration in the UI uses `Formatters` from StudyLapseCore so study-time
  formatting is identical everywhere.
- The recording screen must keep working with VoiceOver: the timer needs an
  accessibility label updated at a coarser cadence than 1 Hz.
- No haptics during recording — the phone is meant to be ignored.
