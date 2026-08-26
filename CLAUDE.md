# StudyLapse — Claude Code Entry Point

## What this is

StudyLapse is a native iOS app that records a study session as a timelapse and
produces a finished, ready-to-post video without the user opening a separate
editor. A session spans a whole study day rather than one sitting: the user
records, pauses, leaves the app entirely, comes back hours later and resumes,
and the app treats the whole day as one continuous session. At the end they tag
which parts were which subject, record a voiceover over the finished cut, and
export.

Single user, entirely on device. No backend, no accounts, no network calls of
any kind in v1. The dominant architectural constraint is that **iOS does not
permit camera capture in the background** — so leaving the app is a hard
teardown, every resume produces a new clip file, and a session is therefore a
*container of N clips* rather than one recording. Almost every design decision
in this suite follows from that. The second constraint is the **study-time
axis**: elapsed study time is the sum of clip durations with paused wall-clock
time excluded, and every timer, tag range, stat, and overlay is indexed against
that axis, never against wall clock.

## Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | Swift 5.9+ | iOS 17.0 minimum deployment target |
| UI | SwiftUI | camera preview is a `UIViewRepresentable` wrapper |
| Capture | AVFoundation | `AVCaptureVideoDataOutput` + `AVAssetWriter` |
| Export | AVFoundation | `AVMutableComposition` + `AVVideoCompositionCoreAnimationTool` |
| Persistence | SwiftData | media files on disk, DB holds relative paths only |
| Live Activity | ActivityKit + WidgetKit | widget extension target |
| Deploy | Xcode over SSH | free provisioning during build phase; see docs/SETUP.md |

## Repo structure

```
StudyLapse.xcodeproj
StudyLapse/
  App/                 app entry, scene phase handling, dependency wiring
  Capture/             AVCaptureSession, frame gating, clip writing, recovery
  Model/               SwiftData entities, study-time math, day-boundary rules
  Storage/             on-disk file layout, path resolution, purge
  Export/              composition graph, overlay layers, render pipeline
  Voiceover/           audio recording, take management, mixing
  Features/            SwiftUI screens: Record, Tagging, Library, Stats, Export
  Shared/              formatters, design tokens, small utilities
StudyLapseActivity/    Live Activity widget extension
StudyLapseTests/       simulator tests — persistence, recovery, export, fixtures
```

## Where to look

| Working on | Read |
|---|---|
| current state, what to do next | STATUS.md |
| build order, phase acceptance criteria | BUILD.md |
| running an unattended overnight build loop | LOOP.md |
| why something is the way it is | DECISIONS.md |
| something unspecified or ambiguous | OPEN_QUESTIONS.md |
| how modules fit together, threading | docs/ARCHITECTURE.md |
| camera, frame intervals, clip files, crash recovery | docs/CAPTURE.md |
| SwiftData schema, file layout, study-time math | docs/DATA_MODEL.md |
| composition, overlays, speed, voiceover mixing | docs/EXPORT.md |
| screens, states, user flows | docs/UI.md |
| building, deploying to device, SSH workflow | docs/SETUP.md |
| how to verify anything without a camera | docs/TESTING.md |

## Standing rules

1. **Read STATUS.md first.** It is the current state of the build. Do not infer
   progress from the codebase.
2. **Specs are source of truth.** If the implementation must deviate from a spec
   doc, update that doc in the same change. A stale spec is worse than no spec.
3. **Never invent unspecified behavior.** If a requirement is missing, ambiguous,
   or contradicts another doc, stop and ask. Add it to OPEN_QUESTIONS.md. Do not
   pick a reasonable-sounding default and proceed.
4. **Do not relitigate DECISIONS.md.** Those choices are settled with reasons
   recorded. Reopen one only if new information directly invalidates the stated
   reason, and say which reason and why.

## Environment note — read before running any command

**You are running on Windows.** There is no Swift toolchain, no Xcode, no iOS
SDK, no simulator, and no `brew` on this machine. Do not attempt to run
`xcodebuild`, `swift build`, `swift test`, `xcrun`, `xcodegen`, `pod`, or any
`.sh` build script locally. They do not exist here and are not worth trying.

Verification happens in CI, not locally. The loop is: edit files, commit, push,
then read the run.

```
gh run watch                       # follow the run triggered by your push
gh run view --log-failed           # only the failing steps
gh run download -n StudyLapse-unsigned-ipa   # the sideloadable artifact
```

Treat a red CI run the way you would treat a local compiler error: read the log,
fix, push again. Never mark work complete without a green run.

**Right now there is no Mac access at all**, so nothing in `Capture/` or
`Export/` can be *verified* — only compiled. Work Phase 0 in BUILD.md, which is
scoped to what CI can prove, then Phase 1, whose device criteria are reachable by
sideloading the CI artifact. Sideloading and physical-device checks are the
developer's job, not yours — ask them to run it and report back.

Once Mac access returns, the developer builds over SSH into a shared macOS
machine with Xcode's GUI available only in limited windows. Both workflows are in
docs/SETUP.md.
