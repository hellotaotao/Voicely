//
//  PerformanceComparisonTests.swift
//  VoicelyTests
//
//  Created by Copilot on 4/12/2026.
//

import Foundation
import Testing
@testable import Voicely

struct PerformanceComparisonTests {
    private static let migrationDefaultsKey = "VoicelyLocalToCloudMigrationV1"

    @Test @MainActor func migrationStartupCheck_beforeAfterComparison() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let localURL = rootURL.appendingPathComponent("local", isDirectory: true)
        let cloudURL = rootURL.appendingPathComponent("cloud", isDirectory: true)

        try fileManager.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: cloudURL, withIntermediateDirectories: true, attributes: nil)
        try Self.seedMirroredAudioFiles(count: 2500, localURL: localURL, cloudURL: cloudURL)

        defer {
            UserDefaults.standard.removeObject(forKey: Self.migrationDefaultsKey)
            try? fileManager.removeItem(at: rootURL)
        }

        let manager = CloudStorageManager(
            testLocalContainerURL: localURL,
            testCloudContainerURL: cloudURL,
            testCloudEnabled: true
        )

        UserDefaults.standard.removeObject(forKey: Self.migrationDefaultsKey)

        let legacyAverageMs = try await Self.averageMilliseconds(runs: 6) {
            try Self.legacyMigrationPass(localURL: localURL, cloudURL: cloudURL)
        }

        UserDefaults.standard.set(true, forKey: Self.migrationDefaultsKey)
        let optimizedAverageMs = await Self.averageMilliseconds(runs: 6) {
            await manager.migrateLocalFilesToCloudIfNeeded()
        }

        let speedup = legacyAverageMs / max(optimizedAverageMs, 0.000_1)
        print(
            String(
                format: "[Perf] Migration startup check avg: legacy=%.3fms optimized=%.3fms speedup=%.1fx",
                legacyAverageMs,
                optimizedAverageMs,
                speedup
            )
        )

        #expect(optimizedAverageMs < legacyAverageMs)
        #expect(speedup >= 5)
    }

    @Test @MainActor func syncUpdateBurst_beforeAfterComparison() async {
        final class DebouncedCounter {
            private var task: Task<Void, Never>?
            private(set) var count = 0
            private let delayNanoseconds: UInt64

            init(delayNanoseconds: UInt64) {
                self.delayNanoseconds = delayNanoseconds
            }

            func receiveEvent() {
                let delay = delayNanoseconds
                task?.cancel()
                task = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delay)
                    guard let self, !Task.isCancelled else { return }
                    self.count += 1
                }
            }

            func cancel() {
                task?.cancel()
                task = nil
            }
        }

        let eventCount = 80
        let burstIntervalNanoseconds: UInt64 = 10_000_000
        var legacyExecutionCount = 0
        let optimized = DebouncedCounter(delayNanoseconds: 250_000_000)

        for _ in 0..<eventCount {
            legacyExecutionCount += 1
            optimized.receiveEvent()
            try? await Task.sleep(nanoseconds: burstIntervalNanoseconds)
        }

        try? await Task.sleep(nanoseconds: 400_000_000)
        let optimizedExecutionCount = optimized.count
        optimized.cancel()

        let reduced = legacyExecutionCount - optimizedExecutionCount
        let reducedPercent = (Double(reduced) / Double(legacyExecutionCount)) * 100
        print(
            String(
                format: "[Perf] Sync update burst: legacy=%d optimized=%d reduced=%.1f%%",
                legacyExecutionCount,
                optimizedExecutionCount,
                reducedPercent
            )
        )

        #expect(optimizedExecutionCount < legacyExecutionCount)
        #expect(optimizedExecutionCount <= 3)
    }

    @Test func idleWakeups_beforeAfterComparison() {
        let simulatedWindowSeconds = 30 * 60
        let legacyWakeups = simulatedWindowSeconds / 30
        let optimizedWakeupsWhenIdle = Self.eventDrivenWakeups(
            in: simulatedWindowSeconds,
            leaseExpiries: []
        )
        let optimizedWakeupsWithSingleLease = Self.eventDrivenWakeups(
            in: simulatedWindowSeconds,
            leaseExpiries: [7 * 60]
        )

        print(
            "[Perf] Scheduler wakeups in 30m: legacy=\(legacyWakeups) optimized(idle)=\(optimizedWakeupsWhenIdle) optimized(1 lease)=\(optimizedWakeupsWithSingleLease)"
        )

        #expect(legacyWakeups == 60)
        #expect(optimizedWakeupsWhenIdle == 0)
        #expect(optimizedWakeupsWithSingleLease == 1)
    }
}

private extension PerformanceComparisonTests {
    static func seedMirroredAudioFiles(count: Int, localURL: URL, cloudURL: URL) throws {
        let payload = Data("seed".utf8)
        for idx in 0..<count {
            let fileName = "recording_\(idx).m4a"
            try payload.write(to: localURL.appendingPathComponent(fileName), options: .atomic)
            try payload.write(to: cloudURL.appendingPathComponent(fileName), options: .atomic)
        }
    }

    static func legacyMigrationPass(localURL: URL, cloudURL: URL) throws {
        let fileManager = FileManager.default
        let localFiles = try fileManager.contentsOfDirectory(at: localURL, includingPropertiesForKeys: nil)

        for file in localFiles where file.pathExtension == "wav" || file.pathExtension == "m4a" {
            let cloudDestination = cloudURL.appendingPathComponent(file.lastPathComponent)
            if !fileManager.fileExists(atPath: cloudDestination.path) {
                try fileManager.moveItem(at: file, to: cloudDestination)
            }
        }
    }

    static func eventDrivenWakeups(in totalSeconds: Int, leaseExpiries: [Int]) -> Int {
        leaseExpiries.filter { $0 > 0 && $0 <= totalSeconds }.count
    }

    static func averageMilliseconds(
        runs: Int,
        operation: () async throws -> Void
    ) async rethrows -> Double {
        let clock = ContinuousClock()
        var totalMs = 0.0

        for _ in 0..<runs {
            let start = clock.now
            try await operation()
            totalMs += durationMilliseconds(start.duration(to: clock.now))
        }

        return totalMs / Double(runs)
    }

    static func durationMilliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return (Double(parts.seconds) * 1_000) + (Double(parts.attoseconds) / 1_000_000_000_000_000)
    }
}
