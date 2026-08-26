import AVKit
import SwiftUI

/// Bare playback screen for the Phase 1 written clip — proves capture,
/// writing, and storage round-trip. No UI polish (BUILD.md non-goals).
struct PlaybackView: View {
    let url: URL

    var body: some View {
        VideoPlayer(player: AVPlayer(url: url))
            .navigationTitle("Playback")
            .onAppear {
                DebugLog.write("Playback", "opened \(url.lastPathComponent)")
            }
    }
}
