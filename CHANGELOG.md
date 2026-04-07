# Changelog

All notable changes to 1Take Camera will be documented in this file.

## [0.1.1] - 2026-04-07 (unreleased)

Post-MVP polish.

### Added
- **Manual start/stop recording** — no more 30-second fixed length; tap the record button to start, tap again to stop. Elapsed time counter (`MM:SS`) shown in a red badge during recording.
- **Standard iOS-camera UI layout** — full-bleed viewfinder, bottom control strip with gradient scrim, large centered shutter button (white ring + red fill / red rounded-square), recording list button on the right, preset indicator pill top-left.
- **Lens selector** — ultra-wide / wide / telephoto pills. Detects available cameras via `AVCaptureDevice.DiscoverySession` and switches `AVCaptureSession` input on tap. Disabled during recording.
- **1Take-style app icon** — dark background, "1Take" + red "CAM" badge, camera lens iris motif, red record dot.

## [0.1.0] - 2026-04-07

First MVP. Full recording loop with real-time audio DSP on iPhone.

### Added
- **Real-time LA-2A / 1176 / VCA compressor** on the audio track during video recording, via the shared `OneTakeDSPCore` SPM package extracted from [1Take v1.6.0](https://github.com/hakaru/1Take).
- **Full-screen viewfinder** with rear camera 1080p 30fps preview, immediately on launch (session prewarm).
- **4 compressor character presets** selectable via bottom pill bar:
  - `None` — bypass
  - `Studio` — LA-2A (opto)
  - `Studio+` — 1176 (FET)
  - `Live` — VCA
- **Post-DSP level meter** (horizontal bar, green/yellow/red grading).
- **Clip warning overlay** — animated red screen-edge border when post-DSP peak exceeds -1 dBFS.
- **Recording list** sheet with playback (Quick Look), swipe-to-delete, and Save-to-Photos per item. Photo library permission is only requested when the user taps Save.
- **Interruption handling** — phone calls, Siri, and route changes gracefully finalize the current MP4.
- **Thermal state monitoring** — logged via `os.Logger` (no progressive degradation yet since the chain is compressor-only).
- **MP4 metadata** — active preset embedded via `commonIdentifierSoftware` (e.g. `"1Take Camera (Studio+)"`).
- **Sidecar JSON log** per recording — capture PTS book-keeping for diagnosis (remove before public release).
- **Display name** "1Take Camera" on the Home Screen.

### A/V sync fixes
During PoC testing a ~60 ms audio-shorter-than-video drift was observed. Fixed by:
- Using `min(firstVideoPTS, firstAudioPTS)` as the asset writer session start time instead of dropping early buffers.
- Not dropping any capture buffers — both tracks record their natural duration, preserving lip-sync.
- Adding a 200 ms wall-clock pause before `stopRunning()` to flush mic pipeline tail buffers.
- Draining the capture queue before calling `MovieWriter.finalize()`.
- Recomputing output CMSampleBuffer duration from the post-conversion frame count at 48 kHz.
- Bypassing `AVAudioConverter` when the capture format already matches the internal format (48 kHz Float32 non-interleaved).

Final observed drift: ~22 ms (audio slightly longer than video), well under the lip-sync perception threshold.

### Architecture
- iOS 17+, Swift 6.1, strict concurrency
- SwiftUI + SPM package (`OneTakeCameraPackage`) mirroring 1Take's structure
- Shared audio DSP via local SPM path to `/Volumes/Dev/DEVELOP/1Take/OneTakePackage` (`OneTakeDSPCore` + `OneTakeDSPPresets`)
- Capture pipeline: `AVCaptureSession` → `AVCaptureVideoDataOutput` / `AVCaptureAudioDataOutput` → `SampleBufferConverter` (CMSampleBuffer ↔ 48 kHz Float32 stereo) → `AudioProcessor` (`CompressorEngine`) → `AVAssetWriter` (H.264 + AAC)
- Reference counting not needed — single-consumer audio pipeline.

### Known limitations (deferred to v0.2)
- Only the compressor stage is applied. NoiseGate / EQ / Saturation / M/S / Limiter are not yet extracted from 1Take's `OneTakeDSPEngine` into pure DSP form.
- Locked portrait orientation, rear camera only, 1080p 30fps fixed.
- No front camera, no 4K, no external mic support.
- No custom preset save/load.
- No QuickTime / BWF timecode.
- No multi-device sync (PeerClock integration deferred to v0.3).
- ~22 ms A/V drift remains in the "audio-longer" direction. Acceptable for v0.1.
