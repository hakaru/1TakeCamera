// AudioProcessor.swift
// Full 8-stage DSP chain for the capture pipeline. No AVAudioEngine.
//
// NOTE: After calling setPreset(), caller must also call setSampleRate()
// to propagate the sample rate to all stateful engines.

import Foundation
import os
import OneTakeDSPCore
import OneTakeDSPPresets

/// Applies the full 8-stage DSP chain to Float32 stereo buffers.
/// Called from the capture serial queue — not thread-safe on its own.
final class AudioProcessor: @unchecked Sendable {
    private var preset: CompressorPreset
    private var audioPreset: AudioPreset

    // Per-engine states
    private var trimState = TrimState()
    private var gateState = GateState()
    private var eqState = EQState()
    private var compState1 = CompressorState()
    private var compState2 = CompressorState()
    private var saturationState = SaturationState()
    private var stereoState = StereoFieldState()
    private var limiterState = LimiterState()

    // Thread-safe peak storage. Updated from captureQueue, read from any thread.
    private let peakLock = OSAllocatedUnfairLock<Float>(initialState: 0)

    // Thread-safe clip flag. Set when post-DSP peak exceeds -1 dBFS (0.891 linear).
    private let clipLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    init(preset: CompressorPreset = .studio, sampleRate: Float = 48000) {
        self.preset = preset
        self.audioPreset = AudioPreset.preset(for: preset.audioPresetType)
        compState1.sampleRate = sampleRate
        compState2.sampleRate = sampleRate
        gateState.sampleRate = sampleRate
        eqState.sampleRate = sampleRate
        stereoState.sampleRate = sampleRate
        limiterState.sampleRate = sampleRate
    }

    /// Switch to a new preset and reset all engine states.
    /// Caller must also call setSampleRate() after this.
    func setPreset(_ new: CompressorPreset) {
        preset = new
        audioPreset = AudioPreset.preset(for: new.audioPresetType)
        trimState = TrimState()
        gateState = GateState()
        eqState = EQState()
        compState1 = CompressorState()
        compState2 = CompressorState()
        saturationState = SaturationState()
        stereoState = StereoFieldState()
        limiterState = LimiterState()
    }

    /// Resets all engine states to their initial values.
    /// Call after a camera switch to clear biquad filter history, envelope followers,
    /// and limiter gain from the previous camera's audio characteristics.
    func resetAllStates() {
        trimState = TrimState()
        gateState = GateState()
        eqState = EQState()
        compState1 = CompressorState()
        compState2 = CompressorState()
        saturationState = SaturationState()
        stereoState = StereoFieldState()
        limiterState = LimiterState()
    }

    /// Propagates sample rate to all stateful engines. Call from captureQueue.
    func setSampleRate(_ sr: Float) {
        compState1.sampleRate = sr
        compState2.sampleRate = sr
        gateState.sampleRate = sr
        eqState.sampleRate = sr
        eqState.cachedSampleRate = 0  // force EQ coefficient recompute
        stereoState.sampleRate = sr
        limiterState.sampleRate = sr
    }

    /// Returns the peak linear amplitude since last call and resets the stored peak to 0.
    func readPeakAndReset() -> Float {
        peakLock.withLock { peak in
            let v = peak
            peak = 0
            return v
        }
    }

    /// Returns true if clipping (> -1 dBFS) was observed since last call; resets the flag.
    func readClippedAndReset() -> Bool {
        clipLock.withLock { flag in
            let v = flag
            flag = false
            return v
        }
    }

    /// Process audio in-place through the full 8-stage chain.
    /// `left` and `right` must each have `frameCount` samples.
    func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let ap = audioPreset

        // Stage 1: Trim
        TrimEngine.process(
            left: left, right: right, frameCount: frameCount,
            settings: TrimSettings(trimDB: ap.inputTrim),
            state: &trimState
        )

        // Stage 2: Gate
        GateEngine.process(
            left: left, right: right, frameCount: frameCount,
            settings: ap.noiseGate,
            state: &gateState
        )

        // Stage 3: EQ
        EQEngine.process(
            left: left, right: right, frameCount: frameCount,
            settings: ap.eq,
            state: &eqState
        )

        // Stage 4: Compressor 1
        CompressorEngine.process(
            left: left, right: right, frameCount: frameCount,
            settings: ap.compressor,
            model: preset.model,
            state: &compState1
        )

        // Stage 5: Compressor 2
        CompressorEngine.process(
            left: left, right: right, frameCount: frameCount,
            settings: ap.compressor2,
            model: preset.model,
            state: &compState2
        )

        // Stage 6: Saturation
        SaturationEngine.process(
            left: left, right: right, frameCount: frameCount,
            settings: ap.saturation,
            state: &saturationState
        )

        // Stage 7: Stereo Field
        StereoFieldEngine.process(
            left: left, right: right, frameCount: frameCount,
            settings: ap.stereoSpread,
            state: &stereoState
        )

        // Stage 8: Limiter
        LimiterEngine.process(
            left: left, right: right, frameCount: frameCount,
            settings: ap.limiter,
            state: &limiterState
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
        if combinedPeak > 0.891 {
            clipLock.withLock { $0 = true }
        }
    }
}
