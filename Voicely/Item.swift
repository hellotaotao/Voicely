//
//  Item.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import SwiftData

enum TranscriptionOwnershipState: String {
    case queued
    case claimed
    case completed
}

@Model
final class VoiceNote {
    var id: UUID = UUID()
    var title: String = "Voice Note"
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFilePath: String = ""
    var transcription: String = ""
    var transcriptionModelIdentifier: String?
    var transcriptionLastErrorMessage: String?
    var isTranscribing: Bool = false
    var transcriptionProgress: Float = 0.0
    var pendingTranscription: Bool = false // Mark if waiting for transcription
    var lastTranscriptionDuration: TimeInterval = 0
    var transcriptionStateRaw: String = ""
    var transcriptionOriginDeviceID: String?
    var transcriptionOwnerDeviceID: String?
    var transcriptionAttemptID: String?
    var transcriptionQueuedAt: Date?
    var transcriptionLeaseExpiresAt: Date?
    
    init(title: String = "", audioFilePath: String = "", transcription: String = "") {
        self.id = UUID()
        self.title = title.isEmpty ? "Voice Note" : title
        self.timestamp = Date()
        self.duration = 0
        self.audioFilePath = audioFilePath
        self.transcription = transcription
        self.transcriptionModelIdentifier = nil
        self.transcriptionLastErrorMessage = nil
        self.isTranscribing = false
        self.transcriptionProgress = 0.0
        self.pendingTranscription = false
    }
}

extension VoiceNote {
    var transcriptionState: TranscriptionOwnershipState? {
        get {
            TranscriptionOwnershipState(rawValue: transcriptionStateRaw)
        }
        set {
            transcriptionStateRaw = newValue?.rawValue ?? ""
        }
    }

    var transcriptionModelDisplayName: String? {
        guard let transcriptionModelIdentifier, !transcriptionModelIdentifier.isEmpty else {
            return nil
        }
        return ModelManager.displayName(for: transcriptionModelIdentifier)
    }

    var hasOwnershipState: Bool {
        !transcriptionStateRaw.isEmpty
    }

    var isAwaitingTranscription: Bool {
        get {
            pendingTranscription
        }
        set {
            pendingTranscription = newValue
        }
    }

    func queueTranscription(at queuedAt: Date) {
        transcriptionState = .queued
        transcriptionQueuedAt = queuedAt
        transcriptionOwnerDeviceID = nil
        transcriptionAttemptID = nil
        transcriptionLeaseExpiresAt = nil
        pendingTranscription = true
        isTranscribing = false
        transcriptionProgress = 0.0
    }

    func claimTranscription(
        ownerDeviceID: String,
        attemptID: String,
        queuedAt: Date,
        leaseExpiresAt: Date
    ) {
        transcriptionState = .claimed
        transcriptionOwnerDeviceID = ownerDeviceID
        transcriptionAttemptID = attemptID
        transcriptionQueuedAt = queuedAt
        transcriptionLeaseExpiresAt = leaseExpiresAt
        transcriptionLastErrorMessage = nil
        pendingTranscription = false
    }

    func completeTranscription() {
        transcriptionState = .completed
        transcriptionOwnerDeviceID = nil
        transcriptionAttemptID = nil
        transcriptionLeaseExpiresAt = nil
        transcriptionLastErrorMessage = nil
        pendingTranscription = false
    }

    func markTranscriptionFailure(_ message: String) {
        transcriptionLastErrorMessage = message
    }

    func clearTransientTranscriptionFlags() {
        isTranscribing = false
        transcriptionProgress = 0.0
        pendingTranscription = false
    }

}
