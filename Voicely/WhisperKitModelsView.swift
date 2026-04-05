//
//  WhisperKitModelsView.swift
//  Voicely
//

import SwiftUI
import WhisperKit

struct WhisperKitModelsView: View {
    @State private var deviceDefault: String = ""
    @State private var supportedModels: [String] = []
    @State private var disabledModels: [String] = []
    @State private var isLoading = true
    @State private var fetchError: String?

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
                            HStack {
                                Text(ModelManager.displayName(for: model))
                                Spacer()
                                if model == deviceDefault {
                                    Text("Device Default")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.blue)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                if !disabledModels.isEmpty {
                    Section("Disabled for This Device (\(disabledModels.count))") {
                        ForEach(disabledModels, id: \.self) { model in
                            Text(ModelManager.displayName(for: model))
                                .foregroundColor(.secondary)
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
}

#Preview {
    NavigationView {
        WhisperKitModelsView()
    }
}
