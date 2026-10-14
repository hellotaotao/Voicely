import AVFoundation
import Foundation
import Qwen3ASR

// usage: QwenReplay <audio.caf 16k mono f32> <cuts.json [[start,end],...] in seconds> <out.jsonl> <context>
let args = CommandLine.arguments
let audioURL = URL(fileURLWithPath: args[1])
let cuts = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let outURL = URL(fileURLWithPath: args[3])
let context = args[4]

let file = try AVAudioFile(forReading: audioURL)
let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: buffer)
let all = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

// MODEL_ID picks another MLX conversion from the same cache (default: the app's).
let modelId = ProcessInfo.processInfo.environment["MODEL_ID"] ?? "mlx-community/Qwen3-ASR-0.6B-4bit"
let penalty = Float(ProcessInfo.processInfo.environment["REPETITION_PENALTY"] ?? "") ?? 1.15
let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/qwen3-speech/models/\(modelId)")
let loadStart = Date()
let model = try await Qwen3ASRModel.fromPretrained(
    modelId: modelId, cacheDir: cacheDir, offlineMode: true, progressHandler: nil)
_ = model.transcribe(audio: [Float](repeating: 0, count: 8_000), sampleRate: 16_000,
                     options: Qwen3DecodingOptions(maxTokens: 4, repetitionPenalty: 1.15))
FileHandle.standardError.write(Data("loaded in \(Date().timeIntervalSince(loadStart)) s\n".utf8))

FileManager.default.createFile(atPath: outURL.path, contents: nil)
let out = try FileHandle(forWritingTo: outURL)
for (index, cut) in cuts.enumerated() {
    let lo = max(0, Int(cut[0] * 16_000)), hi = min(all.count, Int(cut[1] * 16_000))
    guard hi > lo else { continue }
    let samples = Array(all[lo..<hi])
    func run(_ context: String?) -> (String, Double) {
        let began = Date()
        // Mirrors Qwen3ASRDefaults.decodingOptions in the old-dev engine.
        var options = Qwen3DecodingOptions(language: nil, context: context, repetitionPenalty: penalty)
        // NO_LONG_INPUT_NGRAM=1 keeps slices over 15 s off the package's
        // automatic no-repeat-n-gram escalation.
        if ProcessInfo.processInfo.environment["NO_LONG_INPUT_NGRAM"] == "1" { options.longInputThresholdSeconds = .infinity }
        let text = model.transcribe(audio: samples, sampleRate: 16_000, options: options)
        return (text, Date().timeIntervalSince(began))
    }
    let (plain, plainSeconds) = run(nil)
    let (hinted, hintedSeconds) = context.isEmpty ? ("", 0) : run(context)
    let row: [String: Any] = ["index": index + 1, "start": cut[0], "end": cut[1],
                              "plain": plain, "plainSeconds": plainSeconds,
                              "hinted": hinted, "hintedSeconds": hintedSeconds]
    try out.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data("\n".utf8))
    FileHandle.standardError.write(Data("slice \(index + 1)/\(cuts.count) \(Int(cut[0]))s plain=\(String(format: "%.1f", plainSeconds))s\n".utf8))
}
