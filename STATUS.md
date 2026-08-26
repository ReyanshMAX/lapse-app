# Status

**Last updated:** 2026-08-26
**Current phase:** 0 of 9 — Core logic, provable without a Mac
**Next action:** `git add` the four uncommitted `StudyLapseCore` math files
(`DayBoundary.swift`, `Formatters.swift`, `TagRangeMath.swift`, `TimeAxis.swift`
+ their tests) and the further-hardened `.github/workflows/ci.yml` (dynamic
simulator lookup, see Deviations), commit, push, then `gh run watch` and confirm
all four CI jobs actually go green — none of this has been through a CI run yet.

**Environment:** No Mac access for approximately one week. Builds run on GitHub
Actions macOS runners; the `ipa` job produces an unsigned .ipa that is signed
with a free Apple ID and sideloaded from Windows, so `[device]` and `[eyes-on]`
criteria remain reachable. Unavailable: the Xcode debugger, `os_log` console
streaming, Instruments, and any paid-program entitlement.

---

## Done

Nothing yet — no phase has a confirmed green CI run behind it. Spec suite
generated 2026-08-24.

## In progress

- **Phase 0 — Core logic, provable without a Mac**
  - [x] Repo layout, `.gitignore`, `project.yml` — committed (1884355)
  - [x] `.github/workflows/ci.yml` with the `core`, `simulator`, `app`, and
        `ipa` jobs — committed (f7d57ce); config bugs found by run
        32995981666 fixed in c25c813 (pushed, see Deviations) plus one more
        hardening fix made locally today, not yet committed (see Deviations)
  - [ ] Placeholder app target that builds, archives, and sideloads — code
        exists and is pushed; `[device]` sideload check has never happened
        (no green CI run has produced an .ipa yet)
  - [x] `StudyLapseCore` package skeleton, Foundation-only — committed
  - [ ] `TimeAxis` — study/output conversions, speed, minimum-speed floor —
        **implemented, uncommitted.** `StudyLapseCore/Sources/StudyLapseCore/TimeAxis.swift`
        + `TimeAxisTests.swift` exist on disk, untracked by git
  - [ ] `DayBoundary` — `dayKey`, `closeDeadline` — **implemented, uncommitted**
        (`DayBoundary.swift` + `DayBoundaryTests.swift`, untracked)
  - [ ] `TagRangeMath` — seed, split, merge, resize, validate — **implemented,
        uncommitted** (`TagRangeMath.swift` + `TagRangeMathTests.swift`, untracked)
  - [ ] `Formatters` — `H:MM` and `MM:SS` — **implemented, uncommitted**
        (`Formatters.swift` + `FormattersTests.swift`, untracked)
  - [ ] Property test over random tag-range operation sequences (≥1000 cases)
        — **implemented, uncommitted.** `TagRangeMathTests.testTilingInvariantHoldsUnderRandomOperationSequences`
        runs 1000 seeded random split/merge/resize ops against a 9-hour
        session and re-validates the tiling invariant after each one
  - [x] CI grep step asserting no SwiftData/AVFoundation/SwiftUI/UIKit imports
        — present in `ci.yml`'s `core` job; the four new source files above
        only `import Foundation`, so the grep step will still pass once pushed

None of the unchecked items above are blocked on anything — they're just
sitting in the working tree unpushed. `swift test --package-path StudyLapseCore`
has never actually been run (no Swift toolchain on this machine per CLAUDE.md);
correctness is inferred from reading the code, not proven, until CI runs it.

## Next up

1. Finish Phase 0 and keep CI green
2. Phase 1 — one clip captured and played back, via the sideloaded .ipa
3. Phase 2 — multi-clip session, SwiftData, recovery

## Needs developer verification

Nothing yet. Anything completed during an unattended session that carries a
`[device]` or `[eyes-on]` criterion goes here, with what to look for on the
phone. The agent never checks those boxes itself.

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

- 2026-08-26, uncommitted: the `simulator` job's device pin
  (`platform=iOS Simulator,name=iPhone 17`, set in c25c813 above) is the same
  class of bug that broke the `app` job originally — a hardcoded model name
  that silently breaks whenever GitHub rotates the `macos-latest` simulator
  image. Replaced it with a step that queries `xcrun simctl list devices
  available -j` on the runner itself and picks whatever iPhone is actually
  present, via `jq`, then tests against `-destination 'id=<that udid>'`. Not
  yet committed or run — see Next action.

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
  and pushed as c25c813. All four Phase 0 `StudyLapseCore` math files
  (`TimeAxis`, `DayBoundary`, `TagRangeMath`, `Formatters`) plus tests and the
  ≥1000-case property test written and sitting in the working tree, along with
  a further CI hardening fix (dynamic simulator lookup) — none of this is
  committed or pushed yet. Ended without a green run confirming any of it;
  next session should commit, push, and watch CI before doing anything else.