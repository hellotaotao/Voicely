//
//  ModelSelectionIndicator.swift
//  Voicely
//
//  Created by Claude on 6/22/2026.
//

import Foundation

/// Left-column status indicator in the model quick-picker — merges "downloaded" and "selected" into one icon.
enum ModelSelectionIndicator: Equatable {
    case downloadedSelected    // downloaded and selected
    case downloaded            // downloaded, not selected
    case selectedNotDownloaded // selected but not downloaded
    case hidden                // neither: no icon (a hidden placeholder keeps alignment)

    init(isDownloaded: Bool, isSelected: Bool) {
        switch (isDownloaded, isSelected) {
        case (true, true): self = .downloadedSelected
        case (true, false): self = .downloaded
        case (false, true): self = .selectedNotDownloaded
        case (false, false): self = .hidden
        }
    }

    /// SF Symbol name; nil means no icon (rendered as a hidden placeholder).
    /// Semantics: checkmark = selected, filled = downloaded; color reinforces it in the UI (green/blue/orange).
    var symbolName: String? {
        switch self {
        case .downloadedSelected: return "checkmark.circle.fill"
        case .downloaded: return "circle.fill"
        case .selectedNotDownloaded: return "checkmark.circle"
        case .hidden: return nil
        }
    }
}
