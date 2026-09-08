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
