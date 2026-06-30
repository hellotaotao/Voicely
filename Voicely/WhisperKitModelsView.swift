//
//  WhisperKitModelsView.swift
//  Voicely
//

import SwiftUI
import WhisperKit

struct WhisperKitModelsView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @State private var deviceDefault: String = ""
    @State private var supportedModels: [String] = []
    @State private var disabledModels: [String] = []
    @State private var isLoading = true
    @State private var fetchError: String?

    private var modelActionIsBusy: Bool {
        switch modelManager.modelState {
        case .loading, .downloading, .prewarming:
            return true
        case .loaded, .unloaded:
            return false
        }
    }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Fetching device recommendations...")
                        .foregroundColor(.secondary)
                }
            } else if let error = fetchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
            } else {
                if !supportedModels.isEmpty {
                    Section("Supported on This Device (\(supportedModels.count))") {
                        ForEach(supportedModels, id: \.self) { model in
                            ModelRecommendationRow(
                                model: model,
                                isSelected: model == modelManager.selectedModel,
                                isAvailableOffline: modelManager.isModelAvailableOffline(model),
                                isDeviceDefault: model == deviceDefault,
                                isBusy: modelActionIsBusy,
                                isDisabled: false,
                                action: {
                                    selectModel(model)
                                }
                            )
                        }
                    }
                }
                if !disabledModels.isEmpty {
                    Section("Disabled for This Device (\(disabledModels.count))") {
                        ForEach(disabledModels, id: \.self) { model in
                            ModelRecommendationRow(
                                model: model,
                                isSelected: false,
                                isAvailableOffline: modelManager.isModelAvailableOffline(model),
                                isDeviceDefault: model == deviceDefault,
                                isBusy: true,
                                isDisabled: true,
                                action: {}
                            )
                        }
                    }
                }
                if supportedModels.isEmpty && disabledModels.isEmpty {
                    Text("No model data returned. Check your network connection.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Speech Models")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadRecommendations()
        }
    }

    private func loadRecommendations() async {
        isLoading = true
        fetchError = nil
        deviceDefault = ModelManager.platformDefaultModel
        let remote = await WhisperKit.recommendedRemoteModels()
        // Curated allow-list only, ordered high -> low performance.
        let order = ModelManager.curatedModels.map(\.identifier)
        supportedModels = order.filter { remote.supported.contains($0) }
        disabledModels = order.filter { remote.disabled.contains($0) }
        isLoading = false
    }

    private func selectModel(_ model: String) {
        guard !modelActionIsBusy else { return }

        if modelManager.selectedModel != model {
            modelManager.selectedModel = model
        }

        modelManager.modelState = .unloaded
        modelManager.errorMessage = nil

        Task {
            await modelManager.loadModel(model)
        }
    }
}

private struct ModelRecommendationRow: View {
    let model: String
    let isSelected: Bool
    let isAvailableOffline: Bool
    let isDeviceDefault: Bool
    let isBusy: Bool
    let isDisabled: Bool
    let action: () -> Void

    private var title: String {
        // Curated models use their product-facing short name (e.g. "Large v3 Turbo");
        // fall back to the mechanical, size-stripped name for any non-curated model.
        if let curated = ModelManager.curatedModel(for: model) {
            return curated.isEnglishOnly ? curated.displayName + ModelManager.englishOnlySuffix : curated.displayName
        }
        let displayName = ModelManager.displayName(for: model)
        let parts = displayName.split(separator: " ")
        let base: String
        if let last = parts.last, isSizeToken(String(last)) {
            base = parts.dropLast().joined(separator: " ")
        } else {
            base = displayName
        }
        return ModelManager.isEnglishOnly(model) ? base + ModelManager.englishOnlySuffix : base
    }

    private var sizeLabel: String? {
        // Curated models carry an authoritative measured size; prefer it so this
        // detail page matches the Settings picker. Fall back to the size suffix
        // parsed from the identifier for any non-curated model.
        if let curated = ModelManager.curatedModel(for: model) {
            return curated.sizeLabel
        }
        let displayName = ModelManager.displayName(for: model)
        guard let last = displayName.split(separator: " ").last else {
            return nil
        }
        let token = String(last)
        guard isSizeToken(token) else {
            return nil
        }
        return token.replacingOccurrences(of: "Mb", with: " MB")
            .replacingOccurrences(of: "Gb", with: " GB")
    }

    private var curated: ModelManager.CuratedModel? {
        ModelManager.curatedModel(for: model)
    }

    private var tier: ModelManager.PerformanceTier? {
        curated?.tier
    }

    private var tierLabelColor: Color {
        switch tier {
        case .pro, .proFast: return VoicelyTheme.accent
        case .standard:      return .blue
        default:             return .secondary
        }
    }

    private var tierDots: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index < (tier?.filledDots ?? 0) ? tierLabelColor : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var detailText: String {
        if isDisabled {
            return "Not supported on this device"
        }
        return curated?.suitability ?? "On-device transcription"
    }

    private var actionTitle: String {
        if isDisabled { return "Unavailable" }
        if isSelected && isAvailableOffline { return "Selected" }
        if isAvailableOffline { return "Use" }
        return "Download"
    }

    private var actionSystemImage: String {
        if isDisabled { return "xmark.circle" }
        if isSelected && isAvailableOffline { return "checkmark.circle.fill" }
        if isAvailableOffline { return "checkmark.circle" }
        return "arrow.down.circle"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(isDisabled ? .secondary : .primary)
                        if let tier {
                            Text(tier.label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(tierLabelColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tierLabelColor.opacity(0.14), in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        tierDots
                        Text(detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                WrappingFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    if isSelected {
                        PillBadge(text: "Selected", systemImage: "checkmark.circle.fill", variant: .success)
                    }
                    if isAvailableOffline {
                        PillBadge(text: "Offline", systemImage: "iphone", variant: .accent)
                    }
                    if isDeviceDefault {
                        PillBadge(text: "Your device", systemImage: "sparkles", variant: .info)
                    }
                    if let sizeLabel {
                        PillBadge(text: sizeLabel, systemImage: "internaldrive", variant: .neutral)
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: action) {
                Label(actionTitle, systemImage: actionSystemImage)
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(minWidth: 92)
            }
            .buttonStyle(.bordered)
            .tint(isSelected ? .green : VoicelyTheme.accent)
            .disabled(isBusy || isDisabled || (isSelected && isAvailableOffline))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func isSizeToken(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard lowercased.hasSuffix("mb") || lowercased.hasSuffix("gb") else {
            return false
        }
        return lowercased.dropLast(2).allSatisfy { $0.isNumber }
    }
}

#Preview {
    NavigationView {
        WhisperKitModelsView()
            .environmentObject(ModelManager())
    }
}
