# Open Questions

Unresolved. Do not resolve these silently — ask, then move the answer to
DECISIONS.md and delete the entry here.

## Q-001: App name and bundle identifier

- **Blocking:** no — needed before Phase 9, but the bundle ID is baked into the
  project at Phase 1 and changing it later invalidates provisioning
- **Options:** "StudyLapse" is a working title used throughout this suite. It is
  descriptive and almost certainly taken or close to taken on the App Store
- **Depends on it:** bundle identifier, App Store listing, `os_log` subsystem,
  Live Activity display name, every occurrence of the name in these docs

## Q-002: What exactly the v2 focus analysis reports

- **Blocking:** Phase 10 only
- **Options:** (a) objective metrics only — face present/absent, away-from-desk
  count, longest unbroken stretch, focus timeline; (b) objective metrics plus a
  natural-language summary generated from those numbers; (c) something richer
  requiring a vision model, which D-022 rules out for privacy and cost
- **Depends on it:** whether the app ever makes a network call (currently zero,
  which is what makes the "no data collected" privacy label true — D-013), and
  whether a per-frame metadata sidecar should be written during capture in v1 to
  avoid a full re-analysis pass later

## Q-003: Monetisation and the watermark

- **Blocking:** no — but the watermark toggle listed in early scoping was cut
  from the phase plan because it only makes sense as a paid gate
- **Options:** free with no watermark; free with a watermark removed by IAP;
  one-time paid app; free with a paid tier unlocking export presets
- **Depends on it:** whether StoreKit enters the project at all, whether the
  privacy label changes, and whether the export pipeline needs a watermark layer

## Q-004: Paid developer program — who enrols and when

- **Blocking:** Phase 9 hard-blocks on it; Phase 7's home screen widget is
  already deferred because App Groups require it
- **Options:** the account holder enrols as an individual (membership cannot have
  additional members, so the developer would sign in with the holder's Apple ID
  for upload steps) or as an organisation (requires a legal entity)
- **Depends on it:** App Groups, home screen widget, TestFlight, submission, and
  the lead time on identity verification — start this early, not at submission

## Q-007: Stats — multi-tag attribution and streak currency

- **Blocking:** no — Phase 5 ships with the interim choices below, documented in
  `Stats.swift`. Revisit if the stats screen reads wrong to the developer
- **Multi-tag attribution:** docs/UI.md §8 specifies the per-tag split as bands
  of a single horizontal bar with untagged as its own band. That only reads
  correctly if the bands partition the studied total, so a range carrying N tags
  currently contributes `duration / N` to each tag. The alternative
  (full duration to every tag) makes the bar sum past 100%. Even-split chosen
- **Streak currency:** whether a streak whose most recent day is *yesterday*
  still counts as "current". Chosen: yes — current if the run includes today's
  or yesterday's `dayKey`; a gap of a full day or more resets it
- **Depends on it:** only the stats screen's numbers. No schema or export impact

## Q-008: Stale-voiceover banner — "revert the profile" action

- **Blocking:** no — Phase 6 ships the banner with a delete-only action
- **Context:** docs/UI.md §6 and docs/EXPORT.md say the stale-takes banner
  should offer to "delete the affected takes **or revert the profile
  revision**". Deleting is implemented. Reverting the *revision number* alone
  would re-time takes against settings that no longer exist — exactly the
  "never silently re-time" case D-011/DATA_MODEL.md forbids. Reverting the
  *settings* is not possible: no per-revision settings history is stored, and
  adding a snapshot field only for this was judged out of scope (advisor).
- **Options:** (a) delete-only, current — the user re-picks the old settings by
  hand if they want the takes back; (b) snapshot the profile settings onto each
  take at record time, so the banner can restore them; (c) keep a small
  ring-buffer of recent profile-settings snapshots per session
- **Depends on it:** whether `ExportProfile` or `VoiceoverTake` gains a settings
  snapshot field. No effect on the mix pipeline or export correctness.

## Q-009: Phase 8 timer-overlay fix vs. the phase's own file-scope criterion

- **Blocking:** no — Phase 8 ships without this fix; everything else in its
  Scope list is done
- **Context:** BUILD.md Phase 8's Scope bullet list says to fix "the
  penultimate-vs-final timer value on the last export frame," referencing the
  STATUS.md Known limitation that the burned-in timer's true final value (the
  session total) is only visible for a sliver of the last frame because
  `OverlayLayerBuilder.timerLayer` clamps the final keyframe's opacity window
  to `[0.999999, 1.0]` of the output duration instead of splitting the tail
  fairly between the last two labels. The actual fix lives in
  `StudyLapse/Export/OverlayLayerBuilder.swift`. But Phase 8's own acceptance
  criterion 1 requires "a diff review confirms no file outside `Features/`,
  `Shared/`, and docs/UI.md changed," and its Non-goals repeat "no changes to
  ... export composition ... this phase touches SwiftUI views and docs/UI.md
  only." `OverlayLayerBuilder.swift` is neither — fixing this within Phase 8
  would violate its own hard, CI-checkable scope criterion
- **Options:** (a) leave it as a known limitation past Phase 8, fixed in a
  small dedicated change later (its own commit, doesn't need a whole phase);
  (b) treat "penultimate-vs-final" as in scope and accept criterion 1 doesn't
  literally hold for that one file; (c) narrow the fix to something
  expressible in the view layer (not attempted here — the opacity-window
  split is CALayer/CoreAnimation timing owned entirely by
  `OverlayLayerBuilder`, not a SwiftUI view)
- **Depends on it:** nothing else — cosmetic, export duration/composition
  unaffected either way. Chosen for this pass: (a), so Phase 8's own
  criterion 1 holds cleanly

## Q-006: Behavior when the user studies across two devices or reinstalls

- **Blocking:** no
- **Options:** accept total loss on reinstall (current spec — no backup, no
  sync); include the store in iTunes/Finder backup while excluding media;
  CloudKit sync, which D-013 rejected for v1
- **Depends on it:** whether streaks and stats survive a phone upgrade. As
  specified, they do not — the whole storage root is excluded from backup
