import AVKit
import SwiftUI

/// Bare AVPlayer screen for a single written clip — reached from the debug
/// clip browser. Proves capture / writing / storage round-trip on device
/// until the real library (Phase 5) and export (Phase 3) exist.
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
