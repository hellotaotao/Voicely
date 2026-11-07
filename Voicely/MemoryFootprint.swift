//
//  MemoryFootprint.swift
//  Voicely
//
//  Reads the process's physical memory footprint, the figure iOS compares
//  against its per-app limit before it kills an app. Logged in Release next to
//  model loads and decodes so device logs (`log collect`) show load times and
//  peak memory without attaching Xcode.
//

import Darwin
import os

enum MemoryFootprint {
    static let log = Logger(subsystem: "com.hellotaotao.Voicely", category: "Memory")

    /// Current and lifetime-peak footprint in megabytes, or nil if the kernel
    /// call fails.
    static func megabytes() -> (current: Int, peak: Int)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let mb = { (bytes: UInt64) in Int(bytes / 1_048_576) }
        return (mb(info.phys_footprint), mb(UInt64(max(info.ledger_phys_footprint_peak, 0))))
    }

    /// "footprintMB=… peakMB=…" for appending to a log line.
    static var summary: String {
        guard let value = megabytes() else { return "footprintMB=? peakMB=?" }
        return "footprintMB=\(value.current) peakMB=\(value.peak)"
    }

    /// Logs one event with the current and peak footprint.
    static func record(_ event: String, seconds: Double? = nil) {
        let timing = seconds.map { String(format: " seconds=%.2f", $0) } ?? ""
        log.notice("event=\(event, privacy: .public)\(timing, privacy: .public) \(summary, privacy: .public)")
    }
}
