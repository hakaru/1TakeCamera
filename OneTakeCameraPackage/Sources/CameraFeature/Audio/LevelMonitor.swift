// LevelMonitor.swift
// Polls AudioProcessor peak at ~30 Hz and publishes dBFS value on the main actor.

import Foundation
import Observation

@MainActor
@Observable
public final class LevelMonitor {
    public private(set) var peakDB: Float = -60
    public private(set) var isClipping: Bool = false

    private var task: Task<Void, Never>?
    private var clipHideTask: Task<Void, Never>?

    public init() {}

    /// Start polling. `reading` is called from a background Task — must be @Sendable.
    /// `clipReading` is called each poll cycle to detect post-DSP clipping.
    public func start(
        reading: @escaping @Sendable () -> Float,
        clipReading: @escaping @Sendable () -> Bool
    ) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let linear = reading()
                let clipped = clipReading()
                let db = linear > 1e-5 ? 20 * log10f(linear) : -60
                await MainActor.run {
                    self?.peakDB = max(-60, min(0, db))
                    if clipped {
                        self?.isClipping = true
                        self?.scheduleClipHide()
                    }
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        clipHideTask?.cancel()
        clipHideTask = nil
        peakDB = -60
        isClipping = false
    }

    @MainActor
    private func scheduleClipHide() {
        clipHideTask?.cancel()
        clipHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled {
                self?.isClipping = false
            }
        }
    }
}
