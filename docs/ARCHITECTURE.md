# 1Take Camera Architecture

## Overview

1Take Camera is a SwiftUI iOS app built around a custom AVCaptureSession → AVAssetWriter pipeline that injects real-time audio DSP between capture and encoding. The app is a thin shell that hosts a Swift Package (`OneTakeCameraPackage`) containing all features.

## Project structure

```
1TakeCamera/
├── OneTakeCamera.xcodeproj/          # App target shell
├── OneTakeCamera/                    # @main entry + Assets
│   ├── OneTakeCameraApp.swift
│   ├── ContentView.swift              # hosts CameraFeature.RootView()
│   └── Assets.xcassets/AppIcon.appiconset/
└── OneTakeCameraPackage/              # SPM package with all feature code
    ├── Package.swift                  # local path dep on ../1Take/OneTakePackage
    └── Sources/CameraFeature/
        ├── Capture/
        │   ├── CameraSession.swift    # AVCaptureSession orchestrator
        │   ├── MovieWriter.swift      # AVAssetWriter + PTS book-keeping
        │   ├── InterruptionHandler.swift
        │   └── ThermalMonitor.swift
        ├── Audio/
        │   ├── SampleBufferConverter.swift  # CMSampleBuffer ↔ 48 kHz Float32
        │   ├── AudioProcessor.swift   # CompressorEngine + peak / clip tracking
        │   └── LevelMonitor.swift     # @Observable peak DB poller
        ├── Views/
        │   ├── ViewfinderView.swift   # UIViewRepresentable + AVCaptureVideoPreviewLayer
        │   ├── LensSelectorView.swift
        │   ├── PresetSelectorView.swift
        │   ├── LevelMeterView.swift
        │   ├── ClipWarningOverlay.swift
        │   └── RecordingListView.swift
        ├── Models/
        │   ├── CompressorPreset.swift
        │   ├── CaptureMetrics.swift
        │   └── RecordingFile.swift
        └── RootView.swift
```

## Dependencies

- **OneTakeDSPCore** (from `../1Take/OneTakePackage`): `CompressorEngine`, `CompressorState`
- **OneTakeDSPPresets** (from `../1Take/OneTakePackage`): `CompressorSettings`, `AudioPresetType`
- Apple frameworks: AVFoundation, SwiftUI, Photos, QuickLook, Observation, os.Logger

## Capture pipeline

```
AVCaptureSession
├── Video: AVCaptureVideoDataOutput → CameraSession delegate (captureQueue)
│                                          ↓
│                                     MovieWriter.appendVideo(sampleBuffer)
│                                          ↓
│                                     AVAssetWriterInput (H.264)
│
└── Audio: AVCaptureAudioDataOutput → CameraSession delegate (captureQueue)
                                           ↓
                                      SampleBufferConverter → 48 kHz Float32 stereo
                                           ↓
                                      AudioProcessor.process(...) — CompressorEngine
                                           ↓
                                      SampleBufferConverter → CMSampleBuffer (PTS preserved)
                                           ↓
                                      MovieWriter.appendAudio(sampleBuffer)
                                           ↓
                                      AVAssetWriterInput (AAC)
```

All capture delegate callbacks run on a single serial `captureQueue` (`net.hakaru.OneTakeCamera.capture`, QoS `.userInteractive`) to prevent races.

## Timing rules

- **PTS authority is the capture clock.** Never use wall-clock time.
- `MovieWriter.startSession(atSourceTime:)` uses `min(firstVideoPTS, firstAudioPTS)` (the earlier of the two first-delivered buffers). No buffers are dropped.
- Duration of re-wrapped audio CMSampleBuffers is computed from the **post-conversion frame count** at 48 kHz, never from the original capture sample rate.
- On `stopRecording()`: wait 200 ms wall clock before `session.stopRunning()` to let the mic pipeline flush its tail buffers, then drain the capture queue, then call `MovieWriter.finalize()`.
- `SampleBufferConverter` bypasses `AVAudioConverter` when the capture format already matches the internal format (48 kHz Float32 non-interleaved stereo), avoiding priming / tail losses.

## State machine

```
           ┌────────┐
           │  idle  │◄──────────────┐
           └───┬────┘               │
               │ user taps record   │
               ▼                    │
          ┌──────────┐              │
          │ recording│              │
          └────┬─────┘              │
               │ user taps stop /   │
               │ interruption       │
               ▼                    │
          ┌──────────┐              │
          │finalizing│              │
          └────┬─────┘              │
               │ AVAssetWriter      │
               │ finishWriting      │
               ▼                    │
          ┌──────────┐              │
          │   done   ├──────────────┘
          │  (url)   │  auto after display
          └──────────┘
```

The session stays running for viewfinder preview throughout the `done → idle` transition, so recording N+1 can begin instantly.

## Concurrency model

- `RootView` is `@MainActor` (SwiftUI).
- `CameraSession` is `@unchecked Sendable`; all mutable state is touched only from `captureQueue`.
- `MovieWriter`, `SampleBufferConverter`, `AudioProcessor`, `CaptureMetrics` are each accessed only from `captureQueue`.
- Notification observers (`InterruptionHandler`, `ThermalMonitor`) dispatch back to `captureQueue` for state checks and to a new `Task { await session.finalize() }` for async finalize.
- `AudioProcessor` uses `OSAllocatedUnfairLock<Float>` and `OSAllocatedUnfairLock<Bool>` for peak / clip flags read from the main thread via `LevelMonitor` polling (~30 Hz).

## File output

Recordings land in the app's Documents folder as `1TakeCam-YYYYMMDD-HHmmss.mp4`. Each file has a sidecar `.json` with capture diagnostics (remove before public release).

MP4 metadata: `commonIdentifierSoftware` tag set to `"1Take Camera (<preset name>)"`, e.g. `"1Take Camera (Studio+)"`.

## Known limitations (v0.1)

- Compressor is the only DSP stage. Other stages (noise gate, EQ, saturation, M/S, limiter) live inside 1Take's `OneTakeDSPEngine` and require further extraction before they can be reused here.
- Portrait-only orientation, rear camera only, 1080p 30fps fixed.
- No custom preset save/load.
- Sidecar JSON is always written (intended as diagnostic only — to be toggled off before public release).
- Final A/V drift is ~22 ms (audio slightly longer than video). Within the 40 ms lip-sync perception threshold.
