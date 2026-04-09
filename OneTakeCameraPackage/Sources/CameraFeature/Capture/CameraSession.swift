// CameraSession.swift
// Owns AVCaptureSession: rear camera 1080p30 + built-in mic.
// All mutable state is accessed only from captureQueue (serial).
// UI callbacks are dispatched to @MainActor.

import AVFoundation
import CoreMedia
import Foundation
import PeerClock
import UIKit
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "Capture")

// MARK: - LensOption

/// A discovered rear camera lens. Stores only Sendable values; the actual
/// AVCaptureDevice is looked up on demand by uniqueID to stay Sendable-safe
/// under Swift 6 strict concurrency.
struct LensOption: Identifiable, Hashable, Sendable {
    let id: String                                   // == device.uniqueID
    let deviceType: AVCaptureDevice.DeviceType
    let displayName: String                          // "0.5x", "1x", "2x", etc.

    static func == (lhs: LensOption, rhs: LensOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - CameraSession

/// Manages the AVCaptureSession lifecycle for the PoC.
/// Internal state is protected by a dedicated serial capture queue.
/// `onStateChange` is always called on the main actor.
final class CameraSession: NSObject, @unchecked Sendable {

    // MARK: - Static helpers

    /// Returns true when a rear wide-angle camera is available (false on simulator).
    static var isCameraAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    // MARK: - Capture State

    enum State: Sendable {
        case idle
        case recording
        case finalizing
        case done(url: URL)
        case failed(String)
    }

    /// Called on main actor whenever state changes.
    var onStateChange: (@MainActor (State) -> Void)?

    // MARK: - Lens selection (main-actor-readable; written on captureQueue via notifyLenses)

    /// Available rear lenses discovered at session configuration time.
    /// Empty on simulator or devices with a single rear camera.
    private(set) var availableLenses: [LensOption] = []

    /// The id of the currently active lens (matches a LensOption.id in availableLenses).
    private(set) var currentLensID: String = ""

    // MARK: - Camera position

    /// Whether the front camera is currently active.
    private(set) var isFrontCamera: Bool = false

    // MARK: - Audio input

    /// Human-readable name of the currently active audio input (e.g. "Scarlett 2i2").
    /// Updated on route changes; safe to read from any context (written on captureQueue via notifyAudioInput).
    private(set) var currentAudioInputName: String = "Built-in Mic"

    // MARK: - Resolution

    /// The currently configured capture resolution.
    private(set) var currentResolution: CaptureResolution = .hd

    /// Whether the current camera supports 4K.
    private(set) var is4KSupported: Bool = false

    // MARK: - Orientation (main-actor-readable; written on captureQueue)

    /// The device orientation locked at recording start. Used for video transform.
    private(set) var recordingOrientation: UIDeviceOrientation = .portrait

    // MARK: - Orientation change callback

    /// Called on main actor when the device orientation changes so the preview
    /// layer's videoRotationAngle can be updated by the view layer.
    var onOrientationChange: (@MainActor (UIDeviceOrientation) -> Void)?

    /// Called on main actor when the resolution is downgraded (e.g. after camera switch).
    var onResolutionDowngrade: (@MainActor (CaptureResolution) -> Void)?

    /// Called on main actor when the active audio input device name changes.
    var onAudioInputChange: (@MainActor (String) -> Void)?

    // MARK: - Private — all accessed only from captureQueue

    private let captureQueue = DispatchQueue(
        label: "net.hakaru.OneTakeCamera.capture",
        qos: .userInteractive
    )

    private let session = AVCaptureSession()

    /// Exposes the underlying AVCaptureSession for preview layer binding.
    var captureSession: AVCaptureSession { session }
    private var movieWriter: MovieWriter?
    private let converter: SampleBufferConverter
    private let processor: AudioProcessor
    private let metrics: CaptureMetrics

    // PTS book-keeping (captureQueue only)
    private var sessionStartPTS: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var expectedAudioDuration: CMTime = .invalid

    // Diagnostic counters (captureQueue only)
    private var audioBufferCount = 0
    private var videoFrameCount = 0
    private var firstCaptureAudioPTS: CMTime = .invalid
    private var firstCaptureVideoPTS: CMTime = .invalid

    // Stop flag: set before drain so delegate ignores new buffers after drain
    // Accessed from captureQueue only.
    private var stopRequested = false

    // Sample rate initialization guard (captureQueue only)
    private var hasSetSampleRate = false

    // Current video input — kept so we can swap it during lens switching.
    // Accessed from captureQueue only.
    private var currentVideoInput: AVCaptureDeviceInput?

    // Video and audio outputs — stored as properties to allow post-switch reconfiguration.
    // Accessed from captureQueue only.
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?

    // Front/rear camera tracking (captureQueue only)
    private var currentPosition: AVCaptureDevice.Position = .back
    private var lastRearLensID: String = ""

    // Orientation tracking (captureQueue only)
    private var currentDeviceOrientation: UIDeviceOrientation = .portrait

    // Orientation notification observer token (main thread lifetime)
    private var orientationObserver: NSObjectProtocol?

    // Interruption + thermal monitors (live for the session lifetime)
    private var interruptionHandler: InterruptionHandler?
    private let thermalMonitor = ThermalMonitor()

    // PeerClock reference for timecode — set by RootView after prewarm.
    // Only read on captureQueue (from beginRecording).
    private var peerClock: PeerClock?

    // MARK: - Init

    override init() {
        guard let conv = SampleBufferConverter() else {
            fatalError("SampleBufferConverter init failed")
        }
        self.converter = conv
        self.processor = AudioProcessor(sampleRate: Float(SampleBufferConverter.internalSampleRate))
        self.metrics = CaptureMetrics(queue: DispatchQueue(
            label: "net.hakaru.OneTakeCamera.metrics",
            qos: .utility
        ))
        super.init()
    }

    deinit {
        interruptionHandler?.stop()
        thermalMonitor.stop()
        if let obs = orientationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Public API (called from @MainActor)

    /// Returns the post-DSP peak linear amplitude since the last call (thread-safe).
    /// Readable at any time — even before recording starts (during prewarm preview).
    func currentAudioPeak() -> Float {
        processor.readPeakAndReset()
    }

    /// Returns true if post-DSP audio exceeded -1 dBFS (0.891 linear) since last call; resets the flag.
    func currentAudioClipped() -> Bool {
        processor.readClippedAndReset()
    }

    /// Inject the PeerClock reference used for timecode at recording start.
    /// Safe to call from any context.
    func setPeerClock(_ clock: PeerClock?) {
        captureQueue.async { [weak self] in
            self?.peerClock = clock
        }
    }

    func requestPermissionsAndSetup() async -> Bool {
        let camStatus = await AVCaptureDevice.requestAccess(for: .video)
        guard camStatus else {
            logger.error("Camera access denied")
            return false
        }
        let micStatus = await AVCaptureDevice.requestAccess(for: .audio)
        guard micStatus else {
            logger.error("Microphone access denied")
            return false
        }
        return configureSession()
    }

    /// Configures the session (if not already configured) and starts running so the
    /// viewfinder shows a live preview before recording begins.
    /// Does NOT attach a MovieWriter — call `start30SecondRecording()` to begin capture.
    func prewarm() async -> Bool {
        let granted = await requestPermissionsAndSetup()
        guard granted else { return false }
        if !session.isRunning {
            session.startRunning()
            logger.info("CameraSession prewarmed — preview running")
        }

        // Start orientation tracking (must happen on main thread via UIDevice).
        if orientationObserver == nil {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let obs = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let raw = UIDevice.current.orientation
                // Ignore ambiguous orientations; keep last known valid orientation.
                guard raw != .faceUp, raw != .faceDown, raw != .unknown,
                      raw != .portraitUpsideDown else { return }
                self.captureQueue.async { [weak self] in
                    guard let self else { return }
                    self.currentDeviceOrientation = raw
                }
                let callback = self.onOrientationChange
                Task { @MainActor in
                    callback?(raw)
                }
            }
            orientationObserver = obs
            // Seed with current orientation if already valid.
            let initial = UIDevice.current.orientation
            if initial != .faceUp && initial != .faceDown && initial != .unknown
                && initial != .portraitUpsideDown {
                captureQueue.async { [weak self] in
                    self?.currentDeviceOrientation = initial
                }
            }
        }

        // Start interruption handler (keep running for session lifetime; only triggers
        // finalize when recording is active — checked inside the closure via captureQueue).
        if interruptionHandler == nil {
            let handler = InterruptionHandler(session: session) { [weak self] in
                guard let self else { return }
                // Only finalize if actively recording. captureQueue.sync is safe here
                // because this closure is called from a NotificationCenter queue, not captureQueue.
                var isRecording = false
                self.captureQueue.sync { isRecording = self.movieWriter != nil }
                guard isRecording else {
                    logger.info("Interruption received but not recording — ignored")
                    return
                }
                Task { await self.finalize() }
            }
            // Route-change callback: update audio input label + reset format cache when idle.
            handler.onRouteChanged = { [weak self] in
                guard let self else { return }
                var isRecording = false
                self.captureQueue.sync { isRecording = self.movieWriter != nil }
                if !isRecording {
                    // Reset converter so next recording picks up the new format.
                    self.captureQueue.async { [weak self] in
                        self?.converter.resetFormat()
                    }
                }
                // Always refresh the UI label.
                self.refreshAudioInputName()
            }
            handler.start()
            interruptionHandler = handler
        }

        // Seed the initial audio input name.
        refreshAudioInputName()

        thermalMonitor.start()

        return true
    }

    func beginRecording(preset: CompressorPreset = .studio) {
        // Capture resolution + orientation on captureQueue before creating the writer.
        var lockedOrientation: UIDeviceOrientation = .portrait
        var lockedResolution: CaptureResolution = .hd
        var lockedPeerClock: PeerClock?
        captureQueue.sync { [self] in
            lockedOrientation = self.currentDeviceOrientation
            lockedResolution = self.currentResolution
            self.recordingOrientation = lockedOrientation
            lockedPeerClock = self.peerClock
        }

        // Pin the current audio input to prevent AVCaptureSession from auto-switching mid-recording.
        let audioSession = AVAudioSession.sharedInstance()
        let preferredInput = audioSession.currentRoute.inputs.first
        if let input = preferredInput {
            do {
                try audioSession.setPreferredInput(input)
                logger.info("Pinned audio input: \(input.portName, privacy: .public)")
            } catch {
                logger.warning("Could not pin audio input: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Derive timecode start date from PeerClock (or wall clock as fallback).
        let timecodeDate = Self.wallClockDate(from: lockedPeerClock)

        let writer = MovieWriter(
            videoSize: lockedResolution.videoSize,
            videoBitRate: lockedResolution.videoBitRate,
            videoOrientation: lockedOrientation,
            presetName: preset.displayName,
            timecodeStartDate: timecodeDate
        )
        guard let writer else {
            notifyState(.failed("Could not create output file"))
            return
        }
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.processor.setPreset(preset)
            self.movieWriter = writer
        }
        metrics.startPeriodicLogging()
        // Session may already be running from prewarm(); startRunning() is a no-op when running.
        if !session.isRunning {
            session.startRunning()
        }
        notifyState(.recording)
    }

    /// Convert PeerClock.now (mach_continuous_time nanoseconds) to a wall-clock Date.
    /// Falls back to Date() if clock is nil or not synchronized.
    private static func wallClockDate(from clock: PeerClock?) -> Date {
        guard let clock, clock.currentSync.isSynchronized else {
            return Date()
        }
        // PeerClock.now returns mach_continuous_time-based nanoseconds (uptime since boot).
        // Relate to wall clock via ProcessInfo.systemUptime.
        let uptimeNow = ProcessInfo.processInfo.systemUptime
        let bootDate = Date().addingTimeInterval(-uptimeNow)
        let peerUptimeSeconds = Double(clock.now) / 1_000_000_000
        return bootDate.addingTimeInterval(peerUptimeSeconds)
    }

    func stopRecording() async {
        await finalize()
    }

    /// Switch the active rear camera lens. No-op while recording.
    /// Safe to call from any context — work is dispatched to captureQueue.
    func switchLens(to id: String) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            // Don't swap lens while recording — AVCaptureSession input swap mid-write
            // risks frame discontinuities and CMSampleBuffer ordering issues.
            guard self.movieWriter == nil else {
                logger.warning("switchLens ignored — recording in progress")
                return
            }
            guard id != self.currentLensID else { return }

            // Look up the target AVCaptureDevice by uniqueID.
            guard let lens = self.availableLenses.first(where: { $0.id == id }),
                  let device = AVCaptureDevice(uniqueID: lens.id),
                  let newInput = try? AVCaptureDeviceInput(device: device) else {
                logger.error("switchLens: could not create input for id=\(id, privacy: .public)")
                return
            }

            self.session.beginConfiguration()
            if let old = self.currentVideoInput {
                self.session.removeInput(old)
            }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.currentVideoInput = newInput
                let newID = lens.id
                let newName = lens.displayName
                self.session.commitConfiguration()
                self.lastRearLensID = newID
                logger.info("switchLens → \(newName, privacy: .public) (\(newID, privacy: .public))")
                // Notify UI on main actor.
                let lenses = self.availableLenses
                Task { @MainActor [weak self] in
                    self?.availableLenses = lenses
                    self?.currentLensID = newID
                }
            } else {
                // Restore previous input on failure.
                if let old = self.currentVideoInput,
                   self.session.canAddInput(old) {
                    self.session.addInput(old)
                }
                self.session.commitConfiguration()
                logger.error("switchLens: canAddInput returned false for \(id, privacy: .public)")
            }
        }
    }

    func finalize() async {
        notifyState(.finalizing)

        // Release pinned audio input so the session is free to auto-select after recording.
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(nil)
        } catch {
            logger.warning("Could not release pinned audio input: \(error.localizedDescription, privacy: .public)")
        }

        // Step 0: let the audio pipeline flush its tail buffers (~60ms capture latency).
        // Without this, stopRunning() cuts the last ~60ms of audio from the mic driver.
        try? await Task.sleep(for: .milliseconds(200))
        logger.info("tail-flush sleep complete")

        // Step 1: Stop the capture session so AVFoundation stops producing new
        // sample buffers. Pending delegate callbacks already enqueued on captureQueue
        // will still execute before Step 3's async block, because captureQueue is serial.
        session.stopRunning()
        metrics.stopPeriodicLogging()
        // Note: session is restarted after finalize() to keep the viewfinder alive.

        // Step 2: Signal the capture queue to ignore any buffers that arrive between
        // stopRunning() and when the drain block (Step 3) executes.
        // Using async preserves FIFO ordering — this runs after any already-enqueued
        // delegate callbacks, so in practice no new buffers should arrive, but the
        // flag provides a safe guard.
        captureQueue.async { [weak self] in
            self?.stopRequested = true
        }

        // Step 3: Drain — any delegate callbacks that were already enqueued before
        // stopRunning() will run before this async block executes, because captureQueue
        // is serial (FIFO). After this returns, no more appendAudio/appendVideo calls
        // will occur against the writer.
        let writer: MovieWriter? = await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                let w = self.movieWriter
                // Log final capture-side PTS before clearing state
                logger.info("""
                    captureSession drain complete — \
                    firstCapAudio=\(self.firstCaptureAudioPTS.seconds, privacy: .public)s \
                    lastCapAudio=\(self.lastAudioPTS.seconds, privacy: .public)s \
                    firstCapVideo=\(self.firstCaptureVideoPTS.seconds, privacy: .public)s \
                    audioBuffers=\(self.audioBufferCount, privacy: .public) \
                    videoFrames=\(self.videoFrameCount, privacy: .public)
                    """)
                self.movieWriter = nil
                self.sessionStartPTS = .invalid
                self.lastAudioPTS = .invalid
                self.expectedAudioDuration = .invalid
                self.stopRequested = false
                self.hasSetSampleRate = false
                self.audioBufferCount = 0
                self.videoFrameCount = 0
                self.firstCaptureAudioPTS = .invalid
                self.firstCaptureVideoPTS = .invalid
                continuation.resume(returning: w)
            }
        }

        let url = await writer?.finalize()

        // Restart session so viewfinder stays live after recording ends.
        session.startRunning()
        logger.info("CameraSession restarted after finalize — preview resumed")

        if let url {
            notifyState(.done(url: url))
        } else {
            notifyState(.failed("Finalize returned no URL"))
        }
    }

    // MARK: - Session Configuration

    private func configureSession() -> Bool {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .videoRecording, options: [])
            try audioSession.setPreferredSampleRate(48000)
            try audioSession.setActive(true)
        } catch {
            logger.error("AVAudioSession configuration failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Discover all available rear lenses.
        let discoveredLenses = Self.discoverLenses()

        // Pick initial device: prefer wide (1x), fall back to first available.
        let initialLens = discoveredLenses.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? discoveredLenses.first

        guard let initialLens,
              let videoDevice = AVCaptureDevice(uniqueID: initialLens.id) else {
            logger.error("No rear camera device available")
            return false
        }

        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .hd1920x1080

        // Rear camera (initial lens)
        guard let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            logger.error("Could not add rear camera input")
            session.commitConfiguration()
            return false
        }
        session.addInput(videoInput)
        currentVideoInput = videoInput

        // Track last rear lens ID for camera switch restoration.
        lastRearLensID = initialLens.id
        currentPosition = .back

        // Publish lens list + current selection to main actor.
        let lenses = discoveredLenses
        let selectedID = initialLens.id
        Task { @MainActor [weak self] in
            self?.availableLenses = lenses
            self?.currentLensID = selectedID
            self?.isFrontCamera = false
        }

        // Built-in mic
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
              session.canAddInput(audioInput) else {
            logger.error("Could not add mic input")
            session.commitConfiguration()
            return false
        }
        session.addInput(audioInput)

        // Video output
        let vo = AVCaptureVideoDataOutput()
        vo.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        vo.alwaysDiscardsLateVideoFrames = true
        vo.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(vo) else {
            logger.error("Could not add video output")
            session.commitConfiguration()
            return false
        }
        session.addOutput(vo)
        videoOutput = vo

        // Audio output
        let ao = AVCaptureAudioDataOutput()
        ao.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(ao) else {
            logger.error("Could not add audio output")
            session.commitConfiguration()
            return false
        }
        session.addOutput(ao)
        audioOutput = ao

        session.commitConfiguration()

        // Check 4K support for the initial rear camera.
        let supports4K = session.canSetSessionPreset(.hd4K3840x2160)
        Task { @MainActor [weak self] in
            self?.is4KSupported = supports4K
        }

        logger.info("AVCaptureSession configured — 4K supported: \(supports4K, privacy: .public)")
        return true
    }

    // MARK: - Lens Discovery

    /// Queries AVCaptureDevice.DiscoverySession for all available rear lenses and
    /// returns them sorted wide → ultra-wide → telephoto (i.e. 0.5x, 1x, 2x order).
    private static func discoverLenses() -> [LensOption] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera
            ],
            mediaType: .video,
            position: .back
        )

        // Build lens options with display labels.
        let options: [LensOption] = session.devices.compactMap { device in
            let displayName: String
            switch device.deviceType {
            case .builtInUltraWideCamera:
                displayName = "0.5×"
            case .builtInWideAngleCamera:
                displayName = "1×"
            case .builtInTelephotoCamera:
                // Use the switch-over zoom factor to infer the telephoto magnification.
                // virtualDeviceSwitchOverVideoZoomFactors contains the zoom factor at which
                // the system transitions from wide to tele. On iPhone 13 Pro that's 3.0,
                // on iPhone 14 Pro it's 3.0, on iPhone 15 Pro Max it's 5.0, etc.
                if let switchFactor = device.virtualDeviceSwitchOverVideoZoomFactors.last {
                    let factor = switchFactor.intValue
                    displayName = "\(factor)×"
                } else {
                    displayName = "2×"
                }
            default:
                return nil
            }
            return LensOption(id: device.uniqueID, deviceType: device.deviceType, displayName: displayName)
        }

        // Sort: ultra-wide (0.5×) first, then wide (1×), then telephoto.
        let order: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera
        ]
        return options.sorted {
            (order.firstIndex(of: $0.deviceType) ?? 99) < (order.firstIndex(of: $1.deviceType) ?? 99)
        }
    }

    // MARK: - Camera Switch

    /// Toggle between front and rear camera. No-op while recording.
    /// Safe to call from any context — work is dispatched to captureQueue.
    func switchCamera() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.movieWriter == nil else {
                logger.warning("switchCamera ignored — recording in progress")
                return
            }

            let targetPosition: AVCaptureDevice.Position = self.currentPosition == .back ? .front : .back

            // Discover the target device.
            let deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
            guard let device = AVCaptureDevice.default(deviceType, for: .video, position: targetPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device) else {
                logger.error("switchCamera: could not find \(targetPosition == .front ? "front" : "rear", privacy: .public) camera")
                return
            }

            self.session.beginConfiguration()
            if let old = self.currentVideoInput {
                self.session.removeInput(old)
            }
            guard self.session.canAddInput(newInput) else {
                // Restore old input on failure
                if let old = self.currentVideoInput, self.session.canAddInput(old) {
                    self.session.addInput(old)
                }
                self.session.commitConfiguration()
                logger.error("switchCamera: canAddInput returned false")
                return
            }
            self.session.addInput(newInput)
            self.currentVideoInput = newInput
            self.currentPosition = targetPosition

            // Check resolution compatibility after adding new input.
            var resolvedResolution = self.currentResolution
            if self.currentResolution != .hd,
               !self.session.canSetSessionPreset(self.currentResolution.sessionPreset) {
                logger.info("switchCamera: downgrading from \(self.currentResolution.rawValue, privacy: .public) to HD — not supported")
                resolvedResolution = .hd
                self.session.sessionPreset = CaptureResolution.hd.sessionPreset
            }
            self.currentResolution = resolvedResolution
            self.session.commitConfiguration()

            // Post-switch: fix video mirroring on recorded output (never mirror recorded video).
            if let conn = self.videoOutput?.connection(with: .video) {
                conn.isVideoMirrored = false
            }

            // Reset audio DSP state to clear filter history from previous camera.
            self.processor.resetAllStates()
            self.hasSetSampleRate = false

            // Check 4K support for the new camera.
            let supports4K = self.session.canSetSessionPreset(.hd4K3840x2160)
            let isFront = targetPosition == .front
            let rearLenses = isFront ? [] : Self.discoverLenses()
            let rearSelected = isFront ? "" : (
                self.lastRearLensID.isEmpty
                    ? (rearLenses.first(where: { $0.deviceType == .builtInWideAngleCamera })?.id ?? rearLenses.first?.id ?? "")
                    : self.lastRearLensID
            )
            let resolutionForUI = resolvedResolution
            let downgradedFromFour = resolvedResolution != self.currentResolution || (self.currentResolution == .hd && resolvedResolution == .hd && false)
            let wasDowngraded = (resolvedResolution == .hd && self.currentResolution == .fourK)

            // Notify UI.
            let onDowngrade = self.onResolutionDowngrade
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFrontCamera = isFront
                self.is4KSupported = supports4K
                self.currentResolution = resolutionForUI
                if isFront {
                    self.availableLenses = []
                    self.currentLensID = ""
                } else {
                    self.availableLenses = rearLenses
                    self.currentLensID = rearSelected
                }
                if wasDowngraded {
                    onDowngrade?(resolutionForUI)
                }
            }

            logger.info("switchCamera → \(isFront ? "front" : "rear", privacy: .public)")
        }
    }

    // MARK: - Resolution

    /// Change the capture session preset. No-op while recording or if already set.
    /// Safe to call from any context — work is dispatched to captureQueue.
    func setResolution(_ resolution: CaptureResolution) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.movieWriter == nil else {
                logger.warning("setResolution ignored — recording in progress")
                return
            }
            guard resolution != self.currentResolution else { return }
            guard self.session.canSetSessionPreset(resolution.sessionPreset) else {
                logger.warning("setResolution: preset \(resolution.rawValue, privacy: .public) not supported")
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = resolution.sessionPreset
            self.session.commitConfiguration()
            self.currentResolution = resolution
            let res = resolution
            Task { @MainActor [weak self] in
                self?.currentResolution = res
            }
            logger.info("setResolution → \(resolution.rawValue, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private func notifyState(_ state: State) {
        let callback = onStateChange
        Task { @MainActor in
            callback?(state)
        }
    }

    /// Reads the current AVAudioSession route and updates `currentAudioInputName`.
    /// Must be called from captureQueue (or any queue — AVAudioSession is thread-safe for reads).
    private func refreshAudioInputName() {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        let name: String
        if let first = inputs.first {
            // Filter out Bluetooth — not supported per spec
            let btTypes: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
            if btTypes.contains(first.portType) {
                name = "Built-in Mic"
                // Fall back: release any preferred input
                try? AVAudioSession.sharedInstance().setPreferredInput(nil)
            } else {
                name = first.portName
            }
        } else {
            name = "Built-in Mic"
        }
        let callback = onAudioInputChange
        Task { @MainActor [weak self] in
            self?.currentAudioInputName = name
            callback?(name)
        }
    }
}

// MARK: - Delegate (called on captureQueue)

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Guard against buffers arriving after stop was requested.
        // stopRequested is set on captureQueue (same queue as this delegate),
        // so there is no data race.
        guard !stopRequested, let writer = movieWriter else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if output is AVCaptureVideoDataOutput {
            if firstCaptureVideoPTS == .invalid {
                firstCaptureVideoPTS = pts
            }
            videoFrameCount += 1
            if videoFrameCount % 150 == 0 {
                logger.info("video[\(self.videoFrameCount, privacy: .public)] pts=\(pts.seconds, privacy: .public)s")
            }
            writer.appendVideo(sampleBuffer)

        } else {

            audioBufferCount += 1
            if firstCaptureAudioPTS == .invalid { firstCaptureAudioPTS = pts }

            // PTS delta diagnostic
            if lastAudioPTS.isValid && expectedAudioDuration.isValid {
                let actualDelta = CMTimeSubtract(pts, lastAudioPTS).seconds
                let expectedDelta = expectedAudioDuration.seconds
                let deviation = abs(actualDelta - expectedDelta)
                if deviation > metrics.maxPTSDeltaDeviation {
                    metrics.maxPTSDeltaDeviation = deviation
                }
            }

            // Preserve original PTS (duration will be recomputed from converted frame count in toCMSampleBuffer)
            var timingInfo = CMSampleTimingInfo()
            CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)
            let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)

            if audioBufferCount % 50 == 0 {
                logger.info("audio[\(self.audioBufferCount, privacy: .public)] pts=\(pts.seconds, privacy: .public)s samples=\(sampleCount, privacy: .public)")
            }

            // Set sample rate on first audio buffer (internal format is always 48kHz)
            if !hasSetSampleRate {
                processor.setSampleRate(48000)
                hasSetSampleRate = true
            }

            guard let pcmBuffer = converter.toFloat32Buffer(sampleBuffer) else {
                metrics.droppedAudioBuffers += 1
                return
            }

            // DSP in-place — full 8-stage chain
            guard let leftChannel = pcmBuffer.floatChannelData?[0] else {
                metrics.droppedAudioBuffers += 1
                return
            }
            let channelCount = Int(pcmBuffer.format.channelCount)
            let rightChannel: UnsafeMutablePointer<Float>? = channelCount >= 2 ? pcmBuffer.floatChannelData?[1] : nil
            processor.process(
                left: leftChannel,
                right: rightChannel ?? leftChannel,
                frameCount: Int(pcmBuffer.frameLength)
            )

            guard let outBuffer = converter.toCMSampleBuffer(pcmBuffer, timingInfo: timingInfo) else {
                metrics.droppedAudioBuffers += 1
                return
            }

            let ready = writer.appendAudio(outBuffer)
            if !ready {
                metrics.writerBackpressureEvents += 1
            }

            lastAudioPTS = pts
            expectedAudioDuration = CMTime(
                value: CMTimeValue(sampleCount),
                timescale: CMTimeScale(SampleBufferConverter.internalSampleRate)
            )
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureVideoDataOutput {
            metrics.droppedVideoFrames += 1
        } else {
            metrics.droppedAudioBuffers += 1
        }
    }
}

