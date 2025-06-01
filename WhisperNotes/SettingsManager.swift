//
//  SettingsManager.swift
//  WhisperNotes
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var selectedModel: String {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: "selectedWhisperModel")
        }
    }
    
    @Published var isAutoLoadEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoLoadEnabled, forKey: "autoLoadWhisperModel")
        }
    }
    
    private init() {
        selectedModel = UserDefaults.standard.string(forKey: "selectedWhisperModel") ?? "openai/whisper-base"
        isAutoLoadEnabled = UserDefaults.standard.bool(forKey: "autoLoadWhisperModel")
    }
    
    func getDownloadedModels() -> [String] {
        return UserDefaults.standard.stringArray(forKey: "downloadedWhisperModels") ?? []
    }
    
    func addDownloadedModel(_ model: String) {
        var downloaded = getDownloadedModels()
        if !downloaded.contains(model) {
            downloaded.append(model)
            UserDefaults.standard.set(downloaded, forKey: "downloadedWhisperModels")
        }
    }
    
    func removeDownloadedModel(_ model: String) {
        var downloaded = getDownloadedModels()
        downloaded.removeAll { $0 == model }
        UserDefaults.standard.set(downloaded, forKey: "downloadedWhisperModels")
    }
    
    func isModelDownloaded(_ model: String) -> Bool {
        return getDownloadedModels().contains(model)
    }
}