import Foundation
import os

struct SegmentFailureRange: Codable, Equatable {
    var startFrame: Int64
    var endFrame: Int64
}

struct SegmentedTranscriptionProgress: Codable, Equatable {
    var lastFrame: Int64
    var totalFrames: Int64
    var accumulatedText: String
    var failedRanges: [SegmentFailureRange]
    var updatedAt: Date
}

/// Durable on-disk state for in-flight imported-audio transcriptions:
/// a JSON sidecar per note plus the throwaway audio working copy. Lives in a
/// non-synced, backup-excluded directory so half-done work never reaches iCloud.
final class SegmentProgressStore {
    let directory: URL
    private let fileManager = FileManager.default
    private let inProgressNoteIDs = OSAllocatedUnfairLock(initialState: Set<UUID>())

    init(rootDirectory: URL? = nil) {
        let base = rootDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SegmentedTranscription", isDirectory: true)
        self.directory = base
        createDirectoryIfNeeded()
    }

    private func createDirectoryIfNeeded() {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func sidecarURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func load(for id: UUID) -> SegmentedTranscriptionProgress? {
        guard let data = try? Data(contentsOf: sidecarURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(SegmentedTranscriptionProgress.self, from: data)
    }

    func save(_ progress: SegmentedTranscriptionProgress, for id: UUID) {
        createDirectoryIfNeeded()
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: sidecarURL(for: id), options: .atomic)
    }

    func delete(for id: UUID) {
        try? fileManager.removeItem(at: sidecarURL(for: id))
    }

    func workingCopyURL(for id: UUID, fileExtension: String) -> URL {
        let ext = fileExtension.isEmpty ? "audio" : fileExtension
        return directory.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    func existingWorkingCopyURL(for id: UUID) -> URL? {
        let prefix = id.uuidString + "."
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let name = entries.first(where: { $0.hasPrefix(prefix) && !$0.hasSuffix(".json") })
        else { return nil }
        return directory.appendingPathComponent(name)
    }

    func listPendingNoteIDs() -> [UUID] {
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
    }

    /// Copies the shared (security-scoped) source file into the non-synced
    /// working directory so transcription has a stable, controllable copy.
    func importWorkingCopy(from sourceURL: URL, for id: UUID) throws -> URL {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        createDirectoryIfNeeded()
        let destination = workingCopyURL(for: id, fileExtension: sourceURL.pathExtension)
        try? fileManager.removeItem(at: destination)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: sourceURL, options: [.withoutChanges], error: &coordinationError
        ) { readableURL in
            do { try fileManager.copyItem(at: readableURL, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }

    func removeWorkingCopy(for id: UUID) {
        if let url = existingWorkingCopyURL(for: id) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Marks a note as actively transcribing. Returns false if a run is already
    /// in progress for it, so callers can avoid starting a duplicate (e.g. an
    /// import racing a scene-activation resume).
    func beginTranscribing(_ id: UUID) -> Bool {
        inProgressNoteIDs.withLock { ids in
            guard !ids.contains(id) else { return false }
            ids.insert(id)
            return true
        }
    }

    func endTranscribing(_ id: UUID) {
        inProgressNoteIDs.withLock { _ = $0.remove(id) }
    }
}
