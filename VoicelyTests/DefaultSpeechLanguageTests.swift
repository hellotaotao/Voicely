import Testing
@testable import Voicely

struct DefaultSpeechLanguageTests {
    /// Only English and European languages on the device: Parakeet alone.
    @Test(arguments: [
        ["en-AU"],
        ["en-US", "de-DE", "fr-FR"],
        ["pl-PL", "en-GB", "uk-UA"],
        ["el-GR", "pt-BR"],
    ])
    func englishAndEuropeanOnlyStartWithParakeet(languages: [String]) {
        #expect(DefaultSpeechLanguage.key(forLanguages: languages) == "english")
    }

    /// Any other language, such as a Chinese keyboard next to English, keeps
    /// Qwen3-ASR first; so does nothing to go by.
    @Test(arguments: [
        ["en-AU", "zh-Hans"],
        ["zh-Hans"],
        ["en-US", "ja-JP"],
        ["ko-KR"],
        ["de-DE", "tr-TR"],
        ["en-US", "ar"],
        ["nb-NO"],
        [],
    ])
    func anyOtherLanguageStartsWithQwen(languages: [String]) {
        #expect(DefaultSpeechLanguage.key(forLanguages: languages) == "auto")
    }
}
