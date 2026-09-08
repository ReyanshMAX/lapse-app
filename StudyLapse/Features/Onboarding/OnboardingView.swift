import SwiftUI

/// First-launch welcome screen (developer request, 2026-09-08 — see
/// STATUS.md Deviations). Shown once via `RootTabView`'s
/// `hasSeenOnboarding` flag, before the user lands on any tab — including
/// before the camera-permission prime screen `RecordView` shows on its own
/// first appearance, so the permission prompt has context instead of being
/// the very first thing a new user sees.
struct OnboardingView: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xxl) {
            Spacer()

            Image(systemName: "video.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(Color.slAccent)

            VStack(spacing: DesignTokens.Spacing.sm) {
                Text("Welcome to StudyLapse")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.slTextPrimary)
                    .multilineTextAlignment(.center)
                Text("Record a timelapse of your study day and turn it into a finished, shareable video — entirely on your device. Nothing is uploaded.")
                    .font(.body)
                    .foregroundStyle(Color.slTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                OnboardingStep(icon: "video.fill",
                              text: "Record while you study — pause and resume as many times as you need")
                OnboardingStep(icon: "tag.fill",
                              text: "Tag which parts were which subject when you're done")
                OnboardingStep(icon: "square.and.arrow.up",
                              text: "Export a sped-up, shareable timelapse")
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)

            Spacer()
            Spacer()

            Button("Get Started", action: onFinish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DesignTokens.Spacing.xl)
        }
        .padding(.vertical, DesignTokens.Spacing.xxl)
        .screenBackground()
    }
}

private struct OnboardingStep: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.slAccent)
                .frame(width: 28)
            Text(text)
                .foregroundStyle(Color.slTextPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
