import CryptoKit
import Foundation

/// A run of transcript text and the stretch of audio it was transcribed from.
///
/// Spans tile the transcript: their lengths add up to the whole text, and the
/// line break that joins two slices belongs to the span before it. A span is
/// only a bunch of characters, so the text inside it may hold any number of
/// paragraphs after an edit.
struct TranscriptSpan: Codable, Equatable, Sendable {
    /// UTF-16 length, the unit TextKit ranges use.
    var length: Int
    var start: TimeInterval
    var end: TimeInterval
}

/// Spans as stored on a note, with a digest of the text they were built for.
/// iCloud can merge the transcript and its spans from different edits; when
/// the text no longer matches, even at the same length, the spans are ignored.
struct StoredTranscriptTimeline: Codable, Equatable, Sendable {
    var textDigest: String
    var spans: [TranscriptSpan]

    init(spans: [TranscriptSpan], text: String) {
        self.spans = spans
        textDigest = Self.digest(of: text)
    }

    /// The spans, if they were built for exactly this text.
    func spans(for text: String) -> [TranscriptSpan]? {
        guard textDigest == Self.digest(of: text), TranscriptTimeline.fits(spans, text) else { return nil }
        return spans
    }

    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A sentence-sized piece of a timed transcript: what the detail view
/// highlights during playback and seeks to when tapped.
struct TranscriptUnit: Equatable, Sendable {
    var range: NSRange
    /// Estimated by the unit's position inside its span.
    var start: TimeInterval
    /// Start of the span holding the unit; a seek never goes before it.
    var spanStart: TimeInterval
}

/// Builds the spans of a transcript whose slices are joined with line breaks,
/// the way every transcription path joins them.
struct TranscriptSpanBuilder {
    /// Nil once any appended text has no known time, such as text resumed
    /// from a checkpoint written before spans were recorded.
    private(set) var spans: [TranscriptSpan]?
    private var hasText: Bool

    init() {
        spans = []
        hasText = false
    }

    init(resumedText: String, resumedSpans: [TranscriptSpan]?) {
        hasText = !resumedText.isEmpty
        if !hasText {
            spans = []
        } else if let resumedSpans, TranscriptTimeline.fits(resumedSpans, resumedText) {
            spans = resumedSpans
        } else {
            spans = nil
        }
    }

    mutating func append(_ piece: String, start: TimeInterval, end: TimeInterval) {
        guard !piece.isEmpty else { return }
        if hasText, spans != nil {
            spans![spans!.count - 1].length += 1
        }
        spans?.append(TranscriptSpan(length: piece.utf16.count, start: start, end: max(start, end)))
        hasText = true
    }
}

enum TranscriptTimeline {
    /// Spans describe `text` only when they tile it exactly. Anything else, such
    /// as text and spans that reached this device from different edits, is
    /// treated as having no timeline.
    static func fits(_ spans: [TranscriptSpan], _ text: String) -> Bool {
        guard !spans.isEmpty else { return false }
        var total = 0
        for span in spans {
            guard span.length > 0, span.start.isFinite, span.end.isFinite, span.start <= span.end else { return false }
            total += span.length
        }
        return total == text.utf16.count
    }

    /// Whole-file transcripts from a single pass cover the recording as one span.
    static func singleSpan(for text: String, duration: TimeInterval) -> [TranscriptSpan]? {
        guard !text.isEmpty, duration.isFinite, duration > 0 else { return nil }
        return [TranscriptSpan(length: text.utf16.count, start: 0, end: duration)]
    }

    // MARK: - Edits

    /// Carries spans across a user edit. Text changed inside one span keeps that
    /// span's times. A change that crosses a boundary between spans leaves no way
    /// to know where the boundary now falls, so the spans it touches merge into
    /// one that runs from the first one's start to the last one's end. A span
    /// whose text is deleted entirely is dropped.
    static func reanchored(_ spans: [TranscriptSpan], from oldText: String, to newText: String) -> [TranscriptSpan]? {
        guard fits(spans, oldText) else { return nil }
        if oldText == newText { return spans }
        let old = Array(oldText.utf16)
        let new = Array(newText.utf16)
        guard !new.isEmpty else { return nil }
        let hunks = changedHunks(from: old, to: new)

        // Boundaries between spans, in old-text offsets.
        var boundaries: [Int] = []
        var offset = 0
        for span in spans.dropLast() {
            offset += span.length
            boundaries.append(offset)
        }

        var result: [TranscriptSpan] = []
        var current = spans[0]
        var currentStart = 0
        for (index, boundary) in boundaries.enumerated() {
            let next = spans[index + 1]
            guard let mapped = mappedBoundary(boundary, through: hunks) else {
                // The edit crossed this boundary: the two spans become one.
                current.end = max(current.end, next.end)
                continue
            }
            current.length = mapped - currentStart
            if current.length > 0 { result.append(current) }
            current = next
            currentStart = mapped
        }
        current.length = new.count - currentStart
        if current.length > 0 { result.append(current) }
        return fits(result, newText) ? result : nil
    }

    /// One contiguous change: `old` characters replaced by `new` ones.
    struct Hunk: Equatable {
        var old: Range<Int>
        var new: Range<Int>
    }

    /// Changes between two texts, in order. Matching heads and tails are cut off
    /// first; a middle too large to diff in reasonable time counts as one change.
    static func changedHunks(from old: [UInt16], to new: [UInt16]) -> [Hunk] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = old[prefix..<(old.count - suffix)]
        let newMiddle = new[prefix..<(new.count - suffix)]
        if oldMiddle.isEmpty && newMiddle.isEmpty { return [] }
        if oldMiddle.isEmpty || newMiddle.isEmpty || oldMiddle.count * newMiddle.count > maxDiffWork {
            return [Hunk(old: prefix..<(old.count - suffix), new: prefix..<(new.count - suffix))]
        }

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in Array(newMiddle).difference(from: Array(oldMiddle)) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Walk both middles together; matched characters advance in step, and
        // each run of removals and insertions between them is one hunk.
        var hunks: [Hunk] = []
        var i = 0
        var j = 0
        while i < oldMiddle.count || j < newMiddle.count {
            if removed.contains(i) || inserted.contains(j) {
                let oldStart = i, newStart = j
                while removed.contains(i) || inserted.contains(j) {
                    while removed.contains(i) { i += 1 }
                    while inserted.contains(j) { j += 1 }
                }
                hunks.append(Hunk(old: (prefix + oldStart)..<(prefix + i), new: (prefix + newStart)..<(prefix + j)))
            } else {
                i += 1
                j += 1
            }
        }
        return hunks
    }

    /// About a quarter second of diffing on a phone; real edits stay far below.
    private static let maxDiffWork = 4_000_000

    /// Where a span boundary lands in the new text, or nil when a change spans it.
    /// Text inserted right at a boundary joins the span before it.
    private static func mappedBoundary(_ boundary: Int, through hunks: [Hunk]) -> Int? {
        var shift = 0
        for hunk in hunks {
            if hunk.old.upperBound == boundary { return hunk.new.upperBound }
            if hunk.old.lowerBound == boundary { return hunk.new.lowerBound }
            if hunk.old.lowerBound < boundary, boundary < hunk.old.upperBound { return nil }
            if hunk.old.upperBound > boundary { break }
            shift = hunk.new.upperBound - hunk.old.upperBound
        }
        return boundary + shift
    }

    // MARK: - Sentences

    /// Splits each span into sentences and gives each one a start time by its
    /// position in the span, assuming an even speaking rate across the span.
    static func units(text: String, spans: [TranscriptSpan]) -> [TranscriptUnit] {
        guard fits(spans, text) else { return [] }
        let utf16 = Array(text.utf16)
        var units: [TranscriptUnit] = []
        var spanLocation = 0
        for span in spans {
            let spanEnd = spanLocation + span.length
            var unitStart = spanLocation
            var index = spanLocation
            while index < spanEnd {
                var end = index + 1
                if endsSentence(utf16, at: index) {
                    // Keep closing quotes and repeated marks with their sentence.
                    while end < spanEnd, closesSentence(utf16[end]) { end += 1 }
                    if end < spanEnd, utf16[end] == newline { end += 1 }
                    appendUnit(&units, from: unitStart, to: end, in: span, spanLocation: spanLocation)
                    unitStart = end
                }
                index = end
            }
            appendUnit(&units, from: unitStart, to: spanEnd, in: span, spanLocation: spanLocation)
            spanLocation = spanEnd
        }
        return units
    }

    private static func appendUnit(_ units: inout [TranscriptUnit], from location: Int, to end: Int,
                                   in span: TranscriptSpan, spanLocation: Int) {
        guard end > location else { return }
        let fraction = Double(location - spanLocation) / Double(span.length)
        let start = span.start + fraction * (span.end - span.start)
        units.append(TranscriptUnit(range: NSRange(location: location, length: end - location),
                                    start: start, spanStart: span.start))
    }

    private static let newline: UInt16 = 0x0A
    private static let period: UInt16 = 0x2E
    private static let space: UInt16 = 0x20
    private static let terminators: Set<UInt16> = Set("。！？!?；;…\n".utf16)
    private static let closers: Set<UInt16> = Set("。！？!?；;….”’」』)）\"'".utf16)

    private static func endsSentence(_ text: [UInt16], at index: Int) -> Bool {
        let character = text[index]
        if terminators.contains(character) { return true }
        // A period ends a sentence only before a space or the end, not in "3.5".
        guard character == period else { return false }
        return index + 1 >= text.count || text[index + 1] == space || text[index + 1] == newline
    }

    private static func closesSentence(_ character: UInt16) -> Bool {
        character != newline && closers.contains(character)
    }

    /// The unit playing at `time`: the last one starting at or before it, so a
    /// silent stretch keeps the previous sentence lit.
    static func unitIndex(at time: TimeInterval, in units: [TranscriptUnit]) -> Int? {
        var low = 0, high = units.count - 1, result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if units[mid].start <= time { result = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return result
    }

    /// The unit to light at `time` while a tapped unit may be held. Playback
    /// starts a little before a tapped sentence, so it stays lit until playback
    /// reaches it; moving back before the seek point, such as dragging the
    /// waveform, ends the hold.
    static func highlight(at time: TimeInterval?, holding tapped: Int?, from seekTime: TimeInterval,
                          in units: [TranscriptUnit]) -> (index: Int?, hold: Int?) {
        let index = time.flatMap { unitIndex(at: $0, in: units) }
        guard let tapped else { return (index, nil) }
        if let index, index >= tapped { return (index, nil) }
        if let time, time < seekTime - 0.25 { return (index, nil) }
        return (tapped, tapped)
    }

    /// The unit holding the character at `location`.
    static func unitIndex(containing location: Int, in units: [TranscriptUnit]) -> Int? {
        var low = 0, high = units.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = units[mid].range
            if location < range.location { high = mid - 1 }
            else if location >= range.location + range.length { low = mid + 1 }
            else { return mid }
        }
        return nil
    }

    /// Estimated starts can be early or late by a few seconds, so a tap starts
    /// playback a little before the sentence, never before its span.
    static func seekTime(for unit: TranscriptUnit) -> TimeInterval {
        max(unit.spanStart, unit.start - seekLeadIn)
    }

    static let seekLeadIn: TimeInterval = 1.0
}
