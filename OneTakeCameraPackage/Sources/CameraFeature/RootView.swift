// RootView.swift
// v0.0 PoC UI — one big red button, 30-second recording, file path on completion.

import SwiftUI

@MainActor
public struct RootView: View {

    @State private var session = CameraSession()
    @State private var viewState: ViewState = .idle
    @State private var permissionDenied = false
    @State private var selectedPreset: CompressorPreset = .studio
    @State private var levelMonitor = LevelMonitor()
    @State private var showRecordingList = false

    public init() {}

    // MARK: - View States

    enum ViewState {
        case idle
        case recording(secondsRemaining: Int)
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
        case .idle, .done, .failed: return true
        default: return false
        }
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Background layer: viewfinder when camera is available, otherwise simulator placeholder.
            if CameraSession.isCameraAvailable {
                ViewfinderView(session: session.captureSession)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                    Text("Camera unavailable (simulator?)")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
            }

            // Clip warning overlay: full-screen red border when post-DSP peak > -1 dBFS.
            ClipWarningOverlay(isVisible: levelMonitor.isClipping)

            // Recordings list button — top-right overlay.
            VStack {
                HStack {
                    Spacer()
                    Button {
                        showRecordingList = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 16)
                }
                Spacer()
            }

            // Foreground layer: status + record button.
            VStack(spacing: 32) {
                Spacer()

                statusText

                LevelMeterView(peakDB: levelMonitor.peakDB)
                    .padding(.horizontal, 24)

                PresetSelectorView(selection: $selectedPreset, isEnabled: isIdle)

                actionButton

                if case .done(let url) = viewState {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
        }
        .sheet(isPresented: $showRecordingList) {
            RecordingListView()
        }
        .alert("Permission Denied", isPresented: $permissionDenied) {
            Button("OK") {}
        } message: {
            Text("Camera and microphone access are required. Enable them in Settings.")
        }
        .task {
            session.onStateChange = { newState in
                viewState = newState.toViewState
            }
            // Prewarm: configure session + start preview before user taps record.
            if CameraSession.isCameraAvailable {
                let granted = await session.prewarm()
                if !granted {
                    permissionDenied = true
                } else {
                    // Start level meter now that audio is flowing.
                    levelMonitor.start(
                        reading: { [session] in session.currentAudioPeak() },
                        clipReading: { [session] in session.currentAudioClipped() }
                    )
                }
            }
        }
        .onDisappear {
            levelMonitor.stop()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusText: some View {
        switch viewState {
        case .idle:
            Text("Ready")
                .font(.title2)
                .foregroundStyle(.secondary)
        case .recording(let remaining):
            Text("\(remaining)s remaining")
                .font(.largeTitle.monospacedDigit())
                .foregroundStyle(.red)
        case .finalizing:
            Text("Finalizing…")
                .font(.title2)
                .foregroundStyle(.secondary)
        case .done:
            Text("Saved")
                .font(.title2)
                .foregroundStyle(.green)
        case .failed(let message):
            Text("Error: \(message)")
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        Button {
            handleButtonTap()
        } label: {
            Circle()
                .fill(isRecording ? Color.red.opacity(0.5) : Color.red)
                .frame(width: 80, height: 80)
                .overlay {
                    if case .finalizing = viewState {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: isRecording ? "record.circle.fill" : "record.circle")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                }
        }
        .disabled(!canTapButton)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record 30 seconds")
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
                session.start30SecondRecording(preset: selectedPreset)
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
        case .recording(let s): return .recording(secondsRemaining: s)
        case .finalizing: return .finalizing
        case .done(let url): return .done(url: url)
        case .failed(let msg): return .failed(msg)
        }
    }
}
