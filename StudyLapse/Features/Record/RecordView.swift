import AVFoundation
import StudyLapseCore
import SwiftUI
import UIKit

/// Phase 2 record screen: the study-time timer, clip count, and
/// record / pause / resume / end controls wired to `SessionCoordinator`.
/// No preview while recording (docs/UI.md, Q-005); no overlay, tagging, or
/// export yet (BUILD.md Phase 2 non-goals).
struct RecordView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @State private var authorizationStatus: AVAuthorizationStatus = CameraPermission.status
    @State private var errorMessage: String?
    @State private var taggingSession: Session?
    @State private var pendingStartWarnings: [GuardWarningKind] = []
    @State private var showStartWarningConfirm = false
    @State private var ghostImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                if coordinator.status == .paused, let ghostImage {
                    Image(uiImage: ghostImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.35)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
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
            // docs/CAPTURE.md screen dimming: near-black while recording, the
            // timer is the only lit element. Functional only — the token
            // palette pass is Phase 8.
            .background(coordinator.status == .recording ? Color.black : Color.clear)
            .task(id: pausedGhostKey) { await loadGhostImage() }
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

    /// Re-runs `loadGhostImage` whenever the paused session identity changes
    /// (a new pause, or a different session recovered on launch) — not on
    /// every `studySeconds` tick, which `.task(id:)` would otherwise re-fire on
    /// since `coordinator` is `@Observable`.
    private var pausedGhostKey: String {
        coordinator.status == .paused ? (coordinator.session?.id.uuidString ?? "") : ""
    }

    private func loadGhostImage() async {
        guard coordinator.status == .paused, let sessionID = coordinator.session?.id else {
            ghostImage = nil
            return
        }
        let url = GhostOverlayGenerator.url(for: sessionID)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            ghostImage = nil
            return
        }
        ghostImage = image
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
