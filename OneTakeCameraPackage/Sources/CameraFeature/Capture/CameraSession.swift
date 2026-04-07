// CameraSession.swift
// Owns AVCaptureSession: rear camera 1080p30 + built-in mic.
// All mutable state is accessed only from captureQueue (serial).
// UI callbacks are dispatched to @MainActor.

import AVFoundation
import CoreMedia
import Foundation
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

    // Current video input — kept so we can swap it during lens switching.
    // Accessed from captureQueue only.
    private var currentVideoInput: AVCaptureDeviceInput?

    // Interruption + thermal monitors (live for the session lifetime)
    private var interruptionHandler: InterruptionHandler?
    private let thermalMonitor = ThermalMonitor()

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
            handler.start()
            interruptionHandler = handler
        }

        thermalMonitor.start()

        return true
    }

    func beginRecording(preset: CompressorPreset = .studio) {
        let writer = MovieWriter(presetName: preset.displayName)
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

        // Publish lens list + current selection to main actor.
        let lenses = discoveredLenses
        let selectedID = initialLens.id
        Task { @MainActor [weak self] in
            self?.availableLenses = lenses
            self?.currentLensID = selectedID
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
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(videoOutput) else {
            logger.error("Could not add video output")
            session.commitConfiguration()
            return false
        }
        session.addOutput(videoOutput)

        // Audio output
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(audioOutput) else {
            logger.error("Could not add audio output")
            session.commitConfiguration()
            return false
        }
        session.addOutput(audioOutput)

        session.commitConfiguration()
        logger.info("AVCaptureSession configured")
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

    // MARK: - Helpers

    private func notifyState(_ state: State) {
        let callback = onStateChange
        Task { @MainActor in
            callback?(state)
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

            guard let pcmBuffer = converter.toFloat32Buffer(sampleBuffer) else {
                metrics.droppedAudioBuffers += 1
                return
            }

            // DSP in-place (LA-2A compressor)
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

