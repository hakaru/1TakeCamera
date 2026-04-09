# Audio Enhancements — Design Document

**Date:** 2026-04-10
**Status:** Approved
**Scope:** 1Take Camera v0.3 Sub-project B
**Target:** External mic support (USB-C + Lightning) + QuickTime Timecode track

## Overview

Add professional audio input support (USB-C and Lightning-connected microphones) and embed QuickTime Timecode tracks in recorded MP4 files for DAW timeline synchronization.

## 1. External Microphone Support

### Supported Input Types

| Port Type | Example Devices | Detection |
|---|---|---|
| `.usbAudio` | Focusrite Scarlett, RØDE AI-1, USB-C mics | USB-C direct or Lightning→USB camera adapter |
| `.headsetMic` | Shure MV88, RØDE VideoMic ME-L | Lightning direct-connect microphones |
| `.builtInMic` | iPhone internal mic | Default fallback |

**Not supported:** Bluetooth audio (`.bluetoothHFP`, `.bluetoothA2DP`) — latency is incompatible with real-time DSP processing.

### Detection & Display

- Monitor `AVAudioSession.routeChangeNotification` (already handled by `InterruptionHandler`)
- Read `AVAudioSession.sharedInstance().currentRoute.inputs` for active input source
- Display current input name in the UI: small text label below the preset indicator pill (top-left), e.g. `"Scarlett 2i2"` or `"Built-in Mic"`
- `portName` from `AVAudioSessionPortDescription` provides a human-readable device name

### Format Handling

- External interfaces may deliver 44.1kHz / 48kHz / 96kHz, mono / stereo
- `AVAudioSession.setPreferredSampleRate(48000)` is maintained — external devices may or may not honor this
- `SampleBufferConverter` already handles format differences:
  - If capture format matches internal format (48kHz Float32 stereo): bypass AVAudioConverter
  - Otherwise: AVAudioConverter performs sample rate + channel conversion
- No changes needed to SampleBufferConverter

### Route Change Behavior

| Event | During Recording? | Action |
|---|---|---|
| External mic plugged in | No | Auto-switch to new route (AVAudioSession default). Update UI label. |
| External mic plugged in | Yes | Ignore. Continue recording with current route. |
| External mic unplugged | No | Fall back to built-in mic. Update UI label. |
| External mic unplugged | Yes | **Finalize recording** (existing InterruptionHandler behavior on `oldDeviceUnavailable`). |

### Implementation

**Files to create:**
- `Views/AudioInputLabel.swift` — small text label showing current mic name

**Files to modify:**
- `Capture/CameraSession.swift` — add `currentAudioInputName: String` property, update on route change
- `Capture/InterruptionHandler.swift` — extend to detect `.newDeviceAvailable` (non-recording) for UI update callback
- `RootView.swift` — display `AudioInputLabel` in top-left area

**No changes to:**
- `SampleBufferConverter.swift` — already handles format variations
- `AudioProcessor.swift` — DSP chain is format-agnostic (operates on 48kHz Float32 regardless of source)
- `MovieWriter.swift` — audio input settings are independent of mic source

### Testing

- Plug/unplug USB-C audio interface during idle → verify UI label updates
- Plug/unplug during recording → verify finalize on unplug, ignore on plug
- Record with external mic → verify audio quality in MP4 (correct sample rate, no artifacts)
- Record with built-in mic after external was unplugged → verify fallback works

## 2. QuickTime Timecode Track

### Purpose

Embed an absolute timecode track in MP4 files so that recordings from multiple devices can be automatically aligned in DAWs (Final Cut Pro, DaVinci Resolve, Logic Pro) without manual waveform matching.

### Timecode Specification

| Parameter | Value |
|---|---|
| Format | `kCMTimeCodeFormatType_TimeCode32` |
| Frame rate | 30fps (matching video) |
| TC source | PeerClock `clock.now` (synced nanoseconds) → wall clock → HH:MM:SS:FF |
| Fallback | If PeerClock has 0 peers (no sync): `Date()` (device local wall clock) |
| Drop frame | Non-drop (30fps exact, not 29.97) |

### How It Works

1. **At recording start:** read `PeerClock.now` (or `Date()` as fallback), convert to `HH:MM:SS:FF` timecode value
2. **Create timecode input:** `AVAssetWriterInput(mediaType: .timecode)` with `CMTimeCodeFormatDescription`
3. **Per video frame:** increment frame counter, write timecode sample aligned with video PTS
4. **At finalize:** timecode input is marked finished alongside video and audio

### Timecode Calculation

```swift
func timecodeFromPeerClock(_ peerClock: PeerClock?) -> (hours: Int, minutes: Int, seconds: Int, frames: Int) {
    let date: Date
    if let clock = peerClock, clock.peerCount > 0 {
        // PeerClock synced time → Date
        let nanos = clock.now
        date = Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
    } else {
        date = Date()
    }
    let calendar = Calendar.current
    let h = calendar.component(.hour, from: date)
    let m = calendar.component(.minute, from: date)
    let s = calendar.component(.second, from: date)
    let subsecond = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1.0)
    let f = Int(subsecond * 30) // 30fps frame number
    return (h, m, s, f)
}
```

### MovieWriter Changes

- Add `private var timecodeInput: AVAssetWriterInput?`
- Create `CMTimeCodeFormatDescription` with `kCMTimeCodeFormatType_TimeCode32`, 30fps, 24-hour
- In `start()`: create timecode input, add to writer
- In `appendVideo()`: also append a timecode sample with the current frame's TC value
- In `finalize()`: mark timecode input as finished

### PeerClock Integration

- `RemoteControlService` already holds a `PeerClock` instance
- Pass `PeerClock?` reference to `CameraSession` → `MovieWriter` at recording start
- If PeerClock is nil or has 0 peers: use `Date()` — this is transparent to MovieWriter

### DAW Compatibility

| DAW | TC Track Support |
|---|---|
| Final Cut Pro | Auto-reads QuickTime TC track for timeline placement |
| DaVinci Resolve | Reads TC from QuickTime metadata |
| Logic Pro | Reads TC from imported video files |
| Adobe Premiere | Reads QuickTime TC (may need "Timecode" column enabled) |

### Implementation

**Files to modify:**
- `Capture/MovieWriter.swift` — add timecode input creation, per-frame TC sample writing, TC format description
- `Capture/CameraSession.swift` — pass PeerClock reference to MovieWriter at recording start
- `RootView.swift` — pass PeerClock from RemoteControlService to CameraSession

**No new files needed** — timecode is purely a MovieWriter concern.

### Testing

- Record → open MP4 in QuickTime Player → Window → Show Movie Inspector → verify TC track exists
- Record → import into Final Cut Pro → verify TC is displayed on timeline
- Record on two devices simultaneously (both with PeerClock synced) → import both into FCP → verify TCs match (± frame accuracy)
- Record without PeerClock peers → verify TC uses local wall clock (still valid, just not synced)

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| External mic delivers unexpected format (96kHz, mono) | SampleBufferConverter handles all conversions; bypass path for matching formats |
| Lightning mic not detected as `.headsetMic` | Test with actual hardware; fall back gracefully to built-in |
| TC frame count drift over long recordings | TC is derived from frame counter (not re-read from clock per frame), so it's inherently monotonic |
| `kCMTimeCodeFormatType_TimeCode32` not supported by some players | QuickTime TC is the industry standard; VLC/web players may ignore it but that's acceptable |
| PeerClock sync offset changes mid-recording | TC start value is captured once at recording start; subsequent sync adjustments don't affect the in-progress TC |

## Out of Scope

- Bluetooth audio input
- Multi-channel recording (> stereo)
- SMPTE LTC (linear timecode in audio track)
- User-configurable TC start value
- TC burn-in overlay on video
