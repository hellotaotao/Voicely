import Foundation

struct SpeakerTimeRange: Sendable, Equatable {
    var speaker: Int
    var start: TimeInterval
    var end: TimeInterval
}

struct SpeakerAlignedToken: Sendable {
    var range: NSRange
    var start: TimeInterval
    var end: TimeInterval
}

/// Audio-local labels. Units tile the original transcript in UTF-16 units.
struct SpeakerTranscript: Codable, Equatable, Sendable {
    struct Unit: Codable, Equatable, Sendable {
        var length: Int
        var start: TimeInterval?
        var speaker: Int?
    }

    var audioPath: String
    var units: [Unit]
    var customNames: [Int: String]?

    init(audioPath: String, units: [Unit], customNames: [Int: String]? = nil) {
        self.audioPath = audioPath
        self.units = units
        self.customNames = customNames
    }

    private enum CodingKeys: String, CodingKey {
        case audioPath, units, customNames
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        audioPath = try values.decode(String.self, forKey: .audioPath)
        units = try values.decode([Unit].self, forKey: .units)
        // Bad optional names must not erase a valid transcript timeline.
        customNames = try? values.decode([Int: String].self, forKey: .customNames)
    }

    var speakerIDs: [Int] {
        Set(units.compactMap { unit -> Int? in
            guard let speaker = unit.speaker, speaker > 0, unit.start != nil else { return nil }
            return speaker
        }).sorted()
    }

    func customName(for id: Int) -> String? {
        guard let name = customNames?[id], id > 0,
              units.contains(where: { $0.speaker == id && $0.start != nil }) else { return nil }
        return Self.normalizedName(name)
    }

    func displayName(for speaker: Int?) -> String {
        guard let speaker else { return String(localized: "Uncertain speaker") }
        return customName(for: speaker) ?? String(localized: "Speaker \(speaker)")
    }

    static func normalizedName(_ value: String) -> String? {
        let name = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    func fits(text: String, audioPath: String) -> Bool {
        guard !audioPath.isEmpty, self.audioPath == audioPath else { return false }
        return fits(text: text)
    }

    func fits(text: String) -> Bool {
        guard !units.isEmpty else { return false }
        let length = text.utf16.count
        var offset = 0
        var lastTime: TimeInterval = 0
        var hasSpeaker = false
        for unit in units {
            guard unit.length > 0, unit.length <= length - offset else { return false }
            if let start = unit.start {
                guard start.isFinite, start >= lastTime else { return false }
                lastTime = start
            }
            if let speaker = unit.speaker {
                guard speaker > 0, unit.start != nil else { return false }
                hasSpeaker = true
            }
            offset += unit.length
        }
        return offset == length && hasSpeaker
    }
}

enum SpeakerTranscriptBuilder {
    /// A span without word times that belongs to one speaker as a whole.
    struct WholeSpan: Sendable {
        var range: NSRange
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Labels for a recording transcribed while it was made. Spans with word
    /// times are labelled word by word. A slice from Qwen3-ASR has no word
    /// times, but live transcription cuts slices where the speaker changes, so
    /// the whole slice goes to the speaker who held most of it. Nil until at
    /// least two speakers are heard: one speaker needs no headings.
    static func makeLive(text: String, spans: [TranscriptSpan], audioPath: String,
                         segments: [SpeakerTimeRange]) -> SpeakerTranscript? {
        guard let plan = SpeakerTimingPlan(text: text, spans: spans) else { return nil }
        let wholeSpans = plan.fallbackSpans.map {
            WholeSpan(range: NSRange(location: $0.utf16Offset, length: $0.text.utf16.count),
                      start: $0.start, end: $0.end)
        }
        guard let labels = make(text: text, spans: spans, audioPath: audioPath, tokens: plan.storedTokens,
                                segments: segments, wholeSpans: wholeSpans),
              labels.speakerIDs.count >= 2 else { return nil }
        return labels
    }

    static func make(text: String, spans: [TranscriptSpan], audioPath: String,
                     tokens: [SpeakerAlignedToken], segments: [SpeakerTimeRange],
                     wholeSpans: [WholeSpan] = []) -> SpeakerTranscript? {
        guard !audioPath.isEmpty else { return nil }
        let source = text as NSString
        let sentences = TranscriptTimeline.units(text: text, spans: spans)
        let index = SpeakerOverlapIndex(segments: segments)
        guard !sentences.isEmpty, !index.rangesBySpeaker.isEmpty else { return nil }
        let orderedWholeSpans = wholeSpans.sorted { $0.range.location < $1.range.location }
        var wholeSpanCursor = 0

        var lastEnd = 0
        let orderedTokens = tokens.sorted { $0.range.location < $1.range.location }.filter { token in
            let range = token.range
            guard range.location >= lastEnd, range.location < source.length,
                  range.length > 0, range.length <= source.length - range.location,
                  token.start.isFinite, token.end.isFinite, token.start >= 0, token.end > token.start
            else { return false }
            lastEnd = NSMaxRange(range)
            return true
        }
        var output: [SpeakerTranscript.Unit] = []
        var speakerNumbers: [Int: Int] = [:]
        var cursor = 0
        var previousTime: TimeInterval = 0
        var pendingShort: (start: TimeInterval, end: TimeInterval)?

        func append(length: Int, time: TimeInterval?, end: TimeInterval? = nil, speaker: Int?,
                    canBridge: Bool = false) {
            let validTime = time.flatMap { $0 >= previousTime ? $0 : nil }
            if let validTime { previousTime = validTime }
            let number = validTime.flatMap { _ in speaker }.map { speaker in
                if let number = speakerNumbers[speaker] { return number }
                let number = speakerNumbers.count + 1
                speakerNumbers[speaker] = number
                return number
            }
            // Only a normally labeled next unit may resolve the preceding candidate.
            if let pendingShort, let validTime, let end, let speaker, let number,
               index.continues(speaker: speaker, from: pendingShort, into: (validTime, end)) {
                output[output.count - 1].speaker = number
            }
            output.append(.init(length: length, start: validTime, speaker: number))
            if canBridge, speaker == nil, let validTime, let end {
                pendingShort = (validTime, end)
            } else {
                pendingShort = nil
            }
        }

        for sentence in sentences {
            let end = NSMaxRange(sentence.range)
            let contentLength = significantCount(source.substring(with: sentence.range))
            if contentLength == 0, !output.isEmpty {
                output[output.count - 1].length += sentence.range.length
                continue
            }

            var words: [SpeakerAlignedToken] = []
            while cursor < orderedTokens.count, orderedTokens[cursor].range.location < end {
                let word = orderedTokens[cursor]
                if word.range.location >= sentence.range.location, NSMaxRange(word.range) <= end {
                    words.append(word)
                }
                cursor += 1
            }

            guard let start = words.map(\.start).min(), let stop = words.map(\.end).max() else {
                while wholeSpanCursor < orderedWholeSpans.count,
                      NSMaxRange(orderedWholeSpans[wholeSpanCursor].range) <= sentence.range.location {
                    wholeSpanCursor += 1
                }
                if wholeSpanCursor < orderedWholeSpans.count,
                   NSLocationInRange(sentence.range.location, orderedWholeSpans[wholeSpanCursor].range) {
                    let span = orderedWholeSpans[wholeSpanCursor]
                    append(length: sentence.range.length, time: max(span.start, sentence.start),
                           speaker: index.dominantSpeaker(start: span.start, end: span.end))
                } else {
                    append(length: sentence.range.length, time: nil, speaker: nil)
                }
                continue
            }

            if contentLength >= 8, stop - start > 2 {
                let speakers = words.map { index.speaker(start: $0.start, end: $0.end) }
                if Set(speakers.compactMap { $0 }).count > 1 {
                    // Split only on aligned word boundaries, never guessed character positions.
                    var location = sentence.range.location
                    var firstWord = 0
                    for next in 1...words.count
                        where next == words.count || speakers[next] != speakers[firstWord] {
                        let boundary = next == words.count ? end : words[next].range.location
                        let runRange = NSRange(location: location, length: boundary - location)
                        let covered = coversText(runRange, with: words[firstWord..<next], in: source)
                        append(length: runRange.length, time: words[firstWord].start, end: words[firstWord].end,
                               speaker: covered ? speakers[firstWord] : nil)
                        location = boundary
                        firstWord = next
                    }
                    continue
                }
            }

            let covered = coversText(sentence.range, with: words[...], in: source)
            let speaker = covered ? index.speaker(start: start, end: stop) : nil
            append(length: sentence.range.length, time: start, end: stop,
                   speaker: speaker,
                   canBridge: speaker == nil && covered && contentLength <= 12 && stop - start <= 1
                       && hasTimedEdges(sentence.range, words: words, in: source))
        }

        let result = SpeakerTranscript(audioPath: audioPath, units: output)
        return result.fits(text: text) ? result : nil
    }

    private static func significantCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) {
            if CharacterSet.alphanumerics.contains($1) { $0 += 1 }
        }
    }

    private static func coversText(_ range: NSRange, with words: ArraySlice<SpeakerAlignedToken>,
                                   in source: NSString) -> Bool {
        let total = significantCount(source.substring(with: range))
        guard total > 0 else { return false }
        let known = words.reduce(into: 0) { $0 += significantCount(source.substring(with: $1.range)) }
        return Double(known) >= 0.8 * Double(total)
    }

    private static func hasTimedEdges(_ range: NSRange, words: [SpeakerAlignedToken], in source: NSString) -> Bool {
        guard let first = words.first?.range, let last = words.last?.range else { return false }
        // Untimed edge words could hide a speaker change outside the measured window.
        let leading = NSRange(location: range.location, length: first.location - range.location)
        let trailing = NSRange(location: NSMaxRange(last), length: NSMaxRange(range) - NSMaxRange(last))
        return significantCount(source.substring(with: leading)) == 0
            && significantCount(source.substring(with: trailing)) == 0
    }
}

private struct SpeakerOverlapIndex {
    typealias Range = (start: TimeInterval, end: TimeInterval)
    let rangesBySpeaker: [Int: [Range]]

    init(segments: [SpeakerTimeRange]) {
        let valid = segments.filter { $0.speaker >= 0 && $0.start.isFinite && $0.end.isFinite
            && $0.start >= 0 && $0.end > $0.start }
        rangesBySpeaker = Dictionary(grouping: valid, by: \.speaker).mapValues { segments in
            var merged: [Range] = []
            for segment in segments.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, segment.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, segment.end)
                } else {
                    merged.append((segment.start, segment.end))
                }
            }
            return merged
        }
    }

    func speaker(start: TimeInterval, end: TimeInterval) -> Int? {
        let (best, total) = overlap(start: start, end: end)
        guard let best, best.seconds >= 0.55 * total, best.seconds >= 0.55 * (end - start) else { return nil }
        return best.speaker
    }

    /// The speaker who holds most of the speech in a whole slice. Unlike
    /// `speaker`, the speech need not fill the stretch: a slice of one turn
    /// also holds that speaker's pauses.
    func dominantSpeaker(start: TimeInterval, end: TimeInterval) -> Int? {
        let (best, total) = overlap(start: start, end: end)
        guard let best, best.seconds >= 0.55 * total, best.seconds >= 0.3 else { return nil }
        return best.speaker
    }

    private func overlap(start: TimeInterval, end: TimeInterval)
        -> (best: (speaker: Int, seconds: TimeInterval)?, total: TimeInterval) {
        var total: TimeInterval = 0
        var best: (speaker: Int, seconds: TimeInterval)?
        for (speaker, ranges) in rangesBySpeaker {
            var position = lowerBound(ranges) { $0.end > start }
            var seconds: TimeInterval = 0
            while position < ranges.count, ranges[position].start < end {
                seconds += min(end, ranges[position].end) - max(start, ranges[position].start)
                position += 1
            }
            total += seconds
            if seconds > (best?.seconds ?? 0) { best = (speaker, seconds) }
        }
        return (best, total)
    }

    func continues(speaker: Int, from short: Range, into next: Range) -> Bool {
        let gap = next.start - short.end
        guard gap >= 0, gap <= 0.25, let ranges = rangesBySpeaker[speaker] else { return false }

        // Require a single range, not interruptions by silence or scattered overlaps.
        let minimumOverlap = max(0.06, 0.2 * (short.end - short.start))
        let junctionEnd = min(next.end, next.start + 0.06)
        let position = lowerBound(ranges) { $0.end >= junctionEnd }
        guard position < ranges.count,
              short.end - max(short.start, ranges[position].start) >= minimumOverlap else { return false }

        for (other, ranges) in rangesBySpeaker where other != speaker {
            let position = lowerBound(ranges) { $0.end > short.start }
            if position < ranges.count, ranges[position].start < junctionEnd { return false }
        }
        return true
    }
}

/// Adds display-only headings without changing the source text or its search index.
struct SpeakerTranscriptPresentation: Equatable {
    struct Piece: Equatable {
        var source: NSRange
        var display: NSRange
    }

    struct EditableHeading: Equatable {
        let range: NSRange
        let speakerID: Int
    }

    let text: String
    let headings: [NSRange]
    let editableHeadings: [EditableHeading]
    let playbackUnits: [TranscriptUnit]
    private let pieces: [Piece]

    init?(text: String, speakers: SpeakerTranscript, fallbackSpans: [TranscriptSpan] = [],
          label: (Int?) -> String) {
        guard speakers.fits(text: text) else { return nil }
        let source = text as NSString
        let estimatedUnits = TranscriptTimeline.units(text: text, spans: fallbackSpans)
        var anchors: [(offset: Int, start: TimeInterval)] = []
        var scan = 0
        for unit in speakers.units {
            if let start = unit.start { anchors.append((scan, start)) }
            scan += unit.length
        }
        var anchorIndex = 0
        var rendered = ""
        var headingRanges: [NSRange] = []
        var editable: [EditableHeading] = []
        var playback: [TranscriptUnit] = []
        var pieces: [Piece] = []
        var offset = 0
        var displayedOffset = 0
        var previousSpeaker: Int?
        for unit in speakers.units {
            let firstInTurn = offset == 0 || unit.speaker != previousSpeaker
            if firstInTurn {
                let separator = offset == 0 ? "" : "\n\n"
                let name = label(unit.speaker)
                let heading = NSRange(location: displayedOffset + separator.utf16.count, length: name.utf16.count)
                headingRanges.append(heading)
                if let speaker = unit.speaker, heading.length > 0 {
                    editable.append(EditableHeading(range: heading, speakerID: speaker))
                }
                let inserted = separator + name + "\n"
                rendered.append(inserted)
                displayedOffset += inserted.utf16.count
            }

            let range = NSRange(location: offset, length: unit.length)
            let displayed = NSRange(location: displayedOffset, length: unit.length)
            rendered.append(source.substring(with: range))
            if !firstInTurn {
                pieces[pieces.count - 1].source.length += unit.length
                pieces[pieces.count - 1].display.length += unit.length
            } else {
                pieces.append(Piece(source: range, display: displayed))
            }
            if let start = unit.start {
                anchorIndex += 1
                // Aligned times need only a short lead-in.
                playback.append(TranscriptUnit(range: displayed, start: start, spanStart: max(0, start - 0.15)))
            } else if let index = TranscriptTimeline.unitIndex(containing: offset, in: estimatedUnits) {
                // Unknown speaker does not make a previously tappable sentence
                // untappable. Keep estimates in order around aligned neighbors.
                let estimated = estimatedUnits[index]
                let previous = anchorIndex > 0 ? anchors[anchorIndex - 1] : nil
                let next = anchorIndex < anchors.count ? anchors[anchorIndex] : nil
                var start = estimated.start
                if let previous, let next, start < previous.start || start >= next.start {
                    let fraction = Double(offset - previous.offset) / Double(next.offset - previous.offset)
                    start = previous.start + fraction * (next.start - previous.start)
                }
                start = min(next?.start ?? .infinity, max(playback.last?.start ?? 0, start))
                playback.append(TranscriptUnit(range: displayed, start: start, spanStart: min(start, estimated.spanStart)))
            }
            previousSpeaker = unit.speaker
            offset += unit.length
            displayedOffset += unit.length
        }
        self.text = rendered
        headings = headingRanges
        editableHeadings = editable
        playbackUnits = playback
        self.pieces = pieces
    }

    func displayRange(for source: NSRange) -> NSRange {
        guard let last = pieces.last, source.length > 0, source.location >= 0,
              source.location < NSMaxRange(last.source),
              source.length <= NSMaxRange(last.source) - source.location else { return NSRange() }
        let start = displayLocation(for: source.location)
        let end = displayLocation(for: NSMaxRange(source) - 1) + 1
        return NSRange(location: start, length: end - start)
    }

    func textRanges(in displayRange: NSRange) -> [NSRange] {
        var index = lowerBound(pieces) { NSMaxRange($0.display) > displayRange.location }
        var ranges: [NSRange] = []
        while index < pieces.count, pieces[index].display.location < NSMaxRange(displayRange) {
            let range = NSIntersectionRange(pieces[index].display, displayRange)
            if range.length > 0 { ranges.append(range) }
            index += 1
        }
        return ranges
    }

    private func displayLocation(for point: Int) -> Int {
        let piece = pieces[lowerBound(pieces) { NSMaxRange($0.source) > point }]
        return piece.display.location + point - piece.source.location
    }
}

private func lowerBound<T>(_ array: [T], matching predicate: (T) -> Bool) -> Int {
    var low = 0
    var high = array.count
    while low < high {
        let mid = low + (high - low) / 2
        if predicate(array[mid]) { high = mid } else { low = mid + 1 }
    }
    return low
}
