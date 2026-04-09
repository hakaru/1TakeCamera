// CaptureResolution.swift
// Available capture resolutions for the video pipeline.

import AVFoundation
import CoreGraphics

public enum CaptureResolution: String, CaseIterable, Identifiable, Sendable {
    case hd
    case fourK

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hd:   return "HD"
        case .fourK: return "4K"
        }
    }

    public var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd:   return .hd1920x1080
        case .fourK: return .hd4K3840x2160
        }
    }

    public var videoSize: CGSize {
        switch self {
        case .hd:   return CGSize(width: 1920, height: 1080)
        case .fourK: return CGSize(width: 3840, height: 2160)
        }
    }

    public var videoBitRate: Int {
        switch self {
        case .hd:   return 10_000_000
        case .fourK: return 25_000_000
        }
    }
}
