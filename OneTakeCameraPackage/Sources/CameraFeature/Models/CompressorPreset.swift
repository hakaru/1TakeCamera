// CompressorPreset.swift
// 4 compressor character presets for 1Take Camera.

import Foundation
import OneTakeDSPCore
import OneTakeDSPPresets

public enum CompressorPreset: String, CaseIterable, Identifiable, Sendable {
    case none, studio, studioPlus, live

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .studio: "Studio"
        case .studioPlus: "Studio+"
        case .live: "Live"
        }
    }

    public var characterName: String {
        switch self {
        case .none: "Bypass"
        case .studio: "LA-2A"
        case .studioPlus: "1176"
        case .live: "VCA"
        }
    }

    public var settings: CompressorSettings {
        switch self {
        case .none: .bypass
        case .studio: .studioLight
        case .studioPlus: .studioHeavy
        case .live: .live
        }
    }

    public var model: CompressorEngine.Model {
        switch self {
        case .none: .opto   // bypass via settings.enabled=false anyway
        case .studio: .opto
        case .studioPlus: .fet
        case .live: .vca
        }
    }
}
