import AppKit
import UniformTypeIdentifiers

/// Owns the TextKit stack for one note and keeps its live-preview attributes up to date.
final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let storage = NSTextStorage()
    let layoutManager = MarkdownLayoutManager()
    let container = NSTextContainer()
    let textView: MarkdownTextView
    let scrollView = NSScrollView()
    private let styler: MarkdownStyler
    private let undo = UndoManager()

    var onTextChange: (() -> Void)?
    var text: String { storage.string }

    /// Restyle deferred until an IME composition is committed.
    private var pendingAfterComposition = false
    /// Restyle deferred until this note is shown (fonts / appearance changed while it was in a background tab).
    private var isStale = false
    /// Latest rendering with all syntax visible, and the lines where syntax is currently shown (the caret's).
    private var rendering: NSAttributedString?
    private var visibleLines = NSRange(location: 0, length: 0)

    init(text: String, styler: MarkdownStyler) {
        self.styler = styler
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        super.init()

        storage.setAttributedString(NSAttributedString(string: text, attributes: styler.baseAttributes))
        storage.delegate = self
        visibleLines = caretLines()
        rendering = styler.apply(to: storage, visible: visibleLines)

        textView.delegate = self
        textView.styler = styler
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 22, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.22)]
        textView.typingAttributes = styler.baseAttributes

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
    }

    /// Re-applies styling now if this note is on screen, otherwise when it is next shown.
    func setNeedsRestyle() {
        isStale = true
        if textView.window != nil { restyleIfNeeded() }
    }

    func restyleIfNeeded() {
        guard isStale else { return }
        guard !textView.hasMarkedText() else {
            pendingAfterComposition = true
            return
        }
        isStale = false
        textView.typingAttributes = styler.baseAttributes
        visibleLines = caretLines()
        storage.beginEditing()
        rendering = styler.apply(to: storage, visible: visibleLines)
        storage.endEditing()
        textView.needsDisplay = true
    }

    func replaceText(_ newText: String) {
        let selection = textView.selectedRange()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        textView.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
        undo.removeAllActions()
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // While an IME composition is open, the marked-text underline lives in the storage's attributes;
        // restyling now would erase it. Catch up once the composition is committed.
        if textView.hasMarkedText() {
            pendingAfterComposition = true
            return
        }
        pendingAfterComposition = false
        // The selection isn't updated yet: keep syntax visible on the edited lines as well.
        let text = textStorage.mutableString
        let edited = text.lineRange(for: NSRange(location: min(editedRange.location, text.length), length: 0))
        visibleLines = NSUnionRange(edited, caretLines())
        rendering = styler.apply(to: textStorage, visible: visibleLines)
    }

    /// Lines touched by the selection: Markdown syntax is shown there and hidden everywhere else.
    private func caretLines() -> NSRange {
        let text = storage.mutableString
        let sel = textView.selectedRange()
        let loc = min(sel.location, text.length)
        return text.lineRange(for: NSRange(location: loc, length: min(sel.length, text.length - loc)))
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        restyleAfterComposition()
        // An edit away from the caret (checkbox click, Replace All) left syntax shown on the edited lines.
        syncVisibleLines()
        onTextChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        restyleAfterComposition()
        syncVisibleLines()
    }

    /// Shows syntax on the caret's lines and hides it where the caret left, without re-rendering.
    func syncVisibleLines() {
        guard !pendingAfterComposition, !textView.hasMarkedText(), let rendering else { return }
        // Revealing changes glyph widths: not while a mouse drag is selecting (text would shift under the
        // pointer — the text view calls back after mouse-up), and not in the middle of the storage's own edit.
        guard !textView.isTrackingMouse else { return }
        guard storage.editedMask.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.syncVisibleLines() }
            return
        }
        let visible = caretLines()
        guard visible != visibleLines else { return }
        let text = storage.mutableString
        let lines = text.lineRanges(in: visibleLines) + text.lineRanges(in: visible)
        storage.beginEditing()
        styler.reveal(in: storage, rendering: rendering, lines: lines, visible: visible)
        storage.endEditing()
        visibleLines = visible
    }

    /// The IME may still report marked text while it commits, so check again on the next runloop turn.
    private func restyleAfterComposition() {
        guard pendingAfterComposition else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingAfterComposition, !self.textView.hasMarkedText() else { return }
            self.pendingAfterComposition = false
            self.isStale = true
            self.restyleIfNeeded()
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        styler.baseAttributes
    }
}

/// NSTextView with Markdown-aware editing: list continuation, checkbox toggling, image paste/drop.
final class MarkdownTextView: NSTextView {
    weak var styler: MarkdownStyler?
    let placeholderSeed = Int.random(in: 0..<10_000)
    var storeImage: ((Data, String) -> String?)?
    var resolveLink: ((String) -> URL?)?
    /// Right after a note is closed, ⌘Z brings it back (instead of undoing typing in this note).
    var canReopenClosedNote: (() -> Bool)?
    var reopenClosedNote: (() -> Void)?

    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^(?<indent>[ \t]*)(?:(?<quote>>[ \t]?)|(?:(?<bullet>[-*+])|(?<num>\d{1,9})(?<delim>[.)]))[ \t]+(?<box>\[[ xX]\](?:[ \t]+|$))?)"#)

    private func listMatch(_ line: String) -> NSTextCheckingResult? {
        MarkdownTextView.listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private func group(_ m: NSTextCheckingResult, _ name: String) -> NSRange? {
        let r = m.range(withName: name)
        return r.location == NSNotFound ? nil : r
    }

    /// The live backing string (no copy, unlike `string`).
    private var text: NSString { textStorage?.mutableString ?? "" }

    // MARK: Undo

    @objc func undo(_ sender: Any?) {
        if canReopenClosedNote?() == true {
            reopenClosedNote?()
        } else {
            undoManager?.undo()
        }
    }

    private var canUndo: Bool { canReopenClosedNote?() == true || undoManager?.canUndo == true }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(undo(_:)) ? canUndo : super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(undo(_:)) ? canUndo : super.validateMenuItem(item)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Subpixel smoothing on a translucent background makes glyphs look bold; draw like the system does on glass.
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
        guard textStorage?.length == 0, let styler else { return }
        let font = Theme.font(family: styler.family, size: styler.size + 1).adding(.italic)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.placeholderTextColor, .kern: 0.2]
        (Placeholder.text(seed: placeholderSeed) as NSString)
            .draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y - 1), withAttributes: attrs)
    }

    // The panel always claims the active look; only draw the caret when it really has focus.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard let window, NSApp.keyWindow === window else { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    // MARK: Mouse

    private func attribute(_ key: NSAttributedString.Key, at point: NSPoint) -> (Any, NSRange)? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -4, dy: -2).contains(p) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange()
        guard let value = storage.attribute(key, at: index, effectiveRange: &range) else { return nil }
        return (value, range)
    }

    /// True while `super.mouseDown` runs its tracking loop (click-drag selection).
    private(set) var isTrackingMouse = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (value, range) = attribute(.mdCheckbox, at: point), let checked = (value as? NSNumber)?.boolValue {
            breakUndoCoalescing()
            replace(NSRange(location: range.location + 1, length: 1), with: checked ? " " : "x")
            return
        }
        if event.modifierFlags.contains(.command), let (value, _) = attribute(.mdLink, at: point),
           let link = value as? String, let url = resolveLink?(link) {
            NSWorkspace.shared.open(url)
            return
        }
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        (delegate as? EditorController)?.syncVisibleLines()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if attribute(.mdCheckbox, at: point) != nil
            || (event.modifierFlags.contains(.command) && attribute(.mdLink, at: point) != nil) {
            NSCursor.pointingHand.set()
        }
    }

    // MARK: Editing helpers

    /// Replaces text through the normal editing path so it participates in undo (one undo step, one restyle).
    private func replace(_ range: NSRange, with replacement: String, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    private func inCodeBlock(at location: Int) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        return storage.attribute(.mdCodeBlock, at: min(location, storage.length - 1), effectiveRange: nil) != nil
    }

    /// Rewrites every line of the selection with `transform` (nil = unchanged) as a single edit, then restores
    /// a selection shifted by what changed before / inside it.
    private func rewriteSelectedLines(_ transform: (String) -> String?) -> Bool {
        let sel = selectedRange()
        let lines = text.lineRanges(in: sel)
        guard let first = lines.first, let last = lines.last else { return false }
        let block = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var output = ""
        var changed = false
        var firstDelta = 0
        var totalDelta = 0
        for (i, line) in lines.enumerated() {
            let content = text.withoutNewline(line)
            let original = text.substring(with: content)
            let newline = text.substring(with: NSRange(location: NSMaxRange(content), length: NSMaxRange(line) - NSMaxRange(content)))
            let rewritten = transform(original) ?? original
            if rewritten != original { changed = true }
            let delta = (rewritten as NSString).length - (original as NSString).length
            if i == 0 { firstDelta = delta }
            totalDelta += delta
            output += rewritten + newline
        }
        guard changed else { return false }
        breakUndoCoalescing()
        let start = max(first.location, sel.location + firstDelta)
        replace(block, with: output, select: NSRange(location: start, length: max(0, sel.length + totalDelta - firstDelta)))
        return true
    }

    // MARK: List continuation

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        guard !hasMarkedText(), sel.length == 0 else { return super.insertNewline(sender) }
        let line = text.withoutNewline(text.lineRange(for: NSRange(location: sel.location, length: 0)))
        let lineText = text.substring(with: line)

        if inCodeBlock(at: line.location) {
            let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
            insertText("\n" + indent, replacementRange: sel)
            return
        }

        guard let m = listMatch(lineText), sel.location >= line.location + m.range.length else {
            return super.insertNewline(sender)
        }
        let ns = lineText as NSString
        let indent = ns.substring(with: m.range(withName: "indent"))
        let rest = ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)

        if rest.isEmpty {
            // Enter on an empty item: outdent, or end the list at top level.
            if !indent.isEmpty {
                let remove = indent.hasPrefix("\t") ? 1 : min(2, indent.count)
                replace(NSRange(location: line.location, length: remove), with: "",
                        select: NSRange(location: sel.location - remove, length: 0))
            } else {
                replace(NSRange(location: line.location, length: m.range.length), with: "",
                        select: NSRange(location: line.location, length: 0))
            }
            return
        }

        var prefix = indent
        if let bullet = group(m, "bullet") {
            prefix += ns.substring(with: bullet) + " "
        } else if let num = group(m, "num"), let delim = group(m, "delim") {
            prefix += "\((Int(ns.substring(with: num)) ?? 0) + 1)" + ns.substring(with: delim) + " "
        } else {
            prefix += "> "
        }
        if group(m, "box") != nil { prefix += "[ ] " }
        insertText("\n" + prefix, replacementRange: sel)
    }

    override func insertTab(_ sender: Any?) {
        if !indentListLines(outdent: false) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        _ = indentListLines(outdent: true)
    }

    /// Indents / outdents every list line in the selection. Returns false when there is nothing to do.
    private func indentListLines(outdent: Bool) -> Bool {
        guard !inCodeBlock(at: selectedRange().location) else { return false }
        return rewriteSelectedLines { line in
            guard let m = listMatch(line), group(m, "quote") == nil else { return nil }
            if !outdent { return "  " + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = min(2, line.prefix { $0 == " " }.count)
            return spaces > 0 ? String(line.dropFirst(spaces)) : nil
        }
    }

    // MARK: Formatting commands

    @objc func toggleBold(_ sender: Any?) { toggleWrap("**") }
    @objc func toggleItalic(_ sender: Any?) { toggleWrap("*") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleWrap("~~") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleWrap("`") }

    private func toggleWrap(_ marker: String) {
        breakUndoCoalescing()
        let sel = selectedRange()
        let m = (marker as NSString).length
        if sel.length == 0 {
            replace(sel, with: marker + marker, select: NSRange(location: sel.location + m, length: 0))
            return
        }
        let ns = text
        // Already wrapped just outside the selection → unwrap. Runs of the marker character are counted so that
        // "*" inside "**bold**" is not mistaken for italics (italic = 1 or 3 stars, bold = 2 or 3).
        let markerChar = (marker as NSString).character(at: 0)
        var before = 0, after = 0
        while sel.location - before > 0, ns.character(at: sel.location - before - 1) == markerChar { before += 1 }
        while NSMaxRange(sel) + after < ns.length, ns.character(at: NSMaxRange(sel) + after) == markerChar { after += 1 }
        let run = min(before, after)
        let isWrapped = marker == "*" ? (run == 1 || run == 3) : run >= m
        if isWrapped {
            let inner = ns.substring(with: sel)
            replace(NSRange(location: sel.location - m, length: sel.length + m * 2), with: inner,
                    select: NSRange(location: sel.location - m, length: sel.length))
            return
        }
        let selected = ns.substring(with: sel)
        if selected.hasPrefix(marker), selected.hasSuffix(marker), sel.length >= m * 2 {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            replace(sel, with: inner, select: NSRange(location: sel.location, length: (inner as NSString).length))
            return
        }
        replace(sel, with: marker + selected + marker, select: NSRange(location: sel.location + m, length: sel.length))
    }

    /// ⌘↩: toggles the checkbox of each selected line, turning plain lines / bullets / quotes into tasks.
    @objc func toggleTask(_ sender: Any?) {
        guard !inCodeBlock(at: selectedRange().location) else { return }
        let multiline = text.lineRanges(in: selectedRange()).count > 1
        _ = rewriteSelectedLines { line in
            let ns = line as NSString
            if let m = listMatch(line) {
                if let box = group(m, "box") {
                    let checked = ns.substring(with: NSRange(location: box.location + 1, length: 1)).lowercased() == "x"
                    return ns.replacingCharacters(in: NSRange(location: box.location + 1, length: 1), with: checked ? " " : "x")
                }
                // "- foo" → "- [ ] foo", "1. foo" → "1. [ ] foo", "> foo" → "> - [ ] foo"
                let insertion = group(m, "quote") != nil ? "- [ ] " : "[ ] "
                return ns.replacingCharacters(in: NSRange(location: m.range.length, length: 0), with: insertion)
            }
            if multiline && line.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
            return ns.replacingCharacters(in: NSRange(location: indent, length: 0), with: "- [ ] ")
        }
    }

    // MARK: Images

    private func hasImages(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil && pasteboard.string(forType: .string) == nil
    }

    private func imageMarkdown(from pasteboard: NSPasteboard) -> [String] {
        guard let storeImage else { return [] }
        var paths: [String] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: url) else { continue }
                if let path = storeImage(data, url.pathExtension.lowercased()) { paths.append(path) }
            }
            if !urls.isEmpty && paths.isEmpty { return [] }
        }
        if paths.isEmpty, pasteboard.string(forType: .string) == nil {
            if let png = pasteboard.data(forType: .png), let path = storeImage(png, "png") {
                paths.append(path)
            } else if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]), let path = storeImage(png, "png") {
                paths.append(path)
            }
        }
        return paths.map { "![](\($0.replacingOccurrences(of: " ", with: "%20")))" }
    }

    /// Inserts image lines at `range`, each on a line of its own.
    private func insertImages(_ images: [String], replacing range: NSRange) {
        let ns = text
        let needsLeading = range.location > 0 && ns.character(at: range.location - 1) != 0x0A
        let end = NSMaxRange(range)
        let needsTrailing = end < ns.length && ns.character(at: end) != 0x0A
        let insertion = (needsLeading ? "\n" : "") + images.joined(separator: "\n") + (needsTrailing ? "\n" : "")
        replace(range, with: insertion, select: NSRange(location: range.location + (insertion as NSString).length, length: 0))
    }

    override func paste(_ sender: Any?) {
        let images = imageMarkdown(from: .general)
        if images.isEmpty {
            pasteAsPlainText(sender)
        } else {
            insertImages(images, replacing: selectedRange())
        }
    }

    // Plain-text views reject image drags up front; accept them so performDragOperation can store the image.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.png, .tiff, .fileURL]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingEntered(sender)
        return op.isEmpty && hasImages(sender.draggingPasteboard) ? .copy : op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(sender)
        return op.isEmpty && hasImages(sender.draggingPasteboard) ? .copy : op
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = imageMarkdown(from: sender.draggingPasteboard)
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        insertImages(images, replacing: NSRange(location: characterIndexForInsertion(at: point), length: 0))
        return true
    }
}
