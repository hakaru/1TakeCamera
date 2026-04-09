# Audio Enhancements — Design Document

**Date:** 2026-04-10
**Status:** Approved
**Scope:** 1Take Camera v0.3 Sub-project B
**Target:** External mic support (USB-C + Lightning) + QuickTime Timecode track

## Overview

Add professional audio input support (USB-C and Lightning-connected microphones) and embed QuickTime Timecode tracks in recorded `.mov` files for DAW timeline synchronization.

## 1. External Microphone Support

### Supported Input Types

| Port Type | Example Devices | Detection |
|---|---|---|
| `.usbAudio` | Focusrite Scarlett, RØDE AI-1, USB-C mics | USB-C direct or Lightning→USB camera adapter |
| `.headsetMic` | Shure MV88, RØDE VideoMic ME-L | Lightning direct-connect microphones |
| `.lineIn` | 3.5mm → Lightning/USB-C adapters, some pro interfaces | Wired line-level input |
| `.builtInMic` | iPhone internal mic | Default fallback |

**Not supported:** Bluetooth audio (`.bluetoothHFP`, `.bluetoothA2DP`) — latency is incompatible with real-time DSP processing.

> **Note:** iOS devices do not supply 48V phantom power. Condenser microphones that require phantom power must be connected through a powered audio interface (e.g., Focusrite Scarlett) or use self-powered designs.

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

**Converter failure policy:** If `AVAudioConverter` creation fails for an external mic format (e.g., unsupported interleaved layout), log the error and fall back to built-in mic by calling `setPreferredInput(nil)`. Do NOT record silence — either use a working input or don't record.

**Channel mapping:** Multi-channel USB interfaces (e.g., Scarlett 2i2 with 2 inputs) present all channels as a stereo pair. Channels 1+2 map to L+R directly. Per-channel routing is not user-configurable in v0.3.

### Route Change Behavior

| Event | During Recording? | Action |
|---|---|---|
| External mic plugged in | No | Auto-switch to new route (AVAudioSession default). Update UI label. |
| External mic plugged in | Yes | Ignore. Continue recording with current route. |
| External mic unplugged | No | Fall back to built-in mic. Update UI label. |
| External mic unplugged | Yes | **Finalize recording** (existing InterruptionHandler behavior on `oldDeviceUnavailable`). |
| Any route change | Yes | Call `AVAudioSession.sharedInstance().setPreferredInput(currentInput)` to pin the active input. Prevents AVCaptureSession from auto-switching mid-recording. |

### SampleBufferConverter Format Reset

`SampleBufferConverter` caches its bypass/convert decision on the first audio buffer. When the audio route changes (new device connected while NOT recording), the cached format may be stale.

**Fix:** Add `SampleBufferConverter.resetFormat()` that clears `bypassConverter`, `inputFormat`, and `converter`. Call it from `CameraSession` whenever a non-recording route change occurs (new device available or old device unavailable while idle).

### Implementation

**Files to create:**
- `Views/AudioInputLabel.swift` — small text label showing current mic name

**Files to modify:**
- `Capture/CameraSession.swift` — add `currentAudioInputName: String` property, update on route change; at recording start capture `AVAudioSession.sharedInstance().currentRoute.inputs.first` and call `setPreferredInput(_:)` to pin it; at recording end (finalize) call `setPreferredInput(nil)` to release the pin
- `Capture/InterruptionHandler.swift` — extend to detect `.newDeviceAvailable` (non-recording) for UI update callback
- `RootView.swift` — display `AudioInputLabel` in top-left area

**No changes to:**
- `AudioProcessor.swift` — DSP chain is format-agnostic (operates on 48kHz Float32 regardless of source)
- `MovieWriter.swift` — audio input settings are independent of mic source

### Testing

- Plug/unplug USB-C audio interface during idle → verify UI label updates
- Plug/unplug during recording → verify finalize on unplug, ignore on plug
- Record with external mic → verify audio quality in `.mov` (correct sample rate, no artifacts)
- Record with built-in mic after external was unplugged → verify fallback works

## 2. QuickTime Timecode Track

### Purpose

Embed an absolute timecode track in `.mov` files so that recordings from multiple devices can be automatically aligned in DAWs (Final Cut Pro, DaVinci Resolve, Logic Pro) without manual waveform matching.

### Timecode Specification

| Parameter | Value |
|---|---|
| Format | `kCMTimeCodeFormatType_TimeCode64` |
| Frame rate | 30fps (matching video) |
| TC source | PeerClock `clock.now` (synced nanoseconds) → wall clock → HH:MM:SS:FF |
| Fallback | If PeerClock has 0 peers (no sync): `Date()` (device local wall clock) |
| Drop frame | Non-drop (30fps exact, not 29.97) |

> **Note:** `TimeCode64` is recommended by Apple TN2310 for modern AVFoundation workflows. `TimeCode32` is legacy. TC64 uses an 8-byte big-endian frame number.

### How It Works

1. **At recording start:** read `PeerClock.now` (or `Date()` as fallback), convert to `HH:MM:SS:FF` timecode value
2. **Create timecode input:** `AVAssetWriterInput(mediaType: .timecode)` with `CMTimeCodeFormatDescription`; associate with video track
3. **Write ONE timecode sample at recording start** covering the entire recording
4. **At finalize:** timecode input is marked finished alongside video and audio

### Timecode Calculation

```swift
func wallClockDate(from peerClock: PeerClock?) -> Date {
    if let clock = peerClock, clock.peerCount > 0 {
        // PeerClock offset is the difference between local and coordinated clocks.
        // Convert mach time to Date via ProcessInfo.systemUptime relationship:
        let uptimeNow = ProcessInfo.processInfo.systemUptime
        let bootDate = Date().addingTimeInterval(-uptimeNow)
        let peerUptimeSeconds = Double(clock.now) / 1_000_000_000
        return bootDate.addingTimeInterval(peerUptimeSeconds)
    }
    return Date()
}
```

**Verify this conversion against PeerClock's actual `now` implementation before shipping.** If `PeerClock.now` already returns Unix epoch nanoseconds, simplify to `Date(timeIntervalSince1970: Double(clock.now) / 1e9)`.

```swift
func timecodeFromPeerClock(_ peerClock: PeerClock?) -> (hours: Int, minutes: Int, seconds: Int, frames: Int) {
    let date = wallClockDate(from: peerClock)
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
- **Change output format from `.mp4` to `.mov`** (`AVFileType.mov`) when timecode is enabled. QuickTime TC tracks are reliably supported only in `.mov` containers. NLE apps (FCP, Resolve) may ignore TC in `.mp4`.
- File extension changes from `.mp4` to `.mov` (update filename generation).

**TC track creation (at recording start):**

1. Create `CMTimeCodeFormatDescription`:
```swift
var tcFmtDesc: CMTimeCodeFormatDescription?
let frameDuration = CMTime(value: 1, timescale: 30)
CMTimeCodeFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    timeCodeFormatType: kCMTimeCodeFormatType_TimeCode64,
    frameDuration: frameDuration,
    frameQuanta: 30,
    flags: 0, // non-drop frame
    extensions: nil,
    formatDescriptionOut: &tcFmtDesc
)
```

2. Create `AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFmtDesc)`
3. **Associate TC track with video track:** `videoInput.addTrackAssociation(withTrackOf: timecodeInput!, type: .timecode)`
4. Add TC input to writer

**TC sample writing (ONE sample at recording start):**

Write a single timecode sample containing the start frame number. The sample's duration covers the entire recording (set to a large value; the writer truncates on finalize).

```swift
func writeTimecodeStart(frameNumber: Int64, at pts: CMTime) {
    guard let tcInput = timecodeInput, tcInput.isReadyForMoreMediaData else { return }

    // 8-byte big-endian frame number (TimeCode64)
    var frameNumberBE = frameNumber.bigEndian
    let data = Data(bytes: &frameNumberBE, count: 8)

    // Create CMBlockBuffer from data
    var blockBuffer: CMBlockBuffer?
    data.withUnsafeBytes { rawBuf in
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: rawBuf.baseAddress!),
            blockLength: 8,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 8,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
    }

    // Create CMSampleBuffer with duration = 24 hours (truncated on finalize)
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 24 * 60 * 60 * 30, timescale: 30),
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: tcFormatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )

    if let sb = sampleBuffer {
        tcInput.append(sb)
    }
}
```

**Do NOT write timecode per video frame.** One sample at start covers the entire recording.

In `finalize()`: mark `timecodeInput` as finished alongside video and audio inputs.

### PeerClock Integration

- `RemoteControlService` already holds a `PeerClock` instance
- Pass `PeerClock?` reference to `CameraSession` → `MovieWriter` at recording start
- If PeerClock is nil or has 0 peers: use `Date()` — this is transparent to MovieWriter

### PeerClock Epoch

`PeerClock.now` returns nanoseconds in the **Mach absolute time** domain (monotonic, device-uptime based), NOT Unix epoch. To convert to wall-clock time for timecode:

```swift
func wallClockDate(from peerClock: PeerClock?) -> Date {
    if let clock = peerClock, clock.peerCount > 0 {
        // PeerClock offset is the difference between local and coordinated clocks.
        // Convert mach time to Date via ProcessInfo.systemUptime relationship:
        let uptimeNow = ProcessInfo.processInfo.systemUptime
        let bootDate = Date().addingTimeInterval(-uptimeNow)
        let peerUptimeSeconds = Double(clock.now) / 1_000_000_000
        return bootDate.addingTimeInterval(peerUptimeSeconds)
    }
    return Date()
}
```

**Verify this conversion against PeerClock's actual `now` implementation before shipping.** If `PeerClock.now` already returns Unix epoch nanoseconds, simplify to `Date(timeIntervalSince1970: Double(clock.now) / 1e9)`.

### DAW Compatibility

| DAW | TC Track Support |
|---|---|
| Final Cut Pro | Auto-reads QuickTime TC track for timeline placement |
| DaVinci Resolve | Reads TC from QuickTime metadata |
| Logic Pro | Reads TC from imported video files |
| Adobe Premiere | Reads QuickTime TC (may need "Timecode" column enabled) |

### Implementation

**Files to modify:**
- `Capture/MovieWriter.swift` — add timecode input creation, single TC sample write at start, TC format description, output format change to `.mov`
- `Capture/CameraSession.swift` — pass PeerClock reference to MovieWriter at recording start
- `RootView.swift` — pass PeerClock from RemoteControlService to CameraSession

**No new files needed** — timecode is purely a MovieWriter concern.

### Testing

- Record → open `.mov` in QuickTime Player → Window → Show Movie Inspector → verify TC track exists
- Record → import into Final Cut Pro → verify TC is displayed on timeline
- Record on two devices simultaneously (both with PeerClock synced) → import both into FCP → verify TCs match (± frame accuracy)
- Record without PeerClock peers → verify TC uses local wall clock (still valid, just not synced)

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| External mic delivers unexpected format (96kHz, mono) | SampleBufferConverter handles all conversions; bypass path for matching formats |
| Lightning mic not detected as `.headsetMic` | Test with actual hardware; fall back gracefully to built-in |
| TC frame count drift over long recordings | TC is derived from frame counter (not re-read from clock per frame), so it's inherently monotonic |
| `kCMTimeCodeFormatType_TimeCode64` not supported by some players | QuickTime TC is the industry standard; VLC/web players may ignore it but that's acceptable |
| PeerClock sync offset changes mid-recording | TC start value is captured once at recording start; subsequent sync adjustments don't affect the in-progress TC |

## Out of Scope

- Bluetooth audio input
- Multi-channel recording (> stereo)
- SMPTE LTC (linear timecode in audio track)
- User-configurable TC start value
- TC burn-in overlay on video
- USB audio latency compensation (PTS from AVCaptureSession includes device-reported latency; manual compensation is not needed for capture use cases)
