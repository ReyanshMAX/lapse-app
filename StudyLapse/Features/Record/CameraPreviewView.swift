import AVFoundation
import SwiftUI

/// Wraps an `AVCaptureVideoPreviewLayer` (docs/ARCHITECTURE.md notes: "Do not
/// recreate it on SwiftUI state changes; it is expensive" — `makeUIView` runs
/// once, `updateUIView` only re-points the layer's session if it changed).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        applyMirroring(to: view.videoPreviewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Reassign unconditionally, not just when the session identity
        // changes: `makeUIView` binds the layer before the idle preview
        // session has any input configured (it's configured asynchronously,
        // after `.task(id:)` starts it), and `AVCaptureVideoPreviewLayer`'s
        // connection can stay stale if it's never touched again after that —
        // a known AVFoundation gotcha, and the leading suspect once the
        // debug log ruled out the session itself failing to start (`isRunning`
        // was true on every attempt, no interruption/runtime-error fired).
        // This property set is cheap — the "don't recreate it" warning above
        // is about the layer/view itself, not this assignment.
        uiView.videoPreviewLayer.session = session
        applyMirroring(to: uiView.videoPreviewLayer)
    }

    /// The front camera previews mirrored (a selfie reads naturally that
    /// way) — this only affects the live preview, not the recorded output.
    private func applyMirroring(to layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection, connection.isVideoMirroringSupported else { return }
        let isFront = session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device.position }
            .contains(.front)
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = isFront
    }

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
