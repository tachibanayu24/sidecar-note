import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    private var store: NoteStore!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let prefs = Preferences.shared
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = NoteStore(folder: prefs.notesFolder)
        panel = PanelController(store: store)

        buildMainMenu()
        buildStatusItem()
        // Hidden icon: Settings stay reachable with ⌘, while the note is up.
        prefs.$showMenuBarIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in self?.statusItem.isVisible = visible }
            .store(in: &cancellables)

        KeyboardShortcuts.onKeyDown(for: .toggleNote) { [weak self] in self?.panel.toggle() }
        installDevHooks()

        GestureMonitor.shared.onSwipeDown = { [weak self] in self?.panel.toggle() }
        prefs.$gestureEnabled
            .receive(on: DispatchQueue.main)
            .sink { enabled in enabled ? GestureMonitor.shared.start() : GestureMonitor.shared.stop() }
            .store(in: &cancellables)
        // Trackpads re-enumerate after sleep; restart listening so the gesture keeps working.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.prefs.gestureEnabled == true else { return }
                GestureMonitor.shared.restart()
            }
            .store(in: &cancellables)

        // `kill` / `pkill` send SIGTERM, which skips applicationWillTerminate; save before exiting.
        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { NSApp.terminate(nil) }
        sigterm.resume()
        self.sigterm = sigterm

        // Dev builds are launched by tests in the background; never take the keyboard from the user.
        panel.show(takeFocus: !AppInfo.isDevBuild)
    }

    func applicationDidResignActive(_ notification: Notification) {
        store.saveAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.showOrFocus()
        return false
    }

    // MARK: Dev hooks

    /// Dev builds only: lets tests trigger the toggle without synthesizing any keyboard/mouse input, and logs
    /// the resulting focus state. (A notification is not user input, so it is the strictest case — like the gesture.)
    private func installDevHooks() {
        guard AppInfo.isDevBuild else { return }
        observeDev("toggle") { app in
            app.logFocus("before")
            app.panel.panel.allowsKey = true
            app.panel.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { app.logFocus("after") }
        }
        // Preview without stealing the keyboard from whatever the user is doing.
        observeDev("preview") { app in
            app.panel.panel.allowsKey = false
            if app.panel.isShown { app.panel.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.panel.show(takeFocus: false) }
        }
        observeDev("state") { app in app.logFocus("state") }
        observeDev("selftest") { _ in DevSelfTest.run() }
        // Opens Settings, records its size, and closes it again at once.
        observeDev("settings") { app in
            app.openSettings()
            let f = app.settingsWindow?.frame ?? .zero
            DevLog.write("[dev] settings: visible=\(app.settingsWindow?.isVisible == true) size=\(Int(f.width))x\(Int(f.height))")
            app.settingsWindow?.close()
        }
    }

    private func observeDev(_ name: String, _ handler: @escaping @MainActor (AppDelegate) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: .init("SidecarNoteDev." + name), object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }

    private func logFocus(_ label: String) {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        DevLog.write("[dev] \(label): shown=\(panel.isShown) visible=\(panel.panel.isVisible) appActive=\(NSApp.isActive) "
            + "panelKey=\(panel.panel.isKeyWindow) keyWindowIsPanel=\(NSApp.keyWindow === panel.panel) frontmost=\(front)")
    }

    // MARK: Menus

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sidecar Note")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sidecar Note", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    /// Accessory apps show no menu bar, but key equivalents still route through the main menu.
    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Hide", action: #selector(hidePanel), keyEquivalent: "h").target = self
        appMenu.addItem(withTitle: "Quit Sidecar Note", action: #selector(quitWithConfirmation), keyEquivalent: "q").target = self
        main.addItem(submenu: appMenu, title: "Sidecar Note")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "t").target = self
        file.addItem(withTitle: "Close Note", action: #selector(closeNote), keyEquivalent: "w").target = self
        main.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        edit.addItem(find)
        let findNext = NSMenuItem(title: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        edit.addItem(findNext)
        let findPrevious = NSMenuItem(title: "Find Previous", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "G")
        findPrevious.tag = Int(NSFindPanelAction.previous.rawValue)
        edit.addItem(findPrevious)
        main.addItem(submenu: edit, title: "Edit")

        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Bold", action: #selector(MarkdownTextView.toggleBold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(MarkdownTextView.toggleItalic(_:)), keyEquivalent: "i")
        let strike = format.addItem(withTitle: "Strikethrough", action: #selector(MarkdownTextView.toggleStrikethrough(_:)), keyEquivalent: "x")
        strike.keyEquivalentModifierMask = [.command, .shift]
        format.addItem(withTitle: "Code", action: #selector(MarkdownTextView.toggleInlineCode(_:)), keyEquivalent: "e")
        format.addItem(withTitle: "Checkbox", action: #selector(MarkdownTextView.toggleTask(_:)), keyEquivalent: "\r")
        main.addItem(submenu: format, title: "Format")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(increaseFont), keyEquivalent: "+").target = self
        view.addItem(withTitle: "Bigger", action: #selector(increaseFont), keyEquivalent: "=").target = self
        view.addItem(withTitle: "Smaller", action: #selector(decreaseFont), keyEquivalent: "-").target = self
        view.addItem(withTitle: "Actual Size", action: #selector(resetFont), keyEquivalent: "0").target = self
        view.addItem(.separator())
        let next = view.addItem(withTitle: "Next Note", action: #selector(nextNote), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        next.target = self
        let prev = view.addItem(withTitle: "Previous Note", action: #selector(previousNote), keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command, .shift]
        prev.target = self
        let nextCtrl = view.addItem(withTitle: "Next Note", action: #selector(nextNote), keyEquivalent: "\t")
        nextCtrl.keyEquivalentModifierMask = [.control]
        nextCtrl.target = self
        let prevCtrl = view.addItem(withTitle: "Previous Note", action: #selector(previousNote), keyEquivalent: "\t")
        prevCtrl.keyEquivalentModifierMask = [.control, .shift]
        prevCtrl.target = self
        for i in 1...9 {
            let item = view.addItem(withTitle: "Note \(i)", action: #selector(selectNoteByNumber(_:)), keyEquivalent: "\(i)")
            item.tag = i
            item.target = self
        }
        main.addItem(submenu: view, title: "View")

        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectNoteByNumber(_:)) { return menuItem.tag == 9 || menuItem.tag <= store.notes.count }
        return true
    }

    // MARK: Actions

    private var quitArmedUntil: Date?

    /// ⌘Q quits only when pressed twice in a row, so a stray keystroke never closes the note.
    @objc private func quitWithConfirmation() {
        if let until = quitArmedUntil, Date() < until {
            NSApp.terminate(nil)
            return
        }
        guard panel.isShown else {
            NSApp.terminate(nil)
            return
        }
        quitArmedUntil = Date().addingTimeInterval(1.8)
        panel.showToast("Press ⌘Q again to quit")
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func hidePanel() { panel.hide() }
    @objc private func newNote() {
        if !panel.isShown { panel.show() }
        panel.newNote()
    }
    @objc private func closeNote() {
        if let window = NSApp.keyWindow, window === settingsWindow {
            window.performClose(nil)
        } else {
            panel.closeCurrent()
        }
    }
    @objc private func nextNote() { store.selectNext(offset: 1) }
    @objc private func previousNote() { store.selectNext(offset: -1) }
    @objc private func selectNoteByNumber(_ sender: NSMenuItem) {
        // ⌘9 always means "last", like browsers.
        store.select(index: sender.tag == 9 ? store.notes.count - 1 : sender.tag - 1)
    }
    @objc private func increaseFont() { prefs.fontSize = min(Preferences.fontSizeRange.upperBound, prefs.fontSize + 1) }
    @objc private func decreaseFont() { prefs.fontSize = max(Preferences.fontSizeRange.lowerBound, prefs.fontSize - 1) }
    @objc private func resetFont() { prefs.fontSize = Preferences.defaultFontSize }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView { [weak self] url in
                guard let self else { return }
                self.store.changeFolder(to: url)
                self.prefs.notesFolder = url
            }
            // Like the note, a non-activating panel: it takes the keyboard without making the app active,
            // so opening it never depends on macOS agreeing to activate us.
            let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            window.contentViewController = host
            window.setContentSize(host.view.fittingSize)
            window.title = "Sidecar Note Settings"
            window.level = .floating
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        // Hand the keyboard back: to the note if it's up, otherwise to the app used before.
        if panel.isShown {
            panel.showOrFocus()
        } else {
            panel.returnFocusToPreviousApp()
        }
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
