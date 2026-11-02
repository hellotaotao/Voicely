//
//  SearchMatchBar.swift
//  Voicely
//
//  Floats over a note while the library is searched: where the current
//  match is among all of them, and buttons to step between them.
//

import SwiftUI

struct SearchMatchBar: View {
    let current: Int
    let count: Int
    /// The search stopped counting at `NoteSearch.matchLimit`.
    let isCapped: Bool
    let onStep: (Int) -> Void

    private var label: String {
        guard count > 0 else { return "Only the title matches" }
        return "\(current + 1) of \(count)\(isCapped ? "+" : "")"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.footnote.weight(.medium))
                .monospacedDigit()

            if count > 0 {
                Divider().frame(height: 16)
                Button { onStep(-1) } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .accessibilityLabel("Previous match")
                Button { onStep(1) } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .keyboardShortcut("g", modifiers: .command)
                .accessibilityLabel("Next match")
            }
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, 14)
        .padding(.trailing, count > 0 ? 6 : 14)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(VoicelyTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.Detail.searchMatchBar)
    }
}
