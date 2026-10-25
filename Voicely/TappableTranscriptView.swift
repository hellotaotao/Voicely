import SwiftUI
import UIKit

/// A read-only transcript tied to its audio. Tapping a sentence plays from it;
/// as `currentTime` moves, from playback or from dragging the waveform, the
/// sentence being spoken is highlighted and scrolled into view. Scrolling by
/// hand pauses the auto-scroll for a few seconds.
///
/// Backed by `UITextView`/TextKit because long recordings hold tens of
/// thousands of characters: one attributed string with an in-place highlight
/// stays cheap where thousands of SwiftUI views would not.
struct TappableTranscriptView: UIViewRepresentable {
    let text: String
    let spans: [TranscriptSpan]
    /// Nil before playback has started, so nothing is lit on arrival.
    var currentTime: TimeInterval?
    var onSeek: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true          // long-press still selects and copies
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.accessibilityIdentifier = AccessibilityIdentifiers.Detail.transcriptionBody

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false      // keep selection gestures working
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.apply(text: text, spans: spans, currentTime: currentTime)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        weak var textView: UITextView?
        var onSeek: (TimeInterval) -> Void

        private var builtText = ""
        private var builtSpans: [TranscriptSpan] = []
        private var units: [TranscriptUnit] = []
        private var highlightedIndex: Int?
        /// The tapped sentence stays lit until playback reaches it; the seek
        /// lands a little before it, inside the previous sentence.
        private var tappedIndex: Int?
        private var autoScrollPausedUntil: Date = .distantPast

        private let highlightColor = UIColor(VoicelyTheme.accent).withAlphaComponent(0.22)

        init(onSeek: @escaping (TimeInterval) -> Void) { self.onSeek = onSeek }

        /// Rebuilds the text only when the transcript changes; otherwise only
        /// moves the highlight. Runs about ten times a second during playback.
        func apply(text: String, spans: [TranscriptSpan], currentTime: TimeInterval?) {
            guard let textView else { return }
            if text != builtText || spans != builtSpans {
                rebuild(text: text, spans: spans, in: textView)
            }
            updateHighlight(for: currentTime)
        }

        private func rebuild(text: String, spans: [TranscriptSpan], in textView: UITextView) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            textView.attributedText = NSAttributedString(string: text, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ])
            builtText = text
            builtSpans = spans
            units = TranscriptTimeline.units(text: text, spans: spans)
            highlightedIndex = nil
            tappedIndex = nil
        }

        private func updateHighlight(for time: TimeInterval?) {
            var index = time.flatMap { TranscriptTimeline.unitIndex(at: $0, in: units) }
            if let tapped = tappedIndex {
                if let index, index >= tapped { tappedIndex = nil } else { index = tapped }
            }
            setHighlight(index)
        }

        private func setHighlight(_ index: Int?) {
            guard let textView, index != highlightedIndex else { return }
            let storage = textView.textStorage
            storage.beginEditing()
            if let old = highlightedIndex, old < units.count {
                storage.removeAttribute(.backgroundColor, range: units[old].range)
            }
            if let index, index < units.count {
                storage.addAttribute(.backgroundColor, value: highlightColor, range: units[index].range)
            }
            storage.endEditing()
            highlightedIndex = index
            if let index { scrollToUnit(index, in: textView) }
        }

        private func scrollToUnit(_ index: Int, in textView: UITextView) {
            guard Date() >= autoScrollPausedUntil, textView.bounds.height > 0 else { return }
            let layoutManager = textView.layoutManager
            let glyphRange = layoutManager.glyphRange(forCharacterRange: units[index].range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
            rect.origin.y += textView.textContainerInset.top
            let visible = CGRect(origin: textView.contentOffset, size: textView.bounds.size).insetBy(dx: 0, dy: 40)
            guard !visible.contains(rect) else { return }
            let target = rect.minY - textView.bounds.height / 3
            let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
            textView.setContentOffset(CGPoint(x: 0, y: min(max(0, target), maxOffset)), animated: true)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView, !units.isEmpty else { return }
            // A tap that ends a selection, or lands on a selection, is not a seek.
            guard textView.selectedRange.length == 0 else { return }
            var point = gesture.location(in: textView)
            point.x -= textView.textContainerInset.left
            point.y -= textView.textContainerInset.top
            let layoutManager = textView.layoutManager
            let glyphIndex = layoutManager.glyphIndex(for: point, in: textView.textContainer, fractionOfDistanceThroughGlyph: nil)
            // Taps below the last line resolve to the last glyph; ignore them.
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            guard point.y <= lineRect.maxY else { return }
            let location = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard let index = TranscriptTimeline.unitIndex(containing: location, in: units) else { return }
            tappedIndex = index
            setHighlight(index)
            onSeek(TranscriptTimeline.seekTime(for: units[index]))
        }

        // MARK: Scrolling by hand pauses auto-scroll

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
