# Camera Feature Enhancements — Design Document

**Date:** 2026-04-10
**Status:** Approved
**Scope:** 1Take Camera v0.3 Sub-project A
**Target:** Front/rear toggle, orientation support, 4K 30fps

## Overview

Add standard camera features to make 1Take Camera a fully usable video recording tool: front/rear camera switching, multi-orientation support, and 4K resolution option.

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
- `HD | 4K` pill toggle in the top area of the viewfinder (above the preview, or overlaid at top-right)
- Selected option is highlighted (blue, matching preset selector style)
- **Disabled during recording**
- **4K grayed out + disabled** on devices that don't support it (check `AVCaptureDevice.supportsSessionPreset(.hd4K3840x2160)`)

### Implementation
- `CameraSession.setResolution(_ resolution: CaptureResolution)` — reconfigures session preset
- `enum CaptureResolution: String, CaseIterable { case hd, fourK }` with `displayName` ("HD" / "4K") and `sessionPreset`
- Reconfiguration: `session.beginConfiguration()` → change preset → `session.commitConfiguration()`
- Front camera: check 4K support separately (some front cameras don't support 4K)

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
