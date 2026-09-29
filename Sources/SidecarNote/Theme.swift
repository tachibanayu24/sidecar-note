import AppKit

enum AppInfo {
    /// `scripts/build-app.sh --dev` builds a separate app (own bundle id, settings and notes) for testing.
    static let isDevBuild = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
}

enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }

    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let marker = NSColor.tertiaryLabelColor
    static let accent = dynamic(light: NSColor(srgbRed: 0.18, green: 0.45, blue: 0.95, alpha: 1),
                                dark: NSColor(srgbRed: 0.45, green: 0.66, blue: 1.0, alpha: 1))
    static let codeBackground = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let inlineCodeText = dynamic(light: NSColor(srgbRed: 0.78, green: 0.22, blue: 0.36, alpha: 1),
                                        dark: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.62, alpha: 1))
    static let quoteBar = dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.2))
    static let rule = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.14))
    static let checkboxStroke = dynamic(light: NSColor(white: 0, alpha: 0.32), dark: NSColor(white: 1, alpha: 0.38))

    static func font(family: FontFamily, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch family {
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case .system:
            return .systemFont(ofSize: size, weight: weight)
        case .rounded, .serif:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let design: NSFontDescriptor.SystemDesign = family == .rounded ? .rounded : .serif
            if let d = base.fontDescriptor.withDesign(design), let f = NSFont(descriptor: d, size: size) { return f }
            return base
        }
    }

    static func mono(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSFont {
    func adding(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: pointSize) ?? self
    }

    func monospacedDigits() -> NSFont {
        let d = fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]],
        ])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

extension NSString {
    /// Line ranges (including terminators) of every line touching `range`; at least one line.
    func lineRanges(in range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var loc = range.location
        repeat {
            let line = lineRange(for: NSRange(location: min(loc, length), length: 0))
            result.append(line)
            loc = NSMaxRange(line)
        } while loc < NSMaxRange(range) && loc < length
        return result
    }

    /// `range` without its trailing line terminator.
    func withoutNewline(_ range: NSRange) -> NSRange {
        var r = range
        while r.length > 0, isNewline(character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
        return r
    }
}

@inline(__always) func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
@inline(__always) func isBlank(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
