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
struct ExportRequest {
    let session: Session
    let profile: ExportProfile
    let voiceoverTakes: [VoiceoverTake]   // non-muted, non-stale only
}

protocol SessionExporter {
    func export(_ request: ExportRequest,
                progress: @escaping (Double) -> Void) async throws -> URL
}
```

Stages, in order:

1. **Compose.** New `AVMutableComposition`. One video track. For each finalized
   clip ordered by `index`, `insertTimeRange(clip.fullRange, at: cursor)`.
   Advance `cursor` by the clip's duration. No gaps — pauses are already absent
   because paused time was never recorded.
2. **Scale.** Compute `speed` per `TimeAxis.speed(profile:...)` in
   docs/DATA_MODEL.md, clamped to the minimum-speed floor. Apply
   `composition.scaleTimeRange(fullRange, toDuration: fullDuration / speed)`.
3. **Video composition.** `AVMutableVideoComposition` with
   `renderSize` from the aspect preset, `frameDuration = CMTime(value: 1, timescale: 30)`,
   and one `AVMutableVideoCompositionInstruction` spanning the whole range with a
   layer instruction carrying the crop/scale transform.
4. **Overlay.** Build the CALayer tree (below) and attach via
   `AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer:in:)`.
5. **Audio.** Always add a silent audio track for the full duration (D-014).
   Insert each voiceover take at `outputStartSeconds` on a second audio track.
6. **Write.** `AVAssetExportSession` with `presetName = AVAssetExportPresetHEVCHighestQuality`,
   `videoComposition` and `audioMix` set, `outputFileType = .mov`. Poll
   `.progress` on a timer for the progress callback.
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
coordinates match video orientation.

### Timer animation

The timer displays **study time**, not output time. Because the composition is
uniformly scaled, output time `t` maps to study time `t * speed * interval`.
`CATextLayer` cannot animate its string, so generate discrete steps:

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

Format: `H:MM` when total study time ≥ 1 hour, else `MM:SS`.

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
