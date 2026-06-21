//
//  ModelSupportPolicyTests.swift
//  VoicelyTests
//
//  Created by Claude on 6/22/2026.
//

import Foundation
import Testing
@testable import Voicely

struct ModelSupportPolicyTests {

    // MARK: - isEnglishOnly

    @Test func enSuffixModelsAreEnglishOnly() {
        #expect(ModelManager.isEnglishOnly("openai_whisper-tiny.en"))
        #expect(ModelManager.isEnglishOnly("openai_whisper-base.en"))
        #expect(ModelManager.isEnglishOnly("openai_whisper-small.en"))
        #expect(ModelManager.isEnglishOnly("openai_whisper-small.en_217MB"))
        #expect(ModelManager.isEnglishOnly("openai_whisper-medium.en"))
    }

    @Test func distilModelsAreEnglishOnly() {
        #expect(ModelManager.isEnglishOnly("distil-whisper_distil-large-v3"))
        #expect(ModelManager.isEnglishOnly("distil-whisper_distil-large-v3_turbo_600MB"))
    }

    @Test func multilingualModelsAreNotEnglishOnly() {
        #expect(!ModelManager.isEnglishOnly("openai_whisper-small"))
        #expect(!ModelManager.isEnglishOnly("openai_whisper-small_216MB"))
        #expect(!ModelManager.isEnglishOnly("openai_whisper-medium"))
        #expect(!ModelManager.isEnglishOnly("openai_whisper-large-v3"))
        #expect(!ModelManager.isEnglishOnly("openai_whisper-large-v3_turbo_954MB"))
    }

    // MARK: - isUnsupportedModel (从模型列表移除)

    @Test func distilModelsAreUnsupported() {
        #expect(ModelManager.isUnsupportedModel("distil-whisper_distil-large-v3"))
        #expect(ModelManager.isUnsupportedModel("distil-whisper_distil-large-v3_594MB"))
        #expect(ModelManager.isUnsupportedModel("distil-whisper_distil-large-v3_turbo"))
        #expect(ModelManager.isUnsupportedModel("distil-whisper_distil-large-v3_turbo_600MB"))
    }

    @Test func mediumEnglishOnlyIsUnsupported() {
        #expect(ModelManager.isUnsupportedModel("openai_whisper-medium.en"))
    }

    @Test func keptEnglishOnlyModelsRemainSupported() {
        #expect(!ModelManager.isUnsupportedModel("openai_whisper-tiny.en"))
        #expect(!ModelManager.isUnsupportedModel("openai_whisper-base.en"))
        #expect(!ModelManager.isUnsupportedModel("openai_whisper-small.en"))
        #expect(!ModelManager.isUnsupportedModel("openai_whisper-small.en_217MB"))
    }

    @Test func multilingualModelsRemainSupported() {
        #expect(!ModelManager.isUnsupportedModel("openai_whisper-small"))
        #expect(!ModelManager.isUnsupportedModel("openai_whisper-medium"))
        #expect(!ModelManager.isUnsupportedModel("openai_whisper-large-v3"))
        #expect(!ModelManager.isUnsupportedModel("openai_whisper-large-v3_turbo_954MB"))
        #expect(!ModelManager.isUnsupportedModel("openai_whisper-large-v2_turbo"))
    }

    // MARK: - displayNameWithLanguageTag

    @Test func englishOnlyModelDisplayNameGetsTag() {
        let model = "openai_whisper-tiny.en"
        #expect(ModelManager.displayNameWithLanguageTag(for: model)
            == ModelManager.displayName(for: model) + " (English Only)")
    }

    @Test func multilingualModelDisplayNameHasNoTag() {
        let model = "openai_whisper-small"
        #expect(ModelManager.displayNameWithLanguageTag(for: model)
            == ModelManager.displayName(for: model))
        #expect(!ModelManager.displayNameWithLanguageTag(for: model).contains("English Only"))
    }
}
