// CaptureMetrics.swift
// Diagnostic counters for v0.0 PoC — logged via os.Logger every second.

import Foundation
import os

/// Capture pipeline diagnostic counters.
/// All properties are accessed only from the capture serial queue.
final class CaptureMetrics: @unchecked Sendable {
    private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "Capture")

    // MARK: - Counters

    var droppedVideoFrames: Int = 0
    var droppedAudioBuffers: Int = 0
    var writerBackpressureEvents: Int = 0

    // Maximum observed PTS delta deviation from expected (in seconds)
    var maxPTSDeltaDeviation: Double = 0

    // MARK: - Periodic logging

    private var logTimer: DispatchSourceTimer?
    private let logQueue: DispatchQueue

    init(queue: DispatchQueue) {
        self.logQueue = queue
    }

    func startPeriodicLogging() {
        let timer = DispatchSource.makeTimerSource(queue: logQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.logSnapshot()
        }
        timer.resume()
        logTimer = timer
    }

    func stopPeriodicLogging() {
        logTimer?.cancel()
        logTimer = nil
        logSnapshot()
    }

    private func logSnapshot() {
        logger.info("""
            [Metrics] droppedVideo=\(self.droppedVideoFrames, privacy: .public) \
            droppedAudio=\(self.droppedAudioBuffers, privacy: .public) \
            backpressure=\(self.writerBackpressureEvents, privacy: .public) \
            maxPTSDelta=\(String(format: "%.4f", self.maxPTSDeltaDeviation), privacy: .public)s
            """)
    }
}
