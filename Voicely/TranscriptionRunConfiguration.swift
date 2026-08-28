import Foundation

enum TranscriptionTimingGranularity: String, Codable, Equatable, Sendable {
    case none
    case segment
    case word
}

struct TranscriptionRunConfiguration: Codable, Equatable, Sendable {
    let engineMode: TranscriptionEngineMode
    let modelIdentifier: String
    let selectedLanguageKey: String
    let prompt: String?
    let chunkSeconds: TimeInterval
    let singlePassSecondsLimit: TimeInterval
    let minimumChunkCutSeconds: TimeInterval
    let timingGranularity: TranscriptionTimingGranularity
}

struct TranscriptionRunToken: Hashable, Sendable {
    fileprivate let id: UUID

    init() {
        id = UUID()
    }
}
