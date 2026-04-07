// AudioProcessor.swift
// Wraps CompressorEngine for the capture pipeline. No AVAudioEngine.

import Foundation
import OneTakeDSPCore
import OneTakeDSPPresets

/// Applies the hardcoded LA-2A compressor preset to Float32 stereo buffers.
/// Called from the capture serial queue — not thread-safe on its own.
final class AudioProcessor {
    private var state = CompressorState()

    init(sampleRate: Float = 48000) {
        state.sampleRate = sampleRate
    }

    /// Process audio in-place. `left` and `right` must each have `frameCount` samples.
    func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        CompressorEngine.process(
            left: left,
            right: right,
            frameCount: frameCount,
            settings: .studioLight,
            model: .opto,
            state: &state
        )
    }
}
