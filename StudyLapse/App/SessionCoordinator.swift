import Foundation
import Observation
import StudyLapseCore
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Non-fatal conditions surfaced to the recording UI. Guard logic that
/// populates this (battery / thermal / disk) lands in Phase 7 — the type
/// exists now so the coordinator's surface is stable.
enum CaptureWarning: Hashable {
    case batteryLow
    case thermalSerious
    case diskLow
}

/// Owns a study session's lifecycle: creating the `Session`, driving
/// `CaptureController`, persisting each finalized chunk on the main actor, and
/// keeping the study-time axis (`studySeconds`) current. A session is a
/// container of N clips spanning one study day (D-002); leaving the app
/// auto-pauses and finalizes the current chunk (D-016).
@MainActor
@Observable
final class SessionCoordinator {
    private(set) var session: Session?
    /// The session most recently ended by `end()`, kept so the End-Session
    /// button in `RecordView` can push the tagging flow after `session` is
    /// cleared. Not observed via `onChange` — `end()` is also reachable from
    /// the day-boundary auto-close, which must not pop a screen.
    /// (Extends BUILD.md's Phase 2 `SessionCoordinator` contract — see
    /// STATUS.md Deviations.)
    private(set) var lastEndedSession: Session?
    private(set) var status: SessionStatus = .ended
    private(set) var studySeconds: Double = 0
    private(set) var warnings: [CaptureWarning] = []
    private(set) var clipCount: Int = 0
    private(set) var lastError: String?

    private let context: ModelContext
    private let makeFrameSource: () -> FrameSource
    private let makeGuardSignalSource: () -> GuardSignalSource

    private var captureController: CaptureController?
    private var tickTask: Task<Void, Never>?
    private var guardMonitor: GuardMonitor?
    /// Guards a single `autoPause`/`autoPauseAndEnd` in flight at a time —
    /// `GuardMonitor` can report the same threshold on more than one reading
    /// before the resulting `pause()`/`end()` finishes.
    private var isHandlingGuardAction = false
    #if canImport(UIKit)
    private var previousScreenBrightness: CGFloat?
    #endif

    /// `makeFrameSource` defaults to the real camera; tests inject a
    /// `SyntheticFrameSource`. `makeGuardSignalSource` defaults to the real
    /// device signals (battery/thermal/disk); tests inject a synthetic source
    /// to drive `CaptureGuards` at its documented thresholds (BUILD.md Phase 7
    /// criterion 1) without touching `UIDevice`/`ProcessInfo`.
    init(context: ModelContext,
         makeFrameSource: @escaping () -> FrameSource = { CameraFrameSource() },
         makeGuardSignalSource: @escaping () -> GuardSignalSource = { DeviceGuardSignalSource() }) {
        self.context = context
        self.makeFrameSource = makeFrameSource
        self.makeGuardSignalSource = makeGuardSignalSource
    }

    private var dayBoundary: DayBoundary {
        let hour = UserDefaults.standard.object(forKey: "dayCutoffHour") as? Int ?? 4
        return DayBoundary(cutoffHour: hour)
    }

    // MARK: Guards (docs/CAPTURE.md guard table)

    /// A one-off check the UI runs before starting a session — low unplugged
    /// battery or low disk space are "warn, offer to continue" (D-018), not a
    /// hard block, so this returns what to show rather than throwing.
    func evaluateStartWarnings() -> [GuardWarningKind] {
        let monitor = GuardMonitor(source: makeGuardSignalSource())
        return monitor.evaluateSessionStart().compactMap { action in
            if case .warn(let kind) = action { return kind }
            return nil
        }
    }

    // MARK: Lifecycle

    func startNewSession() throws {
        guard status == .ended else {
            throw SessionCoordinatorError.sessionAlreadyActive
        }
        let now = Date()
        // Default 2s (D-006). Keep in sync with the `?? 2` fallback in
        // `Clip.studyDuration`.
        let interval = UserDefaults.standard.object(forKey: "captureIntervalSeconds") as? Double ?? 2
        let newSession = Session(startedAt: now,
                                 dayKey: dayBoundary.dayKey(for: now),
                                 captureIntervalSeconds: interval,
                                 outputFrameRate: 30)
        newSession.status = .recording
        context.insert(newSession)
        try context.save()

        session = newSession
        status = .recording
        studySeconds = 0
        clipCount = 0
        lastError = nil

        try beginCapture(firstClipIndex: 0)
        setIdleTimerDisabled(true)
        setScreenDimmed(true)
        startTicking()
        startGuardMonitoring()
        DebugLog.write("Session", "started \(newSession.id) dayKey \(newSession.dayKey)")
    }

    func pause() async {
        guard status == .recording else { return }
        stopGuardMonitoring()
        await stopCapture()
        pruneUnfinalizedRows()
        status = .paused
        session?.status = .paused
        setIdleTimerDisabled(false)
        setScreenDimmed(false)
        reconcileStudySeconds()
        try? context.save()
        DebugLog.write("Session", "paused; \(clipCount) clips, \(Int(studySeconds))s study")
        evaluateAutoClose()
    }

    func resume() throws {
        guard let session else { throw SessionCoordinatorError.noSession }
        guard status == .paused else { throw SessionCoordinatorError.notResumable }
        let nextIndex = (session.clips.map(\.index).max() ?? -1) + 1
        status = .recording
        session.status = .recording
        try context.save()
        try beginCapture(firstClipIndex: nextIndex)
        setIdleTimerDisabled(true)
        setScreenDimmed(true)
        startTicking()
        startGuardMonitoring()
        DebugLog.write("Session", "resumed at clip index \(nextIndex)")
    }

    func end() async {
        guard status != .ended else { return }
        stopGuardMonitoring()
        await stopCapture()
        pruneUnfinalizedRows()
        status = .ended
        session?.status = .ended
        session?.endedAt = Date()
        setIdleTimerDisabled(false)
        setScreenDimmed(false)
        reconcileStudySeconds()
        stopTicking()
        if let session {
            TagRangeSeeding.ensureSeeded(for: session, in: context)
            DebugLog.write("Session", "seeded \(session.tagRanges.count) tag range(s)")
        }
        try? context.save()
        DebugLog.write("Session", "ended; \(clipCount) clips, \(Int(studySeconds))s study")
        lastEndedSession = session
        session = nil
    }

    // MARK: Scene phase (D-016)

    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background, .inactive:
            if status == .recording {
                DebugLog.write("Session", "scene phase \(phase) while recording -> auto-pause")
                await pause()
            }
        case .active:
            // Re-assert the screen-on lock. iOS can clear
            // `isIdleTimerDisabled` across an app switch, and a transient
            // `.inactive` blip that didn't complete a real pause would
            // otherwise leave us recording with the screen free to sleep.
            if status == .recording { setIdleTimerDisabled(true) }
            evaluateAutoClose()
        @unknown default:
            break
        }
    }

    // MARK: Launch recovery

    func recoverOnLaunch() async {
        ClipRecovery.demoteRecordingSessions(in: context)
        await ClipRecovery.recoverUnfinalized(in: context)
        SessionStorage.sweepOrphanedDirectories(in: context)

        // Re-attach to the most recent still-open session, if any, so a full
        // app kill doesn't lose the day.
        var descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 5
        let recent = (try? context.fetch(descriptor)) ?? []
        if let open = recent.first(where: { $0.status != .ended }) {
            session = open
            status = open.status          // .paused after demotion
            clipCount = open.clips.filter(\.isFinalized).count
            reconcileStudySeconds()
            DebugLog.write("Session", "recovered open session \(open.id), status \(open.status), \(clipCount) clips")
            evaluateAutoClose()
        } else {
            session = nil
            status = .ended
            studySeconds = 0
            clipCount = 0
        }
    }

    // MARK: Capture wiring

    private func beginCapture(firstClipIndex: Int) throws {
        guard let session else { throw SessionCoordinatorError.noSession }
        let sessionID = session.id
        let interval = session.captureIntervalSeconds
        let fps = session.outputFrameRate

        let controller = CaptureController(source: makeFrameSource())
        captureController = controller

        try controller.startRecording(
            firstClipIndex: firstClipIndex,
            urlForClip: { index in
                StorageLocator.url(forRelativePath:
                    "sessions/\(sessionID.uuidString)/clips/\(String(format: "%03d", index))_\(UUID().uuidString).mov")
            },
            intervalSeconds: interval,
            outputFrameRate: fps,
            onClipOpened: { [weak self] opened in
                Task { @MainActor [weak self] in
                    self?.persistOpenedClip(opened)
                }
            },
            onClipFinalized: { [weak self] finalized in
                Task { @MainActor [weak self] in
                    self?.persistFinalizedClip(finalized)
                }
            }
        )
    }

    private func stopCapture() async {
        guard let controller = captureController else { return }
        let trailingChunk = await controller.stopRecording()
        captureController = nil
        if let trailingChunk { persistFinalizedClip(trailingChunk) }
    }

    /// Insert a `Clip` row the moment a chunk opens, `isFinalized == false`, so
    /// a force-quit before the writer finishes still leaves a row for
    /// `ClipRecovery` to repair or delete (docs/CAPTURE.md).
    private func persistOpenedClip(_ opened: OpenedClip) {
        guard let session else { return }
        guard !session.clips.contains(where: { $0.index == opened.index }) else { return }
        let clip = Clip(session: session,
                        index: opened.index,
                        relativePath: StorageLocator.relativePath(for: opened.url),
                        startedAt: Date(),
                        frameCount: 0,
                        studyOffsetStart: StudyOffsets.runningTotal(for: session),
                        isFinalized: false)
        context.insert(clip)
        try? context.save()
        DebugLog.write("Session", "opened clip row \(opened.index)")
    }

    private func persistFinalizedClip(_ finalized: FinalizedClip) {
        guard let session else { return }

        // A rollover or stop can hand back a zero-frame trailing chunk — the
        // controller already dropped its file, so drop its opened row too.
        guard finalized.frameCount > 0 else {
            removeUnfinalizedRow(index: finalized.index)
            return
        }

        let relativePath = StorageLocator.relativePath(for: finalized.url)
        if let existing = session.clips.first(where: { $0.index == finalized.index && !$0.isFinalized }) {
            existing.relativePath = relativePath
            existing.frameCount = finalized.frameCount
            existing.endedAt = Date()
            existing.isFinalized = true
        } else {
            // The open callback hasn't landed yet (or never will) — insert
            // straight to finalized.
            let clip = Clip(session: session,
                            index: finalized.index,
                            relativePath: relativePath,
                            startedAt: Date(),
                            endedAt: Date(),
                            frameCount: finalized.frameCount,
                            studyOffsetStart: 0,
                            isFinalized: true)
            context.insert(clip)
        }
        StudyOffsets.recompute(for: session)
        try? context.save()

        clipCount = session.clips.filter(\.isFinalized).count
        if status != .recording { reconcileStudySeconds() }
        DebugLog.write("Session", "persisted clip \(finalized.index): \(finalized.frameCount) frames")

        // Framing continuity (docs/CAPTURE.md): keep ghost.jpg pointed at the
        // most recently finalized clip's last frame. Fire-and-forget — never
        // blocks or fails capture.
        let sessionID = session.id
        let clipURL = finalized.url
        Task { await GhostOverlayGenerator.regenerate(for: sessionID, clipURL: clipURL) }
    }

    private func removeUnfinalizedRow(index: Int) {
        guard let session else { return }
        let rows = session.clips.filter { $0.index == index && !$0.isFinalized }
        for row in rows { context.delete(row) }
        if !rows.isEmpty {
            session.clips.removeAll { $0.index == index && !$0.isFinalized }
            try? context.save()
        }
    }

    /// After capture has fully stopped, an `isFinalized == false` row whose
    /// file the controller already deleted (a zero-frame chunk opened by a
    /// rollover that was immediately stopped) is a dead orphan — remove it.
    /// Rows backed by a real partial file are left for `ClipRecovery` on the
    /// next launch, which is the only place that can safely read them back.
    private func pruneUnfinalizedRows() {
        guard let session else { return }
        let orphans = session.clips.filter { clip in
            guard !clip.isFinalized, clip.frameCount == 0 else { return false }
            let url = StorageLocator.url(forRelativePath: clip.relativePath)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        guard !orphans.isEmpty else { return }
        for orphan in orphans { context.delete(orphan) }
        let orphanIDs = Set(orphans.map(\.id))
        session.clips.removeAll { orphanIDs.contains($0.id) }
        StudyOffsets.recompute(for: session)
        try? context.save()
        DebugLog.write("Session", "pruned \(orphans.count) dead unfinalized clip row(s) after stop")
    }

    // MARK: Study-time axis

    private func reconcileStudySeconds() {
        guard let session else { return }
        studySeconds = session.clips.filter(\.isFinalized).reduce(0) { $0 + $1.studyDuration }
    }

    /// `studySeconds` free-runs at 1 Hz while recording (never derived from the
    /// capture queue — docs/ARCHITECTURE.md) and is reconciled to the persisted
    /// clip total whenever recording stops.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.status == .recording { self.studySeconds += 1 }
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: Day boundary (D-004)

    private func evaluateAutoClose() {
        guard status == .paused, let session else { return }
        let deadline = dayBoundary.closeDeadline(forDayKey: session.dayKey)
        if Date() >= deadline {
            DebugLog.write("Session", "past close deadline for \(session.dayKey) -> auto-close")
            Task { await end() }
        }
    }

    /// Keeps the display awake while recording (D-018 / docs/CAPTURE.md screen
    /// dimming). Must run on the main thread — this type is `@MainActor`.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        guard UIApplication.shared.isIdleTimerDisabled != disabled else { return }
        UIApplication.shared.isIdleTimerDisabled = disabled
        DebugLog.write("Session", "idle timer disabled = \(disabled) "
            + "(screen \(disabled ? "held on" : "may sleep"))")
        #endif
    }

    /// docs/CAPTURE.md "Screen dimming": drop to near-black while recording —
    /// the phone is meant to be ignored, not looked at — and restore the
    /// previous brightness on pause. The recording screen itself supplies the
    /// only lit element (the timer); see docs/UI.md screen 2.
    private func setScreenDimmed(_ dimmed: Bool) {
        #if canImport(UIKit)
        if dimmed {
            guard previousScreenBrightness == nil else { return }
            previousScreenBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.05
            DebugLog.write("Session", "screen dimmed for recording")
        } else {
            guard let previous = previousScreenBrightness else { return }
            UIScreen.main.brightness = previous
            previousScreenBrightness = nil
            DebugLog.write("Session", "screen brightness restored")
        }
        #endif
    }

    // MARK: Guard monitoring

    private func startGuardMonitoring() {
        let monitor = GuardMonitor(source: makeGuardSignalSource())
        guardMonitor = monitor
        monitor.start { [weak self] actions in
            Task { @MainActor [weak self] in
                self?.handleGuardActions(actions)
            }
        }
    }

    private func stopGuardMonitoring() {
        guardMonitor?.stop()
        guardMonitor = nil
        warnings = []
    }

    /// Applies every action `CaptureGuards` reported for the latest reading.
    /// Non-blocking `.warn` actions replace `warnings` wholesale (so a
    /// resolved condition — e.g. thermal cooling back to `.fair` — clears its
    /// banner automatically); `.autoPause`/`.autoPauseAndEnd` drive the same
    /// `pause()`/`end()` the user's own controls use, once at a time.
    private func handleGuardActions(_ actions: [GuardAction]) {
        warnings = actions.compactMap { action -> CaptureWarning? in
            guard case .warn(let kind) = action else { return nil }
            switch kind {
            case .batteryLowDuringRecording: return .batteryLow
            case .thermalSerious:            return .thermalSerious
            case .batteryLowAtStart, .diskLowAtStart: return nil
            }
        }

        guard !isHandlingGuardAction else { return }
        if actions.contains(.autoPauseAndEnd) {
            isHandlingGuardAction = true
            DebugLog.write("Session", "guard fired autoPauseAndEnd")
            Task { @MainActor [weak self] in
                await self?.pause()
                await self?.end()
                self?.isHandlingGuardAction = false
            }
        } else if actions.contains(.autoPause) {
            isHandlingGuardAction = true
            DebugLog.write("Session", "guard fired autoPause (thermal critical)")
            Task { @MainActor [weak self] in
                await self?.pause()
                self?.isHandlingGuardAction = false
            }
        }
    }
}

enum SessionCoordinatorError: Error {
    case sessionAlreadyActive
    case noSession
    case notResumable
}
