//
//  ChineseScript.swift
//  Voicely
//
//  Which Chinese characters transcripts are shown in. Notes keep the text the
//  engine wrote (Qwen3-ASR writes Simplified); conversion happens only when
//  text is shown, copied or shared, so the setting can change at any time and
//  devices that sync the same notes can each use their own.
//

import Foundation
import Observation

enum ChineseScript: String, CaseIterable, Identifiable, Sendable {
    case simplified
    case traditionalTaiwan
    case traditionalHongKong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simplified: return "Simplified"
        case .traditionalTaiwan: return "Traditional (Taiwan)"
        case .traditionalHongKong: return "Traditional (Hong Kong)"
        }
    }

    /// nil when transcripts are shown as written.
    var converterTarget: ChineseScriptConverter.Target? {
        switch self {
        case .simplified: return nil
        case .traditionalTaiwan: return .taiwan
        case .traditionalHongKong: return .hongKong
        }
    }

    /// Follows the first Chinese entry in the system's preferred languages:
    /// Hong Kong and Macao get Hong Kong forms, any other Traditional Chinese
    /// gets Taiwan forms, everything else Simplified.
    static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> ChineseScript {
        for identifier in preferredLanguages {
            let language = Locale.Language(identifier: identifier)
            guard language.languageCode?.identifier == "zh" else { continue }
            let region = language.region?.identifier
            if region == "HK" || region == "MO" { return .traditionalHongKong }
            if language.script?.identifier == "Hant" || region == "TW" { return .traditionalTaiwan }
            return .simplified
        }
        return .simplified
    }
}

/// The user's choice, observed by every view that shows transcript text.
@MainActor
@Observable
final class ChineseScriptSetting {
    static let shared = ChineseScriptSetting()
    static let defaultsKey = "chineseScript"

    private let defaults: UserDefaults

    /// Until the user picks one, the script follows the system language.
    var script: ChineseScript {
        didSet { defaults.set(script.rawValue, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        script = defaults.string(forKey: Self.defaultsKey).flatMap(ChineseScript.init(rawValue:))
            ?? ChineseScript.systemDefault()
    }

    /// `text` in the chosen script, with every character where it was, so
    /// timeline and search ranges into the stored text still apply.
    func display(_ text: String) -> String {
        guard let target = script.converterTarget else { return text }
        return ChineseScriptConverter.shared(target).convertKeepingLength(text)
    }
}

extension VoiceNote {
    @MainActor var displayTitle: String { ChineseScriptSetting.shared.display(title) }
    @MainActor var displayTranscription: String { ChineseScriptSetting.shared.display(transcription) }
}
