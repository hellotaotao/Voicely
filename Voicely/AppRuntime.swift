//
//  AppRuntime.swift
//  Voicely
//
//  Created by Codex on 3/12/2026.
//

import Foundation

enum AppRuntime {
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        let injectedLibraries = environment["DYLD_INSERT_LIBRARIES"] ?? ""

        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCODE_TEST_PLAN_NAME"] != nil
            || injectedLibraries.contains("XCTest")
            || injectedLibraries.contains("libXCTestBundleInject")
            || NSClassFromString("XCTestCase") != nil
    }

    /// Debug-only launch for screenshots: an in-memory library of invented
    /// notes read from `VOICELY_DEMO_DIR` (built by scripts/demo-library).
    static var isDemoMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["VOICELY_DEMO_DIR"] != nil
        #else
        false
        #endif
    }

    /// Tests and demo mode keep the library in memory and never touch the
    /// user's notes, audio files or iCloud.
    static var isIsolatedFromUserData: Bool {
        isRunningTests || isDemoMode
    }
}
