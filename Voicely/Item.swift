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
    var id: UUID
    var title: String
    var timestamp: Date
    var duration: TimeInterval
    var audioFilePath: String
    var transcription: String
    var isTranscribing: Bool
    
    init(title: String = "", audioFilePath: String = "", transcription: String = "") {
        self.id = UUID()
        self.title = title.isEmpty ? "Voice Note" : title
        self.timestamp = Date()
        self.duration = 0
        self.audioFilePath = audioFilePath
        self.transcription = transcription
        self.isTranscribing = false
    }
}
