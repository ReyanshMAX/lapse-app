import Foundation
import Observation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Non-fatal conditions surfaced to the recording UI. Guard logic that
/// populates this (battery / thermal / disk) lands in Phase 7 — the type
/// exists now so the coordinator's surface is stable.
enum CaptureWarning: Equatable {
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
    private(set) var status: SessionStatus = .ended
    private(set) var studySeconds: Double = 0
    private(set) var warnings: [CaptureWarning] = []
    private(set) var clipCount: Int = 0
    private(set) var lastError: String?

    private let context: ModelContext
    private let makeFrameSource: () -> FrameSource

    private var captureController: CaptureController?
    private var tickTask: Task<Void, Never>?

    /// `makeFrameSource` defaults to the real camera; tests inject a
    /// `SyntheticFrameSource`.
    init(context: ModelContext,
         makeFrameSource: @escaping () -> FrameSource = { CameraFrameSource() }) {
        self.context = context
        self.makeFrameSource = makeFrameSource
    }

    private var dayBoundary: DayBoundary {
        let hour = UserDefaults.standard.object(forKey: "dayCutoffHour") as? Int ?? 4
        return DayBoundary(cutoffHour: hour)
    }

    // MARK: Lifecycle

    func startNewSession() throws {
        guard status == .ended else {
            throw SessionCoordinatorError.sessionAlreadyActive
        }
        let now = Date()
        let interval = UserDefaults.standard.object(forKey: "captureIntervalSeconds") as? Double ?? 3
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
        startTicking()
        DebugLog.write("Session", "started \(newSession.id) dayKey \(newSession.dayKey)")
    }

    func pause() async {
        guard status == .recording else { return }
        await stopCapture()
        status = .paused
        session?.status = .paused
        setIdleTimerDisabled(false)
        reconcileStudySeconds()
        try? context.save()
        DebugLog.write("Session", "paused; \(clipCount) clips, \(Int(studySeconds))s study")
        evaluateAutoClose()
    }

    func resume() throws {
        guard status == .paused, let session else { return }
        let nextIndex = (session.clips.map(\.index).max() ?? -1) + 1
        status = .recording
        session.status = .recording
        try context.save()
        try beginCapture(firstClipIndex: nextIndex)
        setIdleTimerDisabled(true)
        startTicking()
        DebugLog.write("Session", "resumed at clip index \(nextIndex)")
    }

    func end() async {
        guard status != .ended else { return }
        await stopCapture()
        status = .ended
        session?.status = .ended
        session?.endedAt = Date()
        setIdleTimerDisabled(false)
        reconcileStudySeconds()
        stopTicking()
        try? context.save()
        DebugLog.write("Session", "ended; \(clipCount) clips, \(Int(studySeconds))s study")
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
            evaluateAutoClose()
        @unknown default:
            break
        }
    }

    // MARK: Launch recovery

    func recoverOnLaunch() async {
        ClipRecovery.demoteRecordingSessions(in: context)
        await ClipRecovery.recoverUnfinalized(in: context)

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

    private func persistFinalizedClip(_ finalized: FinalizedClip) {
        guard let session else { return }
        // A rollover or stop can hand back a zero-frame trailing chunk — the
        // controller already dropped its file, so drop the row too.
        guard finalized.frameCount > 0 else { return }

        let relativePath = StorageLocator.relativePath(for: finalized.url)
        let clip = Clip(session: session,
                        index: finalized.index,
                        relativePath: relativePath,
                        startedAt: Date(),
                        endedAt: Date(),
                        frameCount: finalized.frameCount,
                        studyOffsetStart: 0,
                        isFinalized: true)
        context.insert(clip)
        StudyOffsets.recompute(for: session)
        try? context.save()

        clipCount = session.clips.filter(\.isFinalized).count
        if status != .recording { reconcileStudySeconds() }
        DebugLog.write("Session", "persisted clip \(finalized.index): \(finalized.frameCount) frames")
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

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

enum SessionCoordinatorError: Error {
    case sessionAlreadyActive
    case noSession
}
