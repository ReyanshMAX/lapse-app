import SwiftData
import SwiftUI

/// Entry point for the End-Session → Tagging → Export flow (docs/UI.md §4→§5).
/// Presented as a full-screen cover from `RecordView` once `SessionCoordinator`
/// has ended the session. Tagging is optional — the close button leaves every
/// range as-is (untagged ranges are a valid state, docs/DATA_MODEL.md).
struct TaggingFlowView: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TaggingView(session: session)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}
