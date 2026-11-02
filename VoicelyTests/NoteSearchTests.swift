//
//  NoteSearchTests.swift
//  VoicelyTests
//

import Foundation
import Testing
@testable import Voicely

struct NoteSearchTests {

    private func marked(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(text[$0.range].characters) }
    }

    @Test func rangesIgnoreCaseAccentsAndWidth() {
        let text = "Café budget. CAFE again, ｃａｆｅ too."
        let ranges = NoteSearch.ranges(of: "cafe", in: text)
        let found = ranges.map { (text as NSString).substring(with: $0) }
        #expect(found == ["Café", "CAFE", "ｃａｆｅ"])
        #expect(NoteSearch.ranges(of: "", in: text).isEmpty)
        #expect(NoteSearch.ranges(of: "e", in: text, limit: 2).count == 2)
    }

    @Test func snippetStartsAtTheSentenceHoldingTheMatch() throws {
        let text = "第一句很长很长。下周把预算表发给财务，然后开会。最后一句。"
        let snippet = try #require(NoteSearch.snippet(of: text, matching: "预算"))
        #expect(String(snippet.characters).hasPrefix("下周把预算表"))
        #expect(marked(snippet) == ["预算"])
    }

    @Test func snippetCutsIntoALongSentenceWithAnEllipsis() throws {
        let filler = String(repeating: "word ", count: 30)
        let text = filler + "the Budget review is due"
        let snippet = try #require(NoteSearch.snippet(of: text, matching: "budget"))
        let plain = String(snippet.characters)
        #expect(plain.hasPrefix("…"))
        #expect(plain.contains("the Budget review"))
        #expect(plain.count < text.count)
        #expect(marked(snippet) == ["Budget"])
    }

    @Test func snippetIsNilWithoutAMatch() {
        #expect(NoteSearch.snippet(of: "nothing here", matching: "budget") == nil)
    }

    @Test func highlightingKeepsTheWholeText() {
        let text = "a 预算 b 预算"
        let attributed = NoteSearch.highlighted(text, ranges: NoteSearch.ranges(of: "预算", in: text))
        #expect(String(attributed.characters) == text)
        #expect(marked(attributed) == ["预算", "预算"])
    }
}
