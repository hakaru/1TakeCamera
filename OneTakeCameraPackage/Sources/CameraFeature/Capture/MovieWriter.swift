// MovieWriter.swift
// Owns AVAssetWriter + video & audio inputs. Writes H.264+AAC MP4 to Documents.

import AVFoundation
import CoreMedia
import Foundation
import UIKit
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "MovieWriter")

/// Writes a single MP4 recording to the app's Documents folder.
/// Created fresh for each recording session.
final class MovieWriter: @unchecked Sendable {

    // MARK: - Public State

    let outputURL: URL
    /// True once both streams have delivered their first buffer and startSession has been called.
    private(set) var isStarted = false

    // MARK: - Startup synchronisation (accessed only from captureQueue)
    /// PTS of the first video buffer received (before session start).
    private var pendingFirstVideoPTS: CMTime = .invalid
    /// PTS of the first audio buffer received (before session start).
    private var pendingFirstAudioPTS: CMTime = .invalid
    /// The source time passed to assetWriter.startSession; valid only after isStarted==true.
    private var sessionStartTime: CMTime = .invalid

    // MARK: - Diagnostic counters (accessed only from captureQueue)
    private(set) var audioSamplesAppended: Int = 0
    private(set) var audioBuffersAppended: Int = 0
    private(set) var videoFramesAppended: Int = 0
    private(set) var firstAudioPTS: CMTime = .invalid
    private(set) var lastAudioPTS: CMTime = .invalid
    private(set) var firstVideoPTS: CMTime = .invalid
    private(set) var lastVideoPTS: CMTime = .invalid
    private(set) var droppedPreStartAudio: Int = 0
    private(set) var droppedPreStartVideo: Int = 0
    private(set) var droppedBackpressureAudio: Int = 0
    private(set) var droppedBackpressureVideo: Int = 0

    // MARK: - Private

    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput

    // MARK: - Init

    init?(
        videoSize: CGSize = CGSize(width: 1920, height: 1080),
        videoBitRate: Int = 10_000_000,
        videoOrientation: UIDeviceOrientation = .portrait,
        presetName: String = "Studio"
    ) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "1TakeCam-\(formatter.string(from: Date())).mp4"
        let url = docs.appendingPathComponent(filename)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            logger.error("Failed to create AVAssetWriter at \(url.path, privacy: .public)")
            return nil
        }
        self.outputURL = url
        self.assetWriter = writer

        // Embed preset name in MP4 software metadata
        let meta = AVMutableMetadataItem()
        meta.identifier = .commonIdentifierSoftware
        meta.value = "1Take Camera (\(presetName))" as NSString
        meta.extendedLanguageTag = "und"
        writer.metadata = [meta]

        // Video input: H.264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vi.expectsMediaDataInRealTime = true
        vi.transform = MovieWriter.transform(for: videoOrientation)
        self.videoInput = vi

        // Audio input: AAC stereo 48kHz
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        ai.expectsMediaDataInRealTime = true
        self.audioInput = ai

        writer.add(vi)
        writer.add(ai)
    }

    // MARK: - Orientation Transform

    /// Returns the CGAffineTransform to embed in AVAssetWriterInput so that the
    /// recorded video plays back at the correct orientation in all players.
    /// The sensor always captures in landscape-right (USB-C on left), so:
    ///   - Portrait      → rotate 90° CCW  (π/2)
    ///   - LandscapeRight → identity        (sensor native; USB-C on left)
    ///   - LandscapeLeft  → rotate 180°    (USB-C on right)
    static func transform(for orientation: UIDeviceOrientation) -> CGAffineTransform {
        switch orientation {
        case .portrait:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .landscapeRight:
            return .identity
        case .landscapeLeft:
            return CGAffineTransform(rotationAngle: .pi)
        default:
            return CGAffineTransform(rotationAngle: .pi / 2) // fallback to portrait
        }
    }

    // MARK: - Lifecycle

    /// Feed a video buffer. The session is started automatically once both the first
    /// video and first audio buffer have been received (whichever arrives second
    /// triggers `startSession`). Both streams write their natural PTSs without
    /// any pre-start dropping, preserving lip-sync.
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if pendingFirstVideoPTS == .invalid {
            pendingFirstVideoPTS = pts
            logger.info("First video PTS: \(pts.seconds, privacy: .public)s")
        }

        if !isStarted {
            tryStartSession()
            // Still not started (audio hasn't arrived yet) — drop this frame.
            if !isStarted { return }
        }

        guard videoInput.isReadyForMoreMediaData else {
            droppedBackpressureVideo += 1
            return
        }

        if firstVideoPTS == .invalid { firstVideoPTS = pts }
        lastVideoPTS = pts
        videoFramesAppended += 1
        videoInput.append(sampleBuffer)
    }

    /// Returns false if the writer is under backpressure (caller increments counter).
    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if pendingFirstAudioPTS == .invalid {
            pendingFirstAudioPTS = pts
            logger.info("First audio PTS: \(pts.seconds, privacy: .public)s")
        }

        if !isStarted {
            tryStartSession()
            // Still not started (video hasn't arrived yet) — drop this buffer.
            if !isStarted { return true }
        }

        guard audioInput.isReadyForMoreMediaData else {
            droppedBackpressureAudio += 1
            return false
        }

        if firstAudioPTS == .invalid { firstAudioPTS = pts }
        lastAudioPTS = pts
        audioBuffersAppended += 1
        audioSamplesAppended += CMSampleBufferGetNumSamples(sampleBuffer)
        audioInput.append(sampleBuffer)
        return true
    }

    // MARK: - Private

    /// Called from captureQueue whenever a new first-PTS is recorded.
    /// Starts the AVAssetWriter session only when both streams have delivered
    /// at least one buffer, using `min(firstVideoPTS, firstAudioPTS)` — the
    /// earlier of the two. This preserves lip-sync by letting each stream write
    /// its natural PTSs without dropping leading buffers.
    private func tryStartSession() {
        guard pendingFirstVideoPTS != .invalid, pendingFirstAudioPTS != .invalid else { return }

        // Use the *earlier* of the two start times.  The stream that starts later
        // will simply have a small gap at its head, which AVAssetWriter handles
        // gracefully.  Neither stream drops buffers, so lip-sync is preserved.
        let startPTS = CMTimeCompare(pendingFirstVideoPTS, pendingFirstAudioPTS) < 0
            ? pendingFirstVideoPTS
            : pendingFirstAudioPTS

        guard assetWriter.startWriting() else {
            logger.error("AVAssetWriter failed to start: \(self.assetWriter.error?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }
        assetWriter.startSession(atSourceTime: startPTS)
        sessionStartTime = startPTS
        isStarted = true

        let driftMs = (pendingFirstVideoPTS.seconds - pendingFirstAudioPTS.seconds) * 1000
        logger.info("""
            startSession atSourceTime=\(startPTS.seconds, privacy: .public)s \
            (video=\(self.pendingFirstVideoPTS.seconds, privacy: .public)s, \
            audio=\(self.pendingFirstAudioPTS.seconds, privacy: .public)s, \
            startup_drift=\(driftMs, privacy: .public)ms) \
            → \(self.outputURL.lastPathComponent, privacy: .public)
            """)
    }

    func finalize() async -> URL? {
        guard isStarted else { return nil }

        // Snapshot all counters before clearing state
        let snap = DiagSnapshot(
            filename: outputURL.lastPathComponent,
            sessionStartTime_s: sessionStartTime.seconds,
            firstVideoPTS: firstVideoPTS,
            lastVideoPTS: lastVideoPTS,
            videoFramesAppended: videoFramesAppended,
            droppedPreStartVideo: droppedPreStartVideo,
            droppedBackpressureVideo: droppedBackpressureVideo,
            firstAudioPTS: firstAudioPTS,
            lastAudioPTS: lastAudioPTS,
            audioSamplesAppended: audioSamplesAppended,
            audioBuffersAppended: audioBuffersAppended,
            droppedPreStartAudio: droppedPreStartAudio,
            droppedBackpressureAudio: droppedBackpressureAudio,
            pendingFirstVideoPTS: pendingFirstVideoPTS,
            pendingFirstAudioPTS: pendingFirstAudioPTS
        )

        // Log state before finalizing
        logger.info("""
            finalize() start — writerStatus=\(self.assetWriter.status.rawValue, privacy: .public) \
            videoInput.expectsRealTime=\(self.videoInput.expectsMediaDataInRealTime, privacy: .public) \
            videoInput.isReady=\(self.videoInput.isReadyForMoreMediaData, privacy: .public) \
            audioInput.expectsRealTime=\(self.audioInput.expectsMediaDataInRealTime, privacy: .public) \
            audioInput.isReady=\(self.audioInput.isReadyForMoreMediaData, privacy: .public)
            """)
        logger.info("""
            PTS summary — \
            firstVideo=\(self.firstVideoPTS.seconds, privacy: .public)s \
            lastVideo=\(self.lastVideoPTS.seconds, privacy: .public)s \
            firstAudio=\(self.firstAudioPTS.seconds, privacy: .public)s \
            lastAudio=\(self.lastAudioPTS.seconds, privacy: .public)s \
            videoFrames=\(self.videoFramesAppended, privacy: .public) \
            audioSamples=\(self.audioSamplesAppended, privacy: .public) \
            audioBuffers=\(self.audioBuffersAppended, privacy: .public) \
            droppedPreStartVideo=\(self.droppedPreStartVideo, privacy: .public) \
            droppedPreStartAudio=\(self.droppedPreStartAudio, privacy: .public) \
            droppedBackpressureVideo=\(self.droppedBackpressureVideo, privacy: .public) \
            droppedBackpressureAudio=\(self.droppedBackpressureAudio, privacy: .public)
            """)

        isStarted = false
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await assetWriter.finishWriting()

        let finalStatus = assetWriter.status
        logger.info("finalize() end — writerStatus=\(finalStatus.rawValue, privacy: .public) error=\(self.assetWriter.error?.localizedDescription ?? "none", privacy: .public)")

        if finalStatus == .completed {
            logger.info("MovieWriter finalized: \(self.outputURL.path, privacy: .public)")
            snap.write(nextTo: outputURL, logger: logger)
            return outputURL
        } else {
            logger.error("MovieWriter finalize failed: \(self.assetWriter.error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
    }

    // MARK: - Diagnostic Snapshot

    private struct DiagSnapshot: Sendable {
        let filename: String
        let sessionStartTime_s: Double
        let firstVideoPTS: CMTime
        let lastVideoPTS: CMTime
        let videoFramesAppended: Int
        let droppedPreStartVideo: Int
        let droppedBackpressureVideo: Int
        let firstAudioPTS: CMTime
        let lastAudioPTS: CMTime
        let audioSamplesAppended: Int
        let audioBuffersAppended: Int
        let droppedPreStartAudio: Int
        let droppedBackpressureAudio: Int
        let pendingFirstVideoPTS: CMTime
        let pendingFirstAudioPTS: CMTime

        func write(nextTo mp4URL: URL, logger: Logger) {
            let jsonURL = mp4URL.deletingPathExtension().appendingPathExtension("json")

            let startupSkew_ms = (pendingFirstVideoPTS.isValid && pendingFirstAudioPTS.isValid)
                ? (pendingFirstVideoPTS.seconds - pendingFirstAudioPTS.seconds) * 1000
                : 0.0

            // Build a plain dictionary for JSONSerialization (avoids Codable for simplicity)
            let dict: [String: Any] = [
                "filename": filename,
                "sessionStartTime_s": sessionStartTime_s,
                "startupSkew_ms": startupSkew_ms,
                "video": [
                    "firstPTS_s": firstVideoPTS.isValid ? firstVideoPTS.seconds : -1,
                    "lastPTS_s": lastVideoPTS.isValid ? lastVideoPTS.seconds : -1,
                    "frameCount": videoFramesAppended,
                    "appendedCount": videoFramesAppended,
                    "droppedPreStart": droppedPreStartVideo,
                    "droppedBackpressure": droppedBackpressureVideo,
                ] as [String: Any],
                "audio": [
                    "firstPTS_s": firstAudioPTS.isValid ? firstAudioPTS.seconds : -1,
                    "lastPTS_s": lastAudioPTS.isValid ? lastAudioPTS.seconds : -1,
                    "sampleCount": audioSamplesAppended,
                    "bufferCount": audioBuffersAppended,
                    "appendedCount": audioBuffersAppended,
                    "droppedPreStart": droppedPreStartAudio,
                    "droppedBackpressure": droppedBackpressureAudio,
                    "convertedSampleRate": 48000,
                ] as [String: Any],
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: jsonURL, options: .atomic)
                logger.info("Sidecar JSON written: \(jsonURL.path, privacy: .public)")
            } catch {
                logger.error("Failed to write sidecar JSON: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
