import SwiftUI
import UIKit

/// A read-only transcript tied to its audio. Tapping a sentence plays from it;
/// as `currentTime` moves, from playback or from dragging the waveform, the
/// sentence being spoken is highlighted and scrolled into view. Scrolling by
/// hand pauses the auto-scroll for a few seconds.
///
/// Search matches are marked too, and `searchJump` scrolls to the current one.
/// With no spans the view only shows text and matches, nothing to tap.
///
/// The text is as tall as it needs to be and scrolls with the page around it,
/// so a long transcript can fill the screen.
///
/// Backed by `UITextView`/TextKit because long recordings hold tens of
/// thousands of characters: one attributed string with an in-place highlight
/// stays cheap where thousands of SwiftUI views would not.
struct TappableTranscriptView: UIViewRepresentable {
    let text: String
    let spans: [TranscriptSpan]
    /// Nil before playback has started, so nothing is lit on arrival.
    var currentTime: TimeInterval?
    /// False holds the page still, for as long as the waveform is being dragged.
    var followsPlayback = true
    /// UTF-16 ranges in `text`.
    var searchRanges: [NSRange] = []
    var currentSearchIndex: Int?
    /// Each change scrolls to the current search match.
    var searchJump = 0
    var onSeek: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }

    func makeUIView(context: Context) -> UITextView {
        let textView = TranscriptTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true          // long-press still selects and copies
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityIdentifier = AccessibilityIdentifiers.Detail.transcriptionBody
        textView.layer.insertSublayer(context.coordinator.highlightLayer, at: 0)
        textView.layer.insertSublayer(context.coordinator.searchLayer, at: 0)
        textView.layer.insertSublayer(context.coordinator.currentSearchLayer, at: 0)
        textView.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.layoutDidChange() }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false      // keep selection gestures working
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.apply(text: text, spans: spans, currentTime: currentTime, followsPlayback: followsPlayback)
        context.coordinator.applySearch(ranges: searchRanges, current: currentSearchIndex, jump: searchJump)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: context.coordinator.height(for: width, in: uiView))
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        coordinator.stopWatchingPage()
    }

    final class Coordinator: NSObject {
        weak var textView: UITextView?
        var onSeek: (TimeInterval) -> Void

        private var builtText = ""
        private var builtSpans: [TranscriptSpan] = []
        private var units: [TranscriptUnit] = []
        private var measured: (width: CGFloat, height: CGFloat)?
        private var highlightedIndex: Int?
        /// The tapped sentence stays lit while playback runs up to it from the
        /// seek point, which lands a little before it in the previous sentence.
        private var tappedIndex: Int?
        private var tapSeekTime: TimeInterval = 0
        private var autoScrollPausedUntil: Date = .distantPast
        private var followsPlayback = true
        private weak var page: UIScrollView?
        /// The player card stays pinned over the top of the page.
        private let pinnedPlayerHeight: CGFloat = 150

        private let highlightColor = UIColor(VoicelyTheme.accent).withAlphaComponent(0.22)
        let highlightLayer = CAShapeLayer()

        private var searchRanges: [NSRange] = []
        private var currentSearchIndex: Int?
        private var searchJump = 0
        private var pendingSearchJump = false
        private let searchColor = UIColor.systemYellow.withAlphaComponent(0.35)
        private let currentSearchColor = UIColor.systemOrange.withAlphaComponent(0.55)
        let searchLayer = CAShapeLayer()
        let currentSearchLayer = CAShapeLayer()

        init(onSeek: @escaping (TimeInterval) -> Void) { self.onSeek = onSeek }

        /// Rebuilds the text only when the transcript changes; otherwise only
        /// moves the highlight. Runs about ten times a second during playback.
        func apply(text: String, spans: [TranscriptSpan], currentTime: TimeInterval?, followsPlayback: Bool) {
            guard let textView else { return }
            if text != builtText || spans != builtSpans {
                rebuild(text: text, spans: spans, in: textView)
            }
            let scrubbingEnded = followsPlayback && !self.followsPlayback
            self.followsPlayback = followsPlayback
            updateHighlight(for: currentTime)
            if scrubbingEnded, let highlightedIndex {
                scrollToUnit(highlightedIndex, in: textView)
            }
        }

        func applySearch(ranges: [NSRange], current: Int?, jump: Int) {
            // Ranges found in a newer transcript than the one shown wait for it.
            let length = (builtText as NSString).length
            let valid = ranges.filter { NSMaxRange($0) <= length }
            if valid != searchRanges || current != currentSearchIndex {
                searchRanges = valid
                currentSearchIndex = current
                redrawSearch()
            }
            if jump != searchJump {
                searchJump = jump
                pendingSearchJump = true
                performPendingSearchJump(retries: 5)
            }
        }

        func layoutDidChange() {
            redrawHighlight()
            redrawSearch()
            performPendingSearchJump(retries: 0)
        }

        /// The first jump can come before the page has laid the text out.
        private func performPendingSearchJump(retries: Int) {
            guard pendingSearchJump, let textView else { return }
            guard let currentSearchIndex, currentSearchIndex < searchRanges.count else {
                pendingSearchJump = false
                return
            }
            if scroll(to: searchRanges[currentSearchIndex], in: textView, force: true) {
                pendingSearchJump = false
                // Playback would pull the page straight back to the spoken sentence.
                autoScrollPausedUntil = Date().addingTimeInterval(4)
            } else if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.performPendingSearchJump(retries: retries - 1)
                }
            }
        }

        private func redrawSearch() {
            guard let textView else { return }
            let others = CGMutablePath()
            let current = CGMutablePath()
            for (index, range) in searchRanges.enumerated() {
                addRects(for: range, in: textView, to: index == currentSearchIndex ? current : others)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            searchLayer.fillColor = searchColor.resolvedColor(with: textView.traitCollection).cgColor
            searchLayer.path = others
            currentSearchLayer.fillColor = currentSearchColor.resolvedColor(with: textView.traitCollection).cgColor
            currentSearchLayer.path = current
            CATransaction.commit()
        }

        private func addRects(for range: NSRange, in textView: UITextView, to path: CGMutablePath) {
            let layoutManager = textView.layoutManager
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let inset = textView.textContainerInset
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textView.textContainer
            ) { rect, _ in
                path.addRect(rect.offsetBy(dx: inset.left, dy: inset.top))
            }
        }

        /// Playback updates the view about ten times a second, and measuring a
        /// long transcript takes far longer than that allows.
        func height(for width: CGFloat, in textView: UITextView) -> CGFloat {
            if let measured, measured.width == width { return measured.height }
            let fitted = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            measured = (width, fitted.height)
            return fitted.height
        }

        private func rebuild(text: String, spans: [TranscriptSpan], in textView: UITextView) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            textView.attributedText = NSAttributedString(string: text, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ])
            // New text leaves the caret at its end, and the page would scroll there.
            textView.selectedRange = NSRange(location: 0, length: 0)
            builtText = text
            builtSpans = spans
            measured = nil
            units = TranscriptTimeline.units(text: text, spans: spans)
            highlightedIndex = nil
            tappedIndex = nil
            searchRanges = []
            currentSearchIndex = nil
            redrawHighlight()
            redrawSearch()
        }

        private func updateHighlight(for time: TimeInterval?) {
            let highlight = TranscriptTimeline.highlight(at: time, holding: tappedIndex, from: tapSeekTime, in: units)
            tappedIndex = highlight.hold
            setHighlight(highlight.index)
        }

        private func setHighlight(_ index: Int?) {
            guard let textView, index != highlightedIndex else { return }
            highlightedIndex = index
            redrawHighlight()
            if let index { scrollToUnit(index, in: textView) }
        }

        /// Draws behind the text. A background attribute would lay the whole
        /// transcript out again on every sentence, since all of it is on the page.
        func redrawHighlight() {
            guard let textView else { return }
            let path = CGMutablePath()
            if let highlightedIndex, highlightedIndex < units.count {
                addRects(for: units[highlightedIndex].range, in: textView, to: path)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.fillColor = highlightColor.resolvedColor(with: textView.traitCollection).cgColor
            highlightLayer.path = path
            CATransaction.commit()
        }

        private func scrollToUnit(_ index: Int, in textView: UITextView) {
            scroll(to: units[index].range, in: textView, force: false)
        }

        /// Brings the range into view unless it already is. `force` ignores
        /// the pauses that hold playback's auto-scroll back. Returns false
        /// when the page was not ready to scroll.
        @discardableResult
        private func scroll(to range: NSRange, in textView: UITextView, force: Bool) -> Bool {
            guard let page = watchedPage(of: textView), textView.bounds.height > 0, page.bounds.height > 0 else { return false }
            guard force || (followsPlayback && Date() >= autoScrollPausedUntil) else { return true }
            let layoutManager = textView.layoutManager
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
            rect.origin.y += textView.textContainerInset.top
            let target = textView.convert(rect, to: page)

            let insets = page.adjustedContentInset
            let coveredTop = insets.top + pinnedPlayerHeight
            let visibleHeight = page.bounds.height - coveredTop - insets.bottom
            let visible = CGRect(x: target.minX, y: page.contentOffset.y + coveredTop, width: target.width, height: visibleHeight)
                .insetBy(dx: 0, dy: 40)
            guard !visible.contains(target) else { return true }

            let lowest = -insets.top
            let highest = max(lowest, page.contentSize.height - page.bounds.height + insets.bottom)
            let offset = target.minY - coveredTop - visibleHeight / 3
            page.setContentOffset(CGPoint(x: page.contentOffset.x, y: min(max(lowest, offset), highest)), animated: true)
            return true
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
            let seekTime = TranscriptTimeline.seekTime(for: units[index])
            tappedIndex = index
            tapSeekTime = seekTime
            setHighlight(index)
            onSeek(seekTime)
        }

        // MARK: Scrolling by hand pauses auto-scroll

        private func watchedPage(of textView: UITextView) -> UIScrollView? {
            if let page { return page }
            var view = textView.superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            page = view as? UIScrollView
            page?.panGestureRecognizer.addTarget(self, action: #selector(handlePagePan(_:)))
            return page
        }

        func stopWatchingPage() {
            page?.panGestureRecognizer.removeTarget(self, action: #selector(handlePagePan(_:)))
            page = nil
        }

        @objc private func handlePagePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                autoScrollPausedUntil = .distantFuture
            default:
                autoScrollPausedUntil = Date().addingTimeInterval(4)
            }
        }
    }
}

/// Lines rewrap when the width changes, which moves the highlight.
private final class TranscriptTextView: UITextView {
    var onWidthChange: (() -> Void)?
    private var laidOutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width != laidOutWidth else { return }
        laidOutWidth = bounds.width
        onWidthChange?()
    }
}
