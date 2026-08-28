# Build Plan

Phases are vertical slices. Each one runs end to end on a real device when
complete.

On finishing a phase: verify every acceptance criterion, then update STATUS.md
before starting the next phase.

Criteria are marked `[ci]` (provable on a GitHub Actions macOS runner),
`[device]` (must run on a physical iPhone) or `[eyes-on]` (needs the developer
looking at the phone). During the no-Mac period, `[device]` and `[eyes-on]` are
still reachable by sideloading the unsigned .ipa CI artifact with a free Apple
ID — see docs/SETUP.md. A green CI run never satisfies a `[device]` or
`[eyes-on]` criterion.

---

## Phase 0 — Core logic, provable without a Mac

There is currently no Mac access. This phase is scoped entirely to what GitHub
Actions can compile and test: the pure-logic package that every later phase
depends on. It deliberately pulls the `StudyLapseCore` work out of Phases 2 and 4
so that the no-Mac period produces real, permanent progress rather than
unverifiable code.

**Scope**
- Repo layout, `.gitignore`, `project.yml`, `.github/workflows/ci.yml` per
  docs/SETUP.md
- A minimal app target: `StudyLapseApp.swift` plus one placeholder SwiftUI view,
  so all three CI jobs are green from the first commit rather than failing until
  Phase 1
- `StudyLapseCore` Swift package — Foundation only, no Apple frameworks
- `TimeAxis`: study/output conversions, speed computation, minimum-speed floor
- `DayBoundary`: `dayKey` and `closeDeadline` with a configurable cutoff hour
- `TagRangeMath`: seed, split, merge, resize, tiling validation
- `Formatters`: `H:MM` and `MM:SS`
- Full unit test suite for all of the above, including a property test over
  random tag-range operation sequences

**Non-goals for this phase**
- No real app functionality — the app target is a placeholder view whose only
  job is to compile and archive
- No committed `.xcodeproj`; it is generated from `project.yml` (D-025)
- No final bundle identifier — the placeholder prefix is fine, since the
  sideloader rewrites it (Q-001)
- No SwiftData, no AVFoundation
- No attempt to sign or install anything

**Interface contracts established**

Identical to the `StudyLapseCore` signatures listed under Phases 2 and 4; those
phases consume this package rather than defining it.

```
project.yml
.github/workflows/ci.yml
StudyLapse/
  App/StudyLapseApp.swift          placeholder @main + one view
StudyLapseCore/Sources/StudyLapseCore/
  TimeAxis.swift
  DayBoundary.swift
  TagRangeMath.swift
  Formatters.swift
```

**Acceptance criteria**
- [x] `[ci]` `swift test --package-path StudyLapseCore` passes on a macOS runner
- [x] `[ci]` a session of clip durations [120s, 300s, 60s] reports 480s of study
      time
- [x] `[ci]` `dayKey` for 02:30 with cutoff hour 4 returns the previous date, and
      `closeDeadline` lands at 04:00 the following day
- [x] `[ci]` `minimumSpeed(interval: 3, fps: 30)` returns 90, and a fit-to-15s
      request on a 9-hour session clamps to that floor
- [x] `[ci]` `TagRangeMath.validate` holds after any random sequence of split,
      merge, and resize operations (property test, ≥1000 cases)
- [x] `[ci]` no import of SwiftData, AVFoundation, SwiftUI, or UIKit anywhere in
      the package — assert with a grep step in CI
- [x] `[ci]` `xcodegen generate` followed by a simulator build succeeds
- [x] `[ci]` the `ipa` job uploads a `StudyLapse.ipa` artifact
- [x] `[device]` that artifact sideloads with a free Apple ID and launches on the
      phone showing the placeholder view — this proves the whole delivery
      pipeline before any real code depends on it

**Deferred to Mac access:** day-boundary tests must be re-run on Apple's
Foundation before Phase 2 is marked complete. swift-corelibs-Foundation's
`Calendar` behavior differs subtly, and CI runs on macOS but the package is
written to be Linux/Windows-portable — verify on the real target.

**Depends on:** none

---

## Phase 1 — One clip, captured and played back on device

**Runnable without a Mac.** CI produces an unsigned .ipa which is signed with a
free Apple ID and sideloaded from Windows (docs/SETUP.md). `[device]` and
`[eyes-on]` criteria are therefore achievable now. What is *not* available is the
debugger and `os_log` console — hence the on-device debug log below, which is not
optional.

The thinnest path that proves capture, writing, storage, and the SSH build/deploy
loop all work. Deploy is part of this phase deliberately, so environment pain
surfaces on day one.

**Scope**
- Xcode project, `StudyLapseCore` package, app target, iOS 17 deployment target
- Camera permission prime and request
- `CaptureController` capturing at a fixed 3s interval into one HEVC clip
- Hardcoded 60-second capture, then finalize
- Playback of the written file with `AVPlayer` on a bare screen
- **On-device debug log**: an append-only in-memory ring buffer surfaced on a
  scrollable screen with a copy-to-clipboard action. With no console access this
  is the only way to see what capture is doing. Every capture event — session
  configured, frame accepted, frame gated out, writer started, writer finished,
  error thrown — writes a line with a timestamp

**Non-goals for this phase**
- No SwiftData, no sessions, no pause/resume, no overlay, no UI polish
- No chunking, no recovery, no guards
- Do not let `CaptureController` own an `AVCaptureSession` — it consumes a
  `FrameSource` from the start (D-026, docs/TESTING.md). Introducing the seam
  later means rewriting the pipeline
- No Live Activity or widget extension — a second bundle ID counts against the
  free Apple ID's three-app limit (docs/SETUP.md)

**Interface contracts established**
```
StudyLapse/Capture/CaptureController.swift
  final class CaptureController {
      init(source: FrameSource, clock: Clock)
      func startClip(to url: URL, intervalSeconds: Double, outputFrameRate: Int32) throws
      func finishClip() async throws -> (frameCount: Int, url: URL)
  }

StudyLapse/Capture/FrameSource.swift
  protocol FrameSource: AnyObject {
      var onFrame: ((CVPixelBuffer, CMTime) -> Void)? { get set }
      func start() throws
      func stop()
  }
  final class CameraFrameSource: FrameSource      // device only
  final class SyntheticFrameSource: FrameSource   // CI

StudyLapse/Shared/DebugLog.swift
  enum DebugLog {
      static func write(_ category: String, _ message: String)
      static var lines: [String] { get }      // newest last, capped at 2000
      static func clear()
  }

StudyLapse/Storage/StorageLocator.swift
  enum StorageLocator {
      static var root: URL                       // Application Support/StudyLapse
      static func url(forRelativePath: String) -> URL
      static func relativePath(for: URL) -> String
  }
```

**Acceptance criteria**
- [x] `[ci]` the app target compiles for the simulator with
      `CODE_SIGNING_ALLOWED=NO`
- [x] `[ci]` driving `CaptureController` with a `SyntheticFrameSource` at a
      3s virtual interval for 60 virtual seconds writes a file with exactly 20
      frames, verified by reading the written asset back
- [x] `[device]` `xcodebuild ... build` succeeds over SSH with no warnings in
      `Capture/`
- [x] `[device]` `xcrun devicectl device install app` and `process launch`
      put the app on the phone and start it
- [x] `[device]` after a 60s capture at a 3s interval, the written file exists
      and `AVAsset.duration` is 20 frames / 30fps ≈ 0.67s (±1 frame)
- [x] `[device]` `StorageLocator.root` has `isExcludedFromBackup == true`
- [x] `[eyes-on]` playback shows a recognisable sped-up view of the scene, with
      no exposure strobing across the clip
- [x] `[eyes-on]` the debug log screen shows accepted-frame lines roughly 3s
      apart and can be copied out for pasting back into a session

**Depends on:** Phase 0

---

## Phase 2 — A real multi-clip session with correct study time

Introduces persistence and the model that everything else rests on.

**Scope**
- SwiftData stack and all entities from docs/DATA_MODEL.md
- `SessionCoordinator` with start / pause / resume / end
- Chunked writing every 120s or 1000 frames (D-015)
- `studyOffsetStart` recomputation and the tiling invariant
- `StudyLapseCore`: `TimeAxis`, `DayBoundary`, `Formatters` with unit tests
- Scene-phase auto-pause (D-016) and launch recovery of unfinalized clips
- Minimal record screen: timer, record/pause/resume/end, clip count

**Non-goals for this phase**
- No tagging, no export, no library, no Live Activity, no guards, no dimming
- No ghost overlay

**Interface contracts established**
```
StudyLapseCore/Sources/StudyLapseCore/TimeAxis.swift
  enum TimeAxis {
      static func studySeconds(clipOffset: Double, frameIndex: Int, interval: Double) -> Double
      static func speed(mode: SpeedMode, totalStudySeconds: Double,
                        interval: Double, fps: Int32) -> Double
      static func minimumSpeed(interval: Double, fps: Int32) -> Double
  }

StudyLapseCore/Sources/StudyLapseCore/DayBoundary.swift
  struct DayBoundary {
      init(cutoffHour: Int)
      func dayKey(for date: Date, calendar: Calendar) -> String
      func closeDeadline(forDayKey: String, calendar: Calendar) -> Date
  }

StudyLapse/App/SessionCoordinator.swift
  @Observable final class SessionCoordinator {
      func startNewSession() throws
      func pause() async
      func resume() throws
      func end() async
      func handleScenePhase(_ phase: ScenePhase) async
      func recoverOnLaunch() async
  }
```

**Acceptance criteria**
- [x] `[ci]` `StudyLapseCoreTests` pass, including: a session of clips
      [120s, 300s, 60s] reports 480s study time; `dayKey` for 02:30 with cutoff 4
      returns the previous date; `closeDeadline` lands at 04:00 the following day
- [x] `[device]` the `studyOffsetStart` tiling invariant is asserted by a test
      that inserts, finalizes, and deletes clips in arbitrary order
      — accepted on the strength of the CI simulator test (`StudyOffsetsTests`,
      incl. 200-case random insert/finalize/delete sequence); pure model math,
      no device-specific behavior. Developer sign-off 2026-08-27.
- [x] `[device]` force-quitting mid-clip and relaunching leaves at most 120s of
      lost study time and no `isFinalized == false` rows
      — developer confirmed on device 2026-08-27
- [x] `[device]` a session left `.recording` at launch is moved to `.paused`
      — developer confirmed on device 2026-08-27
- [x] `[eyes-on]` record 2 min, background the app, return 10 min later, resume,
      record 2 min: the timer reads ~4 min, not ~14 min
      — developer confirmed on device 2026-08-27
- [x] `[eyes-on]` the session persists across a full app kill and relaunch
      — developer confirmed on device 2026-08-27

**Depends on:** Phase 1

---

## Phase 3 — Export with a burned-in timer, saved to Photos

Closes the core loop: study, then get a postable video out.

**Scope**
- `ExportCoordinator` and the composition pipeline in docs/EXPORT.md
- Speed by multiplier and fit-to-duration, with minimum-speed clamping
- Three aspect presets
- Timer overlay: one style (`minimal`), four corner positions
- Silent audio track
- Save to Photos and share sheet
- Export screen with live estimated output duration and render progress

**Non-goals for this phase**
- No intro/outro cards, no additional overlay styles, no voiceover
- No re-export from the library, no export records UI

**Interface contracts established**
```
StudyLapse/Export/SessionExporter.swift
  protocol SessionExporter {
      func export(_ request: ExportRequest,
                  progress: @escaping (Double) -> Void) async throws -> URL
  }
  struct ExportRequest { let session: Session; let profile: ExportProfile
                         let voiceoverTakes: [VoiceoverTake] }

StudyLapse/Export/OverlayLayerBuilder.swift
  enum OverlayLayerBuilder {
      static func build(renderSize: CGSize, profile: ExportProfile,
                        totalStudySeconds: Double, outputDuration: Double) -> CALayer
  }
```

**Acceptance criteria**
- [x] `[device]` exporting a 3-clip session produces a file whose duration
      matches the computed net speed within 100 ms — the multiplier is net
      real-time, so a 100x export of a 1-hour session is ~36s of video, not
      0.6s (it is not stacked on the capture-interval compression)
- [x] `[device]` when the minimum-speed floor binds (a short session with a
      long fit-to target — e.g. 20 min fit to 60s), the export clamps to the
      floor and the UI-reported duration equals the actual output duration
- [x] `[device]` the exported file has an audio track of the full duration
- [x] `[device]` export of a session with zero finalized clips fails with a
      typed error rather than crashing
- [x] `[eyes-on]` the burned-in timer counts study time, is legible at speed, and
      ends at the session's total study time
- [x] `[eyes-on]` the 9:16 export is centre-cropped without stretching and the
      result plays correctly in the Photos app

All six confirmed on device 2026-08-27 (developer sideloaded and verified;
audio track checked via the `Export verify:` debug-log line).

**Depends on:** Phase 2

---

## Phase 4 — Tagging: segment list and slider

**Scope**
- `TagRange` seeding at clip boundaries on session end
- `Tag` entity with autocomplete and use counts
- Segment list screen (default flow)
- Slider screen with split, merge, resize
- `TagRangeMath` is already built and tested in Phase 0 — this phase consumes it,
  and must not redefine or fork it

**Non-goals for this phase**
- No tag colours beyond an auto-assigned palette, no per-tag goals
- No filtering the library by tag yet

**Interface contracts established**
```
StudyLapseCore/Sources/StudyLapseCore/TagRangeMath.swift
  struct Range { var start: Double; var end: Double; var tags: [String] }
  enum TagRangeMath {
      static func seed(fromClipDurations: [Double]) -> [Range]
      static func split(_ ranges: [Range], at: Double) -> [Range]
      static func merge(_ ranges: [Range], at index: Int) -> [Range]
      static func resize(_ ranges: [Range], boundaryIndex: Int, to: Double) -> [Range]
      static func validate(_ ranges: [Range], total: Double) -> Bool  // tiling
  }
```

**Acceptance criteria**
- [x] `[ci]` `validate` returns true after any sequence of split, merge, and
      resize operations, verified by a property test over random operation
      sequences
      — `TagRangeMathTests.testTilingInvariantHoldsUnderRandomOperationSequences`
      (≥1000 cases), green on CI run 33052241705
- [x] `[ci]` resizing a boundary never produces a zero-length or negative
      range
      — `TagRangeMathTests.testResizeNeverProducesDegenerateRangeOverRandomSequences`
      (50 trials × 400 ops, splits interleaved), green on CI run 33052241705
- [x] `[device]` ending a session seeds exactly one range per finalized clip
      — proven in CI by `TagRangeSeedingTests` (pure model math, no
      device-specific behaviour; same `[device]`-tag conflict as Phase 2's
      criteria 2/3/4). Developer sign-off 2026-08-27.
- [x] `[eyes-on]` dragging a slider handle on a 9-hour session moves the boundary
      smoothly and the adjacent durations update live
      — developer confirmed on device 2026-08-27.

**Depends on:** Phase 2

---

## Phase 5 — Library and stats

**Scope**
- Library grid, session detail sheet, delete (rows + directory together)
- Re-export from a past session
- Stats: totals, streak, per-tag split, calendar heatmap, explicit untagged band
- Orphaned-directory sweep on launch
- Manual per-session source-clip purge (D-005)

**Non-goals for this phase**
- No search, no bulk operations, no export of stats

**Acceptance criteria**
- [x] `[device]` deleting a session removes both its rows and its directory
      — `SessionStorageTests.testDeleteSessionRemovesRowsAndDirectory` (real
      directories; cascade + `FileManager` removal). Developer sign-off
      2026-08-27 on the sideloaded `main` build.
- [x] `[device]` a directory with no matching row is removed by the launch sweep
      — `SessionStorageTests.testSweepRemovesOrphanDirectoryButKeepsKnownAndUnparseable`
      (UUID-named orphan removed; known session + non-UUID name left alone).
      Sweep wired into `SessionCoordinator.recoverOnLaunch`. Developer sign-off
      2026-08-27.
- [x] `[device]` purging sources leaves exports playable and marks the session
      as non-re-exportable in the model
      — `SessionStorageTests.testPurgeSourcesKeepsRowsAndExportsAndBlocksReExport`
      (clip files gone, `Clip` rows + study-time total + exports kept,
      `sourcesPurgedAt` set, `ExportCoordinator.buildPlan` throws
      `.sourcesPurged`). Export playability confirmed on device. Developer
      sign-off 2026-08-27.
- [x] `[device]` streak computation uses `dayKey`, so a session ending at 02:00
      counts toward the previous day
      — `StatsTests.testStreakUsesDayKeyNotWallClock` + 8 other streak cases;
      `StatsView` passes `session.dayKey`, never wall clock. Developer sign-off
      2026-08-27.
- [x] `[eyes-on]` the heatmap and per-tag split match a hand-checked week
      — `Stats.perTagSplit` / heatmap bucketing unit-tested; developer
      eyeballed the on-screen result on the sideloaded `main` build 2026-08-27.

**Depends on:** Phases 3 and 4

---

## Phase 6 — Voiceover

**Scope**
- `VoiceoverCoordinator`, `AVAudioRecorder`, take management
- Voiceover screen: scrubber, timeline strip, record/mute/delete/re-record
- Overlap prevention
- Audio mix at export with 50 ms fades
- Profile-revision staleness detection and the stale banner

**Non-goals for this phase**
- No noise reduction, no ducking, no waveform rendering, no trimming within a take

**Interface contracts established**
```
StudyLapse/Voiceover/VoiceoverCoordinator.swift
  @Observable final class VoiceoverCoordinator {
      func startTake(at outputSeconds: Double) throws
      func stopTake() async -> VoiceoverTake
      func delete(_ take: VoiceoverTake)
      func staleTakes(for profile: ExportProfile) -> [VoiceoverTake]
  }
```

**Acceptance criteria**
- [x] `[device]` a take recorded at output position 12.0s appears in the
      re-exported file starting at 12.0s ±50 ms
      — CI proves placement: `ExportTests.testVoiceoverTakesBecomeCompositionTracksAtTheirOutputPositions`
      asserts the take's composition-track segment target starts at exactly
      `outputStartSeconds` (±1 frame). Developer accepted on the CI test
      2026-08-27; the render + listen is a still-pending device check.
- [x] `[device]` changing the export profile bumps `revision` and marks existing
      takes stale; stale takes are excluded from export
      — CI proves the logic: `ExportProfileRevisionTests` (bump semantics),
      `VoiceoverCoordinatorTests.testStaleTakesTrackTheProfileRevision` +
      `testExportSnapshotsFilterAndResolve` (stale/muted excluded from the mix).
      Developer sign-off 2026-08-27.
- [x] `[device]` the record button is disabled when the playhead is inside an
      existing take
      — CI proves the logic: `VoiceoverTimelineTests.testPlayheadInsideTakeIsDetected`,
      `VoiceoverCoordinatorTests.testRecordButtonGatingInsideAnExistingTake`.
      Developer sign-off 2026-08-27.
- [x] `[eyes-on]` a recorded voiceover plays back in sync with the video and has
      no audible click at take boundaries
      — CI proves only that the 50 ms-fade `AVMutableAudioMix` is built and
      keyed to the composition take tracks
      (`testVoiceoverTakesBecomeCompositionTracksAtTheirOutputPositions`
      checks `inputParameters.trackID`). Developer accepted on that basis
      2026-08-27; audibility is a still-pending ears-on check (STATUS.md).

All four are `[device]`/`[eyes-on]`; the developer accepted them on the CI
tests that prove the logic (2026-08-27, "good enough for now"). The on-device
render/listen checks remain in STATUS.md under *Needs developer verification*
as optional confirmation.

**Depends on:** Phase 3

---

## Phase 7 — Live Activity, guards, and dimming

Everything that makes the day-spanning session model actually usable.

**Scope**
- Widget extension, `ActivityAttributes`, App Intent Resume action, deep link
- Battery, thermal, and disk guards per docs/CAPTURE.md
- Screen dimming and idle-timer handling
- ~~Ghost overlay on resume~~ — built, then removed same day at the
  developer's request (2026-08-28): superseded by the live preview now
  showing continuously (see below), which makes a static last-frame overlay
  redundant. docs/CAPTURE.md's "Framing continuity" section rewritten.
- Exposure and white-balance locking across clips
- Framing guide with the 9:16 safe area
- **Camera preview extended to show continuously, including while
  recording** (developer request, 2026-08-28) — resolves Q-005 (now in
  DECISIONS.md as D-028); docs/UI.md screen 2 updated to match. Not
  originally scoped for this phase, but lands here since it reuses this
  phase's preview/framing-guide work.
- ~~Remaining overlay styles and intro/outro cards~~ — already shipped in
  Phase 3 (`OverlayLayerBuilder`'s `boxed`/`mono` styles and intro/outro
  cards), ahead of that phase's own stated non-goals. Nothing to do here.

**Non-goals for this phase**
- No home screen widget (needs App Groups — see Q-004)

**Acceptance criteria**
- [x] `[device]` each guard fires at its documented threshold in a test that
      injects synthetic battery/thermal/disk values
      — CI proves the logic: `CaptureGuardsTests` (every threshold in
      docs/CAPTURE.md's guard table, including the exclusive boundaries) and
      `GuardMonitorTests` (the same thresholds driven through
      `SessionCoordinator` via a synthetic `GuardSignalSource`, asserting the
      resulting `pause()`/`end()`/`warnings` behavior). Developer confirmed
      on device 2026-08-28.
- [x] `[device]` the Live Activity appears on pause and is dismissed on end
      — `SessionCoordinator.pause()` calls `LiveActivityManager.start`,
      `resume()`/`end()` call `.end()`. Developer confirmed on device
      2026-08-28.
- [x] `[eyes-on]` tapping Resume in the Live Activity opens the app already
      recording, in under 2 seconds
      — via a `studylapse://resume` deep link (`StudyLapseApp.onOpenURL`
      calls `coordinator.resume()`), not an `AppIntent` — see STATUS.md
      Deviations for why. Developer confirmed on device 2026-08-28.
- [x] `[eyes-on]` a 3-hour session shows no exposure strobing at clip boundaries
      — `CameraFrameSource.lockExposureAfterWarmup` (exposure + white balance
      locked ~1s after each session/resume), shipped in Phase 1, re-verified
      against this criterion for the first time. Developer confirmed on
      device 2026-08-28.
- [x] `[eyes-on]` screen brightness drops on record and restores on pause
      — `SessionCoordinator.setScreenDimmed` (`UIScreen.main.brightness` ->
      0.05 on record/resume, restored on pause/end). Developer confirmed on
      device 2026-08-28.

All five confirmed on device 2026-08-28. Two follow-up changes requested at
sign-off, done the same day: the ghost overlay was removed, and the camera
preview now shows continuously including while recording (see Scope above,
STATUS.md Deviations, and D-028).

**Depends on:** Phase 2

---

## Phase 8 — UI polish

Every screen through Phase 7 is functional-only — no design tokens, no
aesthetic pass (see STATUS.md's running "UI note" and the Phase 4/7 Done
entries). This phase is the one place that debt gets paid, deliberately
scheduled after every feature screen exists and before Phase 9 ships any of
them. Nothing in this phase changes behavior, data flow, or acceptance
criteria already met by earlier phases — it is a visual and interaction
pass over screens that already work.

**Scope**
- Apply docs/UI.md's "Design tokens" section (background/surface/text/accent
  colors, SF Pro Text / SF Mono type, 14pt corner radius, 4/8/12/16/24/32
  spacing scale) consistently across all six screens plus Stats
- Record (idle / recording / paused), Tagging (segment list + slider),
  Export, Voiceover, Library, and Stats all restyled to the token set —
  no screen skipped
- Fix the known rough edges called out in STATUS.md: `TagSliderView`'s
  hand-rolled per-segment tag label offset (Phase 4 Done), and the
  penultimate-vs-final timer value on the last export frame (Known
  limitations)
- Empty states for Library (no sessions yet) and Stats (no data yet) —
  currently unspecified, add them to docs/UI.md as part of this phase
  rather than leaving them blank
- Loading/transition states: render progress, tag-sheet open/close, tab
  switches — smooth within "system defaults and the recording pulse" per
  docs/UI.md's animation non-goal (do not add animation beyond that)
- VoiceOver pass: confirm the Record screen's coarser-cadence timer label
  (docs/UI.md Notes) and add accessibility labels anywhere a screen is
  icon-only or color-only
- Tag chip and calendar-heatmap color assignment reviewed for contrast
  against the dark palette, not just "does it render"

**Non-goals for this phase**
- No new screens, no new user-facing features, no new SwiftData fields
- No light/dark toggle, no iPad layout, no landscape — docs/UI.md's
  non-goals stand
- No changes to `TagRangeMath`, `TimeAxis`, export composition, or any
  other model/logic layer — this phase touches SwiftUI views and
  docs/UI.md only
- Live Activity visual polish stays in Phase 7's scope, not duplicated here

**Interface contracts established:** none — this phase restyles existing
views, it does not introduce new types or protocols.

**Acceptance criteria**
- [x] `[ci]` the app still builds and every existing simulator test still
      passes with no logic changes — a diff review confirms no file outside
      `Features/`, `Shared/`, and docs/UI.md changed
      — diff for the Phase 8 commit touches only `StudyLapse/Shared/DesignTokens.swift`
      (new), the eight `Features/` screen files, and `docs/UI.md` (+
      `OPEN_QUESTIONS.md`, a process doc, not code); all four CI jobs green
      on run 33151642437. No `StudyLapseCore`, `Model/`, `Capture/`,
      `Export/`, `Storage/`, or `Voiceover/` file touched — verified by
      `git show --stat`.
- [ ] `[eyes-on]` every screen (Record ×3 states, Tagging ×2 modes, Export,
      Voiceover, Library, Stats) uses the docs/UI.md token palette with no
      leftover system-default colors or fonts
      — code-complete: `DesignTokens.swift` implements the token palette;
      every screen restyled, no `.secondary`/`.red`/`.orange`/`.accentColor`/
      `Color.gray` left in `Features/` (verified by grep). Awaiting developer
      eyes-on (STATUS.md).
- [ ] `[eyes-on]` the `TagSliderView` per-segment label reads correctly at
      both a short (single-segment) and a long (9-hour, many-segment)
      session
      — code-complete: removed the redundant `.offset` that double-shifted
      the label past what `.overlay(alignment: .center)` already positioned
      correctly (STATUS.md *In progress*). Awaiting developer eyes-on.
- [ ] `[eyes-on]` Library and Stats each show a designed empty state on a
      fresh install with zero sessions, not a blank screen
      — code-complete: `EmptyStateView` (Shared/DesignTokens.swift) wired
      into both screens; docs/UI.md gained an "Empty states" section.
      Awaiting developer eyes-on.
- [ ] `[eyes-on]` VoiceOver reads the Record-screen timer label and every
      icon-only control without a missing or generic ("button") label
      — code-complete: throttled accessibility label + `.updatesFrequently`
      on the Record timer; explicit labels on the tag-remove button and
      heatmap cells. Awaiting developer eyes-on (VoiceOver can't be verified
      without a device).
- [ ] `[eyes-on]` the developer's read on the whole app, screen to screen, is
      "looks finished," not "looks like a prototype"
      — awaiting developer eyes-on; see STATUS.md *Needs developer
      verification* for the walkthrough.

Everything in Scope is done except the timer-overlay penultimate/final-value
smoothing, which conflicts with this phase's own criterion 1 (the fix lives
in `StudyLapse/Export/`) — left as a known limitation, logged as
OPEN_QUESTIONS.md Q-009 rather than silently either skipped or done by
breaking criterion 1.

**Depends on:** Phases 5, 6, 7 (every screen it restyles must exist first)

---

## Phase 9 — Ship

**Scope**
- App icon, launch screen, App Store screenshots
- Privacy nutrition label: no data collected (D-013)
- Usage strings for camera, microphone, photo library add
- Paid developer program enrolment under the account holder (Q-004)
- Archive, upload, submit

**Non-goals for this phase**
- No analytics, no crash reporting SDK, no ads

**Acceptance criteria**
- [ ] `[device]` `xcodebuild archive` produces a validating archive
- [ ] `[device]` no network entitlements or outbound requests exist in the binary
- [ ] `[eyes-on]` a clean install on a device with no prior data completes a full
      record → tag → export → voiceover → share loop without a crash
- [ ] `[eyes-on]` submitted to App Store Connect and accepted for review

**Depends on:** Phases 5, 6, 7, 8

---

## Phase 10 — v2: on-device focus analysis

Deferred. Do not begin until Q-002 is answered.

**Scope (provisional)**
- Vision framework pass over retained source clips: face presence, head pose,
  away-from-desk intervals, longest unbroken stretch
- Per-session focus summary in the library detail sheet
- Optional natural-language feedback from derived numeric metrics only (D-022)

**Non-goals**
- Never upload frames (D-022)
- No real-time analysis during capture

**Depends on:** Phase 5, Q-002
