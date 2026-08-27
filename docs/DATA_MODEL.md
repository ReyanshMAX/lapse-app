# DATA_MODEL.md — SwiftData schema, on-disk layout, and study-time axis math

## Overview

Metadata lives in SwiftData; all media lives on disk and is referenced by a path
relative to the app's Application Support directory. The central abstraction is
the **study-time axis**: a monotonic seconds counter that advances only while
recording. Clips, tag ranges, and the overlay timer are all positioned on that
axis. Wall-clock time is stored for display and day-boundary logic but is never
used for durations.

## Non-goals

- No sync, no CloudKit, no server-side records
- No soft deletes or audit trail — a deleted session is gone
- No schema migrations in v1 beyond SwiftData's automatic lightweight migration
- No tag hierarchy, nesting, or per-tag goals

## Entities

```swift
import SwiftData
import Foundation

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var startedAt: Date              // wall clock, first clip start
    var endedAt: Date?               // wall clock, nil while open
    var dayKey: String               // "2026-08-24", derived via DayBoundary
    var captureIntervalSeconds: Double   // frozen at session creation, D-006
    var outputFrameRate: Int32       // frozen at session creation, default 30
    var statusRaw: String            // SessionStatus.rawValue
    var noteText: String?
    var sourcesPurgedAt: Date?       // non-nil once source clips are purged (D-005)

    @Relationship(deleteRule: .cascade, inverse: \Clip.session)
    var clips: [Clip] = []
    @Relationship(deleteRule: .cascade, inverse: \TagRange.session)
    var tagRanges: [TagRange] = []
    @Relationship(deleteRule: .cascade, inverse: \VoiceoverTake.session)
    var voiceoverTakes: [VoiceoverTake] = []
    @Relationship(deleteRule: .cascade, inverse: \ExportRecord.session)
    var exports: [ExportRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \ExportProfile.session)
    var exportProfile: ExportProfile?

    init(id: UUID = UUID(), startedAt: Date, dayKey: String,
         captureIntervalSeconds: Double, outputFrameRate: Int32 = 30)
}
// `sourcesPurgedAt` is a lightweight-migratable optional added in Phase 5.


enum SessionStatus: String, Codable {
    case recording, paused, ended
}

@Model
final class Clip {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var index: Int                   // 0-based, ordering within the session
    var relativePath: String         // "sessions/<uuid>/clips/000_<uuid>.mov"
    var startedAt: Date              // wall clock
    var endedAt: Date?
    var frameCount: Int              // frames actually written
    var studyOffsetStart: Double     // study-axis seconds at this clip's frame 0
    var isFinalized: Bool            // false until AVAssetWriter.finishWriting succeeds
    var wasRecovered: Bool           // true if repaired on launch, D-015

    /// Study-axis seconds this clip represents.
    var studyDuration: Double { Double(frameCount) * (session?.captureIntervalSeconds ?? 2) }
    /// Output-video seconds this clip contributes at 1x composition speed.
    var outputDuration: Double { Double(frameCount) / Double(session?.outputFrameRate ?? 30) }
}

@Model
final class TagRange {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var startStudySeconds: Double
    var endStudySeconds: Double
    var tagNames: [String]           // may be empty (untagged range)
    var origin: String               // TagRangeOrigin.rawValue
}

enum TagRangeOrigin: String, Codable {
    case segment    // auto-created at clip boundaries, editable
    case manual     // created or resized via the slider
}

@Model
final class Tag {
    @Attribute(.unique) var name: String   // lowercased, trimmed; display casing in displayName
    var displayName: String
    var colorHex: String
    var useCount: Int
    var lastUsedAt: Date
}

@Model
final class ExportProfile {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var speedModeRaw: String         // "multiplier" | "fitToDuration"
    var speedMultiplier: Double      // used when speedModeRaw == "multiplier"
    var targetDurationSeconds: Double // used when speedModeRaw == "fitToDuration"
    var aspectRaw: String            // "portrait9x16" | "square1x1" | "original"
    var overlayStyleRaw: String      // "minimal" | "boxed" | "mono"
    var overlayCornerRaw: String     // "topLeft" | "topRight" | "bottomLeft" | "bottomRight"
    var includeIntroCard: Bool
    var includeOutroCard: Bool
    var revision: Int                // bumped on any change; invalidates voiceover takes
    var fingerprintAtRevision: String?  // settings signature when `revision` last changed (Phase 6)
}
// `fingerprintAtRevision` is a lightweight-migratable optional added in Phase 6.

@Model
final class VoiceoverTake {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var relativePath: String         // "sessions/<uuid>/voiceovers/<uuid>.m4a"
    var outputStartSeconds: Double   // position on the EXPORTED timeline, not the study axis
    var durationSeconds: Double
    var recordedAgainstProfileRevision: Int
    var isMuted: Bool
    var createdAt: Date
}

@Model
final class ExportRecord {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var relativePath: String         // "sessions/<uuid>/exports/<uuid>.mov"
    var createdAt: Date
    var profileRevision: Int
    var durationSeconds: Double
    var fileSizeBytes: Int64
}
```

## Study-time axis

Three coordinate systems exist. Confusing them is the most likely source of bugs
in this app, so they are named explicitly and never mixed.

| Axis | Unit | Definition | Used for |
|---|---|---|---|
| Wall clock | `Date` | Real time | session start/end display, day boundary, battery warnings |
| Study time | seconds | Sum of clip durations; pauses excluded | overlay timer, tag ranges, all stats, streaks |
| Output time | seconds | Position in the exported video | voiceover alignment, export progress |

Conversions:

```swift
enum TimeAxis {
    /// Study seconds at a given frame within a clip.
    static func studySeconds(clip: Clip, frameIndex: Int, interval: Double) -> Double {
        clip.studyOffsetStart + Double(frameIndex) * interval
    }

    /// Total study seconds for a session — the number shown as "you studied X".
    static func totalStudySeconds(_ session: Session) -> Double {
        session.clips.filter(\.isFinalized).reduce(0) { $0 + $1.studyDuration }
    }

    /// The exported video's NET speed relative to real study time: `speed == 100`
    /// means the video plays 100x faster than the user actually studied. This is
    /// the axis the user picks on and the number the UI shows — it is NOT an
    /// extra multiplier stacked on top of the capture-interval compression.
    /// Clamped to `minimumSpeed` (below).
    static func speed(profile: ExportProfile, totalStudySeconds: Double,
                      interval: Double, fps: Int32) -> Double {
        let floor = interval * Double(fps)                 // minimumSpeed
        switch profile.speedModeRaw {
        case "fitToDuration":
            return max(totalStudySeconds / profile.targetDurationSeconds, floor)
        default:
            return max(profile.speedMultiplier, floor)
        }
    }

    /// Exported-file duration: `totalStudySeconds / speed`. Both the UI figure
    /// and the `AVMutableComposition.scaleTimeRange(toDuration:)` target read
    /// this (see docs/EXPORT.md — the code lives in `StudyLapseCore/TimeAxis`).
    static func outputDuration(profile: ExportProfile, totalStudySeconds: Double,
                               interval: Double, fps: Int32) -> Double {
        totalStudySeconds / speed(profile: profile, totalStudySeconds: totalStudySeconds,
                                  interval: interval, fps: fps)
    }

    /// Map an output-video timestamp to study seconds. Used to drive the overlay
    /// timer. With `speed` on the net axis this is just `outputSeconds * speed`.
    static func outputToStudy(_ outputSeconds: Double, speed: Double) -> Double {
        outputSeconds * speed
    }
}
```

**Invariant:** `clips` sorted by `index` must have `studyOffsetStart[n] ==
studyOffsetStart[n-1] + studyDuration[n-1]`. Recompute and persist this whenever
a clip is finalized, recovered, or deleted. A unit test must assert it.

**Minimum playback speed.** Because export drops frames but cannot create them,
the slowest possible *net* speed is `interval * fps` (at the 2s default / 30fps:
60x) — showing every captured frame exactly once at `fps` already compresses
that much real time into one output second. If a chosen multiplier, or the net
speed a `targetDurationSeconds` implies (`totalStudySeconds / targetDurationSeconds`),
is below that floor, clamp to the floor and surface the resulting actual
duration in the UI rather than silently producing a different video than
requested. Note fit-to-duration only clamps for *short* sessions with a *long*
target (e.g. a 20-min session asked to fill 60s); a multi-hour session fit to
15s is far above the floor and is honoured exactly.

## Day boundary

```swift
struct DayBoundary {
    /// User setting, default 4. Stored in UserDefaults key "dayCutoffHour".
    let cutoffHour: Int

    /// The study day a wall-clock instant belongs to.
    /// 2026-08-24 02:30 with cutoff 4 → "2026-08-23".
    func dayKey(for date: Date, calendar: Calendar = .current) -> String

    /// The instant at which a session started on `dayKey` must auto-close.
    func closeDeadline(forDayKey key: String, calendar: Calendar = .current) -> Date
}
```

Auto-close is evaluated on app foreground and on any session mutation. It fires
only when `status == .paused`. If `status == .recording` past the deadline, the
session stays open and closes at the next pause (D-004).

## On-disk layout

Root: `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
.appendingPathComponent("StudyLapse", isDirectory: true)`

```
StudyLapse/
  sessions/
    <session-uuid>/
      clips/
        000_<clip-uuid>.mov
        001_<clip-uuid>.mov
      voiceovers/
        <take-uuid>.m4a
      exports/
        <export-uuid>.mov
      thumbnail.jpg          generated on session end, first frame of clip 000
      ghost.jpg              last frame of the most recent finalized clip
```

The root directory must be marked `isExcludedFromBackup = true`. Only relative
paths are persisted (D-021); resolve through a single `StorageLocator` type so
the root is computed in exactly one place.

## Notes

- `Tag.name` is the unique key and must be lowercased and trimmed on write;
  `displayName` preserves what the user typed. Lookups go through a
  `#Predicate` fetch + insert-if-absent (`TagCatalog.ensure`), not SwiftData's
  `.unique` upsert.
- `Tag.useCount` / `Tag.lastUsedAt` are **derived**, not incremented: after any
  tag edit, `TagCatalog.refreshUseCounts` recomputes `useCount` as the number
  of `TagRange` rows currently carrying that name (across all sessions) and
  bumps `lastUsedAt` for tags still in use. The field's write semantics were
  never specified and a recomputed count cannot drift when a tag is removed and
  re-added.
- Deleting a session cascades in SwiftData but does **not** delete files. The
  storage layer must remove the session directory in the same operation, and a
  launch-time sweep should delete orphaned directories with no matching row.
  Both live in `SessionStorage` (`deleteSession`, `sweepOrphanedDirectories`).
  The sweep only touches children of `sessions/` whose name parses as a UUID
  with no matching `Session.id` — unparseable names and anything outside
  `sessions/` are left alone.
- `Session.sourcesPurgedAt` records a manual source-clip purge (D-005,
  docs/UI.md §7). `SessionStorage.purgeSources` deletes the files under
  `clips/`, keeps every `Clip` row (they carry `frameCount` /
  `studyOffsetStart`, which all study-time totals, stats, and tag ranges read),
  and stamps the date. `ExportCoordinator.buildPlan` then throws
  `ExportError.sourcesPurged`, and the library detail sheet hides re-export.
  Exports and voiceovers already on disk are untouched and stay playable.
- `ExportProfile.revision` increments on any field change. The write semantics
  (unspecified before Phase 6): `revision` is not bumped on every keystroke.
  `ExportProfile.settingsFingerprint` is a signature of all eight user-visible
  settings; `reconcileRevision()` bumps `revision` and restamps
  `fingerprintAtRevision` only when the fingerprint has actually changed since
  the last reconcile, so toggling a setting and toggling it back is a no-op.
  A fresh profile's first reconcile stamps the fingerprint without bumping, so
  its takes stamp against revision 0. Called from `ExportCoordinator.export`
  (so each `ExportRecord.profileRevision` is current) and on every edit in the
  export screen. A `VoiceoverTake` whose `recordedAgainstProfileRevision`
  differs from the profile's current `revision` is flagged in the UI as
  misaligned and excluded from export — never silently re-timed, since a speed
  change moves every word. A take is stamped with the `ExportRecord.profileRevision`
  of the file it was recorded over, not the live profile.
- Untagged study time is a real state, not an error. Stats must report it as
  "untagged" rather than dropping it from totals.
