import AVFoundation
import Foundation

/// An imported file is kept as a listening copy in the format recordings use
/// (16 kHz mono AAC, about 11 MB an hour), so its transcript can play back,
/// seek and follow along like a recording's. The original stays wherever it
/// came from.
enum ImportedAudioListeningCopy {
    enum CopyError: LocalizedError {
        case formatUnavailable
        case noAudio

        var errorDescription: String? {
            switch self {
            case .formatUnavailable: "The imported audio could not be converted."
            case .noAudio: "The imported audio holds no samples."
            }
        }
    }

    /// Writes the copy next to the recordings and returns its file name, the
    /// form `VoiceNote.audioFilePath` stores.
    @MainActor
    static func store(from source: URL) async throws -> String {
        let destination = CloudStorageManager.shared.generateAudioFilename()
        try await write(from: source, to: destination)
        return destination.lastPathComponent
    }

    nonisolated static func write(from source: URL, to destination: URL) async throws {
        let pcmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely_import_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        try await Task.detached(priority: .utility) {
            try writeMonoPCM(from: source, to: pcmURL)
        }.value
        do {
            try await AudioRecordingService.convertCAFToM4A(from: pcmURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Decodes `source` to the 16 kHz mono Float32 CAF the recorder writes.
    /// Channels are averaged by hand before resampling: on Mac Catalyst,
    /// AVAudioConverter turns stereo into all-zero mono.
    nonisolated static func writeMonoPCM(from source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let sourceFormat = input.processingFormat
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceFormat.sampleRate,
                                             channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            throw CopyError.formatUnavailable
        }
        let output = try AVAudioFile(forWriting: destination, settings: targetFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)

        let inputCapacity: AVAudioFrameCount = 32_768
        var readError: Error?
        var inputExhausted = false
        var wroteFrames = false
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 16_384) else {
                throw CopyError.formatUnavailable
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                // Stop on position, not on a thrown read: AVAudioFile throws at EOF.
                if inputExhausted || input.framePosition >= input.length {
                    inputExhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: buffer, frameCount: inputCapacity)
                } catch {
                    readError = error
                    inputExhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard buffer.frameLength > 0,
                      let mixed = AudioRecordingService.mixedDownToMono(buffer),
                      let mono = copy(mixed, as: monoFormat) else {
                    inputExhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return mono
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? CopyError.formatUnavailable }
            if outBuffer.frameLength > 0 {
                try output.write(from: outBuffer)
                wroteFrames = true
            }
            if status == .endOfStream || (status == .inputRanDry && inputExhausted) { break }
        }
        guard wroteFrames else { throw CopyError.noAudio }
    }

    /// A mono file's own buffers can carry a channel layout the converter was
    /// not set up for; copying the samples gives it exactly the format it expects.
    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let source = buffer.floatChannelData?[0],
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData?[0] else { return nil }
        destination.update(from: source, count: Int(buffer.frameLength))
        copy.frameLength = buffer.frameLength
        return copy
    }
}
