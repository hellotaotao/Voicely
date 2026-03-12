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
}
