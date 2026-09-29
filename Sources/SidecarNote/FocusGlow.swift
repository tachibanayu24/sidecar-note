import AppKit
import QuartzCore

/// Draws the panel's shadow and, while the note has focus, a soft colored halo around it.
/// The panel's own (system) shadow is off because macOS dims it for inactive windows; drawing it here keeps
/// the panel looking identical whether or not it has focus — only the halo changes.
/// Lives in its own click-through child window so it never blocks clicks around the panel.
final class FocusGlowWindow: NSWindow {
    private let spread: CGFloat = 60
    private let glowView: GlowView

    init(cornerRadius: CGFloat) {
        glowView = GlowView(cornerRadius: cornerRadius, inset: spread)
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        contentView = glowView
        alphaValue = 0
    }

    /// The halo may extend past the screen edge (e.g. under the menu bar when the panel sits at the top);
    /// AppKit would otherwise push the window back on screen and the shadow would no longer line up.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Keeps the shadow wrapped around the panel's frame.
    func follow(_ panelFrame: NSRect) {
        setFrame(panelFrame.insetBy(dx: -spread, dy: -spread), display: false)
    }

    func setLit(_ lit: Bool, animated: Bool = true) {
        glowView.setLit(lit, duration: animated ? (lit ? 0.5 : 0.35) : 0)
    }

    /// Picks another sky for the halo (called each time the note is summoned).
    func shuffleSky() {
        glowView.apply(AuraSky.random(excluding: glowView.sky))
    }
}

/// A halo palette: the upper-left glow, the lower-right glow and a wide soft wash underneath.
private struct AuraSky: Equatable {
    let upper: NSColor
    let lower: NSColor
    let wash: NSColor

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static let all: [AuraSky] = [
        // Night
        AuraSky(upper: c(0.42, 0.52, 1.00), lower: c(0.72, 0.45, 0.95), wash: c(0.22, 0.25, 0.70)),
        // Sunset
        AuraSky(upper: c(1.00, 0.62, 0.36), lower: c(0.96, 0.36, 0.58), wash: c(0.60, 0.30, 0.75)),
        // Clear sky
        AuraSky(upper: c(0.38, 0.74, 1.00), lower: c(0.55, 0.92, 0.98), wash: c(0.30, 0.55, 1.00)),
        // Golden hour
        AuraSky(upper: c(1.00, 0.80, 0.40), lower: c(1.00, 0.56, 0.42), wash: c(0.98, 0.70, 0.55)),
        // Aurora
        AuraSky(upper: c(0.30, 0.95, 0.72), lower: c(0.55, 0.50, 1.00), wash: c(0.20, 0.70, 0.80)),
        // Dawn
        AuraSky(upper: c(1.00, 0.72, 0.80), lower: c(0.62, 0.72, 1.00), wash: c(0.95, 0.80, 0.70)),
    ]

    static func random(excluding current: AuraSky?) -> AuraSky {
        all.filter { $0 != current }.randomElement() ?? all[0]
    }
}

private final class GlowView: NSView {
    private let cornerRadius: CGFloat
    private let inset: CGFloat

    // Outside the panel: the neutral drop shadow / lift, and the colored halo.
    private let outside = CALayer()
    private let dropShadow = CALayer()
    private let highlight = CALayer()
    private let halo = CALayer()
    private let upper = CALayer()
    private let lower = CALayer()
    private let wash = CALayer()
    private let outsideMask = CAShapeLayer()

    // Inside the panel: light caught in the glass along its edge, and a thin colored rim.
    private let inside = CALayer()
    private let innerUpper = CAShapeLayer()
    private let innerLower = CAShapeLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let insideMask = CAShapeLayer()

    private(set) var sky: AuraSky?

    init(cornerRadius: CGFloat, inset: CGFloat) {
        self.cornerRadius = cornerRadius
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true

        // Neumorphic pair: a soft dark shadow falling to the bottom-right and a faint light lift at the top-left.
        configure(dropShadow, radius: 16, opacity: 0.3, offset: CGSize(width: 5, height: -8))
        dropShadow.shadowColor = NSColor.black.cgColor
        configure(highlight, radius: 14, opacity: 0.16, offset: CGSize(width: -5, height: 6))
        highlight.shadowColor = NSColor.white.cgColor
        // A tight halo hugging the glass rather than a wide cloud.
        configure(wash, radius: 12, opacity: 0.18, offset: CGSize(width: 0, height: -4))
        configure(lower, radius: 8, opacity: 0.28, offset: CGSize(width: 2, height: -2))
        configure(upper, radius: 6, opacity: 0.34, offset: CGSize(width: -2, height: 2))
        for l in [wash, lower, upper] { halo.addSublayer(l) }
        for l in [highlight, dropShadow, halo] { outside.addSublayer(l) }
        outsideMask.fillRule = .evenOdd
        outside.mask = outsideMask

        // Inner glow: a ring around the panel whose shadow falls inward, clipped to the panel shape.
        for (l, offset) in [(innerUpper, CGSize(width: 2, height: -2)), (innerLower, CGSize(width: -2, height: 2))] {
            l.fillRule = .evenOdd
            l.fillColor = NSColor.black.cgColor
            l.shadowRadius = 9
            l.shadowOpacity = 0.38
            l.shadowOffset = offset
            inside.addSublayer(l)
        }
        rim.startPoint = CGPoint(x: 0, y: 1)
        rim.endPoint = CGPoint(x: 1, y: 0)
        rim.opacity = 0.5
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 1.2
        rim.mask = rimMask
        inside.addSublayer(rim)
        inside.mask = insideMask

        halo.opacity = 0
        inside.opacity = 0
        layer?.addSublayer(outside)
        layer?.addSublayer(inside)
        apply(AuraSky.all[0])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ l: CALayer, radius: CGFloat, opacity: Float, offset: CGSize) {
        l.shadowRadius = radius
        l.shadowOpacity = opacity
        l.shadowOffset = offset
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateForAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateForAppearance()
    }

    /// A light lift reads well on light backgrounds only; dark mode leans on the shadow instead.
    private func updateForAppearance() {
        let dark = effectiveAppearance.isDark
        highlight.shadowOpacity = dark ? 0.06 : 0.5
        dropShadow.shadowOpacity = dark ? 0.38 : 0.18
    }

    func apply(_ sky: AuraSky) {
        self.sky = sky
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        upper.shadowColor = sky.upper.cgColor
        lower.shadowColor = sky.lower.cgColor
        wash.shadowColor = sky.wash.cgColor
        innerUpper.shadowColor = sky.upper.cgColor
        innerLower.shadowColor = sky.lower.cgColor
        rim.colors = [sky.upper.withAlphaComponent(0.95).cgColor,
                      sky.wash.withAlphaComponent(0.35).cgColor,
                      sky.lower.withAlphaComponent(0.9).cgColor]
        CATransaction.commit()
    }

    func setLit(_ lit: Bool, duration: TimeInterval) {
        let target: Float = lit ? 1 : 0
        for l in [halo, inside] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = l.presentation()?.opacity ?? l.opacity
            fade.toValue = target
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.opacity = target
            l.add(fade, forKey: "fade")
        }
    }

    // The window is resized programmatically; make sure the shadow paths follow every size change.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePaths()
    }

    private func updatePaths() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let panelRect = bounds.insetBy(dx: inset, dy: inset)
        let shape = CGPath(roundedRect: panelRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        for l in [outside, dropShadow, highlight, halo, upper, lower, wash, inside, innerUpper, innerLower, rim] {
            l.frame = bounds
        }
        for l in [dropShadow, highlight, upper, lower, wash] {
            l.shadowPath = shape
        }

        let outsidePath = CGMutablePath()
        outsidePath.addRect(bounds)
        outsidePath.addPath(CGPath(roundedRect: panelRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: cornerRadius,
                                   cornerHeight: cornerRadius, transform: nil))
        outsideMask.frame = bounds
        outsideMask.path = outsidePath

        let ring = CGMutablePath()
        ring.addRect(bounds)
        ring.addPath(shape)
        innerUpper.path = ring
        innerLower.path = ring

        insideMask.frame = bounds
        insideMask.path = shape
        rimMask.frame = bounds
        rimMask.path = CGPath(roundedRect: panelRect.insetBy(dx: 0.6, dy: 0.6), cornerWidth: cornerRadius - 0.6,
                              cornerHeight: cornerRadius - 0.6, transform: nil)
        CATransaction.commit()
    }
}
