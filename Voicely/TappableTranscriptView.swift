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
    struct SpeakerRenameSession {
        let initialName: String
        let defaultName: String
        let save: (String) throws -> Void
    }

    let text: String
    let spans: [TranscriptSpan]
    var speakerPresentation: SpeakerTranscriptPresentation?
    /// Nil before playback has started, so nothing is lit on arrival.
    var currentTime: TimeInterval?
    /// False holds the page still, for as long as the waveform is being dragged.
    var followsPlayback = true
    /// UTF-16 ranges in `text`.
    var searchRanges: [NSRange] = []
    var currentSearchIndex: Int?
    /// Each change scrolls to the current search match.
    var searchJump = 0
    var onBeginSpeakerRename: ((Int) -> SpeakerRenameSession?)?
    var onSpeakerRenameError: ((Error) -> Void)?
    var onSeek: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }

    func makeUIView(context: Context) -> TranscriptSurface {
        let surface = TranscriptSurface(frame: .zero)
        let textView = surface.textView
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
        surface.onLayout = { [weak coordinator = context.coordinator] widthChanged in
            coordinator?.layoutDidChange(widthChanged: widthChanged)
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false      // keep selection gestures working
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        context.coordinator.surface = surface
        return surface
    }

    func updateUIView(_ surface: TranscriptSurface, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.onBeginSpeakerRename = onBeginSpeakerRename
        context.coordinator.onSpeakerRenameError = onSpeakerRenameError
        context.coordinator.apply(text: text, spans: spans, speakerPresentation: speakerPresentation,
                                  currentTime: currentTime, followsPlayback: followsPlayback)
        context.coordinator.applySearch(ranges: searchRanges, current: currentSearchIndex, jump: searchJump)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TranscriptSurface, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: context.coordinator.height(for: width, in: uiView.textView))
    }

    static func dismantleUIView(_ uiView: TranscriptSurface, coordinator: Coordinator) {
        coordinator.cancelSpeakerRename()
        coordinator.stopWatchingPage()
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        weak var textView: UITextView?
        weak var surface: TranscriptSurface?
        var onSeek: (TimeInterval) -> Void
        var onBeginSpeakerRename: ((Int) -> SpeakerRenameSession?)?
        var onSpeakerRenameError: ((Error) -> Void)?

        private var builtText = ""
        private var builtSpans: [TranscriptSpan] = []
        private var builtSpeakers: SpeakerTranscriptPresentation?
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

        private struct RenameControl {
            let heading: SpeakerTranscriptPresentation.EditableHeading
            let button: UIButton
        }
        private struct ActiveRename {
            let index: Int
            let session: SpeakerRenameSession
            let editor: TranscriptSpeakerInlineEditor
        }
        private var renameEnabled = false
        private var renameControls: [RenameControl] = []
        private var activeRename: ActiveRename?
        private var needsRenameLayout = false
        private let renameSide: CGFloat = ProcessInfo.processInfo.isMacCatalystApp ? 30 : 44

        private let highlightColor = UIColor(VoicelyTheme.accent).withAlphaComponent(0.22)
        let highlightLayer = CAShapeLayer()

        private var sourceSearchRanges: [NSRange]?
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
        func apply(text: String, spans: [TranscriptSpan], speakerPresentation: SpeakerTranscriptPresentation?,
                   currentTime: TimeInterval?, followsPlayback: Bool) {
            guard let textView else { return }
            let displayText = speakerPresentation?.text ?? text
            let canRename = onBeginSpeakerRename != nil && speakerPresentation?.editableHeadings.isEmpty == false
            if displayText != builtText || spans != builtSpans || speakerPresentation != builtSpeakers
                || canRename != renameEnabled {
                cancelSpeakerRename()
                renameEnabled = canRename
                rebuild(text: displayText, spans: spans, speakerPresentation: speakerPresentation, in: textView)
            }
            let scrubbingEnded = followsPlayback && !self.followsPlayback
            self.followsPlayback = followsPlayback
            updateHighlight(for: currentTime)
            if scrubbingEnded, let highlightedIndex {
                scrollToUnit(highlightedIndex, in: textView)
            }
        }

        func applySearch(ranges: [NSRange], current: Int?, jump: Int) {
            let rangesChanged = ranges != sourceSearchRanges
            if rangesChanged {
                sourceSearchRanges = ranges
                // Ranges found in a newer transcript than the one shown wait for it.
                let length = (builtText as NSString).length
                let mapped = builtSpeakers.map { presentation in ranges.map { presentation.displayRange(for: $0) } } ?? ranges
                searchRanges = mapped.filter { NSMaxRange($0) <= length }
            }
            if rangesChanged || current != currentSearchIndex {
                currentSearchIndex = current
                redrawSearch()
            }
            if jump != searchJump {
                searchJump = jump
                pendingSearchJump = true
                performPendingSearchJump(retries: 5)
            }
        }

        func layoutDidChange(widthChanged: Bool) {
            if widthChanged {
                redrawHighlight()
                redrawSearch()
            }
            if widthChanged || needsRenameLayout {
                layoutSpeakerControls()
            }
            performPendingSearchJump(retries: 0)
        }

        /// The first jump can come before the page has laid the text out.
        private func performPendingSearchJump(retries: Int) {
            guard pendingSearchJump, activeRename == nil, let textView else { return }
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
                for textRange in builtSpeakers?.textRanges(in: range) ?? [range] where textRange.length > 0 {
                    addRects(for: textRange, in: textView, to: index == currentSearchIndex ? current : others)
                }
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

        private func rebuild(text: String, spans: [TranscriptSpan],
                             speakerPresentation: SpeakerTranscriptPresentation?, in textView: UITextView) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            let formatted = NSMutableAttributedString(string: text, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ])
            let caption = UIFont.preferredFont(forTextStyle: .subheadline)
            let headingFont = caption.fontDescriptor.withSymbolicTraits(.traitBold).map {
                UIFont(descriptor: $0, size: caption.pointSize)
            } ?? caption
            for heading in speakerPresentation?.headings ?? [] {
                formatted.addAttributes([.font: headingFont, .foregroundColor: UIColor.secondaryLabel], range: heading)
            }
            let editableHeadings = renameEnabled ? speakerPresentation?.editableHeadings ?? [] : []
            if !editableHeadings.isEmpty {
                let rtl = textView.effectiveUserInterfaceLayoutDirection == .rightToLeft
                let headingParagraph = NSMutableParagraphStyle()
                headingParagraph.lineSpacing = paragraph.lineSpacing
                headingParagraph.minimumLineHeight = renameSide
                headingParagraph.tailIndent = -(renameSide + 2)
                headingParagraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
                headingParagraph.alignment = rtl ? .right : .left
                for heading in editableHeadings {
                    // Style the whole paragraph, including its terminating newline;
                    // no character or placeholder is inserted in the transcript.
                    let range = NSRange(location: heading.range.location, length: heading.range.length + 1)
                    formatted.addAttribute(.paragraphStyle, value: headingParagraph, range: range)
                }
            }
            textView.attributedText = formatted
            // New text leaves the caret at its end, and the page would scroll there.
            textView.selectedRange = NSRange(location: 0, length: 0)
            builtText = text
            builtSpans = spans
            builtSpeakers = speakerPresentation
            measured = nil
            units = speakerPresentation?.playbackUnits ?? TranscriptTimeline.units(text: text, spans: spans)
            highlightedIndex = nil
            tappedIndex = nil
            sourceSearchRanges = nil
            searchRanges = []
            currentSearchIndex = nil
            redrawHighlight()
            redrawSearch()
            replaceSpeakerControls(editableHeadings, in: text)
        }

        // MARK: Speaker rename

        private func replaceSpeakerControls(_ headings: [SpeakerTranscriptPresentation.EditableHeading], in text: String) {
            renameControls.forEach { $0.button.removeFromSuperview() }
            renameControls.removeAll(keepingCapacity: true)
            guard let surface else { return }
            let string = text as NSString
            for (index, heading) in headings.enumerated() {
                let name = string.substring(with: heading.range)
                let button = UIButton(type: .system)
                button.tag = index
                button.tintColor = .secondaryLabel
                button.setImage(UIImage(systemName: "pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13)),
                                for: .normal)
                button.accessibilityLabel = String(localized: "Rename \(name)")
                button.accessibilityIdentifier = "RenameSpeaker-\(heading.speakerID)-\(index)"
                button.addTarget(self, action: #selector(beginSpeakerRename(_:)), for: .touchUpInside)
                button.isHidden = true
                surface.controls.addSubview(button)
                renameControls.append(RenameControl(heading: heading, button: button))
            }
            needsRenameLayout = true
            surface.setNeedsLayout()
        }

        private func layoutSpeakerControls() {
            guard let surface, let textView, textView.bounds.width > 0 else { return }
            needsRenameLayout = false
            guard !renameControls.isEmpty else { return }
            let manager = textView.layoutManager
            let container = textView.textContainer
            let inset = textView.textContainerInset
            let rtl = textView.effectiveUserInterfaceLayoutDirection == .rightToLeft
            manager.ensureLayout(for: container)
            let lane = CGRect(x: inset.left, y: 0, width: max(0, surface.bounds.width - inset.left - inset.right),
                              height: surface.bounds.height)
            for (index, control) in renameControls.enumerated() {
                let glyphs = manager.glyphRange(forCharacterRange: control.heading.range, actualCharacterRange: nil)
                guard glyphs.length > 0, NSMaxRange(glyphs) <= manager.numberOfGlyphs else {
                    control.button.isHidden = true
                    continue
                }
                let lastGlyph = NSMaxRange(glyphs) - 1
                let lastLine = manager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
                    .offsetBy(dx: inset.left, dy: inset.top)
                if let activeRename, activeRename.index == index {
                    let firstLine = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                        .offsetBy(dx: inset.left, dy: inset.top)
                    activeRename.editor.frame = CGRect(x: lane.minX, y: firstLine.minY, width: lane.width,
                                                       height: max(renameSide, lastLine.maxY - firstLine.minY))
                    control.button.isHidden = true
                } else {
                    let used = manager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
                        .offsetBy(dx: inset.left, dy: inset.top)
                    if let frame = TranscriptSpeakerRenameLayout.pencilFrame(
                        at: used, line: lastLine, within: lane, side: renameSide, rightToLeft: rtl
                    ) {
                        control.button.frame = frame
                        control.button.isHidden = false
                    } else {
                        control.button.isHidden = true
                    }
                }
            }
        }

        @objc private func beginSpeakerRename(_ sender: UIButton) {
            guard let surface, let textView, renameControls.indices.contains(sender.tag),
                  renameControls[sender.tag].button === sender, !sender.isHidden else { return }
            let heading = renameControls[sender.tag].heading
            guard let session = onBeginSpeakerRename?(heading.speakerID) else { return }
            cancelSpeakerRename()
            let editor = TranscriptSpeakerInlineEditor(side: renameSide, initialName: session.initialName,
                                                       placeholder: session.defaultName)
            editor.field.delegate = self
            editor.field.onEscape = { [weak self] in self?.cancelSpeakerRename() }
            editor.save.addTarget(self, action: #selector(saveSpeakerRename), for: .touchUpInside)
            editor.cancel.addTarget(self, action: #selector(cancelSpeakerRename), for: .touchUpInside)
            activeRename = ActiveRename(index: sender.tag, session: session, editor: editor)
            surface.controls.addSubview(editor)
            layoutSpeakerControls()
            if let page = watchedPage(of: textView) {
                // Stop a playback-follow animation already started before the tap.
                page.setContentOffset(page.contentOffset, animated: false)
            }
            if editor.field.becomeFirstResponder() {
                editor.field.selectAll(nil)
            }
        }

        @objc private func saveSpeakerRename() {
            // Return and the Save button must both wait for IME composition.
            guard let activeRename, activeRename.editor.field.markedTextRange == nil else { return }
            do {
                try activeRename.session.save(activeRename.editor.field.text ?? "")
                cancelSpeakerRename()
            } catch {
                onSpeakerRenameError?(error)
            }
        }

        @objc func cancelSpeakerRename() {
            guard let activeRename else { return }
            self.activeRename = nil
            activeRename.editor.field.resignFirstResponder()
            activeRename.editor.removeFromSuperview()
            autoScrollPausedUntil = Date().addingTimeInterval(4)
            needsRenameLayout = true
            surface?.setNeedsLayout()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard textField === activeRename?.editor.field else { return true }
            saveSpeakerRename()
            return false
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
            guard activeRename == nil else { return false }
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
            guard let textView, !units.isEmpty, activeRename == nil else { return }
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

/// Keep controls beside, rather than inside, the text view. Buttons and the
/// inline editor never go through the transcript's selection or playback gestures.
final class TranscriptSurface: UIView {
    let textView = UITextView(usingTextLayoutManager: false)
    fileprivate let controls = TranscriptSpeakerControls(frame: .zero)
    var onLayout: ((Bool) -> Void)?
    private var laidOutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(textView)
        addSubview(controls)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        controls.frame = bounds
        let widthChanged = bounds.width != laidOutWidth
        laidOutWidth = bounds.width
        onLayout?(widthChanged)
    }
}

fileprivate final class TranscriptSpeakerControls: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

private final class TranscriptSpeakerRenameField: UITextField {
    var onEscape: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))
        escape.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [escape]
    }

    @objc private func handleEscape() { onEscape?() }
}

private final class TranscriptSpeakerInlineEditor: UIView {
    let field = TranscriptSpeakerRenameField(frame: .zero)
    let save = UIButton(type: .system)
    let cancel = UIButton(type: .system)
    private let row: UIStackView
    private let side: CGFloat

    init(side: CGFloat, initialName: String, placeholder: String) {
        self.side = side
        row = UIStackView(arrangedSubviews: [field, save, cancel])
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        field.text = initialName
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.font = UIFont.preferredFont(forTextStyle: .subheadline)
        field.returnKeyType = .done
        field.autocapitalizationType = .words
        field.autocorrectionType = .no
        field.accessibilityLabel = String(localized: "Rename \(placeholder)")
        field.accessibilityIdentifier = "SpeakerRenameField"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(save, symbol: "checkmark", label: String(localized: "Save"), identifier: "SaveSpeakerRename")
        configure(cancel, symbol: "xmark", label: String(localized: "Cancel"), identifier: "CancelSpeakerRename")
        cancel.tintColor = .secondaryLabel
        row.alignment = .center
        row.spacing = 2
        addSubview(row)
    }

    required init?(coder: NSCoder) { fatalError("Use init(side:initialName:placeholder:)") }

    private func configure(_ button: UIButton, symbol: String, label: String, identifier: String) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)),
                        for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.widthAnchor.constraint(equalToConstant: side).isActive = true
        button.heightAnchor.constraint(equalToConstant: side).isActive = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        row.frame = TranscriptSpeakerRenameLayout.editorRowFrame(
            in: bounds, side: side, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
    }
}

enum TranscriptSpeakerRenameLayout {
    static func editorRowFrame(in bounds: CGRect, side: CGFloat, rightToLeft: Bool) -> CGRect {
        // Keep the actions next to the text field even in a wide Mac window.
        let width = min(bounds.width, 320)
        let x = rightToLeft ? bounds.maxX - width : bounds.minX
        return CGRect(x: x, y: bounds.maxY - side, width: width, height: side)
    }

    static func pencilFrame(at used: CGRect, line: CGRect, within lane: CGRect,
                            side: CGFloat, rightToLeft: Bool) -> CGRect? {
        let gap: CGFloat = 2
        let x = rightToLeft ? used.minX - gap - side : used.maxX + gap
        guard !used.isEmpty, !line.isEmpty,
              x >= lane.minX - 0.5, x + side <= lane.maxX + 0.5 else { return nil }
        return CGRect(x: x, y: line.midY - side / 2, width: side, height: side)
    }
}
