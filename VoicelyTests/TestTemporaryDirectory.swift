import Darwin
import Foundation

/// One scratch directory per test process, under `<tmp>/voicely-tests/`, for the
/// fixture files test helpers write. The process holds an exclusive lock on it and
/// removes it at exit; a run that dies without exiting leaves its directory
/// unlocked, and the next run removes it. Concurrent runs keep their locks, so
/// they never remove each other's files.
///
/// Opt-in replay inputs (`voicely-replay`, `voicely-lid`, …) live next to this
/// directory, not inside it, and are never touched.
enum TestTemporaryDirectory {
    static let url: URL = makeRunDirectory()

    /// A fresh file URL inside the run directory: `<prefix><uuid>.<ext>`.
    static func fileURL(prefix: String, extension ext: String) -> URL {
        url.appendingPathComponent("\(prefix)\(UUID().uuidString).\(ext)")
    }

    /// A fresh, not yet created directory URL inside the run directory.
    static func directoryURL(prefix: String) -> URL {
        url.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
    }

    private static let lockName = ".lock"

    private static func makeRunDirectory() -> URL {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent("voicely-tests", isDirectory: true)
        try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        removeAbandonedRuns(in: parent)

        let run = parent.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: run, withIntermediateDirectories: true)
        // Held open (and locked) for the life of the process; the kernel drops the
        // lock when the process dies, however it dies.
        let descriptor = open(run.appendingPathComponent(lockName).path, O_CREAT | O_RDWR, 0o644)
        if descriptor >= 0 { _ = flock(descriptor, LOCK_EX | LOCK_NB) }
        atexit { try? FileManager.default.removeItem(at: TestTemporaryDirectory.url) }
        return run
    }

    private static func removeAbandonedRuns(in parent: URL) {
        let fileManager = FileManager.default
        let runs = (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        for run in runs where run.lastPathComponent.hasPrefix("run-") {
            let descriptor = open(run.appendingPathComponent(lockName).path, O_RDWR)
            if descriptor < 0 {
                // No lock file: a run that died before creating it, or one creating
                // it right now — only the former is old.
                let modified = (try? run.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified.timeIntervalSinceNow < -60 { try? fileManager.removeItem(at: run) }
                continue
            }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }   // still running
            try? fileManager.removeItem(at: run)
        }
    }
}
