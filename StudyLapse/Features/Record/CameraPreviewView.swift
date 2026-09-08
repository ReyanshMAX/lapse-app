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
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
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
