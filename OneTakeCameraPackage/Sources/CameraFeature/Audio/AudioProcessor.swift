// AudioProcessor.swift
// Wraps CompressorEngine for the capture pipeline. No AVAudioEngine.

import Foundation
import OneTakeDSPCore
import OneTakeDSPPresets

/// Applies a compressor preset to Float32 stereo buffers.
/// Called from the capture serial queue — not thread-safe on its own.
final class AudioProcessor: @unchecked Sendable {
    private var preset: CompressorPreset
    private var state = CompressorState()

    init(preset: CompressorPreset = .studio, sampleRate: Float = 48000) {
        self.preset = preset
        state.sampleRate = sampleRate
    }

    /// Switch to a new preset and reset the compressor envelope history.
    func setPreset(_ new: CompressorPreset) {
        preset = new
        state = CompressorState()
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
            settings: preset.settings,
            model: preset.model,
            state: &state
        )
    }
}
