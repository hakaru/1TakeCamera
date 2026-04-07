// LevelMonitor.swift
// Polls AudioProcessor peak at ~30 Hz and publishes dBFS value on the main actor.

import Foundation
import Observation

@MainActor
@Observable
public final class LevelMonitor {
    public private(set) var peakDB: Float = -60
    private var task: Task<Void, Never>?

    public init() {}

    /// Start polling. `reading` is called from a background Task — must be @Sendable.
    public func start(reading: @escaping @Sendable () -> Float) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let linear = reading()
                let db = linear > 1e-5 ? 20 * log10f(linear) : -60
                await MainActor.run {
                    self?.peakDB = max(-60, min(0, db))
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        peakDB = -60
    }
}
