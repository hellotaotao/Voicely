//
//  Item.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import SwiftData

@Model
final class VoiceNote {
    var id: UUID = UUID()
    var title: String = "Voice Note"
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFilePath: String = ""
    var transcription: String = ""
    var isTranscribing: Bool = false
    var transcriptionProgress: Float = 0.0
    var pendingTranscription: Bool = false // Mark if waiting for transcription
    
    init(title: String = "", audioFilePath: String = "", transcription: String = "") {
        self.id = UUID()
        self.title = title.isEmpty ? "Voice Note" : title
        self.timestamp = Date()
        self.duration = 0
        self.audioFilePath = audioFilePath
        self.transcription = transcription
        self.isTranscribing = false
        self.transcriptionProgress = 0.0
        self.pendingTranscription = false
    }
}
