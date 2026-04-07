# 1Take Camera

iOS video camera app with professional audio DSP baked in.

## What is 1Take Camera?

A camera app where the audio is the differentiator. While other camera apps focus on video features (4K, HDR, slow-mo), 1Take Camera focuses on making the audio sound professional out of the box — using physical modeling compressors (LA-2A, 1176, VCA) processed in real-time during recording.

The audio track in your MP4 file is already mixed and mastered when the recording stops.

## Status

**v0.1.0 built and running on device** (not yet on TestFlight). Manual start/stop recording, lens switching, 4 compressor character presets, level metering, clip warning, recording list with Save-to-Photos. See [CHANGELOG.md](CHANGELOG.md) for full history.

## Architecture

- iOS 17+, Swift 6.0+
- SwiftUI + SPM package architecture (mirrors [1Take](https://github.com/hakaru/1Take))
- Real-time audio DSP via `OneTakeDSPCore` SPM package (extracted from 1Take)
- AVCaptureSession + AVCaptureVideoDataOutput + AVCaptureAudioDataOutput → DSP → AVAssetWriter pipeline
- MP4 (H.264 + AAC) output

## Roadmap

### v0.0 — PoC (Technical Gate)
30-second recording with one preset. Validates the entire pipeline before any UI work.

### v0.1 — MVP ✅ built
- Portrait, rear camera, 1080p 30fps
- 4 audio presets (None / Studio LA-2A / Studio+ 1176 / Live VCA)
- Real-time DSP processing (compressor only — other stages in v0.2)
- Manual start/stop recording, no length limit
- Ultra-wide / wide / telephoto lens switching
- Full-screen viewfinder, iOS-camera-style bottom control strip
- Post-DSP level meter + clip warning overlay
- Recording list with Quick Look playback, swipe-to-delete, Save to Photos
- Interruption handling (calls / Siri / route change)
- Thermal state monitoring (log-only for v0.1)
- A/V sync: ~22 ms (within lip-sync perception threshold)
- 1Take-style app icon

### v0.2 — Full Effect Chain + Standard Features
- Full OneTakeDSPCore chain: NoiseGate / EQ / Compressor1 / Compressor2 / Saturation / M/S / Limiter (requires further extraction in 1Take v1.7.0)
- Front/rear toggle, orientation support, 4K 30fps option
- Custom preset save/load
- QuickTime timecode track
- External USB-C audio interfaces with route-change handling
- Progressive thermal degradation (disable heavy stages on `.serious`+)
- TestFlight public beta

### v0.3 — AI + Sync (Pro)
- AI Settings Optimizer
- [PeerClock](https://github.com/hakaru/PeerClock) integration for multi-device sync
- Master/slave with [1Take](https://github.com/hakaru/1Take)

## Related Projects

- [1Take](https://github.com/hakaru/1Take) — iOS audio recording app, source of the DSP code
- [PeerClock](https://github.com/hakaru/PeerClock) — P2P clock sync library for multi-device coordination

## License

MIT
