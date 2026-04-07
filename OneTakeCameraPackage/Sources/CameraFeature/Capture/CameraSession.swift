// CameraSession.swift
// Owns AVCaptureSession: rear camera 1080p30 + built-in mic.
// All mutable state is accessed only from captureQueue (serial).
// UI callbacks are dispatched to @MainActor.

import AVFoundation
import CoreMedia
import Foundation
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "Capture")

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
        case recording(secondsRemaining: Int)
        case finalizing
        case done(url: URL)
        case failed(String)
    }

    /// Called on main actor whenever state changes.
    var onStateChange: (@MainActor (State) -> Void)?

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

    // Countdown task (main actor)
    private var countdownTask: Task<Void, Never>?

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
        return true
    }

    func start30SecondRecording(preset: CompressorPreset = .studio) {
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

        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: 30, through: 1, by: -1) {
                self.notifyState(.recording(secondsRemaining: remaining))
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            await self.finalize()
        }
    }

    func finalize() async {
        countdownTask?.cancel()
        countdownTask = nil
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

        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .hd1920x1080

        // Rear camera
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            logger.error("Could not add rear camera input")
            session.commitConfiguration()
            return false
        }
        session.addInput(videoInput)

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

