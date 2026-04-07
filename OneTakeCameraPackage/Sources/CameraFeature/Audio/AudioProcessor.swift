// AudioProcessor.swift
// Wraps CompressorEngine for the capture pipeline. No AVAudioEngine.

import Foundation
import os
import OneTakeDSPCore
import OneTakeDSPPresets

/// Applies a compressor preset to Float32 stereo buffers.
/// Called from the capture serial queue — not thread-safe on its own.
final class AudioProcessor: @unchecked Sendable {
    private var preset: CompressorPreset
    private var state = CompressorState()

    // Thread-safe peak storage. Updated from captureQueue, read from any thread.
    private let peakLock = OSAllocatedUnfairLock<Float>(initialState: 0)

    init(preset: CompressorPreset = .studio, sampleRate: Float = 48000) {
        self.preset = preset
        state.sampleRate = sampleRate
    }

    /// Switch to a new preset and reset the compressor envelope history.
    func setPreset(_ new: CompressorPreset) {
        preset = new
        state = CompressorState()
    }

    /// Returns the peak linear amplitude since last call and resets the stored peak to 0.
    func readPeakAndReset() -> Float {
        peakLock.withLock { peak in
            let v = peak
            peak = 0
            return v
        }
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

        // Compute post-DSP peak across both channels.
        var maxL: Float = 0
        var maxR: Float = 0
        for i in 0 ..< frameCount {
            let absL = abs(left[i])
            let absR = abs(right[i])
            if absL > maxL { maxL = absL }
            if absR > maxR { maxR = absR }
        }
        let combinedPeak = max(maxL, maxR)
        peakLock.withLock { $0 = max($0, combinedPeak) }
    }
}
