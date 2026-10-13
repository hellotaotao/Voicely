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

    /// Hardware model identifier, e.g. "iPhone17,1" or "Mac15,6".
    static var hardwareModel: String {
        #if targetEnvironment(macCatalyst)
        let name = "hw.model"
        #else
        let name = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &value, &size, nil, 0)
        return String(cString: value)
    }
}
