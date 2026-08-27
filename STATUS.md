# Status

**Last updated:** 2026-08-27
**Current phase:** 4 of 9 — Tagging: segment list and slider. **In progress** —
all Phase 4 scope built and green on CI (branch `phase-4-tagging`). Criteria
1–2 (`[ci]`) checked; 3–4 (`[device]`/`[eyes-on]`) await developer
verification.
**Next action:** Developer — sideload the latest `phase-4-tagging` build and
check BUILD.md Phase 4 criterion 3 (end a session with ≥2 clips → the Tagging
screen's segment list shows exactly one row per finalized clip; the debug log
prints `seeded N tag range(s)`) and criterion 4 (Slider mode → drag a boundary
handle on a long multi-clip session: it should track the finger and the
adjacent segment durations update live, no stutter). If both pass, check the
boxes and move Phase 4 to Done. Otherwise begin Phase 5 (library + stats).

**Environment:** No Mac access for approximately one week. Builds run on GitHub
Actions macOS runners; the `ipa` job produces an unsigned .ipa that is signed
with a free Apple ID and sideloaded from Windows, so `[device]` and `[eyes-on]`
criteria remain reachable. Unavailable: the Xcode debugger, `os_log` console
streaming, Instruments, and any paid-program entitlement.

---

## Done

- **Phase 0 — Core logic, provable without a Mac** (2026-08-26)
  - `TimeAxis`, `DayBoundary`, `TagRangeMath`, `Formatters` — implemented,
    tested (including the ≥1000-case property test), all green on CI run
    32997397929 (commit 6296a00)
  - Repo layout, `project.yml`, `.github/workflows/ci.yml` (`core`,
    `simulator`, `app`, `ipa` jobs) — all four green on the same run
  - `[device]` criterion: developer sideloaded `StudyLapse-unsigned-ipa` from
    run 32997397929 via Sideloadly and confirmed the placeholder "StudyLapse"
    view launches on their phone (confirmed 2026-08-26)
  - No deviations outstanding — see Deviations log for the three CI config
    bugs found and fixed along the way

## Done

- **Phase 1 — One clip, captured and played back on device** (2026-08-26)
  - `FrameSource` protocol + `CameraFrameSource` (device) / `SyntheticFrameSource`
    (CI) — `StudyLapse/Capture/FrameSource.swift`
  - `CaptureController` — consumes `FrameSource`, never owns `AVCaptureSession`
    (D-026) — `StudyLapse/Capture/CaptureController.swift`. Gates frames at the
    configured interval (0.02s tolerance), synthesizes sequential output
    timestamps, writes HEVC 1920x1080 via `AVAssetWriter`
  - `DebugLog` (lock-guarded ring buffer, capped 2000, D-024) —
    `StudyLapse/Shared/DebugLog.swift`
  - `StorageLocator` (Application Support root, `isExcludedFromBackup`) —
    `StudyLapse/Storage/StorageLocator.swift`
  - `CaptureControllerTests.testSixtySecondSyntheticCaptureWritesTwentyFrames` —
    drives a `SyntheticFrameSource` for 60 virtual seconds at a 3s interval,
    asserts `frameCount == 20` and the independently re-read asset duration
    is ~20/30s
  - Minimal UI: `RecordView` (permission prime → 60s hardcoded capture →
    hands off to playback), `PlaybackView` (bare `AVPlayer`), `DebugLogView`
    (scrollable log + copy-to-clipboard). `StudyLapseApp` now opens on
    `RecordView`, replacing the Phase 0 placeholder
  - All eight acceptance criteria checked in BUILD.md, all green on CI run
    33021301863. The four `[device]`/two `[eyes-on]` criteria were confirmed
    by the developer sideloading that build (2026-08-26): capture runs and
    installs/launches fine; the four `[device]` criteria (install/launch,
    build with no warnings in `Capture/`, ~0.67s written-file duration,
    `StorageLocator.root` backup exclusion) and both `[eyes-on]` criteria
    (recognisable sped-up playback with no strobing; debug log shows
    ~3s-apart accepted-frame lines and copy-to-clipboard works) all confirmed
    good, no crash. Two caveats worth knowing for later phases: (1) the
    "build succeeds over SSH" and "`xcrun devicectl` install/launch" criteria
    were satisfied via the CI-build + Sideloadly-install substitution
    documented in docs/SETUP.md for the no-Mac period, not literally over SSH
    or via `devicectl` — worth a literal SSH/`devicectl` check once Mac
    access returns, not blocking; (2) the written-file duration criterion was
    confirmed qualitatively (playback was a very brief, recognisably sped-up
    clip) rather than by reading `AVAsset.duration` numerically, since that
    needs Xcode/Mac tooling the developer doesn't have right now
  - See Deviations for the two real bugs the synthetic-capture CI test caught
    (writer backpressure dropping frames; a `Capture/` build warning found
    while checking the SSH-build criterion) and the still-unconfirmed raw
    HEVC sample-count question

## In progress

- **Phase 4 — Tagging: segment list and slider.** Code-complete, green on CI;
  only the two device/eyes-on criteria remain (see *Needs developer
  verification*).
  - **`TagRangeSeeding.ensureSeeded`** (`StudyLapse/Model/`) — seeds one
    `.segment` `TagRange` per finalized clip, tiling `[0, totalStudySeconds)`,
    via `TagRangeMath.seed`. Repairing, not one-shot: called from
    `SessionCoordinator.end()` *and* from the tagging screen's `TagEditor`
    init, so a rollover clip whose `persistFinalizedClip` `Task` hadn't landed
    at `end()` time still gets its own range (re-seed if nothing's been tagged,
    append a tail range if it has).
  - **`SessionCoordinator.lastEndedSession`** — lets `RecordView` push the
    tagging flow after `end()` clears `session`. Not observed (the
    day-boundary auto-close also calls `end()`).
  - **`TagCatalog`** (`StudyLapse/Model/`) — `normalize` (lowercase/trim),
    `#Predicate` lookup + insert-if-absent, palette colour assignment,
    autocomplete `suggestions` (use-count ranked), and `refreshUseCounts`
    (recomputes `useCount` from the live `TagRange` rows — derived, not
    incremented; docs/DATA_MODEL.md Notes updated).
  - **`TagEditor`** (`@MainActor @Observable`, `Features/Tagging/`) — working
    set of `TagRangeMath.Range` values, every boundary edit through
    `TagRangeMath`, reconciled onto `@Model` rows by index (ids/origins
    survive); `previewResize` is memory-only per drag frame, `commitResize`
    persists once on release.
  - **Screens** (`Features/Tagging/`): `TaggingFlowView` (full-screen cover),
    `TaggingView` (List / Slider segmented toggle + Continue-to-Export),
    `SegmentListView`, `TagSliderView` (draggable handles, Split/Merge
    controls), `TagFieldSheet` (autocomplete tag picker). `RecordView`'s
    End-Session button now runs End → Tagging → Export.
  - **Tests, `simulator` job**: `TagRangeSeedingTests` (criterion 3 + repair
    semantics + coordinator `end()`), `TagCatalogTests` (normalize, ensure-once,
    no drift, suggestion ranking), `TagEditorTests` (split/merge/resize
    persist; 300-op random sequence refetches rows and asserts they still
    tile). `TagRangeMathTests` (criteria 1–2) in the `core` job.
  - The `ClipsDebugView` "Export this session" link stays as a re-export path
    for device testing — intentional, not the "replaced" state the old Next
    action anticipated.

## Done

- **Phase 3 — Export with a burned-in timer, saved to Photos** (2026-08-27) —
  all six acceptance criteria confirmed on device 2026-08-27 (developer
  sideloaded and verified duration/clamp/audio-track/zero-clip/timer/9:16;
  audio track checked via the `Export verify:` debug-log line). CI verifies the
  composition graph + overlay layer tree (`AVAssetExportSession` +
  `AVVideoCompositionCoreAnimationTool` crash the simulator — see Deviations).
  - `StudyLapseCore`: `TimeAxis.speed` / `outputDuration` — net real-time speed
    on the same axis as `minimumSpeed` (`interval*fps`); `outputDuration =
    study/speed`. Single source of truth for the UI number *and* the
    composition scale target. `TimerOverlay.timerKeyframes` — pure keyframe
    generation, 2000-cap with auto-coarsening, format fixed by total study
    time.
  - `StudyLapse/Export/`: `AVFoundationSessionExporter` — `prepare()` assembles
    the `AVMutableComposition` (concat finalized clips, scale to the clamped
    output duration, insert a full-length silent LPCM track, aspect-preset
    centre-crop transform, build the overlay layer tree); `render()` attaches
    the `AVVideoCompositionCoreAnimationTool` and runs `AVAssetExportSession`
    (HEVC, H.264 fallback). `OverlayLayerBuilder` (discrete opacity keyframe
    stack, four corners, `minimal`/`boxed`/`mono`). `ExportCoordinator`
    (`@Observable`: plan build, `ExportRecord` write, progress,
    `estimatedOutputDuration` / `isClampedToFloor`, post-render track-summary
    log). `SilentAudio`, `PhotosSaver`.
  - `StudyLapse/Features/Export/ExportView` — speed (multiplier / fit-to
    15·30·60s), aspect, timer style + corner, intro/outro, live estimated
    length with a clamp note, render → progress + cancel → Preview / Share /
    Save to Photos. Reached from `ClipsDebugView` ("Export this session") until
    Phase 4 wires the real End-session → Tagging → Export flow.
  - Tests (`simulator` job, all green): `ExportTests` asserts on the `Prepared`
    graph — composed duration == the reported number, one full-length audio
    track, per-preset render size, `cropTransform` is uniform-scale, the
    overlay text stack runs `0:00` → session total, corner placement,
    zero-clip typed error, unfinalized-clip skip. `TimeAxisTests` /
    `TimerOverlayTests` in the `core` job.
  - Follow-ups this session: fixed the speed math (multiplier was stacked on
    the interval compression → ~6000× net); default capture interval 3s→2s
    (D-006); screen-stays-on hardening. All logged under Deviations.

- **Phase 2 — A real multi-clip session with correct study time** (2026-08-27)
  — all six acceptance criteria checked. Criteria 3/4/5/6 confirmed on device
  2026-08-27; criterion 2 (`studyOffsetStart` tiling) accepted on the CI test
  (`StudyOffsetsTests`, 200-case random insert/finalize/delete sequence — pure
  model math, no device-specific behavior). Everything below is built,
  committed, and green on CI.
  - **SwiftData stack** — all seven `@Model` entities from docs/DATA_MODEL.md in
    `StudyLapse/Model/`, `ModelContainerFactory` (on-disk + in-memory).
  - **`StudyOffsets.recompute(for:)`** — reassigns `studyOffsetStart` across a
    session's finalized clips so the tiling invariant holds after any
    finalize/recover/delete. `runningTotal(for:)` gives a new clip its offset.
  - **Chunked writing (D-015)** — `CaptureController.startRecording` /
    `stopRecording`: continuous capture rolling a new chunk every 120s of
    recorded source-PTS or 1000 frames. The threshold frame becomes frame 0 of
    the next chunk (no boundary loss); trailing chunk returned from
    `stopRecording`, rollover chunks delivered via `onClipFinalized`. Single
    `FinalizedClip` value type crosses the queue boundary, never a `@Model`.
    `SyntheticFrameSource` now has a monotonic tick cursor across `emit` calls.
  - **Insert-on-open** — `CaptureController` fires `onClipOpened` when a chunk's
    writer is created; `SessionCoordinator` persists a `Clip` row with
    `isFinalized == false` right then, so a force-quit before `finishWriting`
    leaves a row for recovery (matches docs/CAPTURE.md's launch-recovery flow,
    which assumes such rows exist). Clean stop flips the row to finalized or
    prunes it if the chunk got zero frames.
  - **`ClipRecovery`** — `recoverUnfinalized` repairs or deletes
    `isFinalized == false` rows from whatever `AVURLAsset` can still read;
    `demoteRecordingSessions` moves `.recording` → `.paused` at launch.
  - **`SessionCoordinator`** — `@MainActor @Observable`; start/pause/resume/end,
    `handleScenePhase` (background→auto-pause D-016, active→day-boundary
    auto-close D-004), `recoverOnLaunch` (recover + re-attach to the newest
    open session). `studySeconds` free-runs at 1 Hz while recording, reconciles
    to the persisted clip total on every stop.
  - **App wiring** — `StudyLapseApp` builds the container, owns the coordinator,
    runs `recoverOnLaunch`, forwards `scenePhase`. `RecordView` is the Phase 2
    screen: study-time timer, clip count, record/pause/resume/end.
  - **Tests, all green in the `simulator` job** (15 tests): `StudyOffsetsTests`
    (incl. 200-iteration random op sequence), `ClipRecoveryTests` (real file
    truncation), `SessionCoordinatorTests` (4-not-14-min study time, survives
    simulated app kill + resumes, backgrounding auto-pause), and
    `CaptureControllerTests.testChunkRolloverPreservesTotalFrameCount`.
  - **`ClipsDebugView`** — debug-only clip browser (all sessions, per-clip
    index/frames/offset/flags, tap-to-play). Restores on-device clip viewing
    that the Phase 2 `RecordView` rewrite had dropped. Real library is Phase 5.
  - **Criteria** — 1 (`[ci]`, Phase 0 suite), 3/4 (`[device]`) and 5/6
    (`[eyes-on]`) confirmed on device 2026-08-27, 2 (`[device]`) accepted on
    the CI test. Phase 0's "re-run day-boundary tests on Apple's Foundation"
    deferral is discharged — the `core` job runs `swift test` on macOS.

## Next up

1. Phase 4 — tagging (segment list + slider over `TagRange`, consuming the
   already-built `TagRangeMath`; `Tag` entity with autocomplete). This is also
   where the real End-session → Tagging → Export flow replaces the debug
   "Export this session" entry point in `ClipsDebugView`.

## Needs developer verification

**Phase 4 (sideload the latest `phase-4-tagging` build):**

- **Criterion 3 `[device]` — ending a session seeds exactly one range per
  finalized clip.** Record a session with at least 2 clips (record, pause,
  resume, record, End Session). On End the Tagging screen opens: its segment
  list must show exactly one row per finalized clip, contiguous, covering the
  whole session. The debug log should show `seeded N tag range(s)` with N ==
  the clip count. Proven in CI by `TagRangeSeedingTests` (pure model math, no
  device-specific behaviour — same `[device]`-tag conflict already logged for
  Phase 2 criteria 2/3/4); a green simulator run may be enough for sign-off,
  developer's call.
- **Criterion 4 `[eyes-on]` — slider handle drag on a long session.** In the
  Tagging screen switch to Slider mode. Dragging a boundary handle should move
  the boundary smoothly under the finger and the two adjacent segment
  durations (shown for the selected segment / in the list) should update live.
  Split halves the selected segment; Merge → folds it right. No stutter on a
  session with many ranges (the drag mutates memory only and persists once on
  release).

Also worth a look (not blocking): the End → Tagging → Export hand-off — End
Session should present tagging as a full-screen cover, Continue to Export should
reach the existing export screen with the session's tags available, Close
should dismiss leaving ranges untagged (a valid state).

Phase 3's six device/eyes-on criteria were all confirmed on 2026-08-27.

Known limitations from Phase 3 (not bugs, revisit later):
- The final timer value (session total) is visible for the last frame only;
  the penultimate value fills the rest of the tail. Smooth later if it reads
  wrong.
- The export screen is reached from the debug clip browser, not a real flow —
  Phase 4 adds End-session → Tagging → Export.
- `intro`/`outro` card toggles exist in the UI and render, but the card text
  is minimal (date / total / tags) — polish is Phase 7.

Known caveats (still relevant for later phases):
- Free-ID cert expires ~7 days after signing; re-sideload if the app stops
  launching with no code change.
- The recording screen has no camera preview by design (docs/UI.md, Q-005) —
  a black screen with a timer is correct, not a bug.
- The timer "snapping to the next multiple of the capture interval" (2s by
  default) on pause/resume is expected: study time is
  `frameCount * captureInterval`, and the free-running 1 Hz counter reconciles
  to the true frame count on stop. Number is correct.
- Screen dimming while recording is Phase 7, not wired yet.
- `ghost.jpg` / `thumbnail.jpg` generation on clip finalize / session end is
  deferred to the phases that consume them (7 and 5) — see Deviations.

## Blocked

- **Q-004** paid developer program enrolment — no phase blocker until Phase 8,
  but it has real lead time. Raise it now.

Not blocking, but constraining while there is no Mac:

- No debugger, no console — rely on the Phase 1 on-device debug log (D-024)
- Free-ID certificates expire every 7 days; re-sideload when the app stops
  launching with no code change
- Three apps per free Apple ID, so hold off on the widget extension until Phase 7
- **Q-001** app name and bundle identifier — does not block Phase 0 or the
  sideload path (the sideloader rewrites the bundle ID), but must be settled
  before real provisioning is set up on a Mac

## Deviations from spec

- 2026-08-27, Phase 4: **`SessionCoordinator.lastEndedSession`** added — not in
  BUILD.md's Phase 2 `SessionCoordinator` contract. `end()` clears `session`,
  and `RecordView` needs a handle to the just-ended session to push the tagging
  flow. Read once by the End-Session button, deliberately *not* observed —
  `end()` is also the day-boundary auto-close path (D-004) and must not pop a
  screen while backgrounded.

- 2026-08-27, Phase 4: **TagRange seeding is repairing, not one-shot.**
  BUILD.md says "seed on session end"; `onClipFinalized` persists rollover
  chunks on an async `Task`, so at `end()` time a late chunk's `Clip` row may
  not exist yet and a naive seed would produce N ranges for N+1 clips.
  `TagRangeSeeding.ensureSeeded` is idempotent and self-healing: no ranges →
  seed; untouched ranges that don't tile the current total → re-seed; tagged
  ranges with an uncovered tail → append one `.segment` range (append, not
  extend, to keep criterion 3's one-range-per-clip property). Called from both
  `end()` and `TagEditor.init`.

- 2026-08-27, Phase 4: **`Tag.useCount` / `lastUsedAt` are derived, not
  incremented.** docs/DATA_MODEL.md only declared the field; write semantics
  were unspecified. `TagCatalog.refreshUseCounts` recomputes `useCount` as the
  count of `TagRange` rows currently carrying the name, so it can't drift on
  remove-then-re-add. docs/DATA_MODEL.md Notes updated.

- 2026-08-27, Phase 4: **slider split/merge are explicit controls, not
  tap-to-split.** docs/UI.md §4 said "splitting adds a boundary at the tap
  point"; tap is already spec'd to open the tag field, so Split halves the
  selected segment and Merge → folds it into its right neighbour. docs/UI.md §4
  updated.

- 2026-08-27, Phase 4: the `ClipsDebugView` "Export this session" link is
  **kept**, not replaced — the real End → Tagging → Export flow is wired into
  `RecordView`, but the debug link stays as a re-export entry point for device
  testing during the no-Mac period. STATUS.md's old Next action anticipated a
  straight replacement.

- 2026-08-27 (account-holder decision): **default capture interval 3s → 2s**
  (D-006). Lower floor (60x vs 90x at 30fps) for more watchable short sessions,
  ~50% more source storage (~540 MB for a 9h day, still fine — D-005). Changed
  the `?? 3` fallbacks in `SessionCoordinator.startNewSession` and
  `Clip.studyDuration`, updated DECISIONS.md D-006, docs/DATA_MODEL.md,
  docs/UI.md, docs/CAPTURE.md storage estimate. `SessionCoordinatorTests` now
  pins the interval to 3s in setup so its frame-count assertions are
  independent of the default. No settings screen exists yet to change it
  per-user.

- 2026-08-27, Phase 3 (bug fix): **speed multiplier is net real-time, not
  stacked on the capture interval.** docs/DATA_MODEL.md's `speed()` formula
  computed `baseOutput / target` for fit mode and returned the bare
  `speedMultiplier` for multiplier mode, where `baseOutput = study/(interval*fps)`
  is *already* the interval-compressed length. Net effect: a "100x" multiplier
  at a 2s interval produced 60x·100 = 6000x, collapsing a 1-hour session to
  0.6s. Fixed so `speed` is the net real-time factor on the same axis as
  `minimumSpeed` (`interval*fps`): multiplier mode returns `max(n, floor)`, fit
  mode returns `max(study/target, floor)`, and `outputDuration = study/speed`.
  `TimeAxis.baseOutputSeconds` renamed `nativeOutputSeconds` (= `study/floor`,
  the composition's native length) and is no longer in the speed math. The
  exporter already scales `composition.duration` → `outputDuration` directly,
  so it needed no change. docs/DATA_MODEL.md `speed`/`outputDuration`/
  `outputToStudy` snippets + the minimum-speed paragraph updated; BUILD.md
  Phase 3 criterion 2 reworded (the old "fit-15s on a 9h session clamps" is
  false under the correct math — that's 2160x, far above the floor; the clamp
  only binds for short sessions with long fit targets). ExportView stepper is
  now `30…1200× real time`.

- 2026-08-27, Phase 3: `SessionExporter` / `ExportRequest` shape. BUILD.md's
  contract was `ExportRequest { session: Session; profile: ExportProfile;
  voiceoverTakes: [VoiceoverTake] }`. SwiftData `@Model` objects aren't safe to
  touch off the main actor (docs/ARCHITECTURE.md) and the render isn't
  instantaneous, so `ExportCoordinator` flattens everything into a `Sendable`
  `ExportPlan` value on the main actor and the exporter only sees that. The
  exporter is itself `@MainActor`. Same resolution as Phase 2's
  `CaptureController` (media-only). docs/EXPORT.md updated in the same change.

- 2026-08-27, Phase 3: `OverlayLayerBuilder.build` returns
  `OverlayLayers { parent, video }` rather than `-> CALayer` — the
  `AVVideoCompositionCoreAnimationTool` needs both layers, wired together
  before it's constructed. Also takes the flat overlay fields, not an
  `ExportProfile` (see above). docs/EXPORT.md updated.

- 2026-08-27, Phase 3: **`AVAssetExportSession` +
  `AVVideoCompositionCoreAnimationTool` crash the iOS Simulator** ("Lost
  connection to IOSurface Remote Server; unable to recover, exiting process")
  — the first Phase 3 CI run crash-looped the test host on every render.
  TESTING.md's optimism ("AVAssetExportSession works on the simulator") does
  not hold for the CoreAnimationTool path in headless CI. Resolution: the
  exporter is split into `prepare()` (assemble + return the composition graph
  and overlay layer tree, no rendering — fully CI-inspectable) and `render()`
  (build the tool + run the export). CI asserts on `prepare()`'s output; the
  actual render is a `#if !targetEnvironment(simulator)` device-only test and
  the six `[device]`/`[eyes-on]` criteria. docs/TESTING.md updated.

- 2026-08-27, Phase 3: silent audio is **LPCM in a `.caf`**, not AAC/`.m4a` as
  a casual reading of docs/EXPORT.md ("silent audio track") might suggest — the
  AAC encode path through `AVAudioFile` is the flakier one on the simulator and
  the export session transcodes the track anyway. Written via `AVAudioFile` in
  the file's `processingFormat` (float32). Documented in docs/EXPORT.md stage 3.

- 2026-08-27, Phase 3: export preset is HEVC with an **H.264 fallback**
  (`AVAssetExportPresetHighestQuality`) if the HEVC render fails, rather than
  HEVC only — the simulator's software HEVC encoder is unreliable (same class
  as the Phase 1 encoder history). On device HEVC should win. docs/EXPORT.md
  stage 6 updated.

- 2026-08-27, Phase 2: `CaptureController` interface. docs/CAPTURE.md showed a
  session-aware surface (`start(session:)` / `pause()` / `resume(session:)` /
  `end(session:)`). That contradicts D-026 and docs/ARCHITECTURE.md's
  dependency direction — the capture layer must not import the model layer.
  Kept `CaptureController` media-only: it takes a `FrameSource`, emits
  `FinalizedClip` values, and `SessionCoordinator` (model layer, main actor)
  does all persistence. Updated the docs/CAPTURE.md snippet in the same commit
  to match, and tightened its D-015 wording (rollover is measured as source-PTS
  delta from the chunk's first accepted frame, not "wall time").

- 2026-08-27, Phase 2: `ghost.jpg` (last frame of the most recent finalized
  clip) and `thumbnail.jpg` (first frame of clip 000) — docs/CAPTURE.md and
  docs/ARCHITECTURE.md mention writing these at clip finalize / session end.
  Deferred: the ghost overlay is an explicit Phase 2 non-goal (BUILD.md) and
  lands in Phase 7; the library thumbnail is first shown in Phase 5. Writing
  the JPEGs now would be untested image-extraction code with no consumer.
  `SessionCoordinator.persistFinalizedClip` and `end()` are the insertion
  points when those phases arrive.

- 2026-08-26, Phase 2: BUILD.md Phase 2 tags criteria 2 (`studyOffsetStart`
  tiling invariant test), 3 (force-quit recovery: ≤120s lost, no
  `isFinalized == false` rows) and 4 (session left `.recording` at launch moved
  to `.paused`) as `[device]`. docs/TESTING.md's "What this buys, concretely"
  section lists all three as "Fully verifiable in CI with no camera" via
  `SyntheticFrameSource` + an in-memory `ModelContainer` on the simulator
  runner. Resolution taken: the tests are written in `StudyLapseTests` and run
  in the `simulator` CI job, but the boxes are left unchecked per LOOP.md's
  "never check off a `[device]` criterion" rule. The developer decides whether
  a green simulator run is sufficient to check them or whether a literal
  on-device run is still wanted. Not blocking; no doc was edited because both
  docs are internally consistent — they just disagree on the tag.

- docs/SETUP.md's `app` and `ipa` CI job snippets were each missing their own
  "Generate project" (`xcodegen generate`) step. Each job runs on a fresh
  runner with no state shared from the `simulator` job, so without it there is
  no `.xcodeproj` to build/archive. Added the step to both jobs in
  `.github/workflows/ci.yml` and updated docs/SETUP.md to match.

- Run 32995981666 (first all-four-jobs run) failed three of four jobs. Three
  independent root causes, all fixed in the same commit:
  - `simulator` job: the `StudyLapse` scheme had no test action — there was no
    Xcode test target at all yet (the Phase 0 property tests live in
    `StudyLapseCore`, tested via `swift test` in the `core` job). Added a
    minimal placeholder `StudyLapseTests` XCTest target to `project.yml`,
    wired explicitly into the `StudyLapse` scheme via `scheme.testTargets`
    (XcodeGen does not reliably auto-attach this). Real simulator-level tests
    (persistence, recovery, export, fixtures per CLAUDE.md's repo structure)
    land in this target in later phases.
  - `app` job: `-destination 'platform=iOS Simulator,name=iPhone 15'` — no
    "iPhone 15" simulator exists on the current runner image (Xcode 26.6);
    available devices are iPhone 16e/17/17 Pro/17 Pro Max/17e/Air and iPad
    models. Switched to `'generic/platform=iOS Simulator'`, which the doc
    already recommended as the fallback for exactly this case and doesn't
    need a concrete device to just compile.
  - `simulator` job (second issue, same job): also needed a concrete-device
    destination once the test action existed — `test` (unlike `build`) needs
    a real bootable simulator, so `generic/platform=iOS Simulator` isn't
    enough there. Set it to `'platform=iOS Simulator,name=iPhone 17'`, a
    device confirmed present on the current runner image.
  - `ipa` job: archive validation failed with "Build input file cannot be
    found: .../StudyLapse.app/Info.plist". `project.yml` set several
    `INFOPLIST_KEY_*` settings but never `GENERATE_INFOPLIST_FILE: YES`, so
    no Info.plist was ever generated — those keys were inert. Added
    `GENERATE_INFOPLIST_FILE: YES` to both the `StudyLapse` and
    `StudyLapseTests` target settings.
  - docs/SETUP.md's embedded `project.yml` and `ci.yml` snippets updated to
    match all of the above so the spec doc doesn't go stale.

- 2026-08-26, commit 6296a00: the `simulator` job's device pin
  (`platform=iOS Simulator,name=iPhone 17`, set in c25c813 above) is the same
  class of bug that broke the `app` job originally — a hardcoded model name
  that silently breaks whenever GitHub rotates the `macos-latest` simulator
  image. Replaced it with a step that queries `xcrun simctl list devices
  available -j` on the runner itself and picks whatever iPhone is actually
  present, via `jq`, then tests against `-destination 'id=<that udid>'`.
  Confirmed green on run 32997397929.

- 2026-08-26, Phase 1 (commits 70e2772, aec8db9): the `CaptureControllerTests`
  synthetic-capture test failed twice before going green, both times in ways
  worth recording since they'll recur if this pattern is reused later:
  - Run 33002993690: `frameCount` was 4, not 20. `AVAssetWriterInput` was
    appended to in a tight burst with no real-time pacing (`SyntheticFrameSource`
    has no delay between virtual ticks), so `isReadyForMoreMediaData` went
    false faster than the encoder drained and the code silently dropped
    accepted frames instead of waiting. Fixed by polling `isReadyForMoreMediaData`
    (5ms steps, up to 1s) before giving up — this only engages on frames
    gating already accepted, so it's cheap. `CaptureController.swift`.
  - Run 33003482444: `frameCount` and asset `duration` then matched (20,
    ~0.667s) but a raw `AVAssetReaderTrackOutput` sample count read back 24,
    not 20. Both authoritative checks (the writer's own successful-append
    count, and the independently re-read asset duration) agreed on 20, so
    this is not a `CaptureController` gating bug — but the *root cause of the
    extra 4 raw samples is not fully confirmed*. (An earlier version of this
    note guessed "HEVC B-frame reordering" — that explanation is wrong:
    reordering changes decode order, not sample count. Don't trust it.)
    Relaxed the raw-sample-count assertion to a lower bound (`>= 20`) rather
    than exact equality. A follow-up run (33005802165) added a stricter
    timestamp-range assertion to probe further and got one real data point
    before being dialed back: the furthest raw sample's PTS was exactly
    `20/30`s — one full frame (1/30s) beyond the last real append at `19/30`s.
    That's consistent with the HEVC encoder padding a closing frame at
    `finishWriting()` to satisfy its GOP structure (`AVVideoMaxKeyFrameIntervalKey:
    30` with only 20 frames written is less than one full GOP) — a real,
    plausible mechanism, but still not confirmed by inspecting the actual
    frame content. Either way it sits inside BUILD.md's own "±1 frame"
    tolerance on the device duration criterion, so it doesn't block Phase 1.
    `frameCount` + `duration` remain the authoritative "exactly 20 frames"
    proof; the raw-sample read is a lower-bound sanity check only.
    `CaptureControllerTests.swift`. If this resurfaces against a real device
    file once Mac access returns, re-examine with `ffprobe` or similar rather
    than assuming any explanation above without checking.

- 2026-08-26, commit f7a746a: while checking the `[device]` "no warnings in
  `Capture/`" criterion against the CI build log before checking that box
  (rather than assuming it was clean), found a real Swift 6 concurrency
  warning at `CaptureController.swift:71` — `capture of 'self' with
  non-Sendable type 'CaptureController?' in a '@Sendable' closure`, from the
  `finishClip()` `queue.async { [weak self] in ... }` closure. Fixed by
  declaring `CaptureController: @unchecked Sendable`, which is legitimate
  here (not a suppression): the class already guarantees every mutable field
  is touched only on its own private serial `queue`, the compiler just can't
  see that invariant on its own. Confirmed zero warnings in the next run
  (33021301863).

---

## Update protocol

Write to this file when any of these happen:

- A phase completes — move it to Done with the date and note any deviations
- A phase's individual criterion completes — check the box
- Work stops mid-phase — update **Next action** to the specific next step, not a
  vague area. "Implement `TagRangeMath.resize` per Phase 0 criterion 5" is
  resumable; "continue on core" is not
- Something becomes blocked — add it to Blocked with the question ID
- Implementation diverges from a spec doc — log it under Deviations *and* update
  the spec doc itself (standing rule 2)

**Next action** is the highest-value field. It should always be specific enough
to start typing from.

---

## Unattended session protocol

This project is worked in long autonomous sessions launched by a relaunch script.
A session may be started cold at any time, may be killed mid-task by a usage
limit or a context exhaustion, and will be restarted later with no memory of what
came before. **This file is the only continuity.** Treat every write to it as a
handoff note to a stranger.

### The work loop

1. Take the next unchecked item from **In progress**.
2. Implement it. One concern per commit; small diffs fail legibly.
3. Commit and push.
4. `gh run watch` and wait for the verdict.
5. If red: `gh run view --log-failed`, fix, push again. Delegate log reading to
   a subagent that reports back only the failing target, file, line, and error
   text — never pull a full build log into the main context.
6. If green: check the box here, update **Next action**, commit that too.

### Hard rules

- **Nothing compiles locally.** The dev machine is Windows with no Swift
  toolchain, no Xcode, no simulator, no `brew`. Do not run `xcodebuild`,
  `swift build`, `swift test`, `xcrun`, `xcodegen`, or `brew`. CI is the only
  compiler. See CLAUDE.md.
- **Never check off a `[device]` or `[eyes-on]` criterion.** Move it to *Needs
  developer verification* with a note on what to look for.
- **Three-strike rule.** If the same test or build fails three consecutive
  pushes, stop working on it. Record what was tried and what was ruled out under
  *Blocked*, then move to the next unblocked item.
- **Never stop and wait for the developer.** They are asleep. Standing rule 3
  still holds — do not invent unspecified behavior — but log the question in
  OPEN_QUESTIONS.md and switch to a task that is not blocked by it.
- **Do not start work you may not finish.** Prefer leaving the repo green and
  coherent over a half-done refactor. Never end a session on a red build if a
  revert would make it green.

### Ending a session

Before stopping for any reason — task done, context nearly exhausted, usage limit
hit, three-strike stop — do this first, while there is still room to do it:

1. Commit and push whatever is coherent. Never leave work only on disk.
2. Update **Next action** to a specific, resumable instruction.
3. Add a dated line under **Session log** below.

If you notice context running low mid-task, stop the task and do the above. A
clean handoff beats one more file.

### On usage limits

A usage limit is a normal end to a session, not a failure. It is not worth
working around: do not try to sleep and wait it out inside the session, and do
not switch approaches to conserve tokens at the cost of doing the work properly.
The relaunch script handles the waiting — it restarts a fresh session on a fixed
interval, and a restart that lands before the limit resets simply exits and tries
again later.

What this means in practice: the cost of hitting a limit is bounded entirely by
how good your last STATUS.md write was. Keep it current as you go, rather than
planning to tidy it up at the end — the end may not be yours to choose.

## Session log

Newest last. One line per session: date, what moved, how it ended.

- 2026-08-24 — spec suite generated, no code yet.
- 2026-08-26 — repo scaffolding and initial CI workflow pushed; a subsequent
  run (32995981666) failed 3 of 4 jobs on config bugs (see Deviations), fixed
  and pushed as c25c813, confirmed green (32996684332). Then committed and
  pushed all four Phase 0 `StudyLapseCore` math files (`TimeAxis`,
  `DayBoundary`, `TagRangeMath`, `Formatters`, tests, ≥1000-case property
  test) plus a further CI hardening fix (dynamic simulator lookup replacing
  the `iPhone 17` pin) as commit 6296a00 — run 32997397929 came back green on
  all four jobs. Developer sideloaded the resulting .ipa via Sideloadly and
  confirmed the placeholder view launches. **Phase 0 complete.** Next session
  starts Phase 1 (real camera capture).
- 2026-08-26 — Phase 1: pushed `FrameSource`/`CameraFrameSource`/
  `SyntheticFrameSource`, `CaptureController`, `DebugLog`, `StorageLocator`
  (commit 6ed0526); the synthetic-capture CI test failed twice on real bugs
  (writer backpressure dropping frames, then a HEVC raw-sample-count
  question — see Deviations) before going green as commits 70e2772 and
  aec8db9. Pushed the minimal Record/Playback/DebugLog screens on top
  (commit 642b54d) — run 33004332059 green on all four jobs. Checked off
  Phase 1's two `[ci]` criteria and wrote up the remaining `[device]`/
  `[eyes-on]` ones under Needs developer verification (commit 983d1e3).
  A second-opinion pass caught a wrong root-cause guess in that Deviations
  note ("B-frame reordering" doesn't fit the mechanism) and two gaps in the
  verification writeup — fixed the explanation, added backup-exclusion
  logging at launch, and added a debug-log-overflow caveat (commit c09ceb7).
  Chasing the sample-count question one step further with a stricter test
  assertion (same commit) turned red with a real, useful data point — the
  extra raw samples sit exactly one frame past the last real append,
  consistent with encoder GOP-closing padding — then got dialed back to a
  lower-bound check plus an honest note, since it's exploratory rather than
  a literal BUILD.md criterion and already sits inside the criterion's own
  ±1 frame tolerance. Developer then sideloaded run 33006800466 and
  confirmed all six remaining `[device]`/`[eyes-on]` criteria: capture ran,
  playback was recognisably sped-up with no strobing, the debug log showed
  ~3s-spaced accepted-frame lines and copy worked, the backup-exclusion log
  line was correct, and no crash. Before checking the "no warnings in
  `Capture/`" box on the strength of that, actually read the CI build log
  rather than assume — found a real Sendable-closure warning at
  `CaptureController.swift:71`, fixed it (`@unchecked Sendable`, justified
  by the class's existing serial-queue invariant), confirmed zero warnings
  on the next run (33021301863, commit f7a746a). **Phase 1 complete**, all
  eight BUILD.md criteria checked. Two caveats logged in STATUS.md Done for
  next time: the SSH-build and `devicectl` criteria were satisfied via the
  CI+sideload substitution, not literally, and the duration criterion was
  confirmed qualitatively rather than by reading `AVAsset.duration`
  numerically — both fine for now, worth a literal check once Mac access
  returns. Next session starts Phase 2 (SwiftData stack, `SessionCoordinator`,
  chunked writing at 120s/1000 frames, scene-phase auto-pause, launch
  recovery) per BUILD.md.
- 2026-08-27 — Phase 2, code-complete in one session, no three-strike stalls.
  Commits, each green on CI: (1) STATUS/BUILD — criterion 1 marked done
  (Phase 0 suite covers it verbatim), `[device]`-tag conflict on criteria
  2/3/4 logged; (2) seven SwiftData `@Model` entities + `ModelContainerFactory`;
  (3) `StudyOffsets.recompute` + `StudyOffsetsTests` (incl. 200-iter random
  op sequence); (4) chunked writing with frame-safe PTS-based rollover (D-015),
  `SyntheticFrameSource` monotonic tick cursor, rollover frame-sum test;
  (5) `ClipRecovery` (repair/delete unfinalized, demote `.recording`) +
  `ClipRecoveryTests` with real file truncation; (6) `SessionCoordinator` —
  one red run first (`DayBoundary` needed `import StudyLapseCore` in the app
  target, which had never imported the package before), fixed and green;
  (7) app wiring + Phase 2 `RecordView`. Then an `NSLock` async-context
  warning in a test helper fixed (`withLock`). 15 simulator tests + 20 core
  tests all green. Interface tension resolved in `CaptureController`'s favour
  (media-only, per D-026) with docs/CAPTURE.md updated in the same commit;
  `ghost.jpg`/`thumbnail.jpg` deferred to Phases 7/5 — both logged under
  Deviations. Phase 2 stays *In progress*: all six remaining criteria are
  `[device]`/`[eyes-on]` and written up under *Needs developer verification*
  with exact repro steps. Session ended cleanly with the repo green; next
  agent action is Phase 3 once the developer signs off, or fixing any
  device-check failures they report.
- 2026-08-27 (same session, second-opinion follow-up) — a review pass flagged
  two gaps: (1) `resume()` could silently no-op (plain `return` guards) leaving
  the record button dead with no feedback — changed to throw `.noSession` /
  `.notResumable` so `RecordView` surfaces it; (2) criterion 3's recovery test
  truncated a *cleanly finalized* file, but a real force-quit leaves **no row
  at all** for the in-flight chunk, so `recoverUnfinalized`'s core branch was
  dead code in production. Fixed with insert-on-open (`onClipOpened` →
  unfinalized `Clip` row) so recovery is actually reachable, matching
  docs/CAPTURE.md's flow. Added `testForceQuitMidChunkIsResolvedByRecovery`
  (drops the coordinator mid-chunk, no pause/end) and an opened-index assertion
  to the rollover test. docs/CAPTURE.md updated. Still green.
- 2026-08-27 (device feedback) — developer sideloaded and confirmed Phase 2
  behaves: force-quit recovery, the 4-not-14-min study time, cross-kill
  persistence. Two notes: (1) the timer "snaps to the next multiple of 3s" on
  pause/resume — expected, not a bug: study time is
  `frameCount * captureInterval` (D-003) and the 1 Hz free-running counter
  reconciles to the true frame count on every stop; the number is right, could
  smooth the display later. (2) **Regression found and fixed**: the Phase 2
  `RecordView` rewrite dropped Phase 1's playback path, so captured clips
  couldn't be viewed on device. Restored as `ClipsDebugView` — a debug-only
  browser over every session's clips with tap-to-play, reached from the
  `RecordView` toolbar next to the Debug Log (same rationale as D-024). The
  real library stays Phase 5.
- 2026-08-27 — developer accepted criterion 2 on the CI test and checked the
  box. **Phase 2 complete**, all six criteria checked, moved to Done. Developer
  explicitly asked to hold before Phase 3 — not started. Repo green.
- 2026-08-27 — Phase 3 built in one session. Commits, each chased to green on
  CI: (1) `StudyLapseCore` — `TimeAxis.outputDuration` + `TimerOverlay`
  keyframes + tests (one red first: arrays of tuples aren't `Equatable`);
  (2) the `Export/` module — `AVFoundationSessionExporter`, `OverlayLayerBuilder`,
  `ExportCoordinator`, `SilentAudio`, `PhotosSaver`, `ExportModels`
  (`ExportPlan` value type); (3) fix a main-actor default-arg init;
  (4) **split the exporter into `prepare()`/`render()`** after the first render
  run crash-looped the simulator test host ("Lost connection to IOSurface
  Remote Server" — the `AVVideoCompositionCoreAnimationTool` path doesn't work
  in headless CI). CI now verifies the composition graph + overlay layer tree
  from `prepare()`; the real render is device-only. A `SyntheticFrameSource`
  buffer-fill added for a since-removed pixel test was reverted (it made
  `testChunkRolloverPreservesTotalFrameCount` crash on memory pressure —
  9000 × 8 MB memsets). (5) `ExportView` + `ClipsDebugView` entry + STATUS /
  BUILD / EXPORT.md / TESTING.md. All 24 simulator tests + core tests green.
  **Phase 3 is code-complete; none of its six criteria are checked** — all are
  `[device]`/`[eyes-on]`, written up under *Needs developer verification* with
  exact repro steps. Next agent action: fix anything the device checks turn
  up, else Phase 4.
- 2026-08-27 — three follow-ups before the developer's 1-hour test: (a) idle
  timer / screen-stays-on hardening (re-assert on foreground while recording,
  debug-log the state) — the mechanism was already correct, this makes it
  verifiable and robust to app-switches; (b) **fixed the speed math** — the
  export multiplier was stacked on top of the capture-interval compression
  (100× → ~6000× net). Now `speed` is net real-time on the same axis as
  `minimumSpeed`, `outputDuration = study/speed`. Touched `TimeAxis`,
  `ExportCoordinator.isClampedToFloor`, the tests, `ExportView` stepper, and
  docs/DATA_MODEL.md + BUILD.md criterion 2 + docs/EXPORT.md; (c) **default
  capture interval 3s → 2s** (D-006, account-holder call) — `?? 2` fallbacks,
  DECISIONS + docs updated, `SessionCoordinatorTests` pins 3s in setup. All
  green on CI.
- 2026-08-27 — added a post-render track-summary line to the debug log
  (`Export verify: N video + M audio track(s); file X.XXs, audio track Y.YYs`)
  so criterion 3 is checkable on device. Developer then sideloaded and
  **verified all six Phase 3 criteria** — duration/net-speed, floor clamp,
  audio track, zero-clip error, timer legibility + total, 9:16 crop.
  **Phase 3 complete**, all boxes checked in BUILD.md, moved to Done. Repo
  green. Next: Phase 4 (tagging).
- 2026-08-27 — Phase 4 built in one session on branch `phase-4-tagging`, three
  commits each chased to green on CI: (1) `TagRangeSeeding` + `end()` wiring +
  `lastEndedSession` + `TagRangeSeedingTests`, BUILD.md criteria 1–2 checked;
  (2) `TagCatalog` (autocomplete, derived use counts) + `TagEditor`
  (`TagRangeMath` round-trip onto `@Model` rows) + `TagCatalogTests` /
  `TagEditorTests` (incl. 300-op random sequence refetching rows);
  (3) tagging screens (`TaggingFlowView` / `TaggingView` / `SegmentListView` /
  `TagSliderView` / `TagFieldSheet`), `RecordView` End → Tagging → Export
  wiring, STATUS / BUILD / docs. Advisor pass up front caught the seeding race
  (async rollover-clip persistence vs. `end()`) — seeding made repairing, not
  one-shot. Five Deviations logged (`lastEndedSession`, repairing seed, derived
  `useCount`, explicit slider Split/Merge, kept debug export link). **Phase 4
  stays *In progress*** — criteria 1–2 (`[ci]`) green, 3 (`[device]`, proven in
  CI) and 4 (`[eyes-on]`) written up under *Needs developer verification*. Repo
  green. Next agent action: fix anything the device checks surface, else
  Phase 5 (library + stats).