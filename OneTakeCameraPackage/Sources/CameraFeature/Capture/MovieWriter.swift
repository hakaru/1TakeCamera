// MovieWriter.swift
// Owns AVAssetWriter + video & audio inputs. Writes H.264+AAC MP4 to Documents.

import AVFoundation
import CoreMedia
import Foundation
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "MovieWriter")

/// Writes a single MP4 recording to the app's Documents folder.
/// Created fresh for each recording session.
final class MovieWriter: @unchecked Sendable {

    // MARK: - Public State

    let outputURL: URL
    private(set) var isStarted = false

    // MARK: - Diagnostic counters (accessed only from captureQueue)
    private(set) var audioSamplesAppended: Int = 0
    private(set) var videoFramesAppended: Int = 0
    private(set) var firstAudioPTS: CMTime = .invalid
    private(set) var lastAudioPTS: CMTime = .invalid
    private(set) var firstVideoPTS: CMTime = .invalid
    private(set) var lastVideoPTS: CMTime = .invalid

    // MARK: - Private

    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput

    // MARK: - Init

    init?(videoSize: CGSize = CGSize(width: 1920, height: 1080)) {
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

        // Video input: H.264, 1080p30
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000, // 10 Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vi.expectsMediaDataInRealTime = true
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

    // MARK: - Lifecycle

    func startSession(at sourcePTS: CMTime) {
        guard assetWriter.startWriting() else {
            logger.error("AVAssetWriter failed to start: \(self.assetWriter.error?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }
        assetWriter.startSession(atSourceTime: sourcePTS)
        isStarted = true
        logger.info("MovieWriter session started at \(sourcePTS.seconds, privacy: .public)s → \(self.outputURL.lastPathComponent, privacy: .public)")
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isStarted, videoInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstVideoPTS == .invalid { firstVideoPTS = pts }
        lastVideoPTS = pts
        videoFramesAppended += 1
        videoInput.append(sampleBuffer)
    }

    /// Returns false if the writer is under backpressure (caller increments counter).
    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard isStarted else { return true }
        guard audioInput.isReadyForMoreMediaData else {
            return false
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstAudioPTS == .invalid { firstAudioPTS = pts }
        lastAudioPTS = pts
        audioSamplesAppended += CMSampleBufferGetNumSamples(sampleBuffer)
        audioInput.append(sampleBuffer)
        return true
    }

    func finalize() async -> URL? {
        guard isStarted else { return nil }

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
            audioSamples=\(self.audioSamplesAppended, privacy: .public)
            """)

        isStarted = false
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await assetWriter.finishWriting()

        let finalStatus = assetWriter.status
        logger.info("finalize() end — writerStatus=\(finalStatus.rawValue, privacy: .public) error=\(self.assetWriter.error?.localizedDescription ?? "none", privacy: .public)")

        if finalStatus == .completed {
            logger.info("MovieWriter finalized: \(self.outputURL.path, privacy: .public)")
            return outputURL
        } else {
            logger.error("MovieWriter finalize failed: \(self.assetWriter.error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
    }
}
