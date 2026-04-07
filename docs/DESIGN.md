# 1Take Camera — Design Document

**Date:** 2026-04-07
**Status:** Approved (revised after Codex + Gemini review)
**Project:** New iOS app, separate repository from 1Take

## Overview

1Take Camera is an iOS video recording app that bakes 1Take's audio DSP (LA-2A/1176 physical modeling compressors, AI optimization) directly into video recording. The audio track is processed in real-time during capture and embedded into the resulting MP4 file.

The vision: **"A camera app where the audio is the differentiator."** Other camera apps focus on video features (4K, HDR, slow-mo). 1Take Camera focuses on making the audio sound professional out of the box.

## Vision Alignment

1Take Camera is the second pillar of the v2.0 vision. The three pillars are:

1. **PeerClock** (independent OSS) — P2P clock sync library for Apple devices
2. **1Take Camera** (this project) — Video recording with 1Take audio processing
3. **1Take v2.0** — Multi-device capture coordinator

All three depend on shared SPM packages: `OneTakeDSPCore` (extracted from 1Take, pure DSP, UI-free) and `PeerClock`.

## Goals

- Real-time audio processing during video capture (not post-processing)
- Reuse 1Take's DSP without code duplication via shared SPM package
- Validate the technical approach via a PoC before building app UI
- Establish foundation for future multi-device sync via PeerClock

## Non-Goals

- Replacing professional video editing apps
- Competing on raw video features (4K HDR, slow-mo, ProRes are not v0.1 priorities)
- Cloud sync (recordings stay on device until manually exported in v0.x)
- Live streaming
- Background recording (camera capture cannot continue in background regardless)
- Front camera, orientation handling, external mic support in v0.1

## Project Structure

| Item | Value |
|------|-------|
| Repository | `1TakeCamera` (new, separate) |
| Bundle ID | `net.hakaru.onetakecamera` |
| Platform | iOS 17+ |
| Language | Swift 6.0+ |
| Architecture | SwiftUI + SPM package (mirroring 1Take's structure) |
| Shared dependency | `OneTakeDSPCore` (pure DSP, no UI/Localization) |
| Future dependency | [`PeerClock`](https://github.com/hakaru/PeerClock) (in development, used in v0.3 for multi-device sync) |

```
1TakeCamera/
├── 1TakeCamera.xcodeproj
├── 1TakeCamera/                    # App target (thin shell)
│   ├── 1TakeCameraApp.swift
│   └── Resources/
└── 1TakeCameraPackage/             # SPM package (all features)
    ├── Package.swift
    ├── Sources/CameraFeature/
    │   ├── Capture/
    │   │   ├── CameraSession.swift     # AVCaptureSession lifecycle
    │   │   ├── VideoOutput.swift       # AVCaptureVideoDataOutput
    │   │   ├── AudioOutput.swift       # AVCaptureAudioDataOutput
    │   │   ├── MovieWriter.swift       # AVAssetWriter coordinator
    │   │   ├── InterruptionHandler.swift  # Phone calls / Siri / route changes
    │   │   └── ThermalMonitor.swift    # ProcessInfo.thermalState observer
    │   ├── Audio/
    │   │   ├── AudioProcessor.swift    # Bridges OneTakeDSPCore into capture pipeline
    │   │   └── SampleBufferConverter.swift  # CMSampleBuffer ↔ Float32 buffers
    │   ├── Views/
    │   │   ├── ViewfinderView.swift
    │   │   ├── RecordButton.swift
    │   │   ├── LevelMeter.swift
    │   │   ├── ClipWarningOverlay.swift
    │   │   └── PresetSelector.swift
    │   └── Models/
    │       ├── RecordingSession.swift
    │       └── CaptureMetrics.swift    # Drop counts, backpressure events, route changes
    └── Tests/CameraFeatureTests/
```

## OneTakeDSP Extraction (Prerequisite)

Before 1Take Camera development can start, the audio DSP must be extracted from 1Take into a reusable SPM package. The extraction is **the most error-prone prerequisite** and must address several issues identified by review:

### Issues with naive extraction

- `AudioPreset.swift` currently imports SwiftUI and Localization symbols → not pure DSP
- `AudioEffectsProcessor.swift` is built around `AVAudioEngine` and `AVAudioUnit` types → cannot be reused in a capture pipeline that doesn't run AVAudioEngine
- 1Take's current package uses `platforms: [.iOS(.v18)]` → blocks iOS 17 target

### Extraction plan

1. **Lower 1Take's deployment target to iOS 17** in v1.6.0 (compatibility-only refactor, no user-facing changes)
2. **Create three new SPM products** in the 1Take package (or split into a separate repository — see Repository Strategy below):
   - **`OneTakeDSPCore`** — Pure Swift/Accelerate/CoreAudio DSP types. No SwiftUI, no Localization, no AVAudioEngine. Operates on `Float32` buffers (`UnsafeMutableBufferPointer<Float>` or arrays). This is what 1Take Camera depends on.
   - **`OneTakeDSPPresets`** — Preset value definitions, UI-free
   - **`OneTakeDSPEngine`** — Existing `AudioEffectsProcessor` (AVAudioEngine wrapper). 1Take continues to use this. 1Take Camera does NOT.
3. **Re-architect DSP API to be buffer-format-agnostic**: instead of accepting `AVAudioPCMBuffer`, accept `Float32` arrays + sample rate + channel count. This allows both 1Take (via AVAudioEngine wrapper) and 1Take Camera (via CMSampleBuffer conversion) to use the same core.
4. **Single semver scheme** across the entire shared package (no separate `dsp-v1.0.0` tag)
5. **Use local SPM path during early development**, switch to Git URL once API stabilizes

### Repository Strategy Decision

Two options for where `OneTakeDSPCore` lives:

- **Option A:** Stay inside `1Take` repository as a separate product
- **Option B:** Extract to dedicated `OneTakeDSP` repository

**Decision:** Start with Option A (faster iteration, single repo to manage). Migrate to Option B if the package proves stable and we want strict version isolation. The decision to migrate is non-blocking and can happen any time before 1Take Camera v1.0.

## Phased Roadmap

### v0.0 — PoC (Technical Gate)

**Goal:** Prove the technical approach end-to-end before building any app UI. This is a throwaway harness.

**Scope:**
- No app UI. Single button: "Record 30 seconds"
- AVCaptureSession with rear camera 1080p 30fps + built-in mic
- AVCaptureVideoDataOutput + AVCaptureAudioDataOutput → AVAssetWriter
- One audio preset hardcoded (Studio / LA-2A)
- DSP processing inserted between AVCaptureAudioDataOutput callback and AVAssetWriterInput
- Output MP4 saved to app Documents folder
- Console logging of: dropped video frames, dropped audio buffers, writer backpressure events, audio buffer timestamp delta vs expected

**Success criteria:**
- Recording completes without crashes
- Playback in QuickTime: audio aligned with video, no drift over 30 seconds
- Audible difference from system Camera (compression on the audio is noticeable)
- Diagnostic counters all zero or within acceptable thresholds

**This PoC is the technical gate for the entire project.** If audio sync drifts or DSP processing causes capture buffer drops, the whole approach needs to change. v0.1 cannot start until v0.0 passes.

### v0.1 — MVP (First Public Release)

**Goal:** Ship a minimal but complete app to TestFlight users.

**Features:**
- Portrait orientation, rear camera only
- 1080p 30fps fixed
- 4 audio presets: None, Studio (LA-2A), Studio+ (1176), Live (VCA)
- Real-time audio processing via OneTakeDSPCore
- MP4 output (H.264 + AAC) saved to **app Documents folder** (NOT directly to Photos)
- "Save to Photos" button on the recordings list (separates capture from photo library permission)
- Full-screen viewfinder + bottom UI strip
- Real-time level meter (post-DSP)
- **Clip warning overlay** — screen edges flash red when audio clips
- AVCaptureSession interruption handling (phone calls, Siri, route changes) — pause and finalize file
- Thermal state monitoring — disable Saturation/M/S stages on `.serious`+ thermal state
- MP4 metadata: active preset name embedded in User Data Atom (debugging)

**Constraints:**
- **Built-in microphone only** (no Bluetooth, AirPods, USB audio)
- **Stereo output fixed** (DSP M/S processing requires stereo)
- **No AVAudioEngine** in the recording path
- **Capture-derived `CMSampleBuffer` timestamps and sample counts must not be modified** by DSP (preserve PTS)
- **Single PCM format internally** (e.g., 48kHz Float32 stereo). Format conversion happens at one boundary only (CMSampleBuffer → Float32 array → DSP → Float32 array → CMSampleBuffer)
- **`automaticallyConfiguresApplicationAudioSession`** decision: **set to `false`** and manage AVAudioSession explicitly to ensure mic routing is consistent

**Out of scope:**
- Front camera
- Orientation handling (locked portrait)
- 4K
- AI optimization
- Multi-device sync
- Custom presets
- BWF/QuickTime timecode

### v0.2 — Standard Camera Features

- Front/rear camera toggle
- Orientation support (portrait + landscape)
- 4K 30fps option
- Custom preset save/load
- **QuickTime timecode track** embedded in video file (NOT BWF — BWF is a WAV-only format)
- External microphone support (USB-C audio interfaces, validated with route change handling)

### v0.3 — AI + Sync (Pro Features)

- AI Settings Optimizer (post-recording analysis, suggestions for next session)
- PeerClock integration for multi-device sync
- Master/slave mode: 1Take Camera can be controlled by 1Take v2.0, or vice versa
- QuickTime timecode aligns with audio recordings from 1Take devices for DAW integration

## Audio Processing Pipeline

```
[Microphone (built-in)]
    ↓
AVCaptureAudioDataOutput delegate (high-priority serial queue)
    ↓ CMSampleBuffer (PCM, capture format)
SampleBufferConverter
    ├── Read LPCM samples directly from CMSampleBuffer
    ├── Preserve CMSampleTimingInfo (PTS, duration, sample count)
    ├── Normalize to internal format (48kHz Float32 stereo) — once only
    └── Hand off Float32 buffer to AudioProcessor
    ↓
AudioProcessor (uses OneTakeDSPCore)
    ├── NoiseGate
    ├── EQ
    ├── Compressor 1 (Transparent)
    ├── Compressor 2 (LA-2A / 1176 / VCA)
    ├── Saturation (skipped under thermal pressure)
    ├── M/S Processing (skipped under thermal pressure)
    └── Maximizer
    ↓ Float32 buffer (same sample count)
SampleBufferConverter
    ├── Reconstruct CMSampleBuffer with original PTS, duration, sample count
    └── New CMAudioFormatDescription (still in internal format)
    ↓
AVAssetWriterInput (Audio, AAC)
    ↓
[MP4 file: H.264 video + processed AAC audio]
```

### Timing rules (non-negotiable)

1. **Source-clock authority**: capture-side `CMSampleBuffer` timestamps are the source of truth. Never use wall clock.
2. **PTS preservation**: DSP must not modify sample counts or timestamps. If algorithmic latency is intentionally added, document and compensate explicitly.
3. **Clock sync**: use `AVCaptureSession.synchronizationClock` to ensure video and audio capture share a common time base.
4. **Single format conversion**: capture format → internal format (48kHz Float32 stereo) happens once. AAC encoding happens once at the writer boundary.
5. **No AVAudioEngine** in the recording path.
6. **Bounded audio queue**: if `AVAssetWriterInput.readyForMoreMediaData == false`, drop audio buffers from a bounded queue rather than accumulating unbounded memory.

### Failure modes and responses

| Condition | Detection | Response |
|-----------|-----------|----------|
| Phone call / Siri | `AVCaptureSessionWasInterrupted` notification | Pause capture, finalize MP4, show user message |
| Audio route change | `AVAudioSession.routeChangeNotification` | If new route is incompatible, finalize and stop |
| Thermal state ≥ `.serious` | `ProcessInfo.thermalStateDidChangeNotification` | Disable Saturation, M/S, then Compressor 2 if needed |
| Writer backpressure | `readyForMoreMediaData == false` for >100ms | Drop oldest audio buffer in bounded queue, log event |
| Capture buffer drop | `AVCaptureVideoDataOutput` delegate dropped frame | Increment counter, continue |

## UI Design

**Layout:**

```
┌─────────────────────────────┐
│                             │
│                             │
│     Viewfinder              │
│     (full screen)           │
│                             │
│                  ⚠         │  ← Clip warning (peripheral)
│                             │
│                             │
├─────────────────────────────┤
│  ▓▓▓▓▓░░░  Level Meter      │
│  [None][Studio][S+][Live]   │
│              ⬤              │
└─────────────────────────────┘
```

**Components:**

- Viewfinder fills the screen behind a translucent bottom strip
- **Level meter**: real-time post-DSP audio level
- **Clip warning overlay**: screen-edge flash visible in peripheral vision when post-DSP audio peaks > -1 dB (animated red border, fades after 200ms)
- **Preset selector**: 4 pills (1Take's design language: dark with blue accent)
- **Center red record button**: matches 1Take

**Brand consistency:** Same color palette and visual language as 1Take, adapted for camera-app use (viewfinder priority).

## Permissions

| Permission | When requested | Why |
|------------|---------------|-----|
| `NSCameraUsageDescription` | First record tap | Required to start AVCaptureSession |
| `NSMicrophoneUsageDescription` | First record tap | Required to capture audio |
| `NSPhotoLibraryAddUsageDescription` | First "Save to Photos" tap | Separated from capture so a successful recording isn't lost to a permission denial |

**Rationale:** Capturing and saving to Photos are separate actions. Asking for Photos access at recording time creates the worst possible UX: user records a great take, then loses it because they tapped "Don't Allow."

## Monetization

**Free tier:**
- 1080p recording
- All 4 audio presets (None/Studio/Studio+/Live)
- Standard camera operation
- No watermark, no time limit

**Pro tier ($4.99 one-time):**
- 4K 30fps recording
- Custom preset creation and editing
- AI Settings Optimizer
- Multi-device sync via PeerClock
- QuickTime timecode embedding

**Rationale:** Mirror 1Take's monetization model. Free users get a fully usable camera app — paying gets pro features. No subscription. No ads. No watermarks on free tier.

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| AVCaptureSession + DSP integration unknowns | Could block project | **v0.0 PoC is the technical gate**. Validate end-to-end before any app UI work |
| Audio drift due to PTS mishandling | Lip-sync broken | Hard rule: never modify capture timestamps. PoC validates over 30-second recording |
| DSP processing overruns audio capture queue | Audio glitches | Profile on iPhone 12 (oldest supported); thermal-state-driven graceful degradation |
| OneTakeDSP extraction breaks 1Take | Regression for shipped users | Keep 1Take v1.5.0 untouched; do extraction in v1.6.0 with full test coverage; iOS 17 target lowering is the only user-visible change |
| Photos library permission UX | Friction at first launch | Separate capture from save-to-Photos — different actions, different permission timing |
| File size for long recordings | Storage exhaustion | Documents folder has same quota as Photos; rely on system storage warnings |
| Background interruption mid-recording | Lost recording | InterruptionHandler finalizes the file before suspension |
| Thermal throttling during long recording | Recording fails | ThermalMonitor disables expensive DSP stages progressively |
| Mic route change mid-recording | Capture format mismatch | Detect route change, finalize current take, do not auto-restart |

## Dependencies on Other Projects

- **1Take v1.6.0** must ship with `OneTakeDSPCore` SPM product before 1Take Camera development starts. This is a refactoring release with no user-facing features.
- **PeerClock** ([github.com/hakaru/PeerClock](https://github.com/hakaru/PeerClock)) is currently in development. v0.1+ must exist before 1Take Camera v0.3 sync features can be implemented
- 1Take Camera v0.0 (PoC) only needs OneTakeDSPCore, not PeerClock

## Success Criteria

**v0.0 (PoC):**
- 30-second recording completes without crashes
- Audio aligned with video on QuickTime playback (no perceptible drift)
- Diagnostic counters within acceptable thresholds (zero drops in normal conditions)
- Audible difference from system Camera

**v0.1 (MVP):**
- All v0.0 criteria, plus:
- 10-minute continuous recording on iPhone 12 without thermal failure
- Phone call interruption finalizes file gracefully
- All 4 presets functional
- Drop counters / backpressure logged but not user-visible

**v0.2:**
- Standard camera operations (orientation, camera switching, 4K) work without breaking the audio pipeline
- External USB-C audio interfaces work with proper route change handling

**v0.3:**
- Two devices (1Take Camera + 1Take, or two 1Take Cameras) record synchronized takes that align in a DAW within ±5ms after PeerClock + QuickTime timecode placement

## Open Questions

None. All major scope and architectural decisions are settled. Implementation can begin with the OneTakeDSPCore extraction in 1Take v1.6.0, followed by the v0.0 PoC harness.

## References

- [1Take v2.0 Vision](../../../memory/project_v2_vision.md) (in user's memory store)
- [PeerClock](https://github.com/hakaru/PeerClock)
- [1Take Repository](https://github.com/hakaru/1Take)
- Apple TN2445 — AVCaptureVideoDataOutput frame drops
- AVCaptureSession synchronization clock documentation
