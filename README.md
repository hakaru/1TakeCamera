# 1Take Camera

iOS video camera app with professional audio DSP baked in.

## What is 1Take Camera?

A camera app where the audio is the differentiator. While other camera apps focus on video features (4K, HDR, slow-mo), 1Take Camera focuses on making the audio sound professional out of the box — using physical modeling compressors (LA-2A, 1176, VCA) processed in real-time during recording.

The audio track in your MP4 file is already mixed and mastered when the recording stops.

## Status

**In development.** No release yet. Specs and architecture are being finalized.

## Architecture

- iOS 17+, Swift 6.0+
- SwiftUI + SPM package architecture (mirrors [1Take](https://github.com/hakaru/1Take))
- Real-time audio DSP via `OneTakeDSPCore` SPM package (extracted from 1Take)
- AVCaptureSession + AVCaptureVideoDataOutput + AVCaptureAudioDataOutput → DSP → AVAssetWriter pipeline
- MP4 (H.264 + AAC) output

## Roadmap

### v0.0 — PoC (Technical Gate)
30-second recording with one preset. Validates the entire pipeline before any UI work.

### v0.1 — MVP
- Portrait, rear camera, 1080p 30fps
- 4 audio presets (None / Studio LA-2A / Studio+ 1176 / Live VCA)
- Real-time DSP processing
- Interruption handling (calls/Siri)
- Thermal-aware DSP degradation
- Documents folder + Save to Photos button

### v0.2 — Standard Features
- Front/rear toggle, orientation, 4K
- Custom presets
- QuickTime timecode track
- External USB-C audio interfaces

### v0.3 — AI + Sync (Pro)
- AI Settings Optimizer
- [PeerClock](https://github.com/hakaru/PeerClock) integration for multi-device sync
- Master/slave with [1Take](https://github.com/hakaru/1Take)

## Related Projects

- [1Take](https://github.com/hakaru/1Take) — iOS audio recording app, source of the DSP code
- [PeerClock](https://github.com/hakaru/PeerClock) — P2P clock sync library for multi-device coordination

## License

MIT
