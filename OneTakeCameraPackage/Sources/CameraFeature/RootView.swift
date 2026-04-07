// RootView.swift
// Standard iOS Camera UI layout — full-bleed viewfinder, bottom control strip.

import SwiftUI

@MainActor
public struct RootView: View {

    @State private var session = CameraSession()
    @State private var viewState: ViewState = .idle
    @State private var permissionDenied = false
    @State private var selectedPreset: CompressorPreset = .studio
    @State private var levelMonitor = LevelMonitor()
    @State private var showRecordingList = false
    @State private var remote = RemoteControlService()
    @State private var showSyncSheet = false

    // Lens selection — mirrored from CameraSession after prewarm.
    @State private var currentLensID: String = ""

    // Elapsed time
    @State private var recordingStartDate: Date? = nil
    @State private var elapsedSeconds: Int = 0

    public init() {}

    // MARK: - View States

    enum ViewState {
        case idle
        case recording
        case finalizing
        case done(url: URL)
        case failed(String)
    }

    // MARK: - Computed helpers (outside @ViewBuilder)

    private var isRecording: Bool {
        if case .recording = viewState { return true }
        return false
    }

    /// True when the preset selector should be interactive (not mid-recording or finalizing).
    private var isIdle: Bool {
        switch viewState {
        case .idle, .done, .failed: return true
        default: return false
        }
    }

    private var canTapButton: Bool {
        switch viewState {
        case .idle, .recording, .done, .failed: return true
        default: return false
        }
    }

    private var elapsedText: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Full-screen viewfinder or simulator placeholder.
            backgroundLayer
                .ignoresSafeArea()

            // Bottom control strip anchored to bottom.
            VStack {
                Spacer()
                bottomControlStrip
            }

            // Clip warning overlay (top layer).
            ClipWarningOverlay(isVisible: levelMonitor.isClipping)

            // PeerClock status indicator — top right corner.
            VStack {
                HStack {
                    Spacer()
                    peerClockIndicator
                        .padding(.top, 52)
                        .padding(.trailing, 16)
                }
                Spacer()
            }
        }
        .sheet(isPresented: $showRecordingList) {
            RecordingListView()
        }
        .sheet(isPresented: $showSyncSheet) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("PeerClock Status")
                        .font(.headline)
                    Text(remote.syncStateDescription)
                    Text("Peers: \(remote.peerCount)")
                    if let coord = remote.coordinatorID {
                        Text("Coordinator: \(coord)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle("PeerClock")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { showSyncSheet = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Permission Denied", isPresented: $permissionDenied) {
            Button("OK") {}
        } message: {
            Text("Camera and microphone access are required. Enable them in Settings.")
        }
        .task {
            // Wire RemoteControlService handlers before starting.
            remote.onRemoteStartRequest = { [self] preset in
                Task { @MainActor in
                    selectedPreset = preset
                    if CameraSession.isCameraAvailable && !session.captureSession.isRunning {
                        let granted = await session.prewarm()
                        guard granted else { return }
                    }
                    session.beginRecording(preset: preset)
                }
            }
            remote.onRemoteStopRequest = { [self] in
                Task { @MainActor in
                    await session.stopRecording()
                }
            }
            remote.currentStatusProvider = { [self] in
                let stateString: String
                switch viewState {
                case .idle:        stateString = "idle"
                case .recording:   stateString = "recording"
                case .finalizing:  stateString = "finalizing"
                case .done:        stateString = "idle"
                case .failed:      stateString = "idle"
                }
                let filename: String?
                if case .done(let url) = viewState {
                    filename = url.lastPathComponent
                } else {
                    filename = nil
                }
                return RemoteStatus(
                    state: stateString,
                    presetID: selectedPreset.rawValue,
                    elapsedSeconds: elapsedSeconds,
                    latestFilename: filename
                )
            }
            remote.start()

            session.onStateChange = { newState in
                let newViewState = newState.toViewState
                viewState = newViewState
                if case .recording = newViewState {
                    recordingStartDate = Date()
                    elapsedSeconds = 0
                } else {
                    recordingStartDate = nil
                }
                // Publish status on every state change.
                remote.publishStatusUpdate()
            }
            // Prewarm: configure session + start preview before user taps record.
            if CameraSession.isCameraAvailable {
                let granted = await session.prewarm()
                if !granted {
                    permissionDenied = true
                } else {
                    // Sync initial lens selection from session.
                    currentLensID = session.currentLensID
                    // Start level meter now that audio is flowing.
                    levelMonitor.start(
                        reading: { [session] in session.currentAudioPeak() },
                        clipReading: { [session] in session.currentAudioClipped() }
                    )
                }
            }
        }
        .onChange(of: currentLensID) { _, newID in
            session.switchLens(to: newID)
        }
        .task(id: isRecording) {
            guard isRecording else { return }
            // Update elapsed time every 100ms while recording.
            while !Task.isCancelled {
                if let start = recordingStartDate {
                    elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onDisappear {
            levelMonitor.stop()
        }
    }

    // MARK: - Background Layer

    @ViewBuilder
    private var backgroundLayer: some View {
        if CameraSession.isCameraAvailable {
            ViewfinderView(session: session.captureSession)
        } else {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "video.slash")
                    .font(.largeTitle)
                Text("Camera unavailable (simulator?)")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        }
    }

    // MARK: - Bottom Control Strip

    private var bottomControlStrip: some View {
        VStack(spacing: 12) {
            // Top-left preset indicator pill (idle only)
            HStack {
                if isIdle {
                    Text(selectedPreset.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(.leading, 20)
                }
                Spacer()
            }

            // Elapsed time badge — visible only while recording.
            if isRecording {
                Text(elapsedText)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.7))
                    .cornerRadius(6)
            }

            // Status text for non-recording states.
            if case .finalizing = viewState {
                Text("Finalizing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if case .done = viewState {
                Text("Saved")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            } else if case .failed(let message) = viewState {
                Text("Error: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            // Level meter.
            LevelMeterView(peakDB: levelMonitor.peakDB)
                .frame(height: 6)
                .padding(.horizontal, 40)

            // Lens selector — shown only when 2+ lenses are available.
            if session.availableLenses.count > 1 {
                LensSelectorView(
                    lenses: session.availableLenses,
                    selection: $currentLensID,
                    isEnabled: isIdle
                )
            }

            // Preset selector.
            PresetSelectorView(selection: $selectedPreset, isEnabled: isIdle)

            // Button row: [spacer] [record button] [list button]
            HStack(alignment: .center) {
                // Balance spacer matching list button width.
                Spacer().frame(width: 56)

                Spacer()

                recordButton

                Spacer()

                // Recordings list button.
                Button {
                    showRecordingList = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .padding(.top, 16)
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - PeerClock Indicator

    private var peerClockIndicatorColor: Color {
        if remote.isRunning && remote.peerCount > 0 { return .green }
        if remote.isRunning { return .yellow }
        return Color(white: 0.5)
    }

    @ViewBuilder
    private var peerClockIndicator: some View {
        Button {
            showSyncSheet = true
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(peerClockIndicatorColor)
                    .frame(width: 8, height: 8)
                if remote.peerCount > 0 {
                    Text("\(remote.peerCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.5))
            .clipShape(Capsule())
        }
        .accessibilityLabel("PeerClock: \(remote.syncStateDescription), \(remote.peerCount) peer(s)")
    }

    // MARK: - Record Button

    @ViewBuilder
    private var recordButton: some View {
        Button {
            handleButtonTap()
        } label: {
            ZStack {
                // Outer white ring — always visible.
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 80, height: 80)

                if case .finalizing = viewState {
                    // Spinner while file is being written.
                    ProgressView()
                        .tint(.white)
                        .frame(width: 48, height: 48)
                } else if isRecording {
                    // Stop indicator: red rounded square.
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                } else {
                    // Idle: large red filled circle.
                    Circle()
                        .fill(Color.red)
                        .frame(width: 68, height: 68)
                }
            }
        }
        .disabled(!canTapButton)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Actions

    private func handleButtonTap() {
        Task { @MainActor in
            switch viewState {
            case .idle, .done, .failed:
                viewState = .idle
                // Session should already be running from prewarm() in .task.
                // If camera is unavailable (simulator), skip setup and start directly
                // so the state machine still works for testing.
                if CameraSession.isCameraAvailable && !session.captureSession.isRunning {
                    let granted = await session.prewarm()
                    guard granted else {
                        permissionDenied = true
                        return
                    }
                }
                session.beginRecording(preset: selectedPreset)
            case .recording:
                await session.stopRecording()
            default:
                break
            }
        }
    }
}

// MARK: - Mapping CameraSession.State → ViewState

private extension CameraSession.State {
    var toViewState: RootView.ViewState {
        switch self {
        case .idle: return .idle
        case .recording: return .recording
        case .finalizing: return .finalizing
        case .done(let url): return .done(url: url)
        case .failed(let msg): return .failed(msg)
        }
    }
}
