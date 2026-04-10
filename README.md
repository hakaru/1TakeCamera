# 1Take Camera

iOS video camera app with professional audio DSP baked in.

## What is 1Take Camera?

A camera app where the audio is the differentiator. While other camera apps focus on video features (4K, HDR, slow-mo), 1Take Camera focuses on making the audio sound professional out of the box — using physical modeling compressors (LA-2A, 1176, VCA) processed in real-time during recording.

The audio track in your MP4 file is already mixed and mastered when the recording stops.

## Status

**v0.3.1 — Phase C interop complete** (not yet on TestFlight). Full 8-stage DSP chain, 4K/HD recording, front/rear camera, orientation support, external mic support, QuickTime metadata timecode, and Phase C multi-device interop with [1Take v1.7.0](https://github.com/hakaru/1Take). See [CHANGELOG.md](CHANGELOG.md) for full history.

## Architecture

- iOS 17+, Swift 6.0+
- SwiftUI + SPM package architecture (mirrors [1Take](https://github.com/hakaru/1Take))
- Real-time audio DSP via `OneTakeDSPCore` SPM package (extracted from 1Take)
- AVCaptureSession + AVCaptureVideoDataOutput + AVCaptureAudioDataOutput → DSP → AVAssetWriter pipeline
- MOV (H.264 + AAC + QuickTime metadata timecode) output

## Roadmap

### v0.0 — PoC (Technical Gate) ✅
30-second recording with one preset. Validates the entire pipeline before any UI work.

### v0.1 — MVP ✅
- Portrait, rear camera, 1080p 30fps
- 4 audio presets (None / Studio LA-2A / Studio+ 1176 / Live VCA)
- Real-time DSP processing (compressor only)
- Manual start/stop recording, recording list

### v0.2 — Full Effect Chain + Standard Features ✅
- Full OneTakeDSPCore chain: Trim / NoiseGate / EQ / Compressor1 / Compressor2 / Saturation / M/S / Limiter
- Front/rear toggle, orientation support (portrait + landscape), 4K 30fps option
- External USB-C audio interfaces with route-change handling
- QuickTime metadata timecode track (ISO8601, FCP/Resolve compatible)

### v0.3 — Phase C Interop ✅
- [PeerClock](https://github.com/hakaru/PeerClock) v0.2.0 integration for multi-device sync
- Unified DeviceStatus schema with [1Take v1.7.0](https://github.com/hakaru/1Take)
- Slave mode: receive Start/Stop from 1Take master controller
- 5-second heartbeat, finalizing state broadcast on remote stop

### v0.4 — AI + TestFlight (planned)
- AI Settings Optimizer
- Progressive thermal degradation (disable heavy stages on `.serious`+)
- Custom preset save/load
- TestFlight public beta

## Related Projects

- [1Take](https://github.com/hakaru/1Take) — iOS audio recording app, source of the DSP code
- [PeerClock](https://github.com/hakaru/PeerClock) — P2P clock sync library for multi-device coordination

## License

MIT
