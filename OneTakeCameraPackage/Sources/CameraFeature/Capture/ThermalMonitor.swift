import Foundation
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "Thermal")

public final class ThermalMonitor: @unchecked Sendable {
    private var observer: NSObjectProtocol?

    public init() {}

    deinit { stop() }

    public func start() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            let state = ProcessInfo.processInfo.thermalState
            logger.warning("thermal state changed: \(String(describing: state), privacy: .public)")
        }
        let state = ProcessInfo.processInfo.thermalState
        logger.info("thermal monitor started, current state: \(String(describing: state), privacy: .public)")
    }

    public func stop() {
        if let o = observer {
            NotificationCenter.default.removeObserver(o)
            observer = nil
        }
    }
}
