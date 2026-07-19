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

    @Test func multilingualModelsAreNotEnglishOnly() {
        #expect(!ModelManager.isEnglishOnly("openai_whisper-small"))
        #expect(!ModelManager.isEnglishOnly("openai_whisper-small_216MB"))
        #expect(!ModelManager.isEnglishOnly("openai_whisper-medium"))
        #expect(!ModelManager.isEnglishOnly("openai_whisper-large-v3"))
        #expect(!ModelManager.isEnglishOnly("openai_whisper-large-v3-v20240930_626MB"))
    }

    // MARK: - Curated allow-list

    @Test func curatedListIsExactlyTheOfferedModels() {
        #expect(ModelManager.curatedIdentifiers == [
            "openai_whisper-small",
            "openai_whisper-base",
            "openai_whisper-small.en_217MB",
        ])
    }

    @Test func curatedModelsCarryExpectedTiers() {
        #expect(ModelManager.curatedModel(for: "openai_whisper-base")?.tier == .lite)
        #expect(ModelManager.curatedModel(for: "openai_whisper-small")?.tier == .standard)
        #expect(ModelManager.curatedModel(for: "openai_whisper-small.en_217MB")?.isEnglishOnly == true)
        #expect(ModelManager.curatedModel(for: "openai_whisper-small")?.isEnglishOnly == false)
    }

    @Test func droppedModelsAreNotCurated() {
        #expect(ModelManager.curatedModel(for: "openai_whisper-tiny") == nil)
        #expect(ModelManager.curatedModel(for: "openai_whisper-medium") == nil)
        #expect(ModelManager.curatedModel(for: "openai_whisper-large-v2_turbo") == nil)
        #expect(ModelManager.curatedModel(for: "distil-whisper_distil-large-v3") == nil)
        #expect(ModelManager.curatedModel(for: "openai_whisper-large-v3") == nil)
        #expect(ModelManager.curatedModel(for: "openai_whisper-medium.en") == nil)
    }

    /// The v20240930 turbo builds blank-decode on Apple Silicon Macs (every slice
    /// returns 0 segments in well under a second; A/B verified against the
    /// previous-generation 954MB build and against the full-precision 1.62 GB
    /// original, so it isn't quantization). Whisper is now the fallback engine
    /// behind Qwen3, so the large tier was retired rather than special-cased.
    @Test func retiredTurboModelsAreGone() {
        #expect(ModelManager.curatedModel(for: "openai_whisper-large-v3-v20240930_626MB") == nil)
        #expect(ModelManager.curatedModel(for: "openai_whisper-large-v3-v20240930_turbo_632MB") == nil)
        #expect(ModelManager.isRetiredModel("openai_whisper-large-v3-v20240930_626MB"))
        #expect(ModelManager.isRetiredModel("openai_whisper-large-v3-v20240930_turbo_632MB"))
        #expect(!ModelManager.isRetiredModel("openai_whisper-small"))
    }

    /// Existing installs have a retired identifier saved in UserDefaults; leaving
    /// it selected would keep a model that cannot transcribe on Mac as the active
    /// engine, so the saved value migrates to the platform default.
    @Test func retiredSavedSelectionMigratesToDefault() {
        #expect(ModelManager.migratedSelection(saved: "openai_whisper-large-v3-v20240930_626MB")
                == ModelManager.platformDefaultModel)
        #expect(ModelManager.migratedSelection(saved: "openai_whisper-large-v3-v20240930_turbo_632MB")
                == ModelManager.platformDefaultModel)
        #expect(ModelManager.migratedSelection(saved: "") == ModelManager.platformDefaultModel)
        #expect(ModelManager.migratedSelection(saved: nil) == ModelManager.platformDefaultModel)
        // A still-supported choice is preserved.
        #expect(ModelManager.migratedSelection(saved: "openai_whisper-base") == "openai_whisper-base")
    }

    @Test func curatedMultilingualModelsAreOrderedHighToLow() {
        let dots = ModelManager.curatedModels.filter { !$0.isEnglishOnly }.map(\.tier.filledDots)
        #expect(dots == [2, 1])
    }

    // MARK: - Performance tier indicator

    @Test func performanceTierDotsAndLabels() {
        #expect(ModelManager.PerformanceTier.lite.filledDots == 1)
        #expect(ModelManager.PerformanceTier.standard.filledDots == 2)
        #expect(ModelManager.PerformanceTier.pro.filledDots == 3)
        #expect(ModelManager.PerformanceTier.lite.label == "LITE")
        #expect(ModelManager.PerformanceTier.standard.label == "STANDARD")
        #expect(ModelManager.PerformanceTier.pro.label == "PRO")
        #expect(ModelManager.PerformanceTier.lite.displayName == "Lite")
        #expect(ModelManager.PerformanceTier.standard.displayName == "Standard")
        #expect(ModelManager.PerformanceTier.pro.displayName == "Pro")
        #expect(ModelManager.PerformanceTier.proFast.filledDots == 3)
        #expect(ModelManager.PerformanceTier.proFast.label == "PRO FAST")
        #expect(ModelManager.PerformanceTier.proFast.displayName == "Pro Fast")
    }

    // MARK: - Device default

    /// Whisper is the fallback engine now, so every device gets Standard (Small);
    /// the per-device Pro/Standard split went away with the large tier.
    @Test func everyDeviceDefaultsToStandard() {
        #expect(ModelManager.platformDefaultModel == "openai_whisper-small")
        #expect(ModelManager.curatedModel(for: ModelManager.platformDefaultModel)?.tier == .standard)
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
    // MARK: - pickerTitle format ("Tier (Model)")

    @Test func pickerTitleShowsTierThenModelName() {
        #expect(ModelManager.pickerTitle(for: "openai_whisper-base") == "Lite (Base)")
        #expect(ModelManager.pickerTitle(for: "openai_whisper-small") == "Standard (Small)")
        #expect(ModelManager.pickerTitle(for: "openai_whisper-small.en_217MB") == "Standard (Small, English)")
    }

    // MARK: - Download size labels

    @Test func curatedModelsCarrySizeLabels() {
        #expect(ModelManager.curatedModel(for: "openai_whisper-base")?.sizeLabel == "147 MB")
        #expect(ModelManager.curatedModel(for: "openai_whisper-small")?.sizeLabel == "486 MB")
        #expect(ModelManager.curatedModel(for: "openai_whisper-small.en_217MB")?.sizeLabel == "218 MB")
    }
}
