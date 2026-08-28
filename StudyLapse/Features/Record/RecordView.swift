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

    private var showsPreview: Bool {
        authorizationStatus == .authorized
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
            .onAppear { updatePreviewSession() }
            .onDisappear { previewController.stop() }
            .onChange(of: coordinator.status) { _, _ in updatePreviewSession() }
            .onChange(of: scenePhase) { _, _ in updatePreviewSession() }
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

    /// Starts or stops the *standalone idle-preview* session — never while
    /// recording, since the real capture session supplies the preview then
    /// (`boundPreviewSession`), and a second `AVCaptureSession` would just
    /// fail to acquire the camera. Also off when backgrounded.
    /// `CameraPreviewController` itself no-ops a redundant start/stop, so
    /// calling this liberally on every relevant state change is cheap.
    private func updatePreviewSession() {
        if showsPreview, scenePhase == .active, coordinator.status != .recording {
            previewController.start()
        } else {
            previewController.stop()
        }
    }

    @ViewBuilder
    private var sessionControls: some View {
        Text(Formatters.studyTime(coordinator.studySeconds))
            .font(.system(size: 60, weight: .semibold, design: .monospaced))
            .monospacedDigit()

        Text(clipCountLabel)
            .foregroundStyle(.secondary)

        VStack(spacing: 12) {
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
            ForEach(coordinator.warnings, id: \.self) { warning in
                Text(warningText(warning))
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }

        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
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
        // Release the camera from the idle preview session before the real
        // capture session tries to acquire it — CameraPreviewController.stop()
        // blocks until the hardware is actually released (mirrors
        // CameraFrameSource.stop()'s own synchronous style).
        previewController.stop()
        do {
            try coordinator.startNewSession()
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            DebugLog.write("Record", "start failed: \(error)")
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

    private func resume() {
        errorMessage = nil
        previewController.stop()
        do {
            try coordinator.resume()
        } catch {
            errorMessage = "Couldn't resume: \(error.localizedDescription)"
            DebugLog.write("Record", "resume failed: \(error)")
        }
    }

    @ViewBuilder
    private var permissionPrime: some View {
        VStack(spacing: 16) {
            Text("StudyLapse needs camera access to record your study timelapse. Video stays on this device and is never uploaded.")
                .multilineTextAlignment(.center)
            Button("Enable Camera") {
                Task {
                    _ = await CameraPermission.requestAccess()
                    authorizationStatus = CameraPermission.status
                    DebugLog.write("Permission", "camera authorization now \(authorizationStatus.rawValue)")
                    updatePreviewSession()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var permissionDenied: some View {
        Text("Camera access is required. Enable it in Settings to continue.")
            .multilineTextAlignment(.center)
    }
}
