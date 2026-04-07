import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "Interruption")

/// Observes AVCaptureSession interruption and AVAudioSession route changes.
/// On any interruption, invokes the supplied handler so CameraSession can finalize.
public final class InterruptionHandler: @unchecked Sendable {
    private weak var session: AVCaptureSession?
    private let onInterruption: @Sendable () -> Void
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
            logger.warning("AVAudioSession route change: \(String(describing: reason), privacy: .public)")
            // Only treat as interruption if the new route is incompatible; for MVP, finalize on any.
            if reason == .oldDeviceUnavailable || reason == .unknown {
                self?.onInterruption()
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
