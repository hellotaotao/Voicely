//
//  NoteSearch.swift
//  Voicely
//
//  One matching rule for the library search, so a note the list keeps always
//  has something to highlight once it is opened.
//

import Foundation
import SwiftUI

enum NoteSearch {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    /// Enough to page through; a one-letter query in a long transcript can hit
    /// tens of thousands of times.
    static let matchLimit = 2_000

    static func query(_ searchText: String) -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func contains(_ text: String, _ query: String) -> Bool {
        !ranges(of: query, in: text, limit: 1).isEmpty
    }

    /// UTF-16 ranges, ready for TextKit. A query with Chinese characters
    /// matches in Simplified and Traditional alike: both sides are compared in
    /// Simplified, and that conversion keeps every character in place, so the
    /// ranges still apply to `text` as shown.
    static func ranges(of query: String, in text: String, limit: Int = matchLimit) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var query = query
        var text = text
        if ChineseScriptConverter.containsHan(query) {
            let simplified = ChineseScriptConverter.simplified
            query = simplified.convert(query)
            text = simplified.convertKeepingLength(text)
        }
        let string = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while ranges.count < limit {
            let found = string.range(of: query, options: options, range: searchRange, locale: .current)
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return ranges
    }

    /// The part of `text` around its first match: from the start of that
    /// sentence when it is close, otherwise a little before the match.
    static func snippet(of text: String, matching query: String) -> AttributedString? {
        guard let first = ranges(of: query, in: text, limit: 1).first else { return nil }
        let string = text as NSString
        let lookBack = 60
        let floor = max(0, first.location - lookBack)
        var start = floor
        var startsSentence = floor == 0
        var index = first.location - 1
        while index >= floor {
            if isSentenceEnd(string.character(at: index)) {
                start = index + 1
                startsSentence = true
                break
            }
            index -= 1
        }
        if !startsSentence {
            start = max(0, first.location - 24)
        }
        start = string.rangeOfComposedCharacterSequence(at: start).location
        let end = min(string.length, first.location + first.length + 200)
        let excerpt = string.substring(with: NSRange(location: start, length: end - start))
        let leading = excerpt.prefix { $0.isWhitespace }.utf16.count
        let trimmed = String(excerpt.dropFirst(excerpt.prefix { $0.isWhitespace }.count))
        let match = NSRange(location: first.location - start - leading, length: first.length)
        var result = highlighted(trimmed, ranges: [match])
        if !startsSentence {
            result = AttributedString("…") + result
        }
        return result
    }

    /// `text` with every range marked the way the list marks a match.
    static func highlighted(_ text: String, ranges: [NSRange]) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for range in ranges {
            guard let match = Range(range, in: text), match.lowerBound >= cursor else { continue }
            result += AttributedString(String(text[cursor..<match.lowerBound]))
            var marked = AttributedString(String(text[match]))
            marked.inlinePresentationIntent = .stronglyEmphasized
            marked.backgroundColor = Color.yellow.opacity(0.4)
            result += marked
            cursor = match.upperBound
        }
        result += AttributedString(String(text[cursor...]))
        return result
    }

    private static func isSentenceEnd(_ unit: unichar) -> Bool {
        switch unit {
        case 0x2E, 0x21, 0x3F, 0x0A, 0x3002, 0xFF01, 0xFF1F: // . ! ? newline 。！？
            return true
        default:
            return false
        }
    }
}
