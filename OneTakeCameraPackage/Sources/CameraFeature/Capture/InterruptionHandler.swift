import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "Interruption")

/// Observes AVCaptureSession interruption and AVAudioSession route changes.
/// On any interruption, invokes the supplied handler so CameraSession can finalize.
/// On a non-interruption route change (device available/unavailable), invokes `onRouteChanged`.
public final class InterruptionHandler: @unchecked Sendable {
    private weak var session: AVCaptureSession?
    private let onInterruption: @Sendable () -> Void
    /// Called on any non-interruption route change (.newDeviceAvailable or .oldDeviceUnavailable).
    /// Use this to update UI and reset format caches when not recording.
    var onRouteChanged: (@Sendable () -> Void)?
    private var observers: [NSObjectProtocol] = []

    public init(session: AVCaptureSession, onInterruption: @escaping @Sendable () -> Void) {
        self.session = session
        self.onInterruption = onInterruption
    }

    deinit {
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
    }

    public func start() {
        let nc = NotificationCenter.default

        let capInterrupt = nc.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                .flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            logger.warning("AVCaptureSession interrupted: \(String(describing: reason), privacy: .public)")
            self?.onInterruption()
        }
        observers.append(capInterrupt)

        let routeChange = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
            logger.info("AVAudioSession route change: \(String(describing: reason), privacy: .public)")
            switch reason {
            case .oldDeviceUnavailable, .unknown:
                // Treat as interruption — finalize if recording.
                self?.onInterruption()
                // Also notify of generic route change (e.g. to update label if not recording).
                self?.onRouteChanged?()
            case .newDeviceAvailable:
                // New device plugged in — not an interruption, but update UI and format cache.
                self?.onRouteChanged?()
            default:
                break
            }
        }
        observers.append(routeChange)
    }

    public func stop() {
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
    }
}
