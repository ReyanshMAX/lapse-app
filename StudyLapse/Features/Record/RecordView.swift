import AVFoundation
import StudyLapseCore
import SwiftUI
import UIKit

/// Record screen: the study-time timer, clip count, and record / pause /
/// resume / end controls wired to `SessionCoordinator`, with a live camera
/// preview + framing guide shown in every state, including while recording
/// (D-028 — resolves the former Q-005; screen dimming still applies while
/// recording, so the preview reads dim rather than fully lit).
struct RecordView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorizationStatus: AVAuthorizationStatus = CameraPermission.status
    @State private var errorMessage: String?
    @State private var taggingSession: Session?
    @State private var pendingStartWarnings: [GuardWarningKind] = []
    @State private var showStartWarningConfirm = false
    @State private var previewController = CameraPreviewController()
    @State private var accessibleStudyTime: String = ""
    @State private var lastAnnouncedSeconds: Double = -1000
    @AppStorage(CameraPreferences.positionKey) private var cameraPositionRaw = AVCaptureDevice.Position.back.rawValue

    private var showsPreview: Bool {
        authorizationStatus == .authorized
    }

    private var cameraPosition: AVCaptureDevice.Position {
        AVCaptureDevice.Position(rawValue: cameraPositionRaw) ?? .back
    }

    /// Combines whether the standalone idle-preview session should be running
    /// right now — never while recording (the real capture session supplies
    /// the preview then) or backgrounded — with which camera it should use.
    /// One `Equatable` value driving one `.task(id:)` (see `body`): multiple
    /// independent `Task { await ... }` calls from separate
    /// `.onAppear`/`.onChange` handlers raced each other once
    /// `CameraPreviewController.start`/`stop` became `async` — Swift's
    /// scheduler could run a later "stop" before an earlier "start" landed on
    /// the session queue, leaving the preview off with nothing left to
    /// retrigger it. `.task(id:)` cancels/supersedes instead of racing, and
    /// folding the camera position in here means flipping the camera while
    /// idle/paused reconfigures the live preview the same way.
    private struct PreviewIntent: Equatable {
        var shouldRun: Bool
        var position: AVCaptureDevice.Position
    }

    private var previewIntent: PreviewIntent {
        PreviewIntent(
            shouldRun: showsPreview && scenePhase == .active && coordinator.status != .recording,
            position: cameraPosition)
    }

    /// While recording, bind to the real capture session's own preview layer
    /// (only one `AVCaptureSession` can hold the camera at a time); otherwise
    /// the standalone idle-preview session.
    private var boundPreviewSession: AVCaptureSession {
        coordinator.activePreviewSession ?? previewController.session
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if showsPreview {
                    CameraPreviewView(session: boundPreviewSession)
                        .ignoresSafeArea()
                    FramingGuideView()
                        .ignoresSafeArea()
                    if coordinator.status == .paused {
                        // "Dimmed preview" (docs/UI.md screen 3).
                        Color.black.opacity(0.25).ignoresSafeArea()
                    }
                    if coordinator.status != .recording {
                        // Flip control (docs/UI.md screen 1) — only meaningful
                        // while the idle preview is what's shown; while
                        // recording the real capture session already owns a
                        // fixed camera for the session.
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: flipCamera) {
                                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                                        .font(.title2)
                                        .foregroundStyle(Color.slTextPrimary)
                                        .padding(12)
                                        .background(Circle().fill(Color.black.opacity(0.4)))
                                }
                                .padding()
                                .accessibilityLabel("Switch camera")
                            }
                            Spacer()
                        }
                    }
                }

                VStack(spacing: 24) {
                    switch authorizationStatus {
                    case .authorized:
                        sessionControls
                    case .notDetermined:
                        permissionPrime
                    default:
                        permissionDenied
                    }
                }
                .padding()
            }
            .navigationTitle("StudyLapse")
            .screenBackground()
            .task(id: previewIntent) {
                if previewIntent.shouldRun {
                    await previewController.start(position: previewIntent.position)
                } else {
                    await previewController.stop()
                }
            }
            .onDisappear { Task { await previewController.stop() } }
            .fullScreenCover(item: $taggingSession) { session in
                TaggingFlowView(session: session)
            }
            .confirmationDialog(startWarningMessage, isPresented: $showStartWarningConfirm,
                                titleVisibility: .visible) {
                Button("Start Anyway") { beginRecording() }
                Button("Cancel", role: .cancel) { pendingStartWarnings = [] }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink { LibraryView() } label: {
                        Label("Library", systemImage: "square.grid.2x2")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("Debug Log") { DebugLogView() }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionControls: some View {
        // Visual text updates at 1 Hz (docs/UI.md screen 2); the accessibility
        // label is throttled to a coarser cadence so VoiceOver doesn't
        // re-announce every second (docs/UI.md Notes), and carries
        // `.updatesFrequently` so a focused VoiceOver user can still poll the
        // live value on demand.
        Text(Formatters.studyTime(coordinator.studySeconds))
            .font(.system(size: 48, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Color.slTextPrimary)
            .accessibilityLabel("Study time \(accessibleStudyTime)")
            .accessibilityAddTraits(.updatesFrequently)
            .onAppear { announceStudyTime(coordinator.studySeconds, force: true) }
            .onChange(of: coordinator.studySeconds) { _, new in announceStudyTime(new) }

        Text(clipCountLabel)
            .foregroundStyle(Color.slTextSecondary)

        VStack(spacing: DesignTokens.Spacing.md) {
            switch coordinator.status {
            case .ended:
                actionButton("Start Recording") { start() }
            case .recording:
                actionButton("Pause") { Task { await coordinator.pause() } }
                actionButton("End Session", role: .destructive) { endSession() }
            case .paused:
                actionButton("Resume") { resume() }
                actionButton("End Session", role: .destructive) { endSession() }
            }
        }

        if coordinator.status == .recording {
            VStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(coordinator.warnings, id: \.self) { warning in
                    Text(warningText(warning))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.slWarning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                            .fill(Color.black.opacity(0.55)))
                }
            }
        }

        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(Color.slError)
                .multilineTextAlignment(.center)
        }
    }

    private func announceStudyTime(_ seconds: Double, force: Bool = false) {
        guard force || abs(seconds - lastAnnouncedSeconds) >= 30 else { return }
        lastAnnouncedSeconds = seconds
        accessibleStudyTime = Formatters.studyTime(seconds)
    }

    private var clipCountLabel: String {
        let count = coordinator.clipCount
        return "\(count) clip\(count == 1 ? "" : "s")"
    }

    private func warningText(_ warning: CaptureWarning) -> String {
        switch warning {
        case .batteryLow:     return "Battery low — session will end automatically at 5%."
        case .thermalSerious: return "Phone is running hot."
        case .diskLow:        return "Storage running low."
        }
    }

    private var startWarningMessage: String {
        pendingStartWarnings.map { kind -> String in
            switch kind {
            case .batteryLowAtStart: return "Battery is below 30% and not charging."
            case .diskLowAtStart:    return "Free storage is below 1 GB."
            case .batteryLowDuringRecording, .thermalSerious: return ""
            }
        }.joined(separator: " ")
    }

    private func actionButton(_ title: String, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(title, role: role, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }

    /// docs/CAPTURE.md: low unplugged battery or low disk at session start is
    /// "warn, offer to continue" (D-018), not a hard block.
    private func start() {
        let warnings = coordinator.evaluateStartWarnings()
        if warnings.isEmpty {
            beginRecording()
        } else {
            pendingStartWarnings = warnings
            showStartWarningConfirm = true
        }
    }

    private func beginRecording() {
        errorMessage = nil
        pendingStartWarnings = []
        Task {
            // Release the camera from the idle preview session before the
            // real capture session tries to acquire it — `await`ing
            // `previewController.stop()` suspends until the hardware is
            // actually released.
            await previewController.stop()
            do {
                try await coordinator.startNewSession()
            } catch {
                errorMessage = "Couldn't start recording: \(error.localizedDescription)"
                DebugLog.write("Record", "start failed: \(error)")
            }
        }
    }

    /// End the session, then hand off to the tagging flow (docs/UI.md §4).
    /// Reads `lastEndedSession` rather than observing it — the day-boundary
    /// auto-close also calls `end()` and must not pop this screen.
    private func endSession() {
        Task {
            await coordinator.end()
            taggingSession = coordinator.lastEndedSession
        }
    }

    /// Persists the flipped choice (`CameraPreferences`, shared with
    /// `SessionCoordinator`'s default `makeFrameSource` for the next
    /// recording/resume) and reconfigures the live idle preview via the
    /// `.task(id: previewIntent)` in `body` reacting to the change.
    private func flipCamera() {
        let next: AVCaptureDevice.Position = (cameraPosition == .back) ? .front : .back
        cameraPositionRaw = next.rawValue
    }

    private func resume() {
        errorMessage = nil
        Task {
            await previewController.stop()
            do {
                try await coordinator.resume()
            } catch {
                errorMessage = "Couldn't resume: \(error.localizedDescription)"
                DebugLog.write("Record", "resume failed: \(error)")
            }
        }
    }

    @ViewBuilder
    private var permissionPrime: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Text("StudyLapse needs camera access to record your study timelapse. Video stays on this device and is never uploaded.")
                .foregroundStyle(Color.slTextPrimary)
                .multilineTextAlignment(.center)
            Button("Enable Camera") {
                Task {
                    _ = await CameraPermission.requestAccess()
                    authorizationStatus = CameraPermission.status
                    DebugLog.write("Permission", "camera authorization now \(authorizationStatus.rawValue)")
                    // `authorizationStatus` changing flips `previewIntent`,
                    // which the `.task(id:)` in `body` reacts to automatically.
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var permissionDenied: some View {
        Text("Camera access is required. Enable it in Settings to continue.")
            .foregroundStyle(Color.slTextPrimary)
            .multilineTextAlignment(.center)
    }
}
