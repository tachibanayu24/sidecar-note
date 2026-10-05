import AppKit
import Highlightr
import Markdown

extension NSAttributedString.Key {
    static let mdCodeBlock = NSAttributedString.Key("sn.codeBlock")   // NSNumber (block ordinal)
    static let mdInlineCode = NSAttributedString.Key("sn.inlineCode") // true
    static let mdQuote = NSAttributedString.Key("sn.quote")           // true
    static let mdCheckbox = NSAttributedString.Key("sn.checkbox")     // NSNumber(bool: checked)
    static let mdBullet = NSAttributedString.Key("sn.bullet")         // NSNumber (nesting level)
    static let mdRule = NSAttributedString.Key("sn.rule")             // true
    static let mdImage = NSAttributedString.Key("sn.image")           // ImageBox
    static let mdLink = NSAttributedString.Key("sn.link")             // String (URL)
    static let mdMarker = NSAttributedString.Key("sn.marker")         // true: Markdown syntax, hidden off the caret's line
}

final class ImageBox: NSObject {
    let image: NSImage
    let size: NSSize
    init(image: NSImage, size: NSSize) {
        self.image = image
        self.size = size
    }
}

/// Converts swift-markdown source locations (1-based line, 1-based UTF-8 column) into UTF-16 offsets.
private final class SourceMap {
    let text: NSString
    private var lineStarts: [Int] = [0]
    /// Per line: UTF-8 byte offset → UTF-16 offset within the line (nil = pure ASCII, where both are equal).
    private var byteTables: [Int: [Int]?] = [:]
    /// Per-line column fixes (in UTF-8 bytes). cmark reports lazy continuation lines of list items / quotes
    /// with the container's indent added to their columns, so inline ranges on those lines come out shifted.
    private var columnFixes: [Int: Int] = [:]

    /// Lines the parser saw with extra characters appended (see `MarkdownStyler.parseSource`): positions there
    /// are clamped to the line's real content.
    private let extendedLines: Set<Int>

    init(_ string: String, extendedLines: Set<Int> = []) {
        text = string as NSString
        self.extendedLines = extendedLines
        var i = 0
        for unit in string.utf16 {
            i += 1
            if unit == 0x0A { lineStarts.append(i) }
        }
        // The appended text is not in the source, so it can't calibrate those lines.
        for line in extendedLines { columnFixes[line] = 0 }
    }

    private func lineRange(_ line: Int) -> NSRange {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : text.length
        return NSRange(location: start, length: end - start)
    }

    private func byteTable(_ line: Int) -> [Int]? {
        if let cached = byteTables[line] { return cached }
        let lineText = text.substring(with: lineRange(line))
        var table: [Int]?
        if lineText.utf8.count != lineText.utf16.count {
            var t: [Int] = []
            t.reserveCapacity(lineText.utf8.count + 1)
            var u16 = 0
            for scalar in lineText.unicodeScalars {
                for _ in 0..<String(scalar).utf8.count { t.append(u16) }
                u16 += scalar.utf16.count
            }
            t.append(u16)
            table = t
        }
        byteTables[line] = table
        return table
    }

    /// Records a correction for lines whose reported columns don't match the source. Only Text nodes whose
    /// source span equals their content (no escapes or entities) are trusted, and the first one on a line wins.
    func calibrate(_ node: Markup) {
        if let t = node as? Markdown.Text, let r = t.range, r.lowerBound.line == r.upperBound.line {
            let line = r.lowerBound.line - 1
            let expected = Array(t.string.utf8)
            guard line >= 0, line < lineStarts.count, columnFixes[line] == nil, !expected.isEmpty,
                  r.upperBound.column - r.lowerBound.column == expected.count else { return }
            let bytes = Array(text.substring(with: lineRange(line)).utf8)
            let reported = r.lowerBound.column - 1
            func matches(_ i: Int) -> Bool {
                i >= 0 && i + expected.count <= bytes.count && bytes[i..<i + expected.count].elementsEqual(expected)
            }
            guard !matches(reported) else { return }
            // The real position is to the left of the reported one; take the nearest match.
            let start = min(reported, bytes.count - expected.count)
            if start >= 0, let found = stride(from: start, through: 0, by: -1).first(where: matches) {
                columnFixes[line] = found - reported
            }
            return
        }
        for child in node.children { calibrate(child) }
    }

    func offset(_ loc: SourceLocation) -> Int {
        let line = loc.line - 1
        guard line >= 0, line < lineStarts.count else { return text.length }
        let range = lineRange(line)
        let byte = max(0, loc.column - 1 + (columnFixes[line] ?? 0))
        let limit = extendedLines.contains(line) ? text.withoutNewline(range).length : range.length
        guard let table = byteTable(line) else { return range.location + min(byte, limit) }
        return range.location + min(table[min(byte, table.count - 1)], limit)
    }

    func range(_ r: SourceRange?) -> NSRange? {
        guard let r else { return nil }
        let a = offset(r.lowerBound), b = offset(r.upperBound)
        return b >= a ? NSRange(location: a, length: b - a) : nil
    }
}

/// Turns Markdown source into "live preview" attributes. The characters are never changed:
/// markers stay in place (dimmed or invisible) so editing remains plain text.
final class MarkdownStyler {
    var family: FontFamily = .system { didSet { updateMetrics() } }
    var size: CGFloat = 14 { didSet { updateMetrics() } }
    var contentWidth: CGFloat = 360
    var isDark = false
    var imageProvider: (String) -> NSImage? = { _ in nil }

    private lazy var highlightr: Highlightr? = Highlightr()
    private lazy var highlightLanguages = Set(highlightr?.supportedLanguages() ?? [])
    private var highlightCache: [String: NSAttributedString] = [:]
    private var highlightTheme: String?
    private var imageBoxCache: [String: ImageBox] = [:]

    /// Common fence names that highlight.js knows under another id.
    private static let languageAliases = [
        "js": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript", "py": "python",
        "rb": "ruby", "sh": "bash", "zsh": "bash", "shell": "bash", "console": "bash", "yml": "yaml",
        "md": "markdown", "objc": "objectivec", "c++": "cpp", "cs": "csharp", "kt": "kotlin", "rs": "rust",
        "golang": "go", "html": "xml", "htm": "xml", "plist": "xml", "json5": "json", "dockerfile": "dockerfile",
    ]

    init() { updateMetrics() }

    private static let autolink = try! NSRegularExpression(pattern: #"(?<![(<\w])https?://[^\s<>()\]]+[^\s<>()\].,;:!?'"]"#)

    // MARK: Metrics

    // Cached per font family / size: these are requested on every keystroke and selection change.
    private(set) var bodyFont = NSFont.systemFont(ofSize: 14)
    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var baseParagraph = NSParagraphStyle()
    private var blankParagraph = NSParagraphStyle()
    private let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    private func updateMetrics() {
        bodyFont = Theme.font(family: family, size: size)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = round(size * 0.3)
        p.paragraphSpacing = round(size * 0.14)
        baseParagraph = p
        // Blank lines separate Markdown blocks; keep them short so the note doesn't look sparse.
        let blank = NSMutableParagraphStyle()
        blank.maximumLineHeight = round(size * 0.9)
        blankParagraph = blank
        baseAttributes = [.font: bodyFont, .foregroundColor: Theme.text, .paragraphStyle: baseParagraph]
    }

    private func paragraphStyle() -> NSMutableParagraphStyle {
        baseParagraph.mutableCopy() as! NSMutableParagraphStyle
    }

    /// Image sizes depend on the editor width; highlighting doesn't (its cache is keyed by appearance).
    func clearImageCache() {
        imageBoxCache.removeAll()
    }

    // MARK: Apply

    /// Renders the whole document and writes back only the lines whose attributes changed, so typing only
    /// relays out the paragraph being edited. Syntax stays visible within `visible` (the caret's lines).
    /// Returns the rendering before syntax hiding, for cheap caret moves (`reveal`).
    @discardableResult
    func apply(to storage: NSTextStorage, visible: NSRange) -> NSAttributedString? {
        guard storage.length > 0 else { return nil }
        let rendered = render(storage.string)
        guard rendered.length == storage.length else { return nil }
        // Font fallback (e.g. Japanese glyphs missing from SF) must be resolved here: when called from
        // didProcessEditing the storage has already fixed its attributes and won't do it again.
        rendered.fixAttributes(in: NSRange(location: 0, length: rendered.length))
        let full = rendered.copy() as! NSAttributedString
        hideSyntax(rendered, keeping: visible)
        let s = storage.mutableString
        var loc = 0
        while loc < s.length {
            let line = s.lineRange(for: NSRange(location: loc, length: 0))
            let new = rendered.attributedSubstring(from: line)
            if !storage.attributedSubstring(from: line).isEqual(to: new) {
                copyAttributes(from: new, to: storage, at: line.location)
            }
            loc = NSMaxRange(line)
        }
        return full
    }

    /// The caret moved to other lines: show syntax there and hide it where it left, without re-rendering.
    func reveal(in storage: NSTextStorage, rendering full: NSAttributedString, lines: [NSRange], visible: NSRange) {
        guard full.length == storage.length else { return }
        for line in lines where NSMaxRange(line) <= storage.length {
            let piece = full.attributedSubstring(from: line).mutableCopy() as! NSMutableAttributedString
            hideSyntax(piece, keeping: NSRange(location: visible.location - line.location, length: visible.length))
            if !storage.attributedSubstring(from: line).isEqual(to: piece) {
                copyAttributes(from: piece, to: storage, at: line.location)
            }
        }
    }

    private func copyAttributes(from source: NSAttributedString, to storage: NSTextStorage, at location: Int) {
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, r, _ in
            storage.setAttributes(attrs, range: NSRange(location: location + r.location, length: r.length))
        }
    }

    func render(_ string: String) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(string: string, attributes: baseAttributes)
        guard !string.isEmpty else { return out }
        let (source, extended) = MarkdownStyler.parseSource(string)
        let document = Document(parsing: source)
        let map = SourceMap(string, extendedLines: extended)
        map.calibrate(document)
        var ctx = Context(out: out, map: map)
        for line in ctx.lines(in: NSRange(location: 0, length: out.length))
            where ctx.stripNewline(line).length == 0 && NSMaxRange(line) < out.length {
            out.addAttribute(.paragraphStyle, value: blankParagraph, range: line)
        }
        for child in document.children { block(child, &ctx, listDepth: 0) }
        styleAutolinks(out)
        return out
    }

    /// A line holding nothing but a list marker ("- ", "  1."), as left by Return / Tab in a list.
    private static let emptyItem = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)*[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]*$"#)
    /// The number of an indented ordered item.
    private static let nestedNumber = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)*[ \t]+(\d{1,9})[.)](?:[ \t]|$)"#)

    /// The text handed to the parser. CommonMark lets neither an empty item nor an ordered item numbered other
    /// than 1 interrupt a paragraph, which is exactly what a note looks like while a list is being typed:
    /// "- a\n  - " would make "a" a setext heading (the lone "-" as its underline) and "1. a\n   2. b" a single
    /// paragraph. So the parser sees empty items with a placeholder body (appended; positions on those lines
    /// are clamped back by `SourceMap`) and nested numbers as "01" (same length, still valued 1).
    static func parseSource(_ string: String) -> (String, Set<Int>) {
        let ns = string as NSString
        var out = ""
        var extended = Set<Int>()
        var changed = false
        for (i, line) in ns.lineRanges(in: NSRange(location: 0, length: ns.length)).enumerated() {
            let content = ns.withoutNewline(line)
            var text = ns.substring(with: content)
            let whole = NSRange(location: 0, length: content.length)
            if let m = nestedNumber.firstMatch(in: text, range: whole) {
                let digits = m.range(at: 1)
                text = (text as NSString).replacingCharacters(
                    in: digits, with: String(repeating: "0", count: digits.length - 1) + "1")
                changed = true
            }
            if emptyItem.firstMatch(in: text, range: whole) != nil {
                // Trailing blanks dropped: five or more after the marker would make the body indented code.
                while let last = text.last, last == " " || last == "\t" { text.removeLast() }
                text += " x"
                extended.insert(i)
                changed = true
            }
            out += text + ns.substring(with: NSRange(location: NSMaxRange(content), length: NSMaxRange(line) - NSMaxRange(content)))
        }
        return (changed ? out : string, extended)
    }

    private struct Context {
        let out: NSMutableAttributedString
        let map: SourceMap
        var codeBlockCount = 0
        var text: NSString { map.text }

        func lines(in range: NSRange) -> [NSRange] { text.lineRanges(in: range) }
        func stripNewline(_ r: NSRange) -> NSRange { text.withoutNewline(r) }
    }

    // MARK: Blocks

    private func block(_ node: Markup, _ ctx: inout Context, listDepth: Int) {
        guard let range = ctx.map.range(node.range) else { return }
        let out = ctx.out

        switch node {
        case let heading as Heading:
            styleHeading(heading, range: range, &ctx)

        case let paragraph as Paragraph:
            if let image = soleImage(in: paragraph), let source = image.source,
               styleBlockImage(source: source, range: range, &ctx) {
                return
            }
            inlines(paragraph, &ctx)

        case let quote as BlockQuote:
            for line in ctx.lines(in: range) {
                let content = ctx.stripNewline(line)
                out.addAttribute(.foregroundColor, value: Theme.secondaryText, range: content)
                out.addAttribute(.mdQuote, value: true, range: line)
                // Hide the ">" markers; the layout manager draws a bar instead.
                var i = content.location
                var prefixEnd = i
                while i < NSMaxRange(content) {
                    let c = ctx.text.character(at: i)
                    if c == 0x3E { out.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: i, length: 1)); prefixEnd = i + 1 }
                    else if !isBlank(c) { break }
                    i += 1
                }
                if prefixEnd < NSMaxRange(content), ctx.text.character(at: prefixEnd) == 0x20 { prefixEnd += 1 }
                setHangingIndent(out, line: content, prefixEnd: prefixEnd)
            }
            for child in quote.children { block(child, &ctx, listDepth: listDepth) }

        case is UnorderedList, is OrderedList:
            for child in node.children { block(child, &ctx, listDepth: listDepth) }

        case let item as ListItem:
            styleListItem(item, range: range, &ctx, depth: listDepth)
            for child in item.children { block(child, &ctx, listDepth: listDepth + 1) }

        case let code as CodeBlock:
            styleCodeBlock(code, range: range, &ctx)

        case is ThematicBreak:
            let content = ctx.stripNewline(range)
            out.addAttributes([.foregroundColor: NSColor.clear, .mdRule: true], range: content)

        case let table as Table:
            for line in ctx.lines(in: range) {
                let content = ctx.stripNewline(line)
                out.addAttribute(.font, value: Theme.mono(size: round(size * 0.9)), range: content)
                let lineText = ctx.text.substring(with: content)
                let isSeparator = lineText.allSatisfy { "|-: \t".contains($0) }
                for i in content.location..<NSMaxRange(content) where isSeparator || ctx.text.character(at: i) == 0x7C {
                    out.addAttribute(.foregroundColor, value: Theme.marker, range: NSRange(location: i, length: 1))
                }
            }
            for cell in table.head.cells { inlines(cell, &ctx) }
            for row in table.body.rows { for cell in row.cells { inlines(cell, &ctx) } }

        case is HTMLBlock:
            out.addAttributes([.font: Theme.mono(size: round(size * 0.88)), .foregroundColor: Theme.secondaryText], range: range)

        default:
            for child in node.children { block(child, &ctx, listDepth: listDepth) }
        }
    }

    private func styleHeading(_ heading: Heading, range: NSRange, _ ctx: inout Context) {
        let out = ctx.out
        let level = min(max(heading.level, 1), 6)
        let scale: [CGFloat] = [1.6, 1.32, 1.15, 1.05, 1.0, 0.95]
        let font = Theme.font(family: family, size: round(size * scale[level - 1]), weight: level <= 2 ? .bold : .semibold)
        let p = paragraphStyle()
        p.paragraphSpacingBefore = range.location == 0 ? 0 : round(size * (level <= 2 ? 0.5 : 0.3))
        p.paragraphSpacing = round(size * 0.35)

        let firstLine = ctx.stripNewline(ctx.text.lineRange(for: NSRange(location: range.location, length: 0)))
        let isATX = ctx.text.substring(with: firstLine).trimmingCharacters(in: .whitespaces).hasPrefix("#")
        if isATX {
            out.addAttributes([.font: font, .paragraphStyle: p], range: firstLine)
            let contentStart = Array(heading.children).first.flatMap { ctx.map.range($0.range)?.location } ?? NSMaxRange(firstLine)
            markSyntax(out, NSRange(location: firstLine.location, length: max(0, contentStart - firstLine.location)))
        } else {
            // Setext: content lines followed by an === / --- underline.
            let childRanges = heading.children.compactMap { ctx.map.range($0.range) }
            guard let last = childRanges.last else { return }
            let content = NSRange(location: range.location, length: NSMaxRange(last) - range.location)
            for line in ctx.lines(in: content) {
                out.addAttributes([.font: font, .paragraphStyle: p], range: ctx.stripNewline(line))
            }
            let underlineStart = NSMaxRange(ctx.text.lineRange(for: NSRange(location: NSMaxRange(last) - 1, length: 0)))
            if underlineStart < ctx.text.length {
                let underline = ctx.stripNewline(ctx.text.lineRange(for: NSRange(location: underlineStart, length: 0)))
                out.addAttribute(.font, value: Theme.font(family: family, size: round(size * 0.8)), range: underline)
                markSyntax(out, underline)
            }
        }
        inlines(heading, &ctx)
    }

    private func styleListItem(_ item: ListItem, range: NSRange, _ ctx: inout Context, depth: Int) {
        let out = ctx.out
        let firstLine = ctx.stripNewline(ctx.text.lineRange(for: NSRange(location: range.location, length: 0)))
        let childStart = Array(item.children).first.flatMap { ctx.map.range($0.range)?.location } ?? NSMaxRange(firstLine)
        let prefixEnd = min(max(childStart, range.location), NSMaxRange(firstLine))

        // Marker = first non-space run in the prefix.
        var markerStart = range.location
        while markerStart < prefixEnd, isBlank(ctx.text.character(at: markerStart)) { markerStart += 1 }
        var markerEnd = markerStart
        while markerEnd < prefixEnd, !isBlank(ctx.text.character(at: markerEnd)) { markerEnd += 1 }
        guard markerEnd > markerStart else { return }
        let markerRange = NSRange(location: markerStart, length: markerEnd - markerStart)
        let marker = ctx.text.substring(with: markerRange)

        if let checkbox = item.checkbox {
            let prefix = ctx.text.substring(with: NSRange(location: markerEnd, length: prefixEnd - markerEnd)) as NSString
            let open = prefix.range(of: "[")
            guard open.location != NSNotFound else { return }
            let boxRange = NSRange(location: markerEnd + open.location, length: 3)
            let checked = checkbox == .checked
            out.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear],
                              range: NSRange(location: markerStart, length: boxRange.location - markerStart))
            out.addAttributes([.foregroundColor: NSColor.clear, .font: bodyFont,
                               .mdCheckbox: NSNumber(value: checked)], range: boxRange)
            if checked, NSMaxRange(boxRange) < NSMaxRange(firstLine) {
                // Everything inside the item (all its lines) reads as done.
                var bodyStart = NSMaxRange(boxRange)
                while bodyStart < NSMaxRange(range), isBlank(ctx.text.character(at: bodyStart)) { bodyStart += 1 }
                let body = NSRange(location: bodyStart, length: NSMaxRange(range) - bodyStart)
                out.addAttributes([.foregroundColor: Theme.secondaryText,
                                   .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .strikethroughColor: Theme.marker], range: body)
            }
        } else if marker.first?.isNumber == true {
            out.addAttributes([.foregroundColor: Theme.secondaryText, .font: bodyFont.monospacedDigits()], range: markerRange)
        } else {
            out.addAttributes([.foregroundColor: NSColor.clear, .mdBullet: NSNumber(value: depth)], range: markerRange)
        }

        // Nesting is drawn from the list depth, not the source's spaces: two spaces are far too narrow to read
        // as a level, and items with different marker widths would otherwise sit at uneven offsets.
        let indent = CGFloat(depth) * listIndentStep
        collapseIndent(out, line: firstLine, before: markerStart)
        let contentX = setHangingIndent(out, line: firstLine, prefixEnd: prefixEnd, indent: indent)
        // The item's other lines (continuations, later paragraphs) line up with its text; nested items are
        // styled after this and override their own lines.
        for line in ctx.lines(in: range).dropFirst() {
            let content = ctx.stripNewline(line)
            guard content.length > 0, out.attribute(.mdQuote, at: content.location, effectiveRange: nil) == nil else { continue }
            var textStart = content.location
            while textStart < NSMaxRange(content), isBlank(ctx.text.character(at: textStart)) { textStart += 1 }
            collapseIndent(out, line: content, before: textStart)
            let p = (out.attribute(.paragraphStyle, at: content.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
            p.firstLineHeadIndent = contentX
            p.headIndent = contentX
            out.addAttribute(.paragraphStyle, value: p, range: content)
        }
    }

    private var listIndentStep: CGFloat { round(size * 1.6) }

    /// Shrinks the leading blanks of a list line to nothing; its paragraph indent places it instead.
    /// Inside a quote the blank right after ">" is kept so items line up with the quote's other text.
    private func collapseIndent(_ out: NSMutableAttributedString, line: NSRange, before end: Int) {
        let text = out.mutableString
        var start = end
        while start > line.location, isBlank(text.character(at: start - 1)) { start -= 1 }
        if start > line.location, text.character(at: start - 1) == 0x3E, start < end { start += 1 }
        guard end > start else { return }
        out.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: start, length: end - start))
    }

    /// Wrapped lines align with the text after the list / quote marker. Returns that text's x offset.
    @discardableResult
    private func setHangingIndent(_ out: NSMutableAttributedString, line: NSRange, prefixEnd: Int, indent: CGFloat = 0) -> CGFloat {
        guard prefixEnd > line.location else { return indent }
        let width = ceil(out.attributedSubstring(from: NSRange(location: line.location, length: prefixEnd - line.location)).size().width)
        let p = (out.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
        p.firstLineHeadIndent = indent
        p.headIndent = indent + width
        out.addAttribute(.paragraphStyle, value: p, range: line)
        return indent + width
    }

    private func codeParagraph(first: Bool = false, last: Bool = false, fence: Bool = false) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        // A hidden fence line still pads the block.
        if fence { p.minimumLineHeight = round(size * 0.9) }
        p.lineSpacing = round(size * 0.18)
        p.paragraphSpacing = last ? round(size * 0.6) : 0
        p.paragraphSpacingBefore = first ? round(size * 0.3) : 0
        p.firstLineHeadIndent = 14
        p.headIndent = 14
        p.tailIndent = -14
        return p
    }

    private func styleCodeBlock(_ code: CodeBlock, range: NSRange, _ ctx: inout Context) {
        let out = ctx.out
        ctx.codeBlockCount += 1
        let id = NSNumber(value: ctx.codeBlockCount)
        let lines = ctx.lines(in: range)
        func isFence(_ line: NSRange) -> Bool {
            let t = ctx.text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasPrefix("```") || t.hasPrefix("~~~")
        }
        let fenced = lines.first.map(isFence) ?? false
        let closed = fenced && lines.count > 1 && isFence(lines.last!)

        for (i, line) in lines.enumerated() {
            let isOpen = fenced && i == 0
            let isClose = closed && i == lines.count - 1
            if isOpen || isClose {
                out.addAttributes([.font: Theme.mono(size: round(size * 0.78)),
                                   .paragraphStyle: codeParagraph(first: isOpen, last: isClose, fence: true), .mdCodeBlock: id],
                                  range: line)
                markSyntax(out, ctx.stripNewline(line))
            } else {
                out.addAttributes([.font: Theme.mono(size: round(size * 0.88)), .foregroundColor: Theme.text,
                                   .paragraphStyle: codeParagraph(first: !fenced && i == 0, last: !closed && i == lines.count - 1),
                                   .mdCodeBlock: id], range: line)
            }
        }

        // Syntax highlighting (only colors are taken from the highlight.js theme).
        guard let language = code.language?.trimmingCharacters(in: .whitespaces).lowercased(), !language.isEmpty,
              fenced, lines.count > 1 else { return }
        let bodyLines = lines.dropFirst().dropLast(closed ? 1 : 0)
        guard let first = bodyLines.first, let last = bodyLines.last else { return }
        let bodyRange = ctx.stripNewline(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
        let source = ctx.text.substring(with: bodyRange)
        guard let highlighted = highlight(source, language: language), highlighted.length == bodyRange.length else { return }
        highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, r, _ in
            guard let color = value as? NSColor else { return }
            out.addAttribute(.foregroundColor, value: color, range: NSRange(location: bodyRange.location + r.location, length: r.length))
        }
    }

    private func highlight(_ code: String, language: String) -> NSAttributedString? {
        let key = "\(isDark)|\(language)|\(code)"
        if let cached = highlightCache[key] { return cached }
        guard let highlightr else { return nil }
        let theme = isDark ? "atom-one-dark" : "xcode"
        if theme != highlightTheme {
            highlightr.setTheme(to: theme)
            highlightTheme = theme
        }
        let lang = MarkdownStyler.languageAliases[language] ?? language
        guard highlightLanguages.contains(lang), let result = highlightr.highlight(code, as: lang, fastRender: true)
        else { return nil }
        if highlightCache.count > 200 { highlightCache.removeAll() }
        highlightCache[key] = result
        return result
    }

    // MARK: Images

    private func soleImage(in paragraph: Paragraph) -> Markdown.Image? {
        let meaningful = paragraph.children.filter {
            !($0 is SoftBreak) && !(($0 as? Text)?.string.trimmingCharacters(in: .whitespaces).isEmpty ?? false)
        }
        return meaningful.count == 1 ? meaningful.first as? Markdown.Image : nil
    }

    private func styleBlockImage(source: String, range: NSRange, _ ctx: inout Context) -> Bool {
        let out = ctx.out
        out.addAttribute(.font, value: Theme.font(family: family, size: round(size * 0.78)), range: range)
        markSyntax(out, ctx.stripNewline(range))
        guard let box = imageBox(for: source) else { return true }
        let p = paragraphStyle()
        p.paragraphSpacing = box.size.height + 14
        out.addAttributes([.paragraphStyle: p, .mdImage: box], range: ctx.stripNewline(range))
        return true
    }

    private func imageBox(for source: String) -> ImageBox? {
        if let cached = imageBoxCache[source] { return cached }
        guard let image = imageProvider(source), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, max(40, contentWidth) / image.size.width, 420 / image.size.height)
        let box = ImageBox(image: image, size: NSSize(width: floor(image.size.width * scale),
                                                      height: floor(image.size.height * scale)))
        imageBoxCache[source] = box
        return box
    }

    // MARK: Inline

    private func inlines(_ node: Markup, _ ctx: inout Context) {
        for child in node.children { inline(child, &ctx) }
    }

    private func inline(_ node: Markup, _ ctx: inout Context) {
        guard let range = ctx.map.range(node.range), range.length > 0 else { return }
        let out = ctx.out

        func dimMarkers() -> NSRange {
            let childRanges = node.children.compactMap { ctx.map.range($0.range) }
            guard let first = childRanges.first, let last = childRanges.last else {
                markSyntax(out, range)
                return NSRange(location: range.location, length: 0)
            }
            let inner = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            markSyntax(out, NSRange(location: range.location, length: inner.location - range.location))
            markSyntax(out, NSRange(location: NSMaxRange(inner), length: NSMaxRange(range) - NSMaxRange(inner)))
            return inner
        }

        switch node {
        case is Strong:
            let inner = dimMarkers()
            addTrait(.bold, out, inner)
            inlines(node, &ctx)
        case is Emphasis:
            let inner = dimMarkers()
            addTrait(.italic, out, inner)
            inlines(node, &ctx)
        case is Strikethrough:
            let inner = dimMarkers()
            out.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                               .foregroundColor: Theme.secondaryText], range: inner)
            inlines(node, &ctx)
        case is InlineCode:
            var ticks = 0
            while ticks < range.length / 2, ctx.text.character(at: range.location + ticks) == 0x60 { ticks += 1 }
            let inner = NSRange(location: range.location + ticks, length: range.length - ticks * 2)
            let font = out.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? bodyFont
            markSyntax(out, NSRange(location: range.location, length: ticks))
            markSyntax(out, NSRange(location: NSMaxRange(inner), length: ticks))
            out.addAttributes([.font: Theme.mono(size: round(font.pointSize * 0.88)),
                               .foregroundColor: Theme.inlineCodeText, .mdInlineCode: true], range: inner)
        case let link as Link:
            let inner = dimMarkers()
            if let destination = link.destination {
                out.addAttributes([.foregroundColor: Theme.accent, .mdLink: destination], range: inner)
                let tail = NSRange(location: NSMaxRange(inner) + 1, length: max(0, NSMaxRange(range) - NSMaxRange(inner) - 1))
                if tail.length > 0 {
                    out.addAttribute(.font, value: Theme.font(family: family, size: round(size * 0.8)), range: tail)
                }
            }
            inlines(node, &ctx)
        case is Markdown.Image:
            markSyntax(out, range)
        case is InlineHTML:
            out.addAttribute(.foregroundColor, value: Theme.marker, range: range)
        default:
            inlines(node, &ctx)
        }
    }

    /// Dimmed Markdown syntax; hidden entirely unless the caret is on its line (see `hideSyntax`).
    private func markSyntax(_ out: NSMutableAttributedString, _ r: NSRange) {
        guard r.length > 0 else { return }
        out.addAttributes([.foregroundColor: Theme.marker, .mdMarker: true], range: r)
    }

    /// Collapses syntax outside `visible` (the caret's lines): invisible and nearly zero-width.
    private func hideSyntax(_ out: NSMutableAttributedString, keeping visible: NSRange) {
        out.enumerateAttribute(.mdMarker, in: NSRange(location: 0, length: out.length)) { value, r, _ in
            guard value != nil else { return }
            let pieces = [NSRange(location: r.location, length: max(0, min(NSMaxRange(r), visible.location) - r.location)),
                          NSRange(location: max(r.location, NSMaxRange(visible)),
                                  length: max(0, NSMaxRange(r) - max(r.location, NSMaxRange(visible))))]
            for piece in pieces where piece.length > 0 {
                out.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: piece)
            }
        }
    }

    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, _ out: NSMutableAttributedString, _ r: NSRange) {
        guard r.length > 0 else { return }
        out.enumerateAttribute(.font, in: r) { value, sub, _ in
            guard let font = value as? NSFont, font.pointSize > 1 else { return }
            out.addAttribute(.font, value: font.adding(trait), range: sub)
        }
    }

    private func styleAutolinks(_ out: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: out.length)
        for m in MarkdownStyler.autolink.matches(in: out.string, range: full) {
            let attrs = out.attributes(at: m.range.location, effectiveRange: nil)
            if attrs[.mdCodeBlock] != nil || attrs[.mdInlineCode] != nil || attrs[.mdLink] != nil { continue }
            let url = (out.string as NSString).substring(with: m.range)
            out.addAttributes([.foregroundColor: Theme.accent, .mdLink: url,
                               .underlineStyle: NSUnderlineStyle.single.rawValue,
                               .underlineColor: Theme.accent.withAlphaComponent(0.35)], range: m.range)
        }
    }
}
