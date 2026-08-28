# ARCHITECTURE.md — module boundaries, threading model, and data flow

## Overview

Six modules with one-directional dependencies. SwiftUI features depend on a small
set of `@Observable` coordinators; those coordinators own the AVFoundation and
SwiftData work. No SwiftUI view ever touches an `AVCaptureSession`, a
`ModelContext` write, or a file path directly.

## Non-goals

- No architectural framework (no TCA, no Redux, no VIPER)
- No dependency injection container — plain initializer injection
- No repository/service abstraction over SwiftData beyond what is listed here
- No modularisation into separate Swift packages in v1, except `StudyLapseCore`

## Dependency direction

```
Features (SwiftUI)
      ↓
Coordinators (@Observable)   SessionCoordinator, ExportCoordinator, VoiceoverCoordinator
      ↓
Capture   Export   Voiceover   Storage
      ↓
Model (SwiftData entities + StudyLapseCore pure logic)
```

Nothing below a layer may import anything above it. `Model` imports Foundation
and SwiftData only.

## StudyLapseCore

A pure Swift package with **no Apple-framework dependencies beyond Foundation**,
containing the study-time axis math, day-boundary rules, tag-range operations,
and export-speed computation. It compiles and unit-tests on Linux and Windows,
which matters because the developer's primary machine is Windows with limited
Mac access (see docs/SETUP.md).

```
StudyLapseCore/
  Sources/StudyLapseCore/
    TimeAxis.swift        study/output/wall conversions, speed floor clamping
    DayBoundary.swift     dayKey and closeDeadline
    TagRangeMath.swift    split, merge, resize, coverage, untagged gaps
    Formatters.swift      H:MM and MM:SS formatting
  Tests/StudyLapseCoreTests/
```

The SwiftData entities live in the app target and map to/from these pure types.
Do not import SwiftData into the package.

Caveat: swift-corelibs-Foundation's `Calendar` and `Date` behavior differs
subtly from Apple's. Day-boundary tests must also run on the Mac before a phase
is marked complete.

## Coordinators

```swift
@Observable
final class SessionCoordinator {
    private(set) var session: Session?
    private(set) var status: SessionStatus = .ended
    private(set) var studySeconds: Double = 0
    private(set) var warnings: [CaptureWarning] = []

    func startNewSession() throws
    func pause() async
    func resume() throws
    func end() async
    func handleScenePhase(_ phase: ScenePhase) async
    func recoverOnLaunch() async
}

@Observable
final class ExportCoordinator {
    private(set) var progress: Double?
    private(set) var lastExportURL: URL?
    func export(session: Session, profile: ExportProfile) async throws
    func cancel()
}

@Observable
final class VoiceoverCoordinator {
    private(set) var isRecording: Bool
    private(set) var takes: [VoiceoverTake]
    func startTake(at outputSeconds: Double) throws
    func stopTake() async
    func delete(_ take: VoiceoverTake)
}
```

Coordinators are created once in the app entry point and passed down via
`.environment`. `SessionCoordinator.studySeconds` is driven by a 1 Hz timer while
recording — do not derive it from frame callbacks, which would couple UI updates
to the capture queue.

## Threading

| Work | Queue |
|---|---|
| `AVCaptureSession` configuration and start/stop | `studylapse.capture.session` (serial) |
| Sample buffer delegate, frame gating, writer appends | `studylapse.capture.buffer` (serial) |
| Export composition and render | task on the cooperative pool; progress hops to main |
| SwiftData reads and writes | `@MainActor` `ModelContext` only |
| Audio recording | `AVAudioRecorder` default, main-thread-safe |

SwiftData is not thread-safe here — all context work runs on the main actor.
Capture callbacks must therefore never write to the context directly; they
accumulate counters and hand off at clip boundaries.

## Data flow: a full session

1. User taps Record → `SessionCoordinator.startNewSession()` creates a `Session`
   (main actor), then calls `CaptureController.start` on `sessionQueue`.
2. Frames arrive on `bufferQueue`, are gated, and appended to the writer. Frame
   counters live in the capture layer.
3. Every ~120s a chunk finalizes → hop to main actor, persist `Clip`, recompute
   `studyOffsetStart`.
4. Backgrounding or a pause tap → finalize clip, stop session, status `.paused`,
   start the Live Activity.
5. Resume → new `Clip` with `index = last + 1`, `studyOffsetStart` = running total.
6. End → finalize, status `.ended`, generate `thumbnail.jpg`, seed `TagRange` rows
   at clip boundaries with `origin = .segment`, navigate to tagging.
7. Tagging → edit `TagRange` rows via segment list or slider.
8. Export → `ExportCoordinator` composes, renders, writes `ExportRecord`.
9. Voiceover → takes recorded against the export's profile revision, then
   re-export to bake them in.

## Error handling

One error type per module, surfaced to the UI as a `CaptureWarning` or a
presented alert. No silent catches. Capture errors that make recording impossible
(camera unavailable, writer failure) must end the session cleanly rather than
leaving it in `.recording`.

## Notes

- The camera preview is `CameraPreviewView: UIViewRepresentable` wrapping a
  `UIView` whose `layerClass` is `AVCaptureVideoPreviewLayer`. Do not recreate it
  on SwiftUI state changes; it is expensive.
- Live Activity state is pushed from `SessionCoordinator` only. The widget
  extension reads nothing from disk — everything it needs travels in the
  `ActivityAttributes.ContentState` (App Groups require the paid developer
  program; see OPEN_QUESTIONS.md Q-004).
- `CaptureController` consumes a `FrameSource` protocol rather than owning an
  `AVCaptureSession` directly. `CameraFrameSource` is the only type that touches
  AVFoundation capture; everything downstream is driven by `SyntheticFrameSource`
  in CI. See docs/TESTING.md — this seam is what makes the pipeline verifiable
  without a camera, and it must not be collapsed.
- No time-dependent code calls `Date()` or `CACurrentMediaTime()` directly; a
  clock is injected. Required for testing multi-hour sessions in milliseconds.
- Unit tests target `StudyLapseCore`; simulator tests cover persistence,
  recovery, and export. UI tests are out of scope for v1.
