// MovieWriter.swift
// Owns AVAssetWriter + video & audio inputs. Writes H.264+AAC MP4 to Documents.

import AVFoundation
import CoreMedia
import Foundation
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "Capture")

/// Writes a single MP4 recording to the app's Documents folder.
/// Created fresh for each recording session.
final class MovieWriter: @unchecked Sendable {

    // MARK: - Public State

    let outputURL: URL
    private(set) var isStarted = false

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
        videoInput.append(sampleBuffer)
    }

    /// Returns false if the writer is under backpressure (caller increments counter).
    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard isStarted else { return true }
        guard audioInput.isReadyForMoreMediaData else {
            return false
        }
        audioInput.append(sampleBuffer)
        return true
    }

    func finalize() async -> URL? {
        guard isStarted else { return nil }
        isStarted = false
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await assetWriter.finishWriting()
        if assetWriter.status == .completed {
            logger.info("MovieWriter finalized: \(self.outputURL.path, privacy: .public)")
            return outputURL
        } else {
            logger.error("MovieWriter finalize failed: \(self.assetWriter.error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
    }
}
