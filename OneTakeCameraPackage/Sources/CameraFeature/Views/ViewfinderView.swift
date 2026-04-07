// ViewfinderView.swift
// UIViewRepresentable wrapping AVCaptureVideoPreviewLayer for full-screen camera preview.

import SwiftUI
import AVFoundation

/// Full-screen camera preview backed by AVCaptureVideoPreviewLayer.
/// Must be used on the main actor (UIKit requirement).
public struct ViewfinderView: UIViewRepresentable {
    let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// UIView whose backing layer is AVCaptureVideoPreviewLayer.
public final class PreviewView: UIView {
    public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    // Safe cast: layerClass guarantees the layer is AVCaptureVideoPreviewLayer.
    var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }
}
