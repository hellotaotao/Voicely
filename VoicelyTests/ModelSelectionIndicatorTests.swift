//
//  ModelSelectionIndicatorTests.swift
//  VoicelyTests
//
//  Created by Claude on 6/22/2026.
//

import Foundation
import Testing
@testable import Voicely

struct ModelSelectionIndicatorTests {
    @Test func downloadedAndSelected() {
        let indicator = ModelSelectionIndicator(isDownloaded: true, isSelected: true)
        #expect(indicator == .downloadedSelected)
        #expect(indicator.symbolName == "checkmark.circle.fill")
    }

    @Test func downloadedButNotSelected() {
        let indicator = ModelSelectionIndicator(isDownloaded: true, isSelected: false)
        #expect(indicator == .downloaded)
        #expect(indicator.symbolName == "circle.fill")
    }

    @Test func selectedButNotDownloaded() {
        let indicator = ModelSelectionIndicator(isDownloaded: false, isSelected: true)
        #expect(indicator == .selectedNotDownloaded)
        #expect(indicator.symbolName == "checkmark.circle")
    }

    @Test func neitherDownloadedNorSelectedHasNoIcon() {
        let indicator = ModelSelectionIndicator(isDownloaded: false, isSelected: false)
        #expect(indicator == .hidden)
        #expect(indicator.symbolName == nil)
    }
}
