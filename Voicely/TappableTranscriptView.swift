import SwiftUI
import UIKit

/// A read-only transcript rendered straight from word-level timings. Whisper
/// often stamps a whole phrase with a single timestamp, so consecutive words
/// that share a start are merged into one *unit*: seek + highlight operate on
/// the unit, and tapping any word in it lights the whole unit. As `currentTime`
/// advances the active unit is highlighted and scrolled into view (karaoke
/// style); auto-scroll pauses briefly after the user scrolls by hand.
///
/// Backed by `UITextView`/TextKit because long recordings hold tens of thousands
/// of words — one attributed string with in-place highlight stays cheap, where
/// thousands of SwiftUI word views would not.
struct TappableTranscriptView: UIViewRepresentable {
    let words: [WordToken]
    var currentTime: Double
    var onWordTap: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onWordTap: onWordTap) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true          // long-press still selects/copies
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false       // don't swallow selection gestures
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onWordTap = onWordTap
        context.coordinator.apply(words: words, currentTime: currentTime)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        weak var textView: UITextView?
        var onWordTap: (Double) -> Void

        // One entry per *unit* (a run of words sharing a timestamp), not per word.
        private var unitRanges: [NSRange] = []
        private var unitStarts: [Double] = []
        private var builtWords: [WordToken] = []
        private var highlightedIndex = -1
        /// After a tap we light the tapped unit immediately and hold it here until
        /// playback actually reaches it, so the sync-lead can't snap it backward.
        private var postTapFloorIndex = -1
        private var autoScrollPausedUntil: Date = .distantPast

        private let highlightColor = UIColor(VoicelyTheme.accent).withAlphaComponent(0.30)

        /// Whisper marks unit starts a touch early (worst right after each VAD
        /// cut), so the marker races the voice. Hold the highlight back by this
        /// many seconds to sync it to what's actually being spoken. Tap-to-seek
        /// is unaffected — it still uses each unit's true start. Tunable by feel.
        private let syncLead: Double = 1.6

        init(onWordTap: @escaping (Double) -> Void) { self.onWordTap = onWordTap }

        /// Rebuilds the text only when the word set changes; otherwise just moves
        /// the highlight. Called ~10×/s while playing, so the hot path is cheap:
        /// the array comparison hits the identical-storage fast path when SwiftUI
        /// hands over the same cached array, and pays O(n) once per real change.
        func apply(words: [WordToken], currentTime: Double) {
            guard let textView else { return }
            if words != builtWords {
                rebuild(words: words, in: textView)
                builtWords = words
                highlightedIndex = -1
                postTapFloorIndex = -1
            }
            updateHighlight(for: currentTime)
        }

        private func rebuild(words: [WordToken], in textView: UITextView) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ]
            let full = NSMutableAttributedString()
            var perWord: [(location: Int, length: Int, start: Double)] = []
            perWord.reserveCapacity(words.count)
            for word in words {
                let location = full.length
                full.append(NSAttributedString(string: word.word, attributes: attributes))
                perWord.append((location, full.length - location, word.start))
            }

            // Merge consecutive words that share a start time into one unit, so a
            // phrase Whisper stamped with a single timestamp highlights and seeks
            // as a whole rather than snapping to its first word.
            var ranges: [NSRange] = []
            var starts: [Double] = []
            var i = 0
            while i < perWord.count {
                let groupStart = perWord[i].start
                let location = perWord[i].location
                var j = i
                while j + 1 < perWord.count && perWord[j + 1].start == groupStart { j += 1 }
                let end = perWord[j].location + perWord[j].length
                ranges.append(NSRange(location: location, length: end - location))
                starts.append(groupStart)
                i = j + 1
            }
            unitRanges = ranges
            unitStarts = starts
            textView.attributedText = full
        }

        private func updateHighlight(for time: Double) {
            guard !unitStarts.isEmpty else { return }
            var idx = activeIndex(for: max(0, time - syncLead))
            // Keep the just-tapped unit lit until playback catches up to it.
            if postTapFloorIndex >= 0 {
                if idx >= postTapFloorIndex { postTapFloorIndex = -1 }
                else { idx = postTapFloorIndex }
            }
            setHighlight(idx)
        }

        private func setHighlight(_ idx: Int) {
            guard let textView, idx != highlightedIndex else { return }
            let storage = textView.textStorage
            storage.beginEditing()
            if highlightedIndex >= 0, highlightedIndex < unitRanges.count {
                storage.removeAttribute(.backgroundColor, range: unitRanges[highlightedIndex])
            }
            if idx >= 0, idx < unitRanges.count {
                storage.addAttribute(.backgroundColor, value: highlightColor, range: unitRanges[idx])
            }
            storage.endEditing()
            highlightedIndex = idx
            if idx >= 0 { scrollToUnit(idx, in: textView) }
        }

        /// Last unit whose start is at or before `time` (so gaps keep the prior
        /// unit lit instead of flickering off).
        private func activeIndex(for time: Double) -> Int {
            var lo = 0, hi = unitStarts.count - 1, result = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if unitStarts[mid] <= time { result = mid; lo = mid + 1 }
                else { hi = mid - 1 }
            }
            return result
        }

        private func scrollToUnit(_ idx: Int, in textView: UITextView) {
            guard Date() >= autoScrollPausedUntil else { return }
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: unitRanges[idx], actualCharacterRange: nil)
            var rect = textView.layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: textView.textContainer)
            rect.origin.y += textView.textContainerInset.top
            let target = rect.midY - textView.bounds.height / 2
            let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
            let y = min(max(0, target), maxOffset)
            textView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView, !unitRanges.isEmpty else { return }
            var point = gesture.location(in: textView)
            point.x -= textView.textContainerInset.left
            point.y -= textView.textContainerInset.top
            let charIndex = textView.layoutManager.characterIndex(
                for: point, in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil)
            guard let idx = unitIndex(forChar: charIndex) else { return }
            // Tap anywhere in a unit → light the whole unit now and seek to its start.
            postTapFloorIndex = idx
            setHighlight(idx)
            onWordTap(unitStarts[idx])
        }

        /// Binary search the contiguous, ascending unit ranges for `charIndex`.
        private func unitIndex(forChar charIndex: Int) -> Int? {
            var lo = 0, hi = unitRanges.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = unitRanges[mid]
                if charIndex < r.location { hi = mid - 1 }
                else if charIndex >= r.location + r.length { lo = mid + 1 }
                else { return mid }
            }
            return nil
        }

        // MARK: - Manual scroll pauses auto-follow (~4 s)

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            autoScrollPausedUntil = .distantFuture
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { autoScrollPausedUntil = Date().addingTimeInterval(4) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            autoScrollPausedUntil = Date().addingTimeInterval(4)
        }
    }
}
