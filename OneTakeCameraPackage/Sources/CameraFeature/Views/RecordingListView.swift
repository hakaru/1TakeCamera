import Photos
import QuickLook
import SwiftUI
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "RecordingList")

public struct RecordingListView: View {
    @State private var recordings: [RecordingFile] = []
    @State private var previewURL: URL?
    @State private var saveAlert: SaveAlert?
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if recordings.isEmpty {
                    Text("No recordings yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recordings) { rec in
                        row(for: rec)
                    }
                    .onDelete(perform: deleteRows)
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { reload() }
            .quickLookPreview($previewURL)
            .alert(item: $saveAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func row(for rec: RecordingFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(rec.displayName).font(.headline)
                HStack(spacing: 12) {
                    Text(rec.createdAt, style: .date)
                    Text(rec.sizeString)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                saveToPhotos(rec)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            previewURL = rec.url
        }
    }

    private func reload() {
        recordings = RecordingStore.listRecordings()
    }

    private func deleteRows(_ offsets: IndexSet) {
        for i in offsets {
            let rec = recordings[i]
            do {
                try RecordingStore.delete(rec)
                logger.info("Deleted \(rec.displayName, privacy: .public)")
            } catch {
                logger.error("Delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        reload()
    }

    private func saveToPhotos(_ rec: RecordingFile) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    saveAlert = SaveAlert(title: "Permission denied", message: "Enable Photos access in Settings to save recordings.")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: rec.url)
            } completionHandler: { success, error in
                Task { @MainActor in
                    if success {
                        saveAlert = SaveAlert(title: "Saved to Photos", message: rec.displayName)
                    } else {
                        saveAlert = SaveAlert(title: "Save failed", message: error?.localizedDescription ?? "Unknown error")
                    }
                }
            }
        }
    }
}

private struct SaveAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
