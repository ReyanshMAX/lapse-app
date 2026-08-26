# Status

**Last updated:** 2026-08-26
**Current phase:** 2 of 9 — A real multi-clip session with correct study time
**Next action:** Phase 2 in progress. Criterion 1 (`[ci]` StudyLapseCore tests)
is already green — the [120,300,60]→480, dayKey-02:30, and closeDeadline cases
were all written and passing in Phase 0 (run 33021301863). Next unbuilt piece:
the SwiftData entities in `StudyLapse/Model/` per docs/DATA_MODEL.md plus an
in-memory `ModelContainer` helper for the simulator test target (compile-only
commit), then `studyOffsetStart` recompute + tiling-invariant simulator test,
then `SyntheticFrameSource` monotonic-PTS fix + chunk rollover (D-015), then
`ClipRecovery`, then `SessionCoordinator`, then the record screen + app wiring.

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

- **Phase 2 — A real multi-clip session with correct study time** — in
  progress. See BUILD.md for full scope/interface contracts. Builds
  `SessionCoordinator` and chunked writing (D-015) on top of Phase 1's
  `CaptureController`, plus the SwiftData stack from docs/DATA_MODEL.md.
  - `[ci]` criterion 1 (StudyLapseCore tests) — **done**, satisfied verbatim by
    the Phase 0 test suite (`testTotalStudySecondsSumsClipDurations`,
    `testDayKeyBeforeCutoffBelongsToPreviousDay`,
    `testCloseDeadlineLandsAtCutoffTheFollowingDay`), green on run 33021301863.
  - Phase 0's "Deferred to Mac access" note (day-boundary tests re-run on
    Apple's Foundation before Phase 2 closes) is **discharged**: the `core` CI
    job runs `swift test` on `macos-latest`, which is Apple's Foundation, not
    swift-corelibs.
  - Criteria 2, 3, 4 are tagged `[device]` in BUILD.md but are all listed as
    CI-verifiable in docs/TESTING.md ("Fully verifiable in CI with no camera").
    Plan: write them as `simulator`-job tests so CI exercises them, but leave
    the boxes unchecked per LOOP.md — see Deviations for the doc conflict.

## Next up

1. Phase 2 — SwiftData entities, `SessionCoordinator`, chunked writing,
   scene-phase auto-pause, launch recovery
2. Phase 3 — export with burned-in timer

## Needs developer verification

Nothing open right now. Anything completed during an unattended session that
carries a `[device]` or `[eyes-on]` criterion goes here, with what to look for
on the phone. The agent never checks those boxes itself.

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