import AVFoundation
import CoreML
import Foundation
import Qwen3ASR
import AudioCommon

// usage: QwenCoreML <audio.caf 16k mono f32> <cuts.json> <out.jsonl> [limit]
let args = CommandLine.arguments
let audioURL = URL(fileURLWithPath: args[1])
var cuts = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let outURL = URL(fileURLWithPath: args[3])
if args.count > 4, let limit = Int(args[4]) { cuts = Array(cuts.prefix(limit)) }

let file = try AVAudioFile(forReading: audioURL)
let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: buffer)
let all = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-CoreML")
let loadStart = Date()
// No GPU anywhere: the configuration a locked iPhone is limited to.
let model = try await CoreMLASRModel.fromPretrained(
    encoderComputeUnits: .cpuAndNeuralEngine, decoderComputeUnits: .cpuAndNeuralEngine,
    cacheDir: cacheDir, offlineMode: true)
try model.warmUp()
FileHandle.standardError.write(Data("loaded in \(Date().timeIntervalSince(loadStart)) s\n".utf8))

let tokenizer = Qwen3Tokenizer()
try tokenizer.load(from: cacheDir.appendingPathComponent("vocab.json"))

/// Flattens encoder output without touching MLX. The Neural Engine hands back
/// Float16 with its own strides, so read through the declared layout.
func flatten(_ array: MLMultiArray, rows: Int, hidden: Int) -> [Float] {
    var out = [Float](repeating: 0, count: rows * hidden)
    let strides = array.strides.map { $0.intValue }
    let rowStride = strides[1], colStride = strides[2]
    switch array.dataType {
    case .float16:
        let src = array.dataPointer.assumingMemoryBound(to: Float16.self)
        for t in 0..<rows { for j in 0..<hidden { out[t * hidden + j] = Float(src[t * rowStride + j * colStride]) } }
    default:
        let src = array.dataPointer.assumingMemoryBound(to: Float.self)
        for t in 0..<rows { for j in 0..<hidden { out[t * hidden + j] = src[t * rowStride + j * colStride] } }
    }
    return out
}

/// CoreMLASRModel.transcribe with the MLXArray hop removed: batched prefill,
/// CPU mel, CoreML encoder and decoder. Nothing here can reach Metal.
func transcribeMLXFree(_ audio: [Float], maxTokens: Int = 448) throws -> String {
    let mel = model.featureExtractor.processRaw(audio, sampleRate: 16_000)
    let encoded = try model.encoder.encode(melFeatures: mel)
    let hidden = encoded.embeddings.shape[2].intValue
    let flat = flatten(encoded.embeddings, rows: encoded.outputLength, hidden: hidden)
    let decoder = model.decoder
    decoder.resetCache()
    let imEnd: Int32 = 151645
    let prefix: [Int32] = [151644, 8948, 198, imEnd, 198, 151644, 872, 198, 151669]
    let suffix: [Int32] = [151670, imEnd, 198, 151644, 77091, 198, 151704]
    var logits = try decoder.decoderPrefillTokens(prefix)
    var consumed = 0
    while consumed < encoded.outputLength {
        let n = min(decoder.prefillBatchSize, encoded.outputLength - consumed)
        logits = try decoder.decoderPrefill(flatEmbeddings: flat, offset: consumed, realCount: n)
        consumed += n
    }
    logits = try decoder.decoderPrefillTokens(suffix)
    var tokens: [Int32] = []
    var next = decoder.argmax(logits: logits)
    if next == imEnd { next = decoder.argmax(logits: logits, skipping: imEnd) }
    tokens.append(next)
    for _ in 1..<maxTokens {
        if next == imEnd { break }
        logits = try decoder.decoderStep(embedding: try decoder.embed(tokenId: next))
        next = decoder.argmax(logits: logits)
        tokens.append(next)
    }
    let raw = tokenizer.decode(tokens: tokens.map { Int($0) })
    if let range = raw.range(of: "<asr_text>") {
        return String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
    return raw
}

FileManager.default.createFile(atPath: outURL.path, contents: nil)
let out = try FileHandle(forWritingTo: outURL)
for (index, cut) in cuts.enumerated() {
    let lo = max(0, Int(cut[0] * 16_000)), hi = min(all.count, Int(cut[1] * 16_000))
    guard hi > lo else { continue }
    let samples = Array(all[lo..<hi])
    var began = Date()
    // Each slice creates an MLState and several IOSurface-backed arrays; without
    // a pool they pile up until CoreML cannot allocate another one.
    let noMLX = autoreleasepool { (try? transcribeMLXFree(samples)) ?? "[error]" }
    let noMLXSeconds = Date().timeIntervalSince(began)
    began = Date()
    let batched = ProcessInfo.processInfo.environment["WITH_MLX_HOP"] == "1"
        ? ((try? model.transcribe(audio: samples, sampleRate: 16_000)) ?? "[error]") : ""
    let batchedSeconds = Date().timeIntervalSince(began)
    let row: [String: Any] = ["index": index + 1, "start": cut[0], "end": cut[1],
                              "plain": noMLX, "plainSeconds": noMLXSeconds,
                              "hinted": batched, "hintedSeconds": batchedSeconds]
    try out.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data("\n".utf8))
    FileHandle.standardError.write(Data("slice \(index + 1)/\(cuts.count) \(String(format: "%.1f", cut[1] - cut[0]))s audio: noMLX=\(String(format: "%.1f", noMLXSeconds))s batched=\(String(format: "%.1f", batchedSeconds))s\n".utf8))
}
