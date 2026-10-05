import AppKit
import Combine
import SwiftUI

/// Borderless floating panel that takes keyboard focus without activating the app (like Spotlight), so
/// summoning it never depends on macOS agreeing to activate us. It may also slide past the screen edge.
final class NotePanel: NSPanel {
    /// Dev builds run next to the user's real work: they may only take the keyboard when a test explicitly asks.
    var allowsKey = !AppInfo.isDevBuild
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { true }

    /// Liquid Glass (and glass controls) switch to a lighter "inactive" rendering when the window loses key
    /// status. AppKit asks these (private) hooks which look to use; always answering "active" keeps the panel
    /// identical with or without focus — focus is conveyed only by the halo. Key handling itself is untouched.
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }

    /// The app is usually not active, so ⌘-shortcuts must be routed to the main menu here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the floating note window: layout, show/hide animation, geometry memory.
final class PanelController: NSObject, NSWindowDelegate {
    let panel: NotePanel
    let store: NoteStore
    private let prefs = Preferences.shared

    private let editorHost = FadingTopView()
    private var tabBarHeight: NSLayoutConstraint!
    private let toast = ToastView()
    private let glass = NSGlassEffectView()
    private lazy var glow = FocusGlowWindow(cornerRadius: cornerRadius)
    private var currentEditor: EditorController?
    private var cancellables = Set<AnyCancellable>()

    private(set) var isShown = false
    private var animationGeneration = 0
    private var isAnimating = false
    /// The app to hand focus back to on hide: the last other app that was active.
    private(set) var previousApp: NSRunningApplication?
    private var saveGeometryWork: DispatchWorkItem?

    private let cornerRadius: CGFloat = 24
    /// Tab bar height with tabs, and the thin drag strip left when there is only one note.
    private let tabBarFull: CGFloat = 44
    private let tabBarCollapsed: CGFloat = 16
    private let defaultSize = NSSize(width: 440, height: 580)
    private let minSize = NSSize(width: 300, height: 220)

    init(store: NoteStore) {
        self.store = store
        panel = NotePanel(contentRect: NSRect(origin: .zero, size: defaultSize),
                          styleMask: [.borderless, .resizable, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        super.init()
        configurePanel()
        buildContent()
        bind()
    }

    // MARK: Setup

    private func configurePanel() {
        panel.level = .floating
        // Joins every Space but not full-screen ones (no .fullScreenAuxiliary): hidden over full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The system dims shadows of inactive windows; the glow window draws a constant one instead,
        // so focus changes nothing but the halo.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.minSize = minSize
        panel.delegate = self
    }

    private func buildContent() {
        // Clipped to the rounded shape: the active glass rendering otherwise tints the square corners too.
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = cornerRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        panel.contentView = root

        // Two real Liquid Glass layers, always fully opaque (a faded glass view would show an unblurred desktop
        // through it, which is not glass): Apple's clear glass at the bottom, regular glass above it faded in by
        // the Opacity setting. Both sit behind the content so the text never fades.
        let clearGlass = NSGlassEffectView()
        clearGlass.style = .clear
        clearGlass.cornerRadius = cornerRadius
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        let content = NSView()
        for v in [clearGlass, glass, content] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }

        let tabBarHost = NSHostingView(rootView: TabBar(store: store, onClose: { [weak self] note in self?.close(note) }))
        tabBarHeight = tabBarHost.heightAnchor.constraint(equalToConstant: store.notes.count > 1 ? tabBarFull : tabBarCollapsed)
        for v in [editorHost, tabBarHost, toast] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabBarHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBarHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBarHost.topAnchor.constraint(equalTo: content.topAnchor),
            tabBarHeight,
            editorHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editorHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editorHost.topAnchor.constraint(equalTo: tabBarHost.bottomAnchor),
            editorHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func bind() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0 != NSRunningApplication.current }
            .sink { [weak self] app in self?.previousApp = app }
            .store(in: &cancellables)
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }

        // Displays added / removed / rearranged: bring a visible panel back onto a screen.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.keepOnScreen() }
            .store(in: &cancellables)

        // DispatchQueue.main (not RunLoop.main) so changes also apply while a Settings slider is being dragged.
        store.$selectedID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showSelectedEditor() }
            .store(in: &cancellables)

        // One note: no tab bar, just glass. The bar slides in with the second note.
        store.$notes
            .map { $0.count > 1 }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasTabs in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    ctx.allowsImplicitAnimation = true
                    self.tabBarHeight.animator().constant = hasTabs ? self.tabBarFull : self.tabBarCollapsed
                    self.panel.contentView?.layoutSubtreeIfNeeded()
                }
            }
            .store(in: &cancellables)

        prefs.$opacity.combineLatest(prefs.$theme)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.applyAppearance() }
            .store(in: &cancellables)

        prefs.$focusGlow
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateGlow() }
            .store(in: &cancellables)

        prefs.$fontFamily.combineLatest(prefs.$fontSize)
            .dropFirst()
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.applyFont() }
            .store(in: &cancellables)

        panel.publisher(for: \.effectiveAppearance)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.appearanceChanged() }
            .store(in: &cancellables)

        applyFont(restyle: false)
    }

    private func applyAppearance() {
        panel.appearance = prefs.theme.appearance
        glow.appearance = prefs.theme.appearance
        let base = panel.effectiveAppearance.isDark
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.985, blue: 0.98, alpha: 1)
        // 0 = Apple's clear glass, 0.5 = regular glass, 1 = regular glass with a solid tint.
        let v = prefs.opacity
        glass.alphaValue = min(1, v / 0.5)
        glass.tintColor = v > 0.5 ? base.withAlphaComponent((v - 0.5) / 0.5 * 0.85) : nil
    }

    private func appearanceChanged() {
        applyAppearance()
        let isDark = panel.effectiveAppearance.isDark
        if store.styler.isDark != isDark {
            store.styler.isDark = isDark
            store.restyleAll()
        }
    }

    private func applyFont(restyle: Bool = true) {
        store.styler.family = prefs.fontFamily
        store.styler.size = CGFloat(prefs.fontSize)
        if restyle { store.restyleAll() }
    }

    // MARK: Editor

    private func showSelectedEditor() {
        guard let note = store.selected else { return }
        let editor = note.editor
        guard editor !== currentEditor else { return }
        let old = currentEditor
        currentEditor = editor
        editor.textView.storeImage = { [weak store] data, ext in store?.storeImage(data: data, fileExtension: ext) }
        editor.textView.resolveLink = { [weak store] link in store?.resolve(link) }
        editor.textView.canReopenClosedNote = { [weak store] in store?.canReopen ?? false }
        editor.textView.reopenClosedNote = { [weak store] in store?.reopenLastClosed() }
        editor.restyleIfNeeded()
        let scroll = editor.scrollView
        scroll.frame = editorHost.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.alphaValue = 1
        editorHost.addSubview(scroll)
        updateContentWidth()
        if isShown { focusEditor() }

        guard let old, isShown, !isAnimating else {
            old?.scrollView.removeFromSuperview()
            return
        }
        // Page-like transition: the new note glides in from the side of its tab, the old one drifts away.
        // Only the x origin is animated: the size must keep following the host, which shrinks at the same time
        // when the tab bar slides in with a second note (an animated frame would pin the old, taller size and
        // push the first line up under the tab bar).
        let oldIndex = store.notes.firstIndex { $0.editor === old }
        let newIndex = store.notes.firstIndex { $0.id == note.id } ?? 0
        let forward = oldIndex.map { newIndex > $0 } ?? true
        let shift: CGFloat = forward ? 22 : -22
        let oldScroll = old.scrollView
        scroll.setFrameOrigin(NSPoint(x: shift, y: 0))
        scroll.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            ctx.allowsImplicitAnimation = true
            scroll.animator().setFrameOrigin(.zero)
            scroll.animator().alphaValue = 1
            oldScroll.animator().setFrameOrigin(NSPoint(x: -shift * 0.6, y: 0))
            oldScroll.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Settle on the host's final size whatever happened during the animation.
            self.currentEditor?.scrollView.frame = self.editorHost.bounds
            guard oldScroll !== self.currentEditor?.scrollView else { return }
            oldScroll.removeFromSuperview()
            oldScroll.alphaValue = 1
        })
    }

    private func focusEditor() {
        guard let editor = currentEditor else { return }
        panel.makeFirstResponder(editor.textView)
    }

    private func updateContentWidth() {
        guard let editor = currentEditor else { return }
        let width = editorHost.bounds.width - editor.textView.textContainerInset.width * 2
        if abs(store.styler.contentWidth - width) > 1 {
            store.styler.contentWidth = width
            store.imageWidthChanged()
        }
    }

    // MARK: Tabs

    func newNote() {
        store.newNote()
    }

    func showToast(_ message: String) {
        toast.show(message)
    }

    func closeCurrent() {
        guard let note = store.selected else { return }
        close(note)
    }

    private func close(_ note: Note) {
        switch store.close(note) {
        case .reopenable: toast.show("Closed — ⌘Z to reopen")
        case .failed: toast.show("Couldn’t close — note kept open")
        case .closed: break
        }
    }

    // MARK: Geometry

    private struct Geometry: Codable {
        var width: CGFloat
        var height: CGFloat
        var rightMargin: CGFloat
        var topMargin: CGFloat
    }

    private var geometry: Geometry? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "panelGeometry") else { return nil }
            return try? JSONDecoder().decode(Geometry.self, from: data)
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "panelGeometry")
        }
    }

    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func targetFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let g = geometry ?? Geometry(width: defaultSize.width, height: defaultSize.height, rightMargin: 16,
                                     topMargin: max(16, (vf.height - defaultSize.height) / 2))
        let w = min(max(g.width, minSize.width), vf.width - 16)
        let h = min(max(g.height, minSize.height), vf.height - 16)
        let x = min(max(vf.minX + 8, vf.maxX - g.rightMargin - w), vf.maxX - w - 8)
        let y = min(max(vf.minY + 8, vf.maxY - g.topMargin - h), vf.maxY - h)
        return NSRect(x: round(x), y: round(y), width: round(w), height: round(h))
    }

    /// Where the panel slides from/to. Normally just past the right edge; when another display sits to the
    /// right, a short slide (with the fade) keeps the animation from spilling onto that display.
    private func offscreenFrame(for frame: NSRect, on screen: NSScreen) -> NSRect {
        var f = frame
        f.origin.x = screen.frame.maxX + 24
        let spills = NSScreen.screens.contains { $0 != screen && $0.frame.intersects(f.union(frame)) }
        if spills { f.origin.x = frame.minX + 36 }
        return f
    }

    /// Debounced: window moves arrive for every pixel of a drag.
    private func scheduleGeometrySave() {
        saveGeometryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isShown, !self.isAnimating, let screen = self.panel.screen else { return }
            let vf = screen.visibleFrame
            let f = self.panel.frame
            self.geometry = Geometry(width: f.width, height: f.height,
                                     rightMargin: vf.maxX - f.maxX, topMargin: vf.maxY - f.maxY)
        }
        saveGeometryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func keepOnScreen() {
        guard isShown, !isAnimating,
              !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) else { return }
        panel.setFrame(targetFrame(on: targetScreen()), display: true)
        glow.follow(panel.frame)
    }

    func windowDidMove(_ notification: Notification) {
        glow.follow(panel.frame)
        scheduleGeometrySave()
    }

    func windowDidResize(_ notification: Notification) { glow.follow(panel.frame) }

    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleGeometrySave()
        updateContentWidth()
    }

    // Focus is shown by a halo around the panel, not by changing the glass.
    func windowDidBecomeKey(_ notification: Notification) { updateGlow() }
    func windowDidResignKey(_ notification: Notification) { updateGlow() }

    private func updateGlow() {
        glow.setLit(prefs.focusGlow && isShown && panel.isKeyWindow)
    }

    // MARK: Show / hide

    /// Hotkey & gesture entry point: hidden → show, visible but unfocused → focus, focused → hide.
    func toggle() {
        if !isShown {
            show()
        } else if !panel.isKeyWindow {
            // Not on this Space (e.g. a full-screen app is in front): stay out of the way.
            guard panel.isOnActiveSpace else { return }
            focus()
        } else {
            hide()
        }
    }

    /// Shows the panel, or just focuses it when it is already up.
    func showOrFocus() {
        isShown ? focus() : show()
    }

    /// `takeFocus: false` only for dev previews: shows the panel (halo lit) without taking the keyboard.
    func show(takeFocus: Bool = true) {
        let screen = targetScreen()
        let target = targetFrame(on: screen)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(offscreenFrame(for: target, on: screen), display: false)
        }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.orderFrontRegardless()
        glow.follow(panel.frame)
        // Above the panel: the glass must not sample its own halo (the halo paints the rim itself).
        if glow.parent == nil { panel.addChildWindow(glow, ordered: .above) }
        // The panel joins every Space except full-screen ones, so it isn't on the active Space
        // exactly when a full-screen app is in front.
        guard panel.isOnActiveSpace else {
            orderOutWindows()
            isShown = false
            animationGeneration += 1
            return
        }
        store.reloadChangedFiles()
        glow.shuffleSky()
        animationGeneration += 1
        let generation = animationGeneration
        isShown = true
        isAnimating = true
        if takeFocus {
            focus()
        } else {
            glow.setLit(true, animated: false)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.42
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
            glow.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self, generation == self.animationGeneration else { return }
            self.isAnimating = false
            self.glow.follow(self.panel.frame)
            self.updateContentWidth()
        })
    }

    func hide() {
        guard isShown else { return }
        store.discardSelectedIfBlank()
        store.saveAll()
        animationGeneration += 1
        let generation = animationGeneration
        isShown = false
        isAnimating = true
        let screen = panel.screen ?? targetScreen()
        let wasActive = NSApp.isActive
        glow.setLit(false)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(offscreenFrame(for: panel.frame, on: screen), display: true)
            panel.animator().alphaValue = 0
            glow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, generation == self.animationGeneration else { return }
            self.isAnimating = false
            self.orderOutWindows()
            guard wasActive else { return }
            let otherWindows = NSApp.windows.contains { $0 !== self.panel && $0.isVisible && $0.canBecomeKey }
            if !otherWindows { self.returnFocusToPreviousApp() }
        })
    }

    /// Gives the keyboard back to whatever the user was using before.
    func returnFocusToPreviousApp() {
        if let app = previousApp, !app.isTerminated {
            app.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    private func orderOutWindows() {
        panel.removeChildWindow(glow)
        glow.orderOut(nil)
        panel.orderOut(nil)
    }

    private func focus() {
        panel.makeKeyAndOrderFront(nil)
        focusEditor()
        // Already-key windows (e.g. re-shown mid hide animation) get no becomeKey callback.
        updateGlow()
    }
}

/// A small glass pill message that fades in and out at the bottom of the panel.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        let inner = NSView()
        glass.contentView = inner
        inner.addSubview(label)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ message: String) {
        label.stringValue = message
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

/// Hosts the editor; its top edge fades out so text scrolling up melts into the glass instead of being cut off.
final class FadingTopView: NSView {
    private let fade = CAGradientLayer()
    private let fadeHeight: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        // Layer y grows upward: start at the top edge.
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.mask = fade
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.locations = [0, NSNumber(value: Double(min(1, fadeHeight / max(bounds.height, 1)))), 1]
        CATransaction.commit()
    }
}
