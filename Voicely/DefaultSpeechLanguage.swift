import Foundation
import UIKit

/// The speech language choice a device starts with, until the user picks one.
///
/// English & European (Parakeet alone) when every language the device is set
/// up for, in its preferred languages and its keyboards, is one Parakeet Ultra
/// knows; All supported languages (Qwen3-ASR first) as soon as one is not.
/// The rule leans to Qwen3-ASR because the two mistakes cost differently: a
/// wrong Qwen3-ASR default only takes longer, since Parakeet still takes the
/// passages in its languages, while a wrong Parakeet default turns Chinese
/// into Latin gibberish that nothing downstream can tell from English.
enum DefaultSpeechLanguage {
    /// The setting's key for `languages`, as language identifiers ("en-AU",
    /// "zh-Hans"). Nothing to go by is Qwen3-ASR.
    static func key(forLanguages languages: [String]) -> String {
        let codes = languages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        let parakeetOnly = !codes.isEmpty && codes.allSatisfy(EnglishStretchRouting.parakeetLanguageCodes.contains)
        return parakeetOnly ? "english" : "auto"
    }

    /// The preferred languages and the languages of the enabled keyboards.
    @MainActor static func deviceLanguages() -> [String] {
        let keyboards = UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
            .filter { $0 != "emoji" && $0 != "dictation" }
        return Locale.preferredLanguages + keyboards
    }

    /// Makes the device's default the setting's value until the user picks one.
    @MainActor static func register(in defaults: UserDefaults = .standard) {
        let languages = deviceLanguages()
        let key = key(forLanguages: languages)
        defaults.register(defaults: [Qwen3ASRDefaults.selectedLanguageKey: key])
        debugLog("🔍 [Language] default=\(key) from \(languages)")
    }
}
