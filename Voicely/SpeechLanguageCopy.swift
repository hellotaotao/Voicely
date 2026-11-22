import Foundation

/// How the speech language choices read on screen. They are named for the
/// languages in a recording, never for the models, so choosing needs no idea
/// of what Qwen3-ASR or Parakeet is.
enum SpeechLanguageCopy {
    /// The choice's name in the language menu, Settings and the recording's
    /// language row.
    static func name(for key: String) -> String {
        Qwen3ASRDefaults.languageKey(key) == "english"
            ? String(localized: "English & European (faster)")
            : String(localized: "All supported languages")
    }

    /// What the choice does, under the picker in Settings and when asking
    /// whether to re-transcribe.
    static func description(for key: String) -> String {
        Qwen3ASRDefaults.languageKey(key) == "english"
            ? String(localized: "English and 24 European languages, mixed freely (like French with English). Choose it when nothing else is spoken.")
            : String(localized: "30+ languages, mixed freely. English and European passages automatically go to a more accurate model.")
    }

    static func retranscribeTitle(for key: String) -> String {
        Qwen3ASRDefaults.languageKey(key) == "english"
            ? String(localized: "Re-transcribe: English & European")
            : String(localized: "Re-transcribe: All supported languages")
    }
}
