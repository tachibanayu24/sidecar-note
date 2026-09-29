import AppKit

/// Draws the decorations that replace Markdown markers: code block panels, inline code pills,
/// quote bars, rules, bullets, checkboxes and images.
final class MarkdownLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        let width = container.size.width

        // Code blocks (each block carries its own id, so one enumerated run is one block)
        storage.enumerateAttribute(.mdCodeBlock, in: charRange) { value, range, _ in
            guard value != nil else { return }
            var blockRange = NSRange()
            _ = storage.attribute(.mdCodeBlock, at: range.location, longestEffectiveRange: &blockRange, in: whole)
            guard let (top, bottom) = verticalExtent(ofCharacters: blockRange) else { return }
            let rect = NSRect(x: origin.x, y: origin.y + top - 2, width: width, height: bottom - top + 4)
            Theme.codeBackground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }

        // Inline code (one pill per line when the span wraps)
        storage.enumerateAttribute(.mdInlineCode, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = self.font(at: range.location)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                let glyphOnLine = self.glyphIndex(for: NSPoint(x: rect.midX, y: rect.midY), in: container)
                let baseline = self.baselineY(forGlyphAt: glyphOnLine)
                let h = font.ascender - font.descender + 3
                var r = rect
                r.origin.x += origin.x - 3
                r.size.width += 6
                r.origin.y = origin.y + baseline - font.ascender - 1.5
                r.size.height = h
                Theme.codeBackground.setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            }
        }

        // Quote bars
        storage.enumerateAttribute(.mdQuote, in: charRange) { value, range, _ in
            guard value != nil else { return }
            var quoteRange = NSRange()
            _ = storage.attribute(.mdQuote, at: range.location, longestEffectiveRange: &quoteRange, in: whole)
            guard let (top, bottom) = verticalExtent(ofCharacters: quoteRange) else { return }
            let s = storage.mutableString
            var markerLoc = quoteRange.location
            while markerLoc < NSMaxRange(quoteRange), s.character(at: markerLoc) != 0x3E { markerLoc += 1 } // ">"
            let g = glyphIndexForCharacter(at: min(markerLoc, storage.length - 1))
            let x = lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + location(forGlyphAt: g).x
            let bar = NSRect(x: origin.x + x + 1, y: origin.y + top + 2, width: 3, height: bottom - top - 4)
            Theme.quoteBar.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Horizontal rules
        storage.enumerateAttribute(.mdRule, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let g = glyphIndexForCharacter(at: range.location)
            let font = self.font(at: range.location)
            let y = origin.y + baselineY(forGlyphAt: g) - font.xHeight / 2
            Theme.rule.setFill()
            NSRect(x: origin.x, y: round(y), width: width, height: 1).fill()
        }

        // Bullets
        storage.enumerateAttribute(.mdBullet, in: charRange) { value, range, _ in
            guard let level = (value as? NSNumber)?.intValue else { return }
            let g = glyphIndexForCharacter(at: range.location)
            let font = self.font(at: range.location)
            let glyphRect = boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
            let cx = origin.x + glyphRect.midX
            let cy = origin.y + baselineY(forGlyphAt: g) - font.xHeight / 2
            let d = max(4, round(font.pointSize * 0.34))
            let dot = NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
            Theme.secondaryText.set()
            switch level % 3 {
            case 0: NSBezierPath(ovalIn: dot).fill()
            case 1:
                let p = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                p.lineWidth = 1.2
                p.stroke()
            default: NSBezierPath(roundedRect: dot.insetBy(dx: 0.5, dy: 0.5), xRadius: 1, yRadius: 1).fill()
            }
        }

        // Checkboxes
        storage.enumerateAttribute(.mdCheckbox, in: charRange) { value, range, _ in
            guard let checked = (value as? NSNumber)?.boolValue else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = self.font(at: range.location)
            let rect = boundingRect(forGlyphRange: glyphs, in: container)
            let side = round(font.pointSize * 1.0)
            let cy = origin.y + baselineY(forGlyphAt: glyphs.location) - font.capHeight / 2
            let box = NSRect(x: origin.x + rect.minX + (rect.width - side) / 2, y: cy - side / 2, width: side, height: side)
            MarkdownLayoutManager.drawCheckbox(in: box, checked: checked)
        }

        // Images
        storage.enumerateAttribute(.mdImage, in: charRange) { value, range, _ in
            guard let box = value as? ImageBox else { return }
            let lastGlyph = glyphIndexForCharacter(at: NSMaxRange(range) - 1)
            let line = lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let rect = NSRect(x: origin.x, y: origin.y + line.maxY - box.size.height - 10,
                              width: box.size.width, height: box.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            box.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            Theme.rule.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
            border.lineWidth = 0.5
            border.stroke()
        }
    }

    private static func drawCheckbox(in box: NSRect, checked: Bool) {
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.5, yRadius: 4.5)
        if checked {
            Theme.accent.setFill()
            path.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + box.width * 0.27, y: box.minY + box.height * 0.52))
            check.line(to: NSPoint(x: box.minX + box.width * 0.44, y: box.minY + box.height * 0.69))
            check.line(to: NSPoint(x: box.minX + box.width * 0.74, y: box.minY + box.height * 0.33))
            check.lineWidth = max(1.6, box.width * 0.12)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            path.lineWidth = 1.3
            Theme.checkboxStroke.setStroke()
            path.stroke()
        }
    }

    // MARK: - Helpers

    private func font(at index: Int) -> NSFont {
        textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
    }

    /// Baseline y (container coordinates) of the line containing `glyph`.
    private func baselineY(forGlyphAt glyph: Int) -> CGFloat {
        lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + location(forGlyphAt: glyph).y
    }

    /// Top and bottom (container coordinates) of the lines holding `chars`, excluding line/paragraph spacing at the bottom.
    private func verticalExtent(ofCharacters chars: NSRange) -> (CGFloat, CGFloat)? {
        guard let storage = textStorage, chars.length > 0 else { return nil }
        var last = NSMaxRange(chars) - 1
        let s = storage.mutableString
        // Skip the trailing newline so we don't pick up the next (empty) line.
        while last > chars.location, s.character(at: last) == 0x0A { last -= 1 }
        let firstGlyph = glyphIndexForCharacter(at: chars.location)
        let lastGlyph = glyphIndexForCharacter(at: last)
        let top = lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil).minY
        var bottom = lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxY
        if let p = storage.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle {
            bottom -= p.lineSpacing
        }
        return (top, bottom)
    }
}
