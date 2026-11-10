//
//  ChineseScriptConverter.swift
//  Voicely
//
//  Converts Chinese text between Simplified and Traditional characters with
//  OpenCC's dictionaries (OpenCC 1.4.2, Apache 2.0, files in OpenCC/). This is
//  a Swift port of OpenCC's matching rules, checked against the reference
//  library's output: it changes how characters are written and never swaps
//  one word for another (软件 stays 軟件, it does not become 軟體).
//

import Foundation

final class ChineseScriptConverter: @unchecked Sendable {
    enum Target: String, CaseIterable, Sendable {
        /// OpenCC `s2tw`: Traditional characters, Taiwan forms.
        case taiwan
        /// OpenCC `s2hk`: Traditional characters, Hong Kong forms.
        case hongKong
        /// OpenCC `t2s`: Simplified characters.
        case simplified
    }

    // Loaded on first use; the Traditional dictionaries take tens of MB.
    static let taiwan = ChineseScriptConverter(target: .taiwan)
    static let hongKong = ChineseScriptConverter(target: .hongKong)
    static let simplified = ChineseScriptConverter(target: .simplified)

    static func shared(_ target: Target) -> ChineseScriptConverter {
        switch target {
        case .taiwan: return taiwan
        case .hongKong: return hongKong
        case .simplified: return simplified
        }
    }

    let target: Target
    private let normalization: Lexicon
    private let segmentation: Lexicon?
    private let chain: [Lexicon]
    private let cache = NSCache<NSString, NSString>()

    /// `dictionaryURL` maps a dictionary name such as "STPhrases" to its file;
    /// by default the copy in the app bundle.
    init(target: Target, dictionaryURL: (String) -> URL? = ChineseScriptConverter.bundledDictionaryURL) {
        self.target = target
        var tables: [String: Lexicon] = [:]
        func table(_ name: String) -> Lexicon {
            if let loaded = tables[name] { return loaded }
            let loaded = Lexicon.table(LexiconTable(url: dictionaryURL(name)))
            tables[name] = loaded
            return loaded
        }
        // Mirrors s2tw.json, s2hk.json and t2s.json from OpenCC 1.4.2.
        normalization = table("CJK_Compatibility_Ideographs")
        switch target {
        case .taiwan, .hongKong:
            let phrases = Lexicon.union([table("STPhrases"), table("STPhrases_GeneratedFromRegionalPhrases")])
            segmentation = phrases
            let variants = target == .taiwan
                ? Lexicon.firstMatch([table("TWVariantsPhrases"), table("TWVariants")])
                : Lexicon.firstMatch([table("HKVariantsPhrases"), table("HKVariants")])
            chain = [.firstMatch([phrases, table("STCharacters")]), variants]
        case .simplified:
            segmentation = nil
            chain = [.firstMatch([table("TSPhrases"), table("TSCharactersExt"), table("TSCharacters")])]
        }
        cache.totalCostLimit = 8_000_000
    }

    static func bundledDictionaryURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: "OpenCC-\(name)", withExtension: "txt")
    }

    /// The whole text converted the way OpenCC converts it.
    func convert(_ text: String) -> String {
        guard Self.containsHan(text) else { return text }
        var scalars = Array(text.unicodeScalars)
        scalars = Self.apply(normalization, to: scalars[...])
        var segments: [ArraySlice<Unicode.Scalar>] = []
        if let segmentation {
            segments = Self.segment(scalars, with: segmentation)
        } else {
            segments = [scalars[...]]
        }
        for lexicon in chain {
            segments = segments.map { Self.apply(lexicon, to: $0)[...] }
        }
        var result = String.UnicodeScalarView()
        for segment in segments { result.append(contentsOf: segment) }
        return String(result)
    }

    /// Converted text with exactly as many UTF-16 units and scalars as the
    /// input, so ranges and timeline offsets into the original still point at
    /// the same characters. A sentence whose conversion would change length
    /// (only possible with rare characters outside the Basic Multilingual
    /// Plane) is left as it was. Results are cached.
    func convertKeepingLength(_ text: String) -> String {
        guard Self.containsHan(text) else { return text }
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        var converted = convert(text)
        if !Self.sameLength(converted, text) {
            converted = Self.sentences(of: text).map { sentence in
                let candidate = convert(sentence)
                return Self.sameLength(candidate, sentence) ? candidate : sentence
            }.joined()
        }
        cache.setObject(converted as NSString, forKey: key, cost: key.length)
        return converted
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    // MARK: - OpenCC matching

    /// OpenCC's max-match segmentation: the longest dictionary phrase wins at
    /// each position; runs of characters that start no phrase form one segment.
    private static func segment(_ scalars: [Unicode.Scalar], with lexicon: Lexicon) -> [ArraySlice<Unicode.Scalar>] {
        var segments: [ArraySlice<Unicode.Scalar>] = []
        var runStart = 0
        var index = 0
        while index < scalars.count {
            if let match = lexicon.longestPrefix(of: scalars, at: index) {
                if runStart < index { segments.append(scalars[runStart..<index]) }
                segments.append(scalars[index..<index + match.length])
                index += match.length
                runStart = index
            } else {
                index += 1
            }
        }
        if runStart < scalars.count { segments.append(scalars[runStart..<scalars.count]) }
        return segments
    }

    /// OpenCC's `Conversion::Convert`: walk the segment, replacing the longest
    /// match at each position with its first candidate.
    private static func apply(_ lexicon: Lexicon, to segment: ArraySlice<Unicode.Scalar>) -> [Unicode.Scalar] {
        let scalars = Array(segment)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            if let match = lexicon.longestPrefix(of: scalars, at: index) {
                output.append(contentsOf: match.value)
                index += match.length
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return output
    }

    private static func sameLength(_ a: String, _ b: String) -> Bool {
        a.utf16.count == b.utf16.count && a.unicodeScalars.count == b.unicodeScalars.count
    }

    /// `text` cut after each sentence end, so the pieces join back to `text`.
    private static func sentences(of text: String) -> [String] {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            current.append(scalar)
            if "。！？!?\n".unicodeScalars.contains(scalar) {
                pieces.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { pieces.append(String(current)) }
        return pieces
    }
}

/// One OpenCC dictionary or dictionary group.
private indirect enum Lexicon {
    case table(LexiconTable)
    /// OpenCC "union": the longest match across all members.
    case union([Lexicon])
    /// OpenCC "short_circuit": the first member that matches at all.
    case firstMatch([Lexicon])

    func longestPrefix(of scalars: [Unicode.Scalar], at index: Int) -> (length: Int, value: [Unicode.Scalar])? {
        switch self {
        case .table(let table):
            return table.longestPrefix(of: scalars, at: index)
        case .union(let members):
            var best: (length: Int, value: [Unicode.Scalar])?
            for member in members {
                if let match = member.longestPrefix(of: scalars, at: index), match.length > (best?.length ?? 0) {
                    best = match
                }
            }
            return best
        case .firstMatch(let members):
            for member in members {
                if let match = member.longestPrefix(of: scalars, at: index) { return match }
            }
            return nil
        }
    }
}

/// A prefix tree, so finding the longest key at a position walks the text once.
private final class LexiconTable {
    /// Children of each node; node 0 is the root.
    private var children: [[Unicode.Scalar: Int32]] = [[:]]
    /// The first candidate for the key ending at each node, if any.
    private var values: [[Unicode.Scalar]?] = [nil]

    /// Reads OpenCC's text format: `key<TAB>candidate candidate…`.
    init(url: URL?) {
        guard let url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            #if DEBUG
            print("❌ OpenCC dictionary missing: \(url?.lastPathComponent ?? "nil")")
            #endif
            return
        }
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let key = String(line[..<tab])
            let candidates = line[line.index(after: tab)...]
            let first = candidates.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            guard !key.isEmpty, !first.isEmpty else { continue }
            var node = 0
            for scalar in key.unicodeScalars {
                if let next = children[node][scalar] {
                    node = Int(next)
                } else {
                    children.append([:])
                    values.append(nil)
                    let next = children.count - 1
                    children[node][scalar] = Int32(next)
                    node = next
                }
            }
            values[node] = Array(first.unicodeScalars)
        }
    }

    func longestPrefix(of scalars: [Unicode.Scalar], at index: Int) -> (length: Int, value: [Unicode.Scalar])? {
        var node = 0
        var best: (length: Int, value: [Unicode.Scalar])?
        var position = index
        while position < scalars.count, let next = children[node][scalars[position]] {
            node = Int(next)
            position += 1
            if let value = values[node] { best = (position - index, value) }
        }
        return best
    }
}
