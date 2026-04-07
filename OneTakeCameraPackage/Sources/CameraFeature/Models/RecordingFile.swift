import Foundation

public struct RecordingFile: Identifiable, Hashable, Sendable {
    public let id: URL
    public let url: URL
    public let displayName: String
    public let createdAt: Date
    public let sizeBytes: Int64

    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        self.id = url
        self.url = url
        self.displayName = url.deletingPathExtension().lastPathComponent
        self.createdAt = values.contentModificationDate ?? Date()
        self.sizeBytes = Int64(values.fileSize ?? 0)
    }

    public var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public enum RecordingStore {
    public static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static func listRecordings() -> [RecordingFile] {
        let fm = FileManager.default
        let docs = documentsURL()
        guard let files = try? fm.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .compactMap { try? RecordingFile(url: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static func delete(_ file: RecordingFile) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: file.url.deletingPathExtension().appendingPathExtension("json"))
        try fm.removeItem(at: file.url)
    }
}
