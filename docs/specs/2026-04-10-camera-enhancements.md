# Camera Feature Enhancements — Design Document

**Date:** 2026-04-10
**Status:** Approved
**Scope:** 1Take Camera v0.3 Sub-project A
**Target:** Front/rear toggle, orientation support, 4K 30fps

## Overview

Add standard camera features to make 1Take Camera a fully usable video recording tool: front/rear camera switching, multi-orientation support, and 4K resolution option.

## Threading Rule

All `AVCaptureSession` mutations (`beginConfiguration`, `addInput`, `removeInput`, `commitConfiguration`, `startRunning`, `stopRunning`) and all `AudioProcessor` state changes MUST execute on `captureQueue`. UI callbacks dispatch to `captureQueue.async { }` before touching session state. This matches the existing pattern in `switchLens()` and `beginRecording()`.

## 1. Front/Rear Camera Toggle

### Behavior
- Toggle button with `arrow.triangle.2.circlepath` icon, placed in the bottom control strip near the lens selector
- Tapping switches between front (`.builtInWideAngleCamera, position: .front`) and rear (`.builtInWideAngleCamera, position: .back`)
- **Disabled during recording** — same pattern as lens selector and preset selector
- When front camera is active: lens selector is hidden (front camera has a single lens)
- When switching front → rear: restore the previously selected rear lens
- Front camera preview is **mirrored** (standard iOS behavior via `AVCaptureVideoPreviewLayer`). Recorded MP4 is **not mirrored**.

### Implementation
- `CameraSession.switchCamera()` — runs on captureQueue:
  1. `session.beginConfiguration()`
  2. Remove current video input
  3. Discover and add new camera input (front or rear)
  4. `session.commitConfiguration()`
- Store `currentPosition: AVCaptureDevice.Position` (`.back` by default)
- Store `lastRearLensID: String` to restore rear lens preference
- After camera switch completes, call `audioProcessor.resetAllStates()` on `captureQueue` to clear biquad filter states, envelope followers, and limiter gain. This prevents artifacts from the previous camera's audio pipeline.
- `AudioProcessor` needs a new `public func resetAllStates()` that re-initializes all engine state structs.

### Post-switch reconfiguration (critical)

After `session.commitConfiguration()` in `switchCamera()`, the preview layer's connection is reset. The following must be re-applied immediately:

1. **Preview rotation:** Re-read current device orientation → set `previewLayer.connection?.videoRotationAngle` to the correct value
2. **Mirror flag:** Set `videoOutput.connection(with: .video)?.isVideoMirrored = false` (ensures recorded video is never mirrored, regardless of front/rear)
3. **DSP reset:** Call `audioProcessor.resetAllStates()` to clear filter history from the previous camera's audio characteristics
4. **Resolution check:** If current resolution is 4K and new camera doesn't support it, downgrade to HD and notify UI (see section 3)

`videoOutput` must be stored as a `CameraSession` property (`private var videoOutput: AVCaptureVideoDataOutput?`) to enable post-switch access.

### Switch animation
During `switchCamera()` (between `beginConfiguration` and `commitConfiguration` + post-config steps), the viewfinder briefly shows a blur or fade transition. The switch button and all controls are disabled until the operation completes. Expected duration: <200ms.

## 2. Orientation Support

### Supported Orientations
- Portrait
- Landscape Left (home button / USB-C on the right)
- Landscape Right (home button / USB-C on the left)
- Portrait Upside Down is **not supported** (iPhone only)

### Video Rotation Strategy
- Video is always captured in the sensor's native orientation (landscape)
- `AVAssetWriterInput.transform` is set based on the device orientation **at recording start**
- **Orientation locks at recording start** — rotating the device mid-recording does not change the output video orientation. This is standard pro-video behavior.
- The transform values:
  - Portrait: 90° rotation
  - Landscape Right: 0° (natural sensor orientation)
  - Landscape Left: 180° rotation
- `UIDeviceOrientation.faceUp`, `.faceDown`, `.unknown`: ignored. The last known valid orientation is retained. Use `isValidInterfaceOrientation` filter before updating `recordingOrientation`.

**Explicit transform values (radians, CGAffineTransform):**

```swift
func transform(for orientation: UIDeviceOrientation) -> CGAffineTransform {
    switch orientation {
    case .portrait:            return CGAffineTransform(rotationAngle: .pi / 2)
    case .landscapeRight:      return .identity  // home/USB-C on LEFT = sensor native
    case .landscapeLeft:       return CGAffineTransform(rotationAngle: .pi)
    default:                   return CGAffineTransform(rotationAngle: .pi / 2) // fallback to portrait
    }
}
```

**CAUTION:** `UIDeviceOrientation.landscapeLeft` (home button RIGHT) maps to `AVCaptureVideoOrientation.landscapeRight`. The names are inverted between the two enums. Always use `UIDeviceOrientation` as the source of truth and apply the mapping above.

### Preview Rotation
- `AVCaptureConnection.videoRotationAngle` on the preview layer connection is updated on orientation change
- SwiftUI handles UI rotation automatically — bottom control strip stays at the screen bottom

### Implementation
- Observe `UIDevice.orientationDidChangeNotification` (or use SwiftUI's `@Environment(\.deviceOrientation)`)
- Store `recordingOrientation: UIDeviceOrientation` — captured when recording starts, used for `AVAssetWriterInput.transform`
- `MovieWriter.init` takes a `videoOrientation` parameter
- Update `Info.plist` `UISupportedInterfaceOrientations` to include landscape left and right (currently portrait + landscape left/right are already listed)

## 3. 4K 30fps

### Resolution Options
- **HD** (default): 1920×1080, 30fps — `AVCaptureSession.Preset.hd1920x1080`
- **4K**: 3840×2160, 30fps — `AVCaptureSession.Preset.hd4K3840x2160`

### UI
- `HD | 4K` pill toggle in the **top-left** of the viewfinder, next to the preset indicator pill. The top-right is reserved for the PeerClock status indicator.
- Selected option is highlighted (blue, matching preset selector style)
- **Disabled during recording**
- **4K grayed out + disabled** on devices that don't support it (check `AVCaptureDevice.supportsSessionPreset(.hd4K3840x2160)`)

### Implementation
- `CameraSession.setResolution(_ resolution: CaptureResolution)` — reconfigures session preset
- `enum CaptureResolution: String, CaseIterable { case hd, fourK }` with `displayName` ("HD" / "4K") and `sessionPreset`
- Reconfiguration: `session.beginConfiguration()` → change preset → `session.commitConfiguration()`
- Front camera: check 4K support separately (some front cameras don't support 4K)
- `MovieWriter.init` accepts a `videoSize: CGSize` parameter (currently hardcoded to 1920×1080). When 4K is selected, pass `CGSize(width: 3840, height: 2160)`.
- Video bitrate scales with resolution: HD = 10 Mbps, 4K = 25 Mbps. Set via `AVVideoAverageBitRateKey` in `videoSettings`.
- `CaptureResolution` provides both `sessionPreset` and `videoSize` computed properties.

### Resolution fallback on camera switch

When switching cameras, if the new camera does not support the current session preset:
1. `switchCamera()` checks `session.canSetSessionPreset(currentResolution.sessionPreset)` after adding the new input
2. If false, downgrade to `.hd1920x1080`
3. Notify the UI by updating `currentResolution` state (observed by RootView via callback or @Observable)
4. When switching back to rear camera, do NOT auto-restore 4K — let the user re-select manually

### DSP Performance Note
- 4K doubles the video encoding workload but does **not** affect audio DSP performance (audio is processed independently at 48kHz regardless of video resolution)
- No DSP chain changes needed for 4K

## Files to Create/Modify

### Create
- `Views/CameraSwitchButton.swift` — front/rear toggle button
- `Views/ResolutionToggle.swift` — HD/4K pill toggle
- `Models/CaptureResolution.swift` — resolution enum

### Modify
- `Capture/CameraSession.swift` — switchCamera(), setResolution(), orientation tracking, lastRearLensID
  - Store `videoOutput` and `audioOutput` as instance properties (currently local variables in `configureSession()`). Required for `switchCamera()` / `setResolution()` post-configuration.
- `Capture/MovieWriter.swift` — accept videoOrientation parameter, set AVAssetWriterInput.transform
- `RootView.swift` — add CameraSwitchButton, ResolutionToggle, orientation-aware layout
- `Views/LensSelectorView.swift` — hide when front camera active

## Testing Strategy

- **CameraSession**: unit test for `switchCamera()` state transitions (front→rear→front, lens restore)
- **MovieWriter**: verify transform matrix values for each orientation
- **CaptureResolution**: verify sessionPreset mapping
- **Device verification**: record in portrait, landscape left, landscape right → play in QuickTime → correct orientation
- **Device verification**: record in 4K → ffprobe confirms 3840×2160

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Front camera doesn't support 4K | Check `supportsSessionPreset` and disable 4K toggle |
| Orientation change during AVCaptureSession reconfiguration | Lock orientation at recording start, ignore mid-recording changes |
| Front camera mirror confusion | Preview is mirrored (standard), recorded video is not (standard) |
| Lens selector state when switching cameras | Hide for front, restore last selection for rear |

## Out of Scope
- 60fps (any resolution)
- Portrait Upside Down
- Zoom gesture (pinch to zoom)
- External lens attachments
- Recording mid-camera-switch
