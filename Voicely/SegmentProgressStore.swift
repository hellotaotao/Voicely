import CryptoKit
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

struct RetainedTranscriptionAttempt: Codable, Equatable, Identifiable {
    let id: String
    let progress: SegmentedTranscriptionProgress

    var text: String { progress.accumulatedText }
    var updatedAt: Date { progress.updatedAt }
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

    private func retainedAttemptsDirectory(for id: UUID) -> URL {
        directory.appendingPathComponent("retained-attempts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func listRetainedAttempts(for id: UUID) -> [RetainedTranscriptionAttempt] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: retainedAttemptsDirectory(for: id), includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> RetainedTranscriptionAttempt? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RetainedTranscriptionAttempt.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Preserve a checkpoint before resetting an attempt. Corrupt checkpoints
    /// are retained as raw bytes for diagnosis, not presented as readable text.
    /// Any archive write failure must prevent destructive reset.
    func archiveProgressIfNeeded(for id: UUID) throws {
        let source = sidecarURL(for: id)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let original = try Data(contentsOf: source)
        let progress: SegmentedTranscriptionProgress
        do {
            progress = try JSONDecoder().decode(SegmentedTranscriptionProgress.self, from: original)
        } catch {
            let folder = retainedAttemptsDirectory(for: id)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let key = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            try original.write(to: folder.appendingPathComponent(key + ".raw"), options: .atomic)
            return
        }
        guard !progress.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(progress)
        let key = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let folder = retainedAttemptsDirectory(for: id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(key + ".json")
        let snapshot = RetainedTranscriptionAttempt(id: key, progress: progress)
        // Atomic replacement also repairs an interrupted/corrupt previous copy.
        try encoder.encode(snapshot).write(to: destination, options: .atomic)
    }

    func resetProgressPreservingAttempt(for id: UUID) throws {
        try archiveProgressIfNeeded(for: id)
        let source = sidecarURL(for: id)
        if fileManager.fileExists(atPath: source.path) {
            try fileManager.removeItem(at: source)
        }
    }

    /// Only explicit note deletion removes retained results, never run cleanup.
    func deleteRetainedAttempts(for id: UUID) {
        try? fileManager.removeItem(at: retainedAttemptsDirectory(for: id))
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
        return Array(Set(entries.compactMap { name in
            UUID(uuidString: (name as NSString).deletingPathExtension)
        }))
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
