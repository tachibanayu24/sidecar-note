import AppKit

// English-only app: keep system-provided UI (find bar, context menus, shortcut recorder) in English too.
UserDefaults.standard.set(["en"], forKey: "AppleLanguages")

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
