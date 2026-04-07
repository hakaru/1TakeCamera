// RemoteControlService.swift
// Thin PeerClock wrapper for 1Take Camera.
// Provides: clock sync, remote start/stop, status broadcast.

import Foundation
import PeerClock
import Observation
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "Remote")

// MARK: - RemoteStatus

/// App-level status broadcast to all peers.
public struct RemoteStatus: Codable, Sendable {
    /// "idle" | "recording" | "finalizing"
    public let state: String
    public let presetID: String
    public let elapsedSeconds: Int
    public let latestFilename: String?
}

// MARK: - Command type constants

private enum CommandType {
    static let startRecording = "net.hakaru.1take.camera.start"
    static let stopRecording  = "net.hakaru.1take.camera.stop"
}

// Payload key for start command
private enum PayloadKey {
    static let preset = "preset"
}

// MARK: - RemoteControlService

@MainActor
@Observable
public final class RemoteControlService {

    // MARK: - Observable state

    public private(set) var isRunning = false
    public private(set) var peerCount = 0
    public private(set) var syncStateDescription = "Not started"
    public private(set) var coordinatorID: String?

    // MARK: - Handlers (set by RootView)

    /// Called when a peer requests recording start with a given preset.
    public var onRemoteStartRequest: (@Sendable (CompressorPreset) -> Void)?

    /// Called when a peer requests recording stop.
    public var onRemoteStopRequest: (@Sendable () -> Void)?

    /// Returns current app status for broadcast. Called on MainActor.
    public var currentStatusProvider: (@MainActor () -> RemoteStatus)?

    // MARK: - Private

    private var peerClock: PeerClock?
    private var streamTasks: [Task<Void, Never>] = []

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Start PeerClock discovery and begin listening for commands.
    public func start() {
        guard !isRunning else { return }

        let clock = PeerClock(configuration: .default)
        self.peerClock = clock

        Task {
            do {
                try await clock.start()
                await MainActor.run {
                    self.isRunning = true
                    self.syncStateDescription = "Discovering…"
                }
                logger.info("PeerClock started, localPeerID=\(clock.localPeerID)")
            } catch {
                await MainActor.run {
                    self.syncStateDescription = "Error: \(error.localizedDescription)"
                }
                logger.error("PeerClock start failed: \(error)")
                return
            }

            // Observe sync state
            let syncTask = Task { [weak self] in
                for await state in clock.syncState {
                    guard let self else { return }
                    let description = state.description
                    await MainActor.run {
                        self.syncStateDescription = description
                        if case .synced(_, let quality) = state {
                            self.coordinatorID = clock.coordinatorID?.description
                            logger.debug("Synced: offset=\(quality.offsetNs)ns conf=\(quality.confidence, format: .fixed(precision: 2))")
                        }
                    }
                }
            }

            // Observe peer list
            let peersTask = Task { [weak self] in
                for await peers in clock.peers {
                    guard let self else { return }
                    let count = peers.filter { $0.id != clock.localPeerID }.count
                    await MainActor.run {
                        self.peerCount = count
                        self.coordinatorID = clock.coordinatorID?.description
                    }
                }
            }

            // Observe incoming commands
            let commandTask = Task { [weak self] in
                for await (sender, command) in clock.commands {
                    guard let self else { return }
                    logger.info("Received command '\(command.type)' from \(sender)")
                    await self.handleIncomingCommand(command)
                }
            }

            await MainActor.run {
                self.streamTasks = [syncTask, peersTask, commandTask]
            }
        }
    }

    /// Stop PeerClock and cancel all observation tasks.
    public func stop() {
        streamTasks.forEach { $0.cancel() }
        streamTasks = []

        let pc = peerClock
        peerClock = nil
        isRunning = false
        peerCount = 0
        syncStateDescription = "Stopped"

        Task {
            await pc?.stop()
        }
    }

    /// Push current app status to all peers via PeerClock status registry.
    public func publishStatusUpdate() {
        guard let pc = peerClock, let provider = currentStatusProvider else { return }
        let status = provider()
        Task {
            do {
                try await pc.setStatus(status, forKey: "net.hakaru.1take.camera.status")
            } catch {
                logger.error("publishStatusUpdate failed: \(error)")
            }
        }
    }

    // MARK: - Private

    private func handleIncomingCommand(_ command: Command) async {
        switch command.type {
        case CommandType.startRecording:
            let preset = decodePreset(from: command.payload)
            logger.info("Remote start request: preset=\(preset.rawValue)")
            onRemoteStartRequest?(preset)

        case CommandType.stopRecording:
            logger.info("Remote stop request")
            onRemoteStopRequest?()

        default:
            logger.debug("Unknown command type '\(command.type)' — ignored")
        }
    }

    private func decodePreset(from payload: Data) -> CompressorPreset {
        guard !payload.isEmpty,
              let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: String],
              let rawValue = dict[PayloadKey.preset],
              let preset = CompressorPreset(rawValue: rawValue) else {
            return .studio
        }
        return preset
    }
}

// MARK: - SyncState description

private extension SyncState {
    var description: String {
        switch self {
        case .idle:              return "Idle"
        case .discovering:       return "Discovering…"
        case .syncing:           return "Syncing…"
        case .synced(let offset, _):
            let ms = Int(offset * 1000)
            return "Synced (\(ms)ms offset)"
        case .error(let msg):    return "Error: \(msg)"
        }
    }
}

// MARK: - Outbound command helpers (for use by other apps / future 1Take integration)

public extension RemoteControlService {
    /// Broadcast a start-recording command to all peers.
    func broadcastStart(preset: CompressorPreset) {
        guard let pc = peerClock else { return }
        let payload = (try? JSONSerialization.data(withJSONObject: [PayloadKey.preset: preset.rawValue])) ?? Data()
        let cmd = Command(type: CommandType.startRecording, payload: payload)
        Task {
            do {
                try await pc.broadcast(cmd)
                logger.info("Broadcast start command: preset=\(preset.rawValue)")
            } catch {
                logger.error("broadcastStart failed: \(error)")
            }
        }
    }

    /// Broadcast a stop-recording command to all peers.
    func broadcastStop() {
        guard let pc = peerClock else { return }
        let cmd = Command(type: CommandType.stopRecording)
        Task {
            do {
                try await pc.broadcast(cmd)
                logger.info("Broadcast stop command")
            } catch {
                logger.error("broadcastStop failed: \(error)")
            }
        }
    }
}
