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
import UIKit

enum ChineseScript: String, CaseIterable, Identifiable, Sendable {
    case simplified
    case traditionalTaiwan
    case traditionalHongKong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simplified: return String(localized: "Simplified")
        case .traditionalTaiwan: return String(localized: "Traditional (Taiwan)")
        case .traditionalHongKong: return String(localized: "Traditional (Hong Kong)")
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

    /// The script for someone who has not picked one, from this device's
    /// settings.
    @MainActor
    static func systemDefault() -> ChineseScript {
        defaultScript(
            preferredLanguages: Locale.preferredLanguages,
            keyboardLanguages: UITextInputMode.activeInputModes.compactMap(\.primaryLanguage),
            region: Locale.current.region?.identifier
        )
    }

    /// In order of how much each signal says about the reader:
    /// 1. the first Chinese entry in the system's preferred languages;
    /// 2. the Chinese keyboards, when they all point the same way (Zhuyin and
    ///    Cangjie report zh-Hant, Pinyin zh-Hans, Cantonese yue-Hant);
    /// 3. the region, for Taiwan, Hong Kong and Macao;
    /// otherwise Simplified.
    static func defaultScript(preferredLanguages: [String], keyboardLanguages: [String], region: String?) -> ChineseScript {
        for identifier in preferredLanguages {
            if let script = script(forLanguage: identifier) { return script }
        }
        let keyboardScripts = Set(keyboardLanguages.compactMap(script(forLanguage:)))
        if keyboardScripts.count == 1, let script = keyboardScripts.first { return script }
        if keyboardScripts == [.traditionalTaiwan, .traditionalHongKong] { return .traditionalHongKong }
        switch region {
        case "HK", "MO": return .traditionalHongKong
        case "TW": return .traditionalTaiwan
        default: return .simplified
        }
    }

    /// nil for a language that is not Chinese.
    private static func script(forLanguage identifier: String) -> ChineseScript? {
        let language = Locale.Language(identifier: identifier)
        let code = language.languageCode?.identifier
        guard code == "zh" || code == "yue" else { return nil }
        let script = language.script?.identifier
        let region = language.region?.identifier
        if script == "Hans" { return .simplified }
        if region == "HK" || region == "MO" || code == "yue" { return .traditionalHongKong }
        if script == "Hant" || region == "TW" { return .traditionalTaiwan }
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
