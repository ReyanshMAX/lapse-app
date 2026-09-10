# UI.md — screens, states, and user flows

## Overview

A four-tab bar — Home, Record, Library, Stats (`RootTabView`, added
2026-09-08 at the developer's request; see STATUS.md Deviations) — each tab
owning its own navigation stack. The app opens on Home; Record opens on the
idle camera preview if no session is open, or on the paused session if one
is. Tagging and Export are reached by pushing/covering from Record and
Library, not tabs of their own.

## Non-goals

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

### Home (tab)

Added 2026-09-08 (developer request — see STATUS.md Deviations; the original
"no onboarding carousel" non-goal above is superseded by the same request).
Dashboard: a greeting, today's studied time (live while a session is open),
a CTA button reflecting the live session state ("Start Studying" /
"Resume Session" / "Go to Recording" — switches to the Record tab rather
than duplicating its start/resume logic), a daily study-goal card (added
2026-09-09 — see STATUS.md Deviations: tap to set a target in 30-minute
steps via a sheet, or to edit/remove it once set; shows a progress bar and
time remaining against today's studied time when a goal is set, otherwise
"Set a daily study goal"), the current streak if nonzero, and up to five
recent finished sessions (tap through to the same session detail Library
uses, or "See all" to the Library tab). Empty state ("Ready when you are")
when there are no finished sessions yet.

First launch shows a one-time welcome screen (`OnboardingView`, a
`fullScreenCover` gated on an `hasSeenOnboarding` flag) ahead of any tab —
three lines on what the app does before the camera-permission prime a new
user would otherwise land on cold.

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

Reached on End Session. A Project picker sits above the mode toggle (added
2026-09-09 — see STATUS.md Deviations): a session-level label, distinct from
per-range tags, so it doesn't belong inside the tag field sheet. A menu of
"No Project", existing projects, and "New Project…" (a plain text-entry
alert); also editable afterwards from the Library session detail sheet.

Two modes over the same `TagRange` data (D-010).

**Segment list (default).** One row per block on the study axis: start–end,
duration, and a tag field with autocomplete from the `Tag` table. A session
starts as a single untagged block covering the whole study time — not one
block per clip/pause cycle (changed 2026-09-07; see STATUS.md Deviations) —
and the user splits it into further blocks manually: swipe a row leading-edge
for **Split** (halves it at its midpoint, added 2026-09-08 once List became
the mode people land in with only one starting block — see STATUS.md
Deviations) or trailing-edge for **Merge →** (folds it into the next row).
Multi-select tags per row. Untagged rows are allowed and shown in secondary
text. The tag field sheet shows the most-used tags as a row of tappable
chips above the free-text field (added 2026-09-09 — see STATUS.md
Deviations) so re-tagging with a subject you already use is one tap.

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
with 15/30/60s presets), aspect (three-way picker), rotate (0°/90°/180°/270°)
and a horizontal-flip toggle (added 2026-09-09 — see STATUS.md Deviations;
applied before the crop and the timer overlay, so the overlay's corner always
tracks the *displayed* orientation, not the recorded one), overlay style and
corner, intro/outro toggles. Live estimated output duration updates as
controls change, and shows the clamped value when the minimum-speed floor
binds (docs/DATA_MODEL.md).

Render button → progress with cancel → result screen with Save to Photos and
Share.

### 6. Library

Grid of sessions, newest first: thumbnail, date, total study time, tag chips. Tap
opens a detail sheet with a freeform notes field and a project picker (both
added 2026-09-09 — see STATUS.md Deviations), the clip list, exports,
re-export, and delete. Delete removes the database rows and the session
directory together.

A toolbar button (added 2026-09-10 — developer request, "merge multiple study
sessions at export... not merge the source clips") opens **Merge Sessions**: a
list of finished, re-exportable sessions with Today/This Week/All quick
filters, multi-select (checkmark rows), and a footer showing the running
selection count and combined study time. Sessions whose capture interval or
frame rate doesn't match the current selection are disabled with an inline
note (docs/EXPORT.md "Merging sessions" — mixed settings can't merge in v1).
Continue (enabled at 2+ selected) pushes the same Export screen (§5) used for
a normal export, titled "Merge & Export" — same controls, same render flow,
just built from every selected session's clips concatenated chronologically.

The result has no session to live under, so it doesn't appear in any tile.
Library gets a **Merged** section above the grid instead: each row shows the
session count, render date, duration/size, and Preview/Share/Delete — the same
row shape the session detail sheet's exports already use. Deleting one removes
its file and database row together; it never touches the sessions that
contributed to it (docs/DATA_MODEL.md Notes).

### 7. Stats

Total hours, current streak, a Recap section (added 2026-09-09 — see
STATUS.md Deviations: study time, session count, top tag, and longest
session over the trailing 7 and 30 days), a By-project total per assigned
project (same date, shown only once at least one session has a project),
per-tag time split as a horizontal bar, and a calendar heatmap by `dayKey`.
Untagged time appears explicitly as its own band.

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
