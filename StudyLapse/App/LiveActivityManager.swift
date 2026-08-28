import ActivityKit
import Foundation

/// Starts/updates/ends the Live Activity shown while a session is paused
/// (docs/UI.md "Live Activity"): "Shown while a session is paused... While
/// recording, the app is foregrounded by definition, so no Live Activity is
/// presented." `SessionCoordinator` is the only caller (docs/ARCHITECTURE.md
/// notes: "Live Activity state is pushed from SessionCoordinator only").
///
/// No push updates — everything travels in `Activity.request`/`.update`'s
/// `ContentState`, which needs no App Groups or paid-program entitlement
/// (docs/ARCHITECTURE.md).
@MainActor
enum LiveActivityManager {
    private static var current: Activity<StudyLapseActivityAttributes>?

    static func start(dayKey: String, studySeconds: Double, clipCount: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            DebugLog.write("LiveActivity", "Live Activities not enabled by the user")
            return
        }
        end()   // replace any stale activity left over from a previous pause

        let attributes = StudyLapseActivityAttributes(dayKey: dayKey)
        let state = StudyLapseActivityAttributes.ContentState(
            studySeconds: studySeconds, clipCount: clipCount)
        do {
            current = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil))
            DebugLog.write("LiveActivity", "started for dayKey \(dayKey)")
        } catch {
            DebugLog.write("LiveActivity", "failed to start: \(error)")
        }
    }

    static func update(studySeconds: Double, clipCount: Int) {
        guard let current else { return }
        let state = StudyLapseActivityAttributes.ContentState(
            studySeconds: studySeconds, clipCount: clipCount)
        Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
    }

    static func end() {
        guard let activity = current else { return }
        current = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        DebugLog.write("LiveActivity", "ended")
    }
}
