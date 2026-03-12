//
//  DeviceIdentity.swift
//  Voicely
//
//  Created by Codex on 3/12/2026.
//

import Foundation

enum DeviceIdentity {
    private static let userDefaultsKey = "VoicelyDeviceIdentity"

    static var currentDeviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: userDefaultsKey), !existing.isEmpty {
            return existing
        }

        let newValue = UUID().uuidString
        defaults.set(newValue, forKey: userDefaultsKey)
        return newValue
    }
}
