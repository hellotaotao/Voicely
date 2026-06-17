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
        .navigationTitle("Device Recommendations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadRecommendations()
        }
    }

    private func loadRecommendations() async {
        isLoading = true
        fetchError = nil
        deviceDefault = WhisperKit.recommendedModels().default
        let remote = await WhisperKit.recommendedRemoteModels()
        supportedModels = remote.supported
        disabledModels = remote.disabled
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
        let displayName = ModelManager.displayName(for: model)
        let parts = displayName.split(separator: " ")
        guard let last = parts.last, isSizeToken(String(last)) else {
            return displayName
        }
        return parts.dropLast().joined(separator: " ")
    }

    private var sizeLabel: String? {
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

    private var detailText: String {
        if isDisabled {
            return "Not recommended for this device."
        }
        if isAvailableOffline {
            return "Ready for offline transcription."
        }
        return "Download before using for offline transcription."
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(isDisabled ? .secondary : .primary)
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                WrappingFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    if isSelected {
                        PillBadge(text: "Selected", systemImage: "checkmark.circle.fill", variant: .success)
                    }
                    if isAvailableOffline {
                        PillBadge(text: "Offline", systemImage: "iphone", variant: .accent)
                    }
                    if isDeviceDefault {
                        PillBadge(text: "Recommended", systemImage: "sparkles", variant: .info)
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
