# EXPORT.md — composition graph, overlay rendering, speed, voiceover mixing

## Overview

Export concatenates a session's finalized clips into an `AVMutableComposition`,
scales the result to the requested speed, burns in an animated study timer and
optional intro/outro cards via `AVVideoCompositionCoreAnimationTool`, mixes any
voiceover takes onto a silent audio track, and writes a finished file ready to
post. This is the app's differentiating feature — everything else is a tracker.

## Non-goals

- No subrange export in v1 — whole session only (D-019)
- No transitions, filters, colour grading, music, or captions
- No re-encoding of source clips outside of export
- No background export in v1; the export screen stays foregrounded with progress
- No direct upload to TikTok/Instagram APIs — hand off via the share sheet

## Pipeline

```swift
// Phase 3 shape. `ExportRequest` carries a Sendable `ExportPlan` snapshot
// rather than the live `@Model` objects — see "Threading" below.
struct ExportPlan: Sendable {            // built on the main actor by ExportCoordinator
    struct Clip: Sendable { let url: URL; let frameCount: Int }
    let clips: [Clip]
    let captureIntervalSeconds: Double
    let outputFrameRate: Int32
    let totalStudySeconds: Double
    let speedMode: SpeedMode
    let aspect: AspectPreset
    let overlayStyle: OverlayStyle
    let overlayCorner: OverlayCorner
    let includeIntroCard: Bool
    let includeOutroCard: Bool
    // sessionID / sessionStartedAt / dayKey / profileRevision / tagNames …
    var outputDuration: Double            // == TimeAxis.outputDuration(...)
}

struct ExportRequest: Sendable {
    let plan: ExportPlan
    var voiceoverTakes: [VoiceoverTakeSnapshot] = []   // Phase 6; non-muted, non-stale only
}

@MainActor
protocol SessionExporter {
    func export(_ request: ExportRequest,
                progress: @escaping (Double) -> Void) async throws -> URL
}
```

### Threading (Phase 3 deviation from the original `ExportRequest`)

The original contract was `ExportRequest { session: Session; profile: ExportProfile;
… }`. SwiftData `@Model` objects are not safe to touch off the main actor
(docs/ARCHITECTURE.md), and export composition + render is not instantaneous, so
`ExportCoordinator` reads everything it needs off the models **on the main
actor** into the `Sendable` `ExportPlan` value, and the exporter only ever sees
that. `AVFoundationSessionExporter` is itself `@MainActor` — the heavy work is
`AVAssetExportSession`'s own, and awaiting it doesn't block the actor. This is
the same resolution used for `CaptureController` in Phase 2 (media-only, no
model layer). `ExportProfile` fields are flattened onto the plan; the raw
strings map to the `AspectPreset` / `OverlayStyle` / `OverlayCorner` enums in
`StudyLapse/Export/ExportModels.swift`.

Stages, in order:

1. **Compose.** New `AVMutableComposition`. One video track. For each finalized
   clip ordered by `index`, `insertTimeRange(clip.fullRange, at: cursor)`.
   Advance `cursor` by the clip's duration. No gaps — pauses are already absent
   because paused time was never recorded.
2. **Scale.** Compute the output length once, via
   `TimeAxis.outputDuration(mode:totalStudySeconds:interval:fps:)` in
   StudyLapseCore (which clamps to the minimum-speed floor and is the *single*
   source of truth for both this scale target and the number the UI shows).
   Apply `composition.scaleTimeRange(fullRange, toDuration: outputDuration)` to
   the **video track only** — do the audio insert afterwards so it isn't scaled.
3. **Audio.** Synthesise a silent **LPCM `.caf`** of exactly the scaled
   `composition.duration` (`SilentAudio.makeFile`) and insert it on its own
   track (D-014). LPCM not AAC — the AAC encode path is the flakier one on the
   simulator and the export session transcodes anyway. `insertEmptyTimeRange`
   alone is not enough: the export session drops a fully-empty track.
   Voiceover takes go on a second track in Phase 6.
4. **Video composition.** `AVMutableVideoComposition` with `renderSize` from the
   aspect preset, `frameDuration = CMTime(value: 1, timescale: 30)`, one
   instruction spanning the whole range (black `backgroundColor`) with a layer
   instruction carrying the centre-crop transform
   (`AVFoundationSessionExporter.cropTransform`: scale to fill, translate to
   centre, never stretch; `original` is identity).
5. **Overlay.** `OverlayLayerBuilder.build(...)` returns an
   `OverlayLayers { parent, video }` pair (deviation from the `-> CALayer`
   contract — the Core Animation tool needs both, wired before it is
   constructed), attached via
   `AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer:in:)`.
6. **Write.** `AVAssetExportSession`, `presetName = AVAssetExportPresetHEVCHighestQuality`
   with a fallback to `AVAssetExportPresetHighestQuality` (H.264) if the HEVC
   render fails — the simulator's software HEVC encoder is unreliable (STATUS.md
   Phase 1). `videoComposition` set, `outputFileType = .mov`. `exportAsynchronously`
   then poll `.status`/`.progress` from the main actor between `Task.sleep`s.
7. **Record.** Insert an `ExportRecord`, write the file into the session's
   `exports/` directory, then present the share sheet.

## Aspect presets

| Preset | renderSize | Behavior |
|---|---|---|
| `portrait9x16` | 1080 × 1920 | centre-crop the 16:9 source horizontally, scale to fill |
| `square1x1` | 1080 × 1080 | centre-crop, scale to fill |
| `original` | 1920 × 1080 | identity transform |

Crop is centre-weighted with no user-adjustable framing in v1. The framing guide
at capture (docs/UI.md) exists so the centre crop is usable.

## Overlay layer tree

```
parentLayer                     (renderSize bounds)
├── videoLayer                  (renderSize bounds — required by CoreAnimationTool)
├── introCardLayer              (optional, opacity keyframed 1→0 at 1.5s)
├── timerLayer                  (CATextLayer, positioned by overlayCorner)
└── outroCardLayer              (optional, opacity keyframed 0→1 at duration-1.5s)
```

All animations must set `beginTime = AVCoreAnimationBeginTimeAtZero` (never 0,
which Core Animation treats as "now"), `isRemovedOnCompletion = false`, and
`fillMode = .forwards`. Set `parentLayer.isGeometryFlipped = true` so layer
coordinates match video orientation (origin top-left, y down — corner insets
are computed in that space).

`OverlayLayerBuilder.build(...)` returns `OverlayLayers { parent, video }`
rather than a lone `CALayer`: the Core Animation tool needs both layers and
they must be wired (`parent.addSublayer(video)`) before it is constructed. It
takes the flat overlay fields (`style`, `corner`, `includeIntroCard`, …)
directly rather than an `ExportProfile`, since the exporter never holds a
`@Model`.

### Timer animation

The timer displays **study time**, not output time. Because the composition is
uniformly scaled, output time `t` maps to study time `t * speed` (with `speed`
the net real-time multiplier — see docs/DATA_MODEL.md), i.e. linearly from 0 to
`totalStudySeconds` across `outputDuration`. `CATextLayer` cannot animate its
string, so generate discrete steps:

```swift
/// One keyframe per displayed value change. At a 1-minute display granularity a
/// 9-hour session needs 540 keyframes — cheap. Never emit per-second keyframes
/// for long sessions; cap total keyframes at 2000 and coarsen granularity to fit.
func timerKeyframes(totalStudySeconds: Double,
                    outputDuration: Double,
                    granularity: TimerGranularity) -> [(time: Double, text: String)]

enum TimerGranularity { case seconds, minutes }
```

Implement as a stack of pre-rendered `CATextLayer`s (one per keyframe) whose
opacity is keyframed on and off in sequence, or as a single layer driven by a
`CAKeyframeAnimation` on a custom animatable property with a delegate-supplied
string. The layer-stack approach is simpler and is the default; switch only if
keyframe counts become a memory problem.

`timerKeyframes` (in `StudyLapseCore/TimerOverlay.swift`) appends a final
`(outputDuration, totalText)` keyframe so the exact session total is shown at
the end. Because study time only *reaches* the total at the final instant, that
label is visible for the last frame only — the penultimate value (one
granularity step below the total) fills the rest of the tail. Acceptable for
v1; smooth it later if it reads wrong.

Format is fixed by **total** study time, not the running value, so the digits
never change shape mid-video: `H:MM` when total ≥ 1 hour, else `MM:SS`.
`OverlayLayerBuilder` picks `seconds` granularity below 10 minutes total,
`minutes` above.

### Overlay styles

| Style | Description |
|---|---|
| `minimal` | White SF Mono digits, 64pt, soft drop shadow, no background |
| `boxed` | Same digits inside a 60%-opacity black rounded rect, 12pt padding |
| `mono` | Large thin white digits, 96pt, no shadow, no background |

Corner positions inset 48pt from the render bounds on each axis.

### Cards

Intro card: session date, total study time, tag names joined by `·`. Outro card:
total study time and streak count. Both are `CATextLayer`s over a solid
background layer, centred, using the same type styles as the app (docs/UI.md).

## Voiceover mixing

- Takes are positioned on the **output** timeline (`outputStartSeconds`), not the
  study axis, because the user records them while watching the finished cut.
- Build an `AVMutableAudioMix` with one `AVMutableAudioMixInputParameters` per
  take. Apply a 50 ms linear fade in and out at each take's edges to avoid clicks.
- Overlapping takes are not permitted — the UI must prevent creating them; if
  found at export time, keep the newer take and log a deviation.
- Takes whose `recordedAgainstProfileRevision` differs from the profile's current
  revision are excluded from export and surfaced in the UI as misaligned
  (docs/DATA_MODEL.md). Never silently re-time them.

## Progress and cancellation

`AVAssetExportSession.progress` is coarse and does not account for the overlay
render. Report it directly rather than inventing a weighted estimate. Cancellation
calls `cancelExport()` and deletes the partial output file.

Expected wall-clock render time: roughly 1–3× the output video duration on an
A15-class device. A 60-second export finishes in under three minutes; do not add
a background-task assertion in v1, just keep the screen alive.

## Notes

- `AVAssetExportSession` supports `videoComposition` including a
  `CoreAnimationTool`, so `AVAssetWriter` is not required in v1. If per-frame
  Metal rendering becomes necessary later, replace stage 6 with a custom
  `AVVideoCompositing` — that is the escape hatch, not the default.
- Saving to Photos requires `NSPhotoLibraryAddUsageDescription` and
  `PHPhotoLibrary.requestAuthorization(for: .addOnly)`.
- Export must refuse to run on a session with zero finalized clips, and must skip
  unfinalized ones rather than failing the whole export.
