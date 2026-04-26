//
//  DesignSystem.swift
//  Voicely
//
//  Shared visual tokens and reusable building blocks for the redesigned UI.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum VoicelyTheme {
    static let accent = Color.accentColor

    static func accentTint(_ opacity: Double = 1.0) -> Color {
        Color.accentColor.opacity(opacity)
    }

    static let surface = Color(UIColor.secondarySystemGroupedBackground)
    static let surfaceRaised = Color(UIColor.tertiarySystemGroupedBackground)
    static let groupedBackground = Color(UIColor.systemGroupedBackground)

    static let hairline = Color.primary.opacity(0.08)
    static let subtleBorder = Color.primary.opacity(0.05)

    static let cornerLarge: CGFloat = 20
    static let cornerMedium: CGFloat = 14
    static let cornerSmall: CGFloat = 10
}

// MARK: - Waveform Bars

struct WaveformBars: View {
    let seed: Int
    let progress: Double
    var barCount: Int = 80
    var activeTint: Color = .accentColor
    var inactiveTint: Color = .secondary
    var height: CGFloat = 52
    var onSeek: ((Double) -> Void)? = nil

    private var bars: [CGFloat] {
        WaveformBars.generate(seed: seed, count: barCount)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, h in
                    let pos = Double(index) / Double(max(barCount - 1, 1))
                    let played = pos <= progress
                    let near = abs(pos - progress) < 0.018
                    RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                        .fill(barColor(played: played, near: near))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, geo.size.height * h))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let onSeek else { return }
                        let ratio = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                        onSeek(Double(ratio))
                    }
            )
        }
        .frame(height: height)
    }

    private func barColor(played: Bool, near: Bool) -> Color {
        if near { return activeTint }
        if played { return activeTint.opacity(0.78) }
        return inactiveTint.opacity(0.35)
    }

    static func generate(seed: Int, count: Int) -> [CGFloat] {
        func rand(_ n: Int) -> CGFloat {
            let x = sin(Double(n) + 1) * 73856.0
            return CGFloat(x - x.rounded(.down))
        }
        let raw = (0..<count).map { rand(seed * 419 + $0) }
        return raw.enumerated().map { i, v in
            let a = raw[max(0, i - 2)]
            let b = raw[max(0, i - 1)]
            let c = raw[min(count - 1, i + 1)]
            return max(0.08, (a * 0.15 + b * 0.3 + v * 0.4 + c * 0.15) * 0.92 + 0.08)
        }
    }
}

// MARK: - Pill Badge

struct PillBadge: View {
    enum Variant {
        case neutral, accent, success, warning, info, danger
    }

    let text: String
    var systemImage: String? = nil
    var variant: Variant = .neutral

    private var tint: Color {
        switch variant {
        case .neutral:  return .secondary
        case .accent:   return .accentColor
        case .success:  return .green
        case .warning:  return .orange
        case .info:     return .blue
        case .danger:   return .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
    }
}

// MARK: - Card

struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    var corner: CGFloat = VoicelyTheme.cornerLarge
    var tint: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(VoicelyTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(tint?.opacity(0.25) ?? VoicelyTheme.subtleBorder, lineWidth: 1)
            )
    }
}

// MARK: - Uppercase section label

struct SectionHeaderLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .tracking(0.9)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - Circle icon button

struct CircleIconButton: View {
    let systemImage: String
    var size: CGFloat = 36
    var iconSize: Font = .subheadline
    var tint: Color = .primary
    var background: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(iconSize.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(background ?? Color.primary.opacity(0.06))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
