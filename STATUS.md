# Status

**Last updated:** 2026-08-26
**Current phase:** 1 of 9 — One clip, captured and played back on device
**Next action:** Start Phase 1 per BUILD.md. First interface contract to stand
up: `StudyLapse/Capture/CaptureController.swift` consuming a `FrameSource`
(not owning `AVCaptureSession` directly — D-026, docs/TESTING.md), plus camera
permission prime/request. The on-device debug log (append-only ring buffer,
scrollable, copy-to-clipboard) is not optional for this phase — there's still
no console/debugger.

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

## In progress

- **Phase 1 — One clip, captured and played back on device** — not started.
  See BUILD.md for full scope/interface contracts. Key constraint:
  `CaptureController` must consume a `FrameSource` from the start rather than
  owning `AVCaptureSession` directly (D-026, docs/TESTING.md) — this seam is
  much more expensive to introduce later.

## Next up

1. Phase 1 — one clip captured and played back, via the sideloaded .ipa
2. Phase 2 — multi-clip session, SwiftData, recovery

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