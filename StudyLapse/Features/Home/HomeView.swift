import StudyLapseCore
import SwiftData
import SwiftUI

/// Home tab: the app's dashboard (developer request, 2026-09-08 — see
/// STATUS.md Deviations). Today's status and study time, current streak, a
/// jump-in CTA that reflects the live session state, and a few recent
/// sessions. Reads the same `SessionCoordinator`/`Stats` sources
/// `RecordView`/`StatsView` already use — no new persistence, purely a
/// different view over existing data.
struct HomeView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]
    @Binding var selection: AppTab
    /// A daily study-time target the user can set from this screen (developer
    /// request, 2026-09-09 — "study goals"). Plain `UserDefaults`, like
    /// `dayCutoffHour`/`cameraPositionRawValue` already are, rather than a
    /// SwiftData row: it's a single-user local preference, not something any
    /// session/stat references. `0` means "no goal set" — there's no settings
    /// screen in this app yet to put a dedicated control on (docs/UI.md's
    /// four settings have never had UI built for them either), so the goal is
    /// set and cleared from right here via `goalEditorPresented`.
    @AppStorage("dailyStudyGoalSeconds") private var dailyGoalSeconds: Double = 0
    @State private var goalEditorPresented = false

    private var finishedSessions: [Session] { sessions.filter { $0.status == .ended } }
    private var recentSessions: [Session] { Array(finishedSessions.prefix(5)) }

    private var todayKey: String {
        let hour = UserDefaults.standard.object(forKey: "dayCutoffHour") as? Int ?? 4
        return DayBoundary(cutoffHour: hour).dayKey(for: Date())
    }

    private var streak: Int {
        let studiedDayKeys = Set(finishedSessions.map(\.dayKey))
        return Stats.currentStreak(studiedDayKeys: studiedDayKeys, today: todayKey)
    }

    private func studySeconds(_ session: Session) -> Double {
        session.orderedFinalizedClips.reduce(0) { $0 + $1.studyDuration }
    }

    /// Already-finished sessions for today plus, if a session is currently
    /// open for today, its live/reconciled total — never both counted for
    /// the same session, since `finishedSessions` excludes anything still
    /// `.recording`/`.paused`.
    private var todaysStudySeconds: Double {
        var total = finishedSessions.filter { $0.dayKey == todayKey }
            .reduce(0) { $0 + studySeconds($1) }
        if let session = coordinator.session, session.dayKey == todayKey {
            total += coordinator.studySeconds
        }
        return total
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                Text(greeting)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.slTextPrimary)

                statusCard
                goalCard

                if streak > 0 {
                    streakRow
                }

                if recentSessions.isEmpty {
                    EmptyStateView(
                        systemImage: "video.badge.plus",
                        title: "Ready when you are",
                        message: "Start your first study session above.")
                        .frame(minHeight: 200)
                } else {
                    recentSessionsSection
                }
            }
            .padding()
        }
        .navigationTitle("StudyLapse")
        .screenBackground()
        .sheet(isPresented: $goalEditorPresented) {
            GoalEditorSheet(goalSeconds: $dailyGoalSeconds)
        }
    }

    // MARK: Daily goal

    @ViewBuilder
    private var goalCard: some View {
        Button { goalEditorPresented = true } label: {
            if dailyGoalSeconds > 0 {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    HStack {
                        Text("Daily goal")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.slTextSecondary)
                        Spacer()
                        Text(Formatters.studyTime(min(todaysStudySeconds, dailyGoalSeconds))
                             + " / " + Formatters.studyTime(dailyGoalSeconds))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.slTextSecondary)
                    }
                    ProgressView(value: min(todaysStudySeconds / dailyGoalSeconds, 1))
                        .tint(Color.slAccent)
                    Text(goalMet ? "Goal reached today" : "\(Formatters.studyTime(dailyGoalSeconds - todaysStudySeconds)) to go")
                        .font(.caption)
                        .foregroundStyle(goalMet ? Color.slAccent : Color.slTextSecondary)
                }
            } else {
                HStack {
                    Image(systemName: "target")
                        .foregroundStyle(Color.slAccent)
                    Text("Set a daily study goal")
                        .foregroundStyle(Color.slTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color.slTextSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).fill(Color.slSurface))
    }

    private var goalMet: Bool {
        dailyGoalSeconds > 0 && todaysStudySeconds >= dailyGoalSeconds
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(statusTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.slTextSecondary)
                Text(Formatters.studyTime(todaysStudySeconds))
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.slTextPrimary)
                Text("studied today")
                    .font(.caption)
                    .foregroundStyle(Color.slTextSecondary)
            }

            Button {
                selection = .record
            } label: {
                Text(ctaTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(coordinator.status == .recording ? Color.slRecording : Color.slAccent)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).fill(Color.slSurface))
    }

    private var statusTitle: String {
        switch coordinator.status {
        case .ended: return "No active session"
        case .paused: return "Session paused"
        case .recording: return "Recording now"
        }
    }

    private var ctaTitle: String {
        switch coordinator.status {
        case .ended: return "Start Studying"
        case .paused: return "Resume Session"
        case .recording: return "Go to Recording"
        }
    }

    @ViewBuilder
    private var streakRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "flame.fill")
                .foregroundStyle(Color.slWarning)
            Text("\(streak)-day streak")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.slTextPrimary)
            Spacer()
        }
        .padding(DesignTokens.Spacing.md)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).fill(Color.slSurface))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text("Recent sessions")
                    .font(.headline)
                    .foregroundStyle(Color.slTextPrimary)
                Spacer()
                Button("See all") { selection = .library }
                    .font(.subheadline)
            }
            ForEach(recentSessions) { session in
                NavigationLink {
                    SessionDetailView(session: session)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.startedAt.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(Color.slTextPrimary)
                            Text(Formatters.studyTime(studySeconds(session)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.slTextSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color.slTextSecondary)
                    }
                    .padding(DesignTokens.Spacing.md)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).fill(Color.slSurface))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Picks (or clears) `dailyGoalSeconds` in half-hour steps up to 8 hours —
/// plenty of headroom for a daily target without a free-text field that could
/// end up storing something nonsensical (docs/UI.md has no precedent settings
/// screen to match, so this keeps the same "Stepper with a sane range" style
/// Export's speed multiplier already uses).
private struct GoalEditorSheet: View {
    @Binding var goalSeconds: Double
    @Environment(\.dismiss) private var dismiss
    @State private var draftMinutes: Double

    init(goalSeconds: Binding<Double>) {
        _goalSeconds = goalSeconds
        _draftMinutes = State(initialValue: goalSeconds.wrappedValue > 0 ? goalSeconds.wrappedValue / 60 : 60)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $draftMinutes, in: 30...480, step: 30) {
                        Text(Formatters.studyTime(draftMinutes * 60))
                    }
                } footer: {
                    Text("Shown on Home as progress toward today's study time.")
                }
                if goalSeconds > 0 {
                    Section {
                        Button("Remove goal", role: .destructive) {
                            goalSeconds = 0
                            dismiss()
                        }
                    }
                }
            }
            .tokenizedListStyle()
            .navigationTitle("Daily Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        goalSeconds = draftMinutes * 60
                        dismiss()
                    }
                }
            }
        }
    }
}
