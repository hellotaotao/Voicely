import Testing
@testable import Voicely

/// Editing a timed transcript must keep word timings coherent: unchanged head and
/// tail keep their stamps, the edited span inherits its position's stamp, and the
/// units always concatenate back to exactly the edited text.
struct WordTokenReanchorTests {
    private let units = [
        WordToken(word: "Hello", start: 0.0, end: 0.5),
        WordToken(word: " world", start: 0.5, end: 1.0),
        WordToken(word: " foo", start: 1.0, end: 1.5),
        WordToken(word: " bar", start: 1.5, end: 2.0),
    ]   // "Hello world foo bar"

    @Test func unchangedTextReturnsSameUnits() {
        #expect(WordToken.reanchored(units, editedText: "Hello world foo bar") == units)
    }

    @Test func resultAlwaysConcatenatesToEditedText() {
        for edited in ["Hello world FOO bar",
                       "Hello world foo bar baz",
                       "Hello world bar",
                       "Hi world foo bar",
                       "",
                       "completely different text"] {
            #expect(WordToken.reanchored(units, editedText: edited).map(\.word).joined() == edited)
        }
    }

    @Test func midEditInheritsItsPositionTimestampAndKeepsEnds() {
        let result = WordToken.reanchored(units, editedText: "Hello world FOO bar")
        #expect(result.count == 4)
        #expect(result[0] == units[0])      // head preserved
        #expect(result[1] == units[1])
        #expect(result[3] == units[3])      // tail preserved
        #expect(result[2].word == " FOO")
        #expect(result[2].start == 1.0)     // inherits old " foo" start
    }

    @Test func appendInheritsLastEnd() {
        let result = WordToken.reanchored(units, editedText: "Hello world foo bar baz")
        #expect(result.count == 5)
        #expect(Array(result.prefix(4)) == units)
        #expect(result[4].word == " baz")
        #expect(result[4].start == 2.0)     // last unit's end time
    }

    @Test func emptyEditClearsUnits() {
        #expect(WordToken.reanchored(units, editedText: "").isEmpty)
    }

    @Test func editingWithNoExistingUnitsMakesOneUnit() {
        #expect(WordToken.reanchored([], editedText: "new text")
                == [WordToken(word: "new text", start: 0, end: 0)])
    }
}
